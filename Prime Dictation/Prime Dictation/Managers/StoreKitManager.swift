import Foundation
import StoreKit

@MainActor
final class StoreKitManager: ObservableObject {
    // MARK: - Singleton
    static let shared = StoreKitManager()
    private init() {}

    // MARK: - Product IDs
    enum ProductID: String, CaseIterable {
        // Subscriptions
        case standardMonthly    = "pd_standard_monthly_499"   // 150 min/month
        case dailyMonthly       = "pd_daily_monthly_1999"     // 60 min/day
        case dailyAnnual        = "pd_daily_annual_9999"      // 60 min/day annual

        // Lifetime Deal (non-consumable IAP)
        case lifetimeDeal       = "pd_lifetime_7999"          // 60 min/day forever
    }

    enum SubscriptionConfig {
        static let subscriptionGroupID = "21837782"  // your real ID
    }

    // MARK: - Published state

    /// StoreKit products
    @Published private(set) var products: [ProductID: Product] = [:]

    /// Current entitlements (active subs and LTD)
    @Published private(set) var activeSubscriptions: Set<ProductID> = []
    @Published private(set) var hasLifetimeDeal: Bool = false

    /// Effective subscription period for the *chosen* plan
    @Published private(set) var currentPeriodStart: Date?
    @Published private(set) var currentPeriodEnd: Date?

    /// The "best" plan we consider active for this user.
    var currentPlan: ProductID? {
        if hasLifetimeDeal { return .lifetimeDeal }
        if activeSubscriptions.contains(.dailyAnnual)   { return .dailyAnnual }
        if activeSubscriptions.contains(.dailyMonthly)  { return .dailyMonthly }
        if activeSubscriptions.contains(.standardMonthly) { return .standardMonthly }
        return nil
    }

    /// Map StoreKit entitlements → your SubscriptionSchedule
    var effectiveSchedule: SubscriptionSchedule {
        if hasLifetimeDeal {
            return .daily
        }
        if activeSubscriptions.contains(.dailyAnnual) ||
            activeSubscriptions.contains(.dailyMonthly) {
            return .daily
        }
        if activeSubscriptions.contains(.standardMonthly) {
            return .monthly
        }
        return .none
    }

    // Convenience
    var hasAnyActiveSub: Bool {
        !activeSubscriptions.isEmpty || hasLifetimeDeal
    }

    /// Max daily minutes based on highest “tier”
    var maxDailyTranscriptionMinutes: Int? {
        if hasLifetimeDeal { return 60 }               // LTD
        if activeSubscriptions.contains(.dailyMonthly) { return 60 }
        if activeSubscriptions.contains(.dailyAnnual)  { return 60 }
        return nil
    }

    /// Monthly allowance for the Standard Plan
    var monthlyTranscriptionMinutesLimit: Int? {
        if activeSubscriptions.contains(.standardMonthly) { return 150 }
        return nil
    }

    private var updatesTask: Task<Void, Never>?

    func startObservingTransactions() {
        // Only start once
        guard updatesTask == nil else { return }

        updatesTask = Task.detached(priority: .background) { [weak self] in
            guard let self else { return }

            for await result in Transaction.updates {
                if case .verified(let transaction) = result {
                    await self.refreshEntitlements()
                    await transaction.finish()
                }
            }
        }
    }

    deinit {
        updatesTask?.cancel()
    }
}

@MainActor
extension StoreKitManager {
    /// Call once on app launch
    func configure() async {
        await loadProducts()
        await refreshEntitlements()
    }

    // MARK: - Load products from App Store

    private func loadProducts() async {
        do {
            let ids = ProductID.allCases.map { $0.rawValue }
            let storeProducts = try await Product.products(for: ids)

            var dict: [ProductID: Product] = [:]
            for product in storeProducts {
                if let id = ProductID(rawValue: product.id) {
                    dict[id] = product
                }
            }
            self.products = dict
        } catch {
            print("⚠️ Failed to load products: \(error)")
        }
    }

    // MARK: - Check current entitlements

