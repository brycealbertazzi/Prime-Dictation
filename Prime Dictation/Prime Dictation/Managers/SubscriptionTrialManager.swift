import UIKit

enum SubscriptionSchedule: Int, Codable {
    case none
    case daily
    case monthly
}

struct SubscriptionUsage: Codable {
    var schedule: SubscriptionSchedule
    var dailySecondsUsed: TimeInterval
    var monthlySecondsUsed: TimeInterval
    /// The normalized start of the daily bucket this `dailySecondsUsed` belongs to.
    /// Example: startOfDay in the user's local time.
    var dailyBucketStart: Date?
    /// Last subscription period start we synced from StoreKit (server authoritative).
    var lastPeriodStartFromApple: Date?
    /// Last subscription period end we synced from StoreKit.
    var lastPeriodEndFromApple: Date?
}


enum AccessLevel {
    case locked // trial over, no subscription. No recording allowed
    case trial        // within free minutes
    case subscribed   // has any active sub, has transcription minutes remaining
    case subscription_expired // Has had sub before, but it expired and the user did not renew. Recording and transcription not allowed
}

final class SubscriptionManager {
    static let DAILY_LIMIT: TimeInterval = 20 // 60 minutes
    static let MONTHLY_LIMIT: TimeInterval = 30 // 150 minutes
    var isSubscribed: Bool = false  // updated via StoreKit checks
    var trialManager = TrialManager()
    private let key = "primeDictationSubscriptionUsage"
    private let hasEverSubscribedKey = "primeDictationHasEverSubscribed"

    var accessLevel: AccessLevel {
        if isSubscribed {
            hasEverSubscribed = true
            return .subscribed
        }
        if hasEverSubscribed {
            return .subscription_expired
        }
        switch trialManager.state {
        case .completed:
            return .locked
        case .notStarted, .inProgress:
            return .trial
        }
    }
    
    var usage: SubscriptionUsage {
        get {
            if let data = UserDefaults.standard.data(forKey: key),
               let decoded = try? JSONDecoder().decode(SubscriptionUsage.self, from: data) {
                return decoded
            }
            return SubscriptionUsage(schedule: .none, dailySecondsUsed: 0, monthlySecondsUsed: 0, dailyBucketStart: nil, lastPeriodStartFromApple: nil, lastPeriodEndFromApple: nil)
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: key)
            }
        }
    }
    
    var schedule: SubscriptionSchedule {
        get {
            return usage.schedule
        }
        set {
            var u = usage
            u.schedule = newValue
            usage = u
        }
    }
    
    var hasEverSubscribed: Bool {
        get {
            // Defaults to false if the key doesn't exist yet
            return UserDefaults.standard.bool(forKey: hasEverSubscribedKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: hasEverSubscribedKey)
        }
    }
    
    // Only call when the user is subscribed
    func canTranscribe(recordingSeconds: TimeInterval) -> Bool {
        if accessLevel == .subscription_expired {
            return false
        }
        
        let remainingTranscriptionTimeInSchedulePeriod: TimeInterval = self.remainingTranscriptionTime()
        
        return recordingSeconds <= remainingTranscriptionTimeInSchedulePeriod
    }
    
    /// Add `seconds` to the daily/monthly transcription usage
    func addTranscription(seconds: TimeInterval) {
        var u = usage

        switch u.schedule {
        case .daily:
            u.dailySecondsUsed += seconds
        case .monthly:
            u.monthlySecondsUsed += seconds
        case .none:
            break
        }

        usage = u
    }
    
    // Will only be called when the user is subscribed
    func remainingTranscriptionTime() -> TimeInterval {
        let remaining: TimeInterval
        let zero: TimeInterval = TimeInterval(0)
        print("usage: \(usage)")
        switch usage.schedule {
        case .daily:
            remaining = Self.DAILY_LIMIT - usage.dailySecondsUsed
        case .monthly:
            remaining = Self.MONTHLY_LIMIT - usage.monthlySecondsUsed
        case .none:
            return zero
        }

        return max(zero, remaining)
    }
    
    // Apply StoreKitManager state to this SubscriptionManager
    @MainActor
    func applyStoreKitEntitlements() {
        let manager = StoreKitManager.shared

        if manager.hasLifetimeDeal {
            // Lifetime deal acts like "always subscribed", but no rolling limit
            hasEverSubscribed = true
            isSubscribed = true
            schedule = .none
        } else if manager.activeSubscriptions.contains(.dailyAnnual) ||
                  manager.activeSubscriptions.contains(.dailyMonthly) {
            hasEverSubscribed = true
            isSubscribed = true
            schedule = .daily
        } else if manager.activeSubscriptions.contains(.standardMonthly) {
            hasEverSubscribed = true
            isSubscribed = true
            schedule = .monthly
        } else {
            // No active sub
            isSubscribed = false
            // keep hasEverSubscribed as-is (so we can show "subscription expired" state)
            if !hasEverSubscribed {
                schedule = .none
            }
        }
    }
}

