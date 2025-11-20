import UIKit

enum TrialState: Int, Codable {
    case notStarted
    case inProgress
    case completed
}

struct TrialUsage: Codable {
    var totalSeconds: TimeInterval
    var state: TrialState
}

enum AccessLevel {
    case locked       // trial over, no subscription
    case trial        // within free minutes
    case subscribed   // has any active sub
}

final class SubscriptionState {
    var isSubscribed: Bool = false  // updated via StoreKit checks
    var trialManager = TrialManager()

    var accessLevel: AccessLevel {
        if isSubscribed {
            return .subscribed
        }
        switch trialManager.state {
        case .completed:
            return .locked
        case .notStarted, .inProgress:
            return .trial
        }
    }
}

final class TrialManager {
    static let TRIAL_LIMIT: TimeInterval = 60 * 3 // 3 minutes
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


