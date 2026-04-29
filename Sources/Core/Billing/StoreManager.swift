// StoreManager.swift — StoreKit 2 purchase and entitlement state
import Foundation
import StoreKit

@MainActor
final class StoreManager: ObservableObject {
    static let proProductID = "com.swiftftp.app.pro"

    @Published private(set) var products: [Product] = []
    @Published private(set) var isPro = false
    @Published private(set) var isLoading = false
    @Published var statusMessage: String?

    private var updatesTask: Task<Void, Never>?

    init() {
        updatesTask = listenForTransactions()
        Task {
            await refreshEntitlements()
            await loadProducts()
        }
    }

    deinit {
        updatesTask?.cancel()
    }

    var proProduct: Product? {
        products.first { $0.id == Self.proProductID }
    }

    func loadProducts() async {
        isLoading = true
        defer { isLoading = false }
        do {
            products = try await Product.products(for: [Self.proProductID])
            if products.isEmpty {
                statusMessage = "未找到 Pro 内购产品，请确认 App Store Connect 配置。"
            }
        } catch {
            statusMessage = "加载购买项目失败：\(error.localizedDescription)"
        }
    }

    func purchasePro() async {
        if proProduct == nil {
            await loadProducts()
        }
        guard let product = proProduct else {
            statusMessage = "Pro 内购产品暂不可用。"
            return
        }

        isLoading = true
        defer { isLoading = false }
        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                let transaction = try Self.verified(verification)
                isPro = true
                statusMessage = "已解锁 Pro。"
                await transaction.finish()
            case .userCancelled:
                statusMessage = nil
            case .pending:
                statusMessage = "购买正在等待确认。"
            @unknown default:
                statusMessage = "购买状态未知，请稍后重试。"
            }
        } catch {
            statusMessage = "购买失败：\(error.localizedDescription)"
        }
    }

    func restorePurchases() async {
        isLoading = true
        defer { isLoading = false }
        do {
            try await AppStore.sync()
            await refreshEntitlements()
            statusMessage = isPro ? "已恢复 Pro 购买。" : "没有找到可恢复的 Pro 购买。"
        } catch {
            statusMessage = "恢复购买失败：\(error.localizedDescription)"
        }
    }

    func refreshEntitlements() async {
        var unlocked = false
        for await result in Transaction.currentEntitlements {
            guard let transaction = try? Self.verified(result),
                  transaction.productID == Self.proProductID,
                  transaction.revocationDate == nil else { continue }
            unlocked = true
        }
        isPro = unlocked
    }

    private func listenForTransactions() -> Task<Void, Never> {
        Task { [weak self] in
            for await result in Transaction.updates {
                guard let self else { return }
                guard let transaction = try? Self.verified(result) else { continue }
                if transaction.productID == Self.proProductID {
                    self.isPro = transaction.revocationDate == nil
                    await transaction.finish()
                }
            }
        }
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
