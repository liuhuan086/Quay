// StoreManager.swift — StoreKit 2 purchase and entitlement state
import Foundation
import StoreKit

enum AppCapability: Hashable, Sendable {
    case coreFTP
    case cloudIntegrations
}

struct Entitlements: Equatable, Sendable {
    var hasTrialTransaction: Bool = false
    var trialExpiresAt: Date?
    var hasPro: Bool = false
    var hasCloud: Bool = false

    func capabilities(now: Date) -> Set<AppCapability> {
        var result = Set<AppCapability>()
        if hasPro || (trialExpiresAt.map { $0 > now } ?? false) {
            result.insert(.coreFTP)
        }
        if hasCloud {
            result.insert(.cloudIntegrations)
        }
        return result
    }

    func canUseCoreFTP(now: Date) -> Bool {
        capabilities(now: now).contains(.coreFTP)
    }

    func status(now: Date) -> EntitlementStatus {
        if hasPro { return .pro }
        if let trialExpiresAt {
            return trialExpiresAt > now ? .trialActive : .trialExpired
        }
        return hasTrialTransaction ? .trialExpired : .neverStarted
    }
}

enum EntitlementStatus: Equatable, Sendable {
    case neverStarted
    case trialActive
    case trialExpired
    case pro
    case entitlementUnknown
}

enum PurchaseKind: Equatable, Sendable {
    case trial
    case pro

    var displayName: String {
        switch self {
        case .trial: return "7 天试用"
        case .pro: return "Quay Pro"
        }
    }
}

@MainActor
final class StoreManager: ObservableObject {
    static let trialProductID = "com.swiftftp.app.trial7"
    static let proProductID = "com.swiftftp.app.pro"
    static let trialLength: TimeInterval = 7 * 24 * 60 * 60

    @Published private(set) var products: [Product] = []
    @Published private(set) var entitlements = Entitlements()
    @Published private(set) var entitlementStatus: EntitlementStatus = .entitlementUnknown
    @Published private(set) var pendingPurchaseKind: PurchaseKind?
    @Published private(set) var hasCompletedInitialEntitlementRefresh = false
    @Published private(set) var isLoading = false
    @Published private(set) var isRefreshingEntitlements = false
    @Published var statusMessage: String?

    private var updatesTask: Task<Void, Never>?
    private var hasVerifiedEntitlementSnapshot = false
    private let now: @Sendable () -> Date

    init(now: @escaping @Sendable () -> Date = Date.init) {
        self.now = now
        updatesTask = listenForTransactions()
        Task {
            await recoverUnfinishedTransactions()
            await refreshEntitlements()
            await loadProducts()
        }
    }

    deinit {
        updatesTask?.cancel()
    }

    var trialProduct: Product? {
        products.first { $0.id == Self.trialProductID }
    }

    var proProduct: Product? {
        products.first { $0.id == Self.proProductID }
    }

    var proDisplayPrice: String? {
        proProduct?.displayPrice
    }

    var canStartTrial: Bool {
        trialProduct != nil && proProduct != nil
    }

    var isPro: Bool {
        entitlements.hasPro
    }

    func loadProducts() async {
        isLoading = true
        defer { isLoading = false }
        do {
            products = try await Product.products(for: [Self.trialProductID, Self.proProductID])
            let foundIDs = Set(products.map(\.id))
            let missing = [Self.trialProductID, Self.proProductID].filter { !foundIDs.contains($0) }
            if missing.isEmpty {
                if statusMessage?.contains("购买项目") == true {
                    statusMessage = nil
                }
            } else {
                statusMessage = "未找到购买项目：\(missing.joined(separator: "、"))。请确认 App Store Connect 或 StoreKit 配置。"
            }
        } catch {
            statusMessage = "加载购买项目失败：\(error.localizedDescription)"
        }
    }

    @discardableResult
    func purchaseTrial() async -> Bool {
        if trialProduct == nil || proProduct == nil {
            await loadProducts()
        }
        guard proDisplayPrice != nil else {
            statusMessage = "价格仍在加载中，请稍后重试。"
            return false
        }
        guard let product = trialProduct else {
            statusMessage = "7 天试用暂不可用。"
            return false
        }
        return await purchase(product, kind: .trial)
    }

    @discardableResult
    func purchasePro() async -> Bool {
        if proProduct == nil {
            await loadProducts()
        }
        guard let product = proProduct else {
            statusMessage = "Quay Pro 暂不可用。"
            return false
        }
        return await purchase(product, kind: .pro)
    }

    @discardableResult
    func restorePurchases() async -> Bool {
        isLoading = true
        defer { isLoading = false }
        do {
            try await AppStore.sync()
            await refreshEntitlements()
            let hasKnownPurchase = entitlements.hasPro || entitlements.hasTrialTransaction
            statusMessage = hasKnownPurchase
                ? "已完成恢复购买。"
                : "没有找到可恢复的购买。"
            return hasKnownPurchase
        } catch {
            statusMessage = "恢复购买失败：\(error.localizedDescription)"
            return false
        }
    }

