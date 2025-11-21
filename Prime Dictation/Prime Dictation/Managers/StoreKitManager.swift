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
        case lifetimeDeal       = "pd_ltd_7999"               // 60 min/day forever
    }

    // MARK: - Published state

    /// StoreKit products
    @Published private(set) var products: [ProductID: Product] = [:]

    /// Current entitlements (active subs and LTD)
    @Published private(set) var activeSubscriptions: Set<ProductID> = []
    @Published private(set) var hasLifetimeDeal: Bool = false

    // Convenience
    var hasAnyActiveSub: Bool {
        !activeSubscriptions.isEmpty || hasLifetimeDeal
    }

    /// Max daily minutes based on highest “tier”
    var maxDailyTranscriptionMinutes: Int? {
        if hasLifetimeDeal { return 60 }              // LTD
        if activeSubscriptions.contains(.dailyMonthly) { return 60 }
        if activeSubscriptions.contains(.dailyAnnual) { return 60 }
        // Standard plan is monthly based, not daily
        return nil
    }

    /// Monthly allowance for the Standard Plan
    var monthlyTranscriptionMinutesLimit: Int? {
        if activeSubscriptions.contains(.standardMonthly) { return 150 }
        // You *could* also decide that daily plans imply some monthly equivalent,
        // but per your current design: daily plan is enforced as daily, not monthly.
        return nil
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
        var activeSubs = Set<ProductID>()
        var lifetime = false

        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result else {
                continue
            }

            if let id = ProductID(rawValue: transaction.productID) {
                switch id {
                case .standardMonthly, .dailyMonthly, .dailyAnnual:
                    activeSubs.insert(id)

                case .lifetimeDeal:
                    lifetime = true
                }
            }
        }

        self.activeSubscriptions = activeSubs
        self.hasLifetimeDeal = lifetime
    }
}

@MainActor
extension StoreKitManager {
    enum PurchaseError: Error {
        case productNotLoaded
        case userCancelled
        case failedVerification
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
            // You can choose to handle this state if needed
            break

        @unknown default:
            break
        }
    }
}
