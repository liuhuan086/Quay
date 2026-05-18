// KeychainManager.swift — Swift 6–safe Keychain wrapper
import Foundation
import Security

public final class KeychainManager: Sendable {
    public static let shared = KeychainManager()
    private let service = "com.swiftftp.app"
    private init() {}

    // Save or update a password in the Data Protection Keychain.
    // `label` appears in Keychain Access as a human-readable name.
    public func savePassword(_ password: String, for key: String, label: String? = nil) throws {
        let data = Data(password.utf8)
        var attributes: [CFString: Any] = [
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        if let label { attributes[kSecAttrLabel] = label }

        let addQuery = searchQuery(for: key).merging(attributes) { _, new in new }
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)

        if addStatus == errSecSuccess { return }
        if addStatus == errSecDuplicateItem {
            let updateStatus = SecItemUpdate(searchQuery(for: key) as CFDictionary, attributes as CFDictionary)
            guard updateStatus == errSecSuccess else { throw KeychainError.saveFailed(updateStatus) }
            return
        }
        throw KeychainError.saveFailed(addStatus)
    }

    // Returns the stored password, or nil if no item exists.
    // On first access, migrates any legacy (non-Data-Protection) item to the modern keychain.
    public func getPassword(for key: String) throws -> String? {
        if let password = try copyPassword(from: searchQuery(for: key)) {
            return password
        }
        // Legacy migration: pre-sandbox items stored without kSecUseDataProtectionKeychain.
        // A sandboxed app legitimately gets errSecMissingEntitlement on the file-based
        // keychain, so tolerate any error here and treat it as "no legacy item".
        guard let legacyPassword = try? copyPassword(from: legacySearchQuery(for: key)) else {
            return nil
        }
        // Only delete the legacy copy after the modern write succeeds — otherwise a
        // transient failure would destroy the only stored copy of the password.
        try savePassword(legacyPassword, for: key)
        SecItemDelete(legacySearchQuery(for: key) as CFDictionary)
        return legacyPassword
    }

    @discardableResult
    public func deletePassword(for key: String) -> Bool {
        let modern = SecItemDelete(searchQuery(for: key) as CFDictionary)
        let legacy = SecItemDelete(legacySearchQuery(for: key) as CFDictionary)
        let modernOK = modern == errSecSuccess || modern == errSecItemNotFound
        let legacyOK = legacy == errSecSuccess || legacy == errSecItemNotFound
        return modernOK && legacyOK
    }

    public func hasPassword(for key: String) -> Bool {
        var q = searchQuery(for: key)
        q[kSecMatchLimit] = kSecMatchLimitOne
        if SecItemCopyMatching(q as CFDictionary, nil) == errSecSuccess { return true }
        var lq = legacySearchQuery(for: key)
        lq[kSecMatchLimit] = kSecMatchLimitOne
        return SecItemCopyMatching(lq as CFDictionary, nil) == errSecSuccess
    }

    // MARK: - Private

    private func copyPassword(from query: [CFString: Any]) throws -> String? {
        var readQuery = query
        readQuery[kSecReturnData] = kCFBooleanTrue
        readQuery[kSecMatchLimit] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(readQuery as CFDictionary, &result)
        // Only "no such item" maps to nil. errSecMissingEntitlement on the modern
        // Data Protection query is a fatal signing/entitlement misconfiguration and
        // must surface — silently returning nil would make every credential appear lost.
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess,
              let data = result as? Data,
              let password = String(data: data, encoding: .utf8) else {
            throw KeychainError.retrieveFailed(status)
        }
        return password
    }

    // Modern Data Protection Keychain (requires App Sandbox + keychain-access-groups entitlement).
    private func searchQuery(for key: String) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: key,
            kSecUseDataProtectionKeychain: kCFBooleanTrue!
        ]
    }

    // Legacy keychain format used before App Sandbox was enforced.
    private func legacySearchQuery(for key: String) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: key
        ]
    }
}

public enum KeychainError: LocalizedError {
    case saveFailed(OSStatus)
    case retrieveFailed(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .saveFailed(let s):    return "Keychain 保存失败 (\(s))"
        case .retrieveFailed(let s): return "Keychain 读取失败 (\(s))"
        }
    }
}
