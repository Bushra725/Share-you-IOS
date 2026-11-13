import Foundation
import StoreKit

/// Share you Premium with StoreKit 2 (port of Android's Play Billing `Premium`).
///
/// App Store Connect › Monetization — product ids (same names as Google Play):
///  - Auto-renewable subscriptions (one group "Premium"): zapshare_premium_monthly, zapshare_premium_yearly
///  - Non-consumable: zapshare_premium_lifetime
/// Transactions are verified on device by StoreKit 2 (JWS signature). Premium also unlocks for
/// 24 hours after a rewarded ad (same as Android), kept separate so "Restore" never clears it.
@MainActor
final class StoreService: ObservableObject {
    static let shared = StoreService()

    static let monthly = "zapshare_premium_monthly"
    static let yearly = "zapshare_premium_yearly"
    static let lifetime = "zapshare_premium_lifetime"
    static let allIDs = [monthly, yearly, lifetime]
    private static let adUnlockSeconds: TimeInterval = 24 * 60 * 60

    enum Entitlement { case none, monthly, yearly, lifetime, adTemp, debug }

    @Published private(set) var products: [Product] = []
    @Published private(set) var entitlement: Entitlement = .none
    @Published private(set) var willRenew = true
    @Published private(set) var expiration: Date?
    @Published private(set) var isPremium = false
    @Published var message: String?
    @Published private(set) var purchasing = false
    @Published private(set) var loadingProducts = false

    private var updates: Task<Void, Never>?

    func start() {
        refresh()
        updates?.cancel()
        updates = Task.detached { [weak self] in
            for await result in Transaction.updates {
                if case .verified(let t) = result { await t.finish() }
                await self?.refreshEntitlements()
            }
        }
        Task { await loadProducts() }
        refreshEntitlements()
    }

    func loadProducts() async {
        loadingProducts = true
        defer { loadingProducts = false }
        do {
            let loaded = try await Product.products(for: Self.allIDs)
            products = Self.allIDs.compactMap { id in loaded.first { $0.id == id } }
            if products.isEmpty {
                message = String(localized: "Plans are not available yet. Create the IAP products in App Store Connect, or check your connection and try again.")
            } else if message?.contains("not available") == true {
                message = nil
            }
        } catch {
            message = String(localized: "The App Store is not available right now. \(error.localizedDescription)")
            Log.e("StoreKit products failed", error)
        }
    }

    func product(_ id: String) -> Product? { products.first { $0.id == id } }

    /// Buy the selected plan id. Reloads products if needed and always surfaces a message on failure.
    func purchase(productID: String) async {
        if purchasing { return }
        if product(productID) == nil {
            await loadProducts()
        }
        guard let product = product(productID) else {
            message = String(localized: "This plan could not be loaded from the App Store. Confirm \(productID) exists in App Store Connect and try again.")
            return
        }
        await purchase(product)
    }

    func purchase(_ product: Product) async {
        purchasing = true
        message = nil
        defer { purchasing = false }
        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                guard case .verified(let transaction) = verification else {
                    message = String(localized: "The purchase could not be verified.")
                    return
                }
                await transaction.finish()
                await refreshEntitlementsNow()
                AnalyticsService.log(.purchase, ["product_id": product.id])
                message = nil
            case .pending:
                message = String(localized: "Purchase pending approval.")
            case .userCancelled:
                message = String(localized: "Purchase cancelled.")
            @unknown default:
                message = String(localized: "Purchase did not complete.")
            }
        } catch {
            message = String(localized: "Purchase failed. \(error.localizedDescription)")
            Log.e("StoreKit purchase failed", error)
        }
    }

    /// "Restore purchases" — syncs with the App Store (may ask the user to sign in).
    func restore() async {
        do {
            try await AppStore.sync()
            await refreshEntitlementsNow()
            message = isPurchased ? String(localized: "Purchases restored.") : String(localized: "No previous purchase was found for this Apple ID.")
        } catch {
            message = String(localized: "Restore failed. \(error.localizedDescription)")
        }
    }

    func refreshEntitlements() { Task { await refreshEntitlementsNow() } }

    private var isPurchased: Bool { [.monthly, .yearly, .lifetime].contains(entitlement) }

    func refreshEntitlementsNow() async {
        var best: Entitlement = .none
        var renew = true
        var expires: Date?
        for await result in Transaction.currentEntitlements {
            guard case .verified(let t) = result, t.revocationDate == nil else { continue }
            switch t.productID {
            case Self.lifetime:
                best = .lifetime
            case Self.yearly where best != .lifetime:
                best = .yearly; expires = t.expirationDate
            case Self.monthly where best == .none:
                best = .monthly; expires = t.expirationDate
            default: break
            }
        }
        if best == .monthly || best == .yearly,
           let product = product(best == .yearly ? Self.yearly : Self.monthly),
           let status = try? await product.subscription?.status.first,
           case .verified(let info) = status.renewalInfo {
            renew = info.willAutoRenew
        }
        purchasedEntitlement = best
        willRenew = renew
        expiration = expires
        refresh()
    }

    private var purchasedEntitlement: Entitlement = .none

    /// Rewarded-ad unlock: Premium for 24 hours.
    func grantFromAd() {
        Prefs.shared.premiumAdUntil = Date().addingTimeInterval(Self.adUnlockSeconds)
        refresh()
    }

    /// Debug builds only: test Premium screens without a sandbox account.
    func setDebugPremium(_ on: Bool) {
        Prefs.shared.premiumDebug = on
        refresh()
    }

    func refresh() {
        let prefs = Prefs.shared
        #if DEBUG
        let debug = prefs.premiumDebug
        #else
        let debug = false
        #endif
        if debug { entitlement = .debug }
        else if purchasedEntitlement != .none { entitlement = purchasedEntitlement }
        else if Date() < prefs.premiumAdUntil { entitlement = .adTemp }
        else { entitlement = .none }
        isPremium = entitlement != .none
        CrashReporter.log("premium=\(isPremium)")
    }

    var statusLabel: String {
        switch entitlement {
        case .none: return String(localized: "Free")
        case .debug: return String(localized: "Premium (debug)")
        case .lifetime: return String(localized: "Lifetime")
        case .adTemp: return String(localized: "Premium for 24 hours (ad unlock)")
        case .monthly:
            return willRenew ? String(localized: "Monthly · renews via the App Store")
                             : String(localized: "Monthly · cancelled (active until period ends)")
        case .yearly:
            return willRenew ? String(localized: "Yearly · renews via the App Store")
                             : String(localized: "Yearly · cancelled (active until period ends)")
        }
    }
}
