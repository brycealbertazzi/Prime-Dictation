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
        case lifetimeDeal       = "pd_lifetime_7999"               // 60 min/day forever
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

    var currentPlan: ProductID? {
        if hasLifetimeDeal { return .lifetimeDeal }
        if activeSubscriptions.contains(.dailyAnnual)   { return .dailyAnnual }
        if activeSubscriptions.contains(.dailyMonthly)  { return .dailyMonthly }
        if activeSubscriptions.contains(.standardMonthly) { return .standardMonthly }
        return nil
    }
    
    // Convenience
    var hasAnyActiveSub: Bool {
        !activeSubscriptions.isEmpty || hasLifetimeDeal
    }

    /// Max daily minutes based on highest “tier”
    var maxDailyTranscriptionMinutes: Int? {
        if hasLifetimeDeal { return 60 }              // LTD
        if activeSubscriptions.contains(.dailyMonthly) { return 60 }
        if activeSubscriptions.contains(.dailyAnnual) { return 60 }
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
                // Each `result` is a VerificationResult<Transaction>
                if case .verified(let transaction) = result {
                    // Update your entitlement state
                    await self.refreshEntitlements()

                    // Always finish the transaction
                    await transaction.finish()
                } else {
                    // Unverified – ignore or log
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
        
        // 🔍 TEMP: print subscription group IDs
        for product in products.values {
            if let groupID = product.subscription?.subscriptionGroupID {
                print("💡 Product \(product.id) is in subscription group: \(groupID)")
            } else {
                print("⚠️ Product \(product.id) has no subscription group")
            }
        }
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
        var bestStartDate: Date?   // <- NEW

        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result else { continue }

            let productID = transaction.productID
            let purchaseDate = transaction.purchaseDate
            let expirationDate = transaction.expirationDate
            let revocationDate = transaction.revocationDate

            print("––––––––––––––––––––")
            print("Entitlement for productID: \(productID)")
            print("  purchaseDate : \(purchaseDate)")
            print("  expirationDate: \(String(describing: expirationDate))")
            print("  revocationDate: \(String(describing: revocationDate))")

            // Skip already-expired just in case
            if let exp = expirationDate, exp <= now {
                print("  -> Skipping because it is already expired at \(exp)")
                continue
            }

            guard let id = ProductID(rawValue: productID) else { continue }

            switch id {
            case .standardMonthly, .dailyMonthly, .dailyAnnual:
                // We have multiple, so choose the one with the furthest expiration
                if let exp = expirationDate {
                    if bestExpiration == nil || exp > bestExpiration! {
                        bestExpiration = exp
                        bestStartDate = purchaseDate      // <- capture start
                        bestSubID = id
                        print("  -> Now treating \(id.rawValue) as BEST sub (exp \(exp))")
                    } else {
                        print("  -> Keeping previous best sub: \(bestSubID?.rawValue ?? "nil")")
                    }
                } else {
                    // No expiration? (unlikely for subs) – fall back to latest purchaseDate
                    if bestExpiration == nil, let currentBest = bestSubID {
                        print("  -> No expiration, but already have best: \(currentBest.rawValue)")
                    } else if bestSubID == nil {
                        bestSubID = id
                        bestStartDate = purchaseDate      // <- capture start
                        print("  -> Treating \(id.rawValue) as best sub (no expiration)")
                    }
                }

            case .lifetimeDeal:
                print("  -> Treating as lifetime deal")
                lifetime = true
            }
        }

        var activeSubs = Set<ProductID>()
        if let best = bestSubID {
            activeSubs.insert(best)
        }

        print("StoreKitManager: refreshed entitlements")
        print("  activeSubs: \(activeSubs)")
        print("  lifetime: \(lifetime)")
        print("  periodStart: \(String(describing: bestStartDate))")
        print("  periodEnd: \(String(describing: bestExpiration))")

        self.activeSubscriptions = activeSubs
        self.hasLifetimeDeal = lifetime
        self.currentPeriodStart = bestStartDate
        self.currentPeriodEnd = bestExpiration
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
            // User closed the sheet / backed out
            throw PurchaseError.userCancelled

        case .pending:
            // Family approval, Ask to Buy, etc
            throw PurchaseError.pending

        @unknown default:
            throw PurchaseError.unknown
        }
    }

}