    func refreshEntitlements() async {
        var lifetime = false
        let now = Date()

        // Track the *single* best subscription in the group
        var bestSubID: ProductID?
        var bestExpiration: Date?
        var bestStartDate: Date?
        var bestPriority: Int = -1   // higher = better

        // Helper: priority per plan (higher number = higher tier)
        func priority(for id: ProductID) -> Int {
            switch id {
            case .dailyAnnual:   return 3
            case .dailyMonthly:  return 2
            case .standardMonthly: return 1
            case .lifetimeDeal:  return 100
            }
        }

        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result else { continue }

            let productID = transaction.productID
            let purchaseDate = transaction.purchaseDate
            let expirationDate = transaction.expirationDate
            let revocationDate = transaction.revocationDate

            // Skip already-expired just in case
            if let exp = expirationDate, exp <= now {
                continue
            }

            guard let id = ProductID(rawValue: productID) else { continue }

            switch id {
            case .standardMonthly, .dailyMonthly, .dailyAnnual:
                let p = priority(for: id)

                // 1) Prefer higher tier (priority)
                if p > bestPriority {
                    bestPriority  = p
                    bestSubID     = id
                    bestStartDate = purchaseDate
                    bestExpiration = expirationDate
                }
                // 2) If same tier, prefer the later expiration
                else if p == bestPriority {
                    if let exp = expirationDate {
                        if bestExpiration == nil || exp > bestExpiration! {
                            bestSubID     = id
                            bestStartDate = purchaseDate
                            bestExpiration = exp
                        }
                    }
                }

            case .lifetimeDeal:
                lifetime = true
            }
        }

        var activeSubs = Set<ProductID>()
        if let best = bestSubID {
            activeSubs.insert(best)
        }
        print("Storekit Manager: activeSubs-> \(activeSubs)")
        self.activeSubscriptions = activeSubs
        self.hasLifetimeDeal = lifetime
        self.currentPeriodStart = bestStartDate
        self.currentPeriodEnd   = bestExpiration
    }

}

@MainActor
extension StoreKitManager {
    enum PurchaseError: Error {
        case productNotLoaded
        case failedVerification
        case userCancelled
        case pending
        case unknown
    }

    func purchase(_ productID: ProductID) async throws {
        guard let product = products[productID] else {
            throw PurchaseError.productNotLoaded
        }

        let result = try await product.purchase()

        switch result {
        case .success(let verification):
            guard case .verified(let transaction) = verification else {
                throw PurchaseError.failedVerification
            }

            // Update entitlements immediately
            await refreshEntitlements()

            // Finish the transaction
            await transaction.finish()

        case .userCancelled:
            throw PurchaseError.userCancelled

        case .pending:
            throw PurchaseError.pending

        @unknown default:
            throw PurchaseError.unknown
        }
    }

    func applyEntitlements(to subscriptionManager: SubscriptionManager) {
        let oldSchedule = subscriptionManager.schedule
        let newSchedule = effectiveSchedule

        // Basic flags
        let hasSub = hasLifetimeDeal || !activeSubscriptions.isEmpty
        subscriptionManager.isSubscribed = hasSub
        if hasSub {
            subscriptionManager.hasEverSubscribed = true
        }

        // If the plan type changed (daily <-> monthly <-> none),
        // reset BOTH buckets for cleanliness.
        if oldSchedule != newSchedule {
            var usage = subscriptionManager.usage

            usage.dailySecondsUsed = 0
            usage.dailyBucketStart = nil

            // Clear monthly bucket
            usage.monthlySecondsUsed = 0
            usage.lastPeriodStartFromApple = nil
            usage.lastPeriodEndFromApple = nil

            subscriptionManager.usage = usage
        }

        subscriptionManager.schedule = newSchedule

        // Always sync buckets to the latest subscription period info
        subscriptionManager.refreshBuckets(
            now: Date(),
            latestPeriodStart: currentPeriodStart,
            latestPeriodEnd: currentPeriodEnd
        )
    }
}