    func refreshEntitlements() async {
        isRefreshingEntitlements = true
        defer {
            isRefreshingEntitlements = false
            hasCompletedInitialEntitlementRefresh = true
        }

        var snapshot = Entitlements()
        var hasUnverifiedKnownTransaction = false

        for await result in Transaction.currentEntitlements {
            switch result {
            case .verified(let transaction):
                apply(transaction, to: &snapshot)
            case .unverified(let transaction, _):
                if Self.isKnownProductID(transaction.productID) {
                    hasUnverifiedKnownTransaction = true
                }
            }
        }

        if hasUnverifiedKnownTransaction && snapshot == Entitlements() {
            handleUnknownEntitlements()
            return
        }

        hasVerifiedEntitlementSnapshot = true
        entitlements = snapshot
        entitlementStatus = snapshot.status(now: now())
        clearSatisfiedPendingPurchase()
    }

    private func purchase(_ product: Product, kind: PurchaseKind) async -> Bool {
        isLoading = true
        defer { isLoading = false }
        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                let transaction = try Self.verified(verification)
                guard transaction.productID == product.id else {
                    statusMessage = "收到未知购买项目，未解锁功能。"
                    return false
                }
                applyVerifiedTransaction(transaction)
                pendingPurchaseKind = nil
                statusMessage = kind == .trial ? "7 天试用已开始。" : "已解锁 Quay Pro。"
                await transaction.finish()
                return true
            case .userCancelled:
                statusMessage = nil
                return false
            case .pending:
                pendingPurchaseKind = kind
                statusMessage = "\(kind.displayName) 正在等待批准。"
                return true
            @unknown default:
                statusMessage = "购买状态未知，请稍后重试。"
                return false
            }
        } catch {
            statusMessage = "购买失败：\(error.localizedDescription)"
            return false
        }
    }

    private func listenForTransactions() -> Task<Void, Never> {
        Task { [weak self] in
            for await result in Transaction.updates {
                guard let self else { return }
                guard let transaction = try? Self.verified(result) else {
                    await MainActor.run {
                        self.statusMessage = "收到未验证的交易更新，未解锁功能。"
                    }
                    continue
                }
                guard Self.isKnownProductID(transaction.productID) else {
                    await MainActor.run {
                        self.statusMessage = "收到未知购买项目，未解锁功能。"
                    }
                    continue
                }
                await MainActor.run {
                    self.applyVerifiedTransaction(transaction)
                }
                await transaction.finish()
            }
        }
    }

    private func recoverUnfinishedTransactions() async {
        for await result in Transaction.unfinished {
            guard let transaction = try? Self.verified(result) else {
                statusMessage = "发现未验证的未完成交易，未解锁功能。"
                continue
            }
            guard Self.isKnownProductID(transaction.productID) else {
                statusMessage = "发现未知购买项目的未完成交易，未自动完成。"
                continue
            }
            applyVerifiedTransaction(transaction)
            await transaction.finish()
        }
    }

    private func applyVerifiedTransaction(_ transaction: Transaction) {
        switch transaction.productID {
        case Self.proProductID:
            entitlements.hasPro = transaction.revocationDate == nil
        case Self.trialProductID:
            if transaction.revocationDate == nil {
                entitlements.hasTrialTransaction = true
                entitlements.trialExpiresAt = transaction.purchaseDate.addingTimeInterval(Self.trialLength)
            } else {
                entitlements.hasTrialTransaction = false
                entitlements.trialExpiresAt = nil
            }
        default:
            break
        }
        hasVerifiedEntitlementSnapshot = true
        entitlementStatus = entitlements.status(now: now())
        clearSatisfiedPendingPurchase()
    }

    private func apply(_ transaction: Transaction, to snapshot: inout Entitlements) {
        guard transaction.revocationDate == nil else { return }

        switch transaction.productID {
        case Self.proProductID:
            snapshot.hasPro = true
        case Self.trialProductID:
            snapshot.hasTrialTransaction = true
            let expiresAt = transaction.purchaseDate.addingTimeInterval(Self.trialLength)
            if let current = snapshot.trialExpiresAt {
                snapshot.trialExpiresAt = max(current, expiresAt)
            } else {
                snapshot.trialExpiresAt = expiresAt
            }
        default:
            break
        }
    }

    private func handleUnknownEntitlements() {
        if hasVerifiedEntitlementSnapshot {
            entitlementStatus = entitlements.status(now: now())
            statusMessage = "暂时无法重新校验购买，已沿用本次会话的购买状态。"
        } else {
            entitlementStatus = .entitlementUnknown
            statusMessage = "无法校验购买状态。你可以重试或恢复购买。"
        }
    }

    private func clearSatisfiedPendingPurchase() {
        guard let pendingPurchaseKind else { return }
        switch pendingPurchaseKind {
        case .trial where entitlements.hasTrialTransaction:
            self.pendingPurchaseKind = nil
        case .pro where entitlements.hasPro:
            self.pendingPurchaseKind = nil
        default:
            break
        }
    }

    private static func isKnownProductID(_ productID: String) -> Bool {
        productID == trialProductID || productID == proProductID
    }

    private static func verified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .verified(let value):
            return value
        case .unverified:
            throw StoreError.failedVerification
        }
    }
}

private enum StoreError: LocalizedError {
    case failedVerification

    var errorDescription: String? {
        switch self {
        case .failedVerification:
            return "交易验证失败"
        }
    }
}
