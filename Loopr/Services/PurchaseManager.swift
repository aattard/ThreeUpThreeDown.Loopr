import Foundation
import StoreKit

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Product ID
// ─────────────────────────────────────────────────────────────────────────────
// ⚠️  When you create the app in App Store Connect, change this to match
//     the Product ID you set up there.
//
//     Current (dev / local StoreKit testing):  "com.adamattard.Loopr.lifetime"
//     Future  (App Store Connect):             "io.3up3down.Loopr.lifetime"
// ─────────────────────────────────────────────────────────────────────────────
private let kProductID = "com.adamattard.Loopr.lifetime"

// iCloud KVS key – never change this after shipping or existing trial dates
// will be lost for real users.
private let kTrialStartKey  = "loopr_trial_start_date"
private let kPurchasedKey   = "loopr_purchased"          // local cache only

// How many days the free trial lasts
private let kTrialDays: Double = 7

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Access State
// ─────────────────────────────────────────────────────────────────────────────
enum AccessState {
    case trial(daysRemaining: Int)   // Still in the free trial window
    case expired                     // Trial over, not purchased
    case purchased                   // One-time purchase complete
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - PurchaseManager
// ─────────────────────────────────────────────────────────────────────────────
@MainActor
final class PurchaseManager {

    // Shared singleton – use PurchaseManager.shared everywhere
    static let shared = PurchaseManager()

    // The StoreKit product, loaded once at launch
    private(set) var product: Product?

    // Current access state – read this to decide whether to show paywall
    private(set) var accessState: AccessState = .trial(daysRemaining: 7)

    // True while a purchase or restore is in flight (use to show a spinner)
    private(set) var isLoading = false

    // Set by PaywallViewController so it can be dismissed after purchase
    var onPurchaseSuccess: (() -> Void)?

    private init() {}

    // ─────────────────────────────────────────────────────────────────────
    // MARK: - Public API
    // ─────────────────────────────────────────────────────────────────────

    /// Call once from AppDelegate / SceneDelegate at launch.
    func initialize() async {
        await loadProduct()
        await refreshAccessState()
        // Listen for purchases made outside the app (e.g. family sharing / gifting)
        startTransactionListener()
    }

    /// Returns true if the user is allowed to start a session right now.
    func canStartSession() -> Bool {
        switch accessState {
        case .trial, .purchased: return true
        case .expired:           return false
        }
    }

    /// Initiates the $1.99 purchase flow.
    func purchase() async throws {
        guard let product else {
            throw PurchaseError.productNotFound
        }
        isLoading = true
        defer { isLoading = false }

        let result = try await product.purchase()

        switch result {
        case .success(let verification):
            let transaction = try checkVerified(verification)
            await transaction.finish()
            markPurchased()
        case .userCancelled:
            break   // Nothing to do
        case .pending:
            // Requires parental approval – do nothing for now
            break
        @unknown default:
            break
        }
    }

    /// Restores any previous purchases (required by App Store guidelines).
    func restorePurchases() async {
        isLoading = true
        defer { isLoading = false }

        // AppStore.sync() re-validates all receipts; our transaction listener
        // will fire and call markPurchased() automatically.
        try? await AppStore.sync()
        await refreshAccessState()
    }

    // ─────────────────────────────────────────────────────────────────────
    // MARK: - Trial Date (iCloud KVS + UserDefaults fallback)
    // ─────────────────────────────────────────────────────────────────────

    /// Returns the first-launch date, creating and persisting it if needed.
    func trialStartDate() -> Date {
        let store = NSUbiquitousKeyValueStore.default

        // 1. Check iCloud first (survives reinstalls on same Apple ID)
        if let icloudDate = store.object(forKey: kTrialStartKey) as? Date {
            // Keep local cache in sync
            UserDefaults.standard.set(icloudDate, forKey: kTrialStartKey)
            return icloudDate
        }

        // 2. iCloud not available yet – fall back to UserDefaults
        if let localDate = UserDefaults.standard.object(forKey: kTrialStartKey) as? Date {
            // Opportunistically push to iCloud for next time
            store.set(localDate, forKey: kTrialStartKey)
            store.synchronize()
            return localDate
        }

        // 3. First ever launch – record now in both stores
        let now = Date()
        store.set(now, forKey: kTrialStartKey)
        store.synchronize()
        UserDefaults.standard.set(now, forKey: kTrialStartKey)
        print("🗓 Loopr: Trial started \(now)")
        return now
    }

    /// Days remaining in the trial (0 if expired).
    func trialDaysRemaining() -> Int {
        //return 0  // TEMP: force expired for testing - remove before shipping
        
        let elapsed = Date().timeIntervalSince(trialStartDate())
        let remaining = kTrialDays - elapsed / 86_400
        
        // Round UP remaining partial days (0.01 to 7.99 → 1 to 8)
        // Then subtract 1 to get days remaining (1 to 7)
        if remaining > 0 {
            return min(Int(ceil(remaining)), 7)  // Cap at 7 days max
        } else {
            return 0
        }
    }

    // ─────────────────────────────────────────────────────────────────────
    // MARK: - Private Helpers
    // ─────────────────────────────────────────────────────────────────────

    private func loadProduct() async {
        do {
            let products = try await Product.products(for: [kProductID])
            product = products.first
            if product == nil {
                print("⚠️ Loopr: Product '\(kProductID)' not found – check App Store Connect or local StoreKit config")
            } else {
                print("✅ Loopr: Product loaded – \(product!.displayPrice)")
            }
        } catch {
            print("⚠️ Loopr: Failed to load product – \(error)")
        }
    }

    private func refreshAccessState() async {
        // 1. Check StoreKit transaction history for a valid purchase
        for await result in Transaction.currentEntitlements {
            if case .verified(let transaction) = result,
               transaction.productID == kProductID,
               transaction.revocationDate == nil {
                markPurchased()
                return
            }
        }

        // 2. No purchase found – evaluate trial
        let days = trialDaysRemaining()
        if days > 0 {
            accessState = .trial(daysRemaining: days)
            print("⏳ Loopr: \(days) trial day(s) remaining")
        } else {
            accessState = .expired
            print("🔒 Loopr: Trial expired")
        }
    }

    /// Marks the access state as purchased and persists a local flag.
    private func markPurchased() {
        accessState = .purchased
        UserDefaults.standard.set(true, forKey: kPurchasedKey)
        print("✅ Loopr: Access granted (purchased)")
        onPurchaseSuccess?()
    }

    private func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .unverified:
            throw PurchaseError.failedVerification
        case .verified(let value):
            return value
        }
    }

    /// Listens for transactions that arrive outside the normal purchase flow
    /// (e.g. gifted purchases, family sharing, deferred purchases approved later).
    private func startTransactionListener() {
        Task.detached(priority: .background) { [weak self] in
            for await result in Transaction.updates {
                if case .verified(let transaction) = result,
                   transaction.productID == kProductID,
                   transaction.revocationDate == nil {
                    await transaction.finish()
                    await MainActor.run {
                        self?.markPurchased()
                    }
                }
            }
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Errors
// ─────────────────────────────────────────────────────────────────────────────
enum PurchaseError: LocalizedError {
    case productNotFound
    case failedVerification

    var errorDescription: String? {
        switch self {
        case .productNotFound:
            return "Could not find the product. Please check your internet connection and try again."
        case .failedVerification:
            return "Purchase verification failed. Please try restoring your purchases."
        }
    }
}