extension SubscriptionManager {
    /// Call this on app launch / foreground with the latest period dates from StoreKit.
    ///
    /// - Parameters:
    ///   - now: Current date (defaults to `Date()`).
    ///   - latestPeriodStart: Latest subscription period start from StoreKit (if any).
    ///   - latestPeriodEnd: Latest subscription period end from StoreKit (if any).
    func refreshBuckets(
        now: Date = Date(),
        latestPeriodStart: Date?,
        latestPeriodEnd: Date?
    ) {
        var u = usage
        let calendar = Calendar.current

        // --- DAILY BUCKET (for 60 min/day plans) ---
        if u.schedule == .daily {
            let todayStart = calendar.startOfDay(for: now)

            if let bucketStart = u.dailyBucketStart {
                // If the stored bucket isn't "today", reset it
                if calendar.compare(bucketStart, to: todayStart, toGranularity: .day) != .orderedSame {
                    u.dailyBucketStart = todayStart
                    u.dailySecondsUsed = 0
                }
            } else {
                // First-time setup
                u.dailyBucketStart = todayStart
                u.dailySecondsUsed = 0
            }
        }

        // --- MONTHLY BUCKET (for 150 min/month plan) ---
        if u.schedule == .monthly {
            // Only act if we actually have fresh data from StoreKit
            if let latestStart = latestPeriodStart, let latestEnd = latestPeriodEnd {
                let isNewPeriod =
                    u.lastPeriodStartFromApple == nil ||
                    u.lastPeriodEndFromApple == nil ||
                    u.lastPeriodStartFromApple! != latestStart ||
                    u.lastPeriodEndFromApple! != latestEnd

                if isNewPeriod {
                    // New StoreKit period => reset monthly usage and store new bounds
                    u.lastPeriodStartFromApple = latestStart
                    u.lastPeriodEndFromApple = latestEnd
                    u.monthlySecondsUsed = 0
                }
            }
        }

        usage = u
    }
}

enum TrialState: Int, Codable {
    case notStarted
    case inProgress
    case completed
}

struct TrialUsage: Codable {
    var totalSeconds: TimeInterval
    var state: TrialState
}

final class TrialManager {
    static let TRIAL_LIMIT: TimeInterval = 10 // 3 minutes
    private let key = "primeDictationTrialUsage"

    var usage: TrialUsage {
        get {
            if let data = UserDefaults.standard.data(forKey: key),
               let decoded = try? JSONDecoder().decode(TrialUsage.self, from: data) {
                return decoded
            }
            return TrialUsage(totalSeconds: 0, state: .notStarted)
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: key)
            }
        }
    }

    var state: TrialState {
        get { usage.state }
        set {
            var u = usage
            u.state = newValue
            usage = u
        }
    }

    /// Add `seconds` to the trial usage
    func addRecording(seconds: TimeInterval) {
        var u = usage
        u.totalSeconds += seconds

        if u.state == .notStarted {
            u.state = .inProgress
        }

        usage = u   // single write, state + totalSeconds together
    }
    
    func remainingFreeTrialTime() -> TimeInterval {
        return Self.TRIAL_LIMIT - usage.totalSeconds
    }
    
    func endFreeTrial() {
        var u = usage
        
        u.state = .completed
        u.totalSeconds = Self.TRIAL_LIMIT
        
        usage = u
    }
    
}


