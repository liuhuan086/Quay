// KeychainManager.swift — Swift 6–safe Keychain wrapper
import Foundation
import Security

public final class KeychainManager: Sendable {
    public static let shared = KeychainManager()
    private let service = "com.swiftftp.app"
    private init() {}

    @discardableResult
    public func savePassword(_ password: String, for key: String) throws -> Bool {
        let data = password.data(using: .utf8)!
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service, kSecAttrAccount: key, kSecValueData: data
        ]
        SecItemDelete(query as CFDictionary)
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.saveFailed(status) }
        return true
    }

    public func getPassword(for key: String) throws -> String {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword, kSecAttrService: service,
            kSecAttrAccount: key, kSecReturnData: kCFBooleanTrue!, kSecMatchLimit: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data,
              let pwd = String(data: data, encoding: .utf8) else {
            if status == errSecItemNotFound { return "" }
            throw KeychainError.retrieveFailed(status)
        }
        return pwd
    }

    @discardableResult
    public func deletePassword(for key: String) -> Bool {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: key
        ]
        return SecItemDelete(query as CFDictionary) == errSecSuccess
    }

    public func hasPassword(for key: String) -> Bool {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword, kSecAttrService: service,
            kSecAttrAccount: key, kSecMatchLimit: kSecMatchLimitOne
        ]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }
}

public enum KeychainError: LocalizedError {
    case saveFailed(OSStatus), retrieveFailed(OSStatus)
    public var errorDescription: String? {
        switch self {
        case .saveFailed(let s):    return "Keychain 保存失败 (\(s))"
        case .retrieveFailed(let s):return "Keychain 读取失败 (\(s))"
        }
    }
}
