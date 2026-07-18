// ServerRepository.swift
import Foundation

final class ServerRepository: @unchecked Sendable {
    enum CredentialPolicy {
        case replace
        case replaceIfNonEmpty
        case preserve
    }

    private let key: String
    private let store: ServerRepositoryStore

    init(key: String = "swiftftp.v2.servers", keychain: any KeychainStoring = KeychainManager.shared) {
        self.key = key
        self.store = ServerRepositoryStore(key: key, keychain: keychain)
    }

    func fetchAll() -> [ServerConfig] {
        Self.fetchAll(from: key)
    }

    func migrateLegacyPasswordsIfNeeded() async {
        await store.migrateLegacyPasswordsIfNeeded()
    }

    func password(for id: UUID) async throws -> String {
        try await store.password(for: id)
    }

    func deletePassword(for id: UUID) async throws {
        try await store.deletePassword(for: id)
    }

    func save(_ c: ServerConfig, credentialPolicy: CredentialPolicy = .replace) async throws {
        try await store.save(c, credentialPolicy: credentialPolicy)
    }

    func update(_ c: ServerConfig, credentialPolicy: CredentialPolicy = .replaceIfNonEmpty) async throws {
        try await store.update(c, credentialPolicy: credentialPolicy)
    }

    @discardableResult
    func updateLastConnected(for id: UUID, at date: Date) async -> ServerConfig? {
        await store.updateLastConnected(for: id, at: date)
    }

    // Deleting a server always succeeds; the Keychain scrub is best-effort.
    // Returns false if the stored credential could not be removed (the server
    // is still deleted) so the caller can surface a non-blocking notice.
    @discardableResult
    func delete(_ id: UUID) async -> Bool {
        await store.delete(id)
    }

    func exportJSON() throws -> Data {
        let exportable = fetchAll().map { config in
            var copy = config
            copy.sshKeyBookmark = nil
            return copy
        }
        return try Self.makeEncoder().encode(exportable)
    }

    func importJSON(_ data: Data) async throws {
        try await store.importJSON(data)
    }

    private static func fetchAll(from key: String) -> [ServerConfig] {
        loadList(from: key)
            .map { config in
                var sanitized = config
                sanitized.password = ""
                return sanitized
            }
            .sorted { $0.displayName < $1.displayName }
    }

    private static func loadList(from key: String) -> [ServerConfig] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let list = try? makeDecoder().decode([ServerConfig].self, from: data) else { return [] }
        return list
    }

    private static func persist(
        _ list: [ServerConfig],
        key: String,
        preservingLegacyPasswordsFrom existing: [ServerConfig] = [],
        strippingLegacyPasswordFor strippedIDs: Set<UUID> = []
    ) {
        // ServerConfig.encode deliberately omits `password`, so a normal
        // encode strips every credential from the blob. Re-inject ONLY the
        // still-unmigrated legacy plaintext — present in the pre-write
        // snapshot and not explicitly stripped — so a Keychain outage cannot
        // let an unrelated write destroy the user's only saved copy. No
        // non-legacy password is ever written: re-injection is driven solely
        // by `existing`, never by `list`.
        var pendingLegacy: [String: String] = [:]
        for config in existing where !config.password.isEmpty {
            guard !strippedIDs.contains(config.id) else { continue }
            pendingLegacy[config.id.uuidString] = config.password
        }

        guard let encoded = try? makeEncoder().encode(list) else { return }

        if pendingLegacy.isEmpty {
            UserDefaults.standard.set(encoded, forKey: key)
            return
        }

        guard var array = (try? JSONSerialization.jsonObject(with: encoded)) as? [[String: Any]] else {
            UserDefaults.standard.set(encoded, forKey: key)
            return
        }
        for i in array.indices {
            if let idString = array[i]["id"] as? String,
               let legacy = pendingLegacy[idString] {
                array[i]["password"] = legacy
            }
        }
        if let patched = try? JSONSerialization.data(withJSONObject: array) {
            UserDefaults.standard.set(patched, forKey: key)
        } else {
            UserDefaults.standard.set(encoded, forKey: key)
        }
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private actor ServerRepositoryStore {
        private let key: String
        private let keychain: any KeychainStoring
        private var blockedCredentialIDsKey: String { "\(key).blockedCredentialIDs" }

        init(key: String, keychain: any KeychainStoring) {
            self.key = key
            self.keychain = keychain
        }

        func migrateLegacyPasswordsIfNeeded() {
            var all = loadList()
            let legacyIndices = all.indices.filter { !all[$0].password.isEmpty }
            guard !legacyIndices.isEmpty else { return }

            var migratedAll = true
            for i in legacyIndices {
                do {
                    try keychain.savePassword(all[i].password, for: credentialAccount(for: all[i].id), label: all[i].displayName)
                    unblockCredential(for: all[i].id)
                    all[i].password = ""
                } catch {
                    migratedAll = false
                }
            }

            // persist() blanks every password before writing, so a partial
            // persist would erase any credential that failed to reach the
            // Keychain. Only rewrite UserDefaults once every legacy credential
            // is safely stored; otherwise leave the plaintext for a later
            // retry (already-saved entries are re-saved idempotently).
            if migratedAll {
                persist(all)
            }
        }

        func password(for id: UUID) throws -> String {
            let account = credentialAccount(for: id)
            var readError: Error?
            if !isCredentialBlocked(id) {
                do {
                    if let password = try keychain.getPassword(for: account) {
                        return password
                    }
                } catch {
                    readError = error
                }
            }

            // No Keychain entry yet — run the all-or-nothing legacy migration
            // (never a per-entry persist, which would drop other legacy
            // credentials), then read back.
            migrateLegacyPasswordsIfNeeded()
            if !isCredentialBlocked(id) {
                do {
                    if let password = try keychain.getPassword(for: account) {
                        return password
                    }
                } catch {
                    readError = error
                }
            }

            // Migration could not reach the Keychain (e.g. locked). Fall back
            // to the still-present legacy plaintext so the connection can
            // proceed, without mutating storage.
            if let legacyPassword = loadList().first(where: { $0.id == id })?.password,
               !legacyPassword.isEmpty {
                return legacyPassword
            }
            if let readError { throw readError }
            return ""
        }

        func deletePassword(for id: UUID) throws {
            let existing = loadList()
            guard keychain.deletePassword(for: credentialAccount(for: id)) else {
                blockCredential(for: id)
                throw ServerRepositoryError.keychainDeleteFailed
            }
            unblockCredential(for: id)
            var all = existing
            if let index = all.firstIndex(where: { $0.id == id }) {
                all[index].password = ""
                persist(all, preservingLegacyPasswordsFrom: existing, strippingLegacyPasswordFor: [id])
            }
        }

        func save(_ config: ServerConfig, credentialPolicy: CredentialPolicy) throws {
            try validate(config)
            migrateLegacyPasswordsIfNeeded()
            let existing = loadList()
            let replacingExisting = existing.contains { $0.id == config.id }
            try persistCredential(
                for: config,
                policy: credentialPolicy,
                shouldDeleteEmptyCredential: replacingExisting
            )
            var all = existing
            var stored = config
            stored.password = ""
            if let index = all.firstIndex(where: { $0.id == config.id }) {
                all[index] = stored
            } else {
                all.append(stored)
            }
            persist(
                all,
                preservingLegacyPasswordsFrom: existing,
                strippingLegacyPasswordFor: strippedLegacyPasswordIDs(for: config, policy: credentialPolicy)
            )
        }

        func update(_ config: ServerConfig, credentialPolicy: CredentialPolicy) throws {
            try save(config, credentialPolicy: credentialPolicy)
        }

        @discardableResult
        func updateLastConnected(for id: UUID, at date: Date) -> ServerConfig? {
            migrateLegacyPasswordsIfNeeded()
            let existing = loadList()
            var all = existing
            guard let index = all.firstIndex(where: { $0.id == id }) else { return nil }
            all[index].lastConnectedAt = date
            let updated = all[index]
            persist(all, preservingLegacyPasswordsFrom: existing)
            return updated
        }

        @discardableResult
        func delete(_ id: UUID) -> Bool {
            let existing = loadList()
            // Best-effort credential scrub. If deletion fails, block future
            // reads for this id so a re-import cannot reuse the stale secret.
            let credentialCleared = keychain.deletePassword(for: credentialAccount(for: id))
            if credentialCleared {
                unblockCredential(for: id)
            } else {
                blockCredential(for: id)
            }
            var all = existing
            all.removeAll { $0.id == id }
            persist(all, preservingLegacyPasswordsFrom: existing, strippingLegacyPasswordFor: [id])
            return credentialCleared
        }

        func importJSON(_ data: Data) throws {
            let incoming = try ServerRepository.makeDecoder().decode([ServerConfig].self, from: data)
            try incoming.forEach(validate)
            migrateLegacyPasswordsIfNeeded()
            let existing = loadList()
            var all = existing
            var strippedIDs: Set<UUID> = []
            var newlyWrittenCredentialIDs: [UUID] = []
            do {
                for config in incoming where !all.contains(where: { $0.id == config.id }) {
                    try persistCredential(for: config, policy: .replace, shouldDeleteEmptyCredential: false)
                    if !config.password.isEmpty {
                        newlyWrittenCredentialIDs.append(config.id)
                    }
                    var stored = config
                    stored.password = ""
                    stored.sshKeyBookmark = nil
                    all.append(stored)
                    strippedIDs.insert(config.id)
                }
            } catch {
                for id in newlyWrittenCredentialIDs {
                    if keychain.deletePassword(for: credentialAccount(for: id)) {
                        unblockCredential(for: id)
                    } else {
                        blockCredential(for: id)
                    }
                }
                throw error
            }
            persist(all, preservingLegacyPasswordsFrom: existing, strippingLegacyPasswordFor: strippedIDs)
        }

        private func loadList() -> [ServerConfig] {
            ServerRepository.loadList(from: key)
        }

        private func persist(
            _ list: [ServerConfig],
            preservingLegacyPasswordsFrom existing: [ServerConfig] = [],
            strippingLegacyPasswordFor strippedIDs: Set<UUID> = []
        ) {
            ServerRepository.persist(
                list,
                key: key,
                preservingLegacyPasswordsFrom: existing,
                strippingLegacyPasswordFor: strippedIDs
            )
        }

        private func persistCredential(
            for config: ServerConfig,
            policy: CredentialPolicy,
            shouldDeleteEmptyCredential: Bool
        ) throws {
            switch policy {
            case .preserve:
                return
            case .replaceIfNonEmpty where config.password.isEmpty:
                return
            case .replace, .replaceIfNonEmpty:
                break
            }

            let account = credentialAccount(for: config.id)
            if config.password.isEmpty {
                guard shouldDeleteEmptyCredential else { return }
                guard keychain.deletePassword(for: account) else {
                    blockCredential(for: config.id)
                    throw ServerRepositoryError.keychainDeleteFailed
                }
                unblockCredential(for: config.id)
            } else {
                try keychain.savePassword(config.password, for: account, label: config.displayName)
                unblockCredential(for: config.id)
            }
        }

        private func credentialAccount(for id: UUID) -> String {
            id.uuidString
        }

        private func validate(_ config: ServerConfig) throws {
            guard !config.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ServerRepositoryError.invalidConfiguration("主机不能为空")
            }
            guard !config.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ServerRepositoryError.invalidConfiguration("用户名不能为空")
            }
            guard (1...65_535).contains(config.port) else {
                throw ServerRepositoryError.invalidConfiguration("端口必须是 1–65535 之间的整数")
            }
        }

        private func isCredentialBlocked(_ id: UUID) -> Bool {
            loadBlockedCredentialIDs().contains(id)
        }

        private func blockCredential(for id: UUID) {
            var ids = loadBlockedCredentialIDs()
            ids.insert(id)
            saveBlockedCredentialIDs(ids)
        }

        private func unblockCredential(for id: UUID) {
            var ids = loadBlockedCredentialIDs()
            guard ids.remove(id) != nil else { return }
            saveBlockedCredentialIDs(ids)
        }

        private func loadBlockedCredentialIDs() -> Set<UUID> {
            guard let raw = UserDefaults.standard.array(forKey: blockedCredentialIDsKey) as? [String] else {
                return []
            }
            return Set(raw.compactMap(UUID.init(uuidString:)))
        }

        private func saveBlockedCredentialIDs(_ ids: Set<UUID>) {
            if ids.isEmpty {
                UserDefaults.standard.removeObject(forKey: blockedCredentialIDsKey)
            } else {
                UserDefaults.standard.set(ids.map(\.uuidString).sorted(), forKey: blockedCredentialIDsKey)
            }
        }

        private func strippedLegacyPasswordIDs(for config: ServerConfig, policy: CredentialPolicy) -> Set<UUID> {
            switch policy {
            case .preserve:
                return []
            case .replaceIfNonEmpty:
                return config.password.isEmpty ? [] : [config.id]
            case .replace:
                return [config.id]
            }
        }
    }
}

enum ServerRepositoryError: LocalizedError {
    case keychainDeleteFailed
    case invalidConfiguration(String)

    var errorDescription: String? {
        switch self {
        case .keychainDeleteFailed:
            return "Keychain 删除失败，请检查应用的沙盒与 Keychain 权限后重试。"
        case .invalidConfiguration(let message):
            return "服务器配置无效：\(message)"
        }
    }
}

// MARK: - NotificationService
@preconcurrency import UserNotifications

final class NotificationService: Sendable {
    func sendTransferComplete(fileName: String, direction: TransferDirection) {
        send(title: direction == .upload ? "上传完成" : "下载完成", body: fileName, sound: .default)
    }
    func sendTransferFailed(fileName: String, error: Error) {
        send(title: "传输失败", body: "\(fileName): \(error.localizedDescription)", sound: .defaultCritical)
    }
    func sendSyncEvent(fileName: String, remotePath: String) {
        send(title: "实时同步", body: "\(fileName) → \(remotePath)", sound: nil)
    }
    private func send(title: String, body: String, sound: UNNotificationSound?) {
        let center = UNUserNotificationCenter.current()
        let c = UNMutableNotificationContent()
        c.title = title; c.body = body
        if let s = sound { c.sound = s }
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil)

        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                center.add(request)
            case .notDetermined:
                center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                    guard granted else { return }
                    center.add(request)
                }
            case .denied:
                break
            @unknown default:
                break
            }
        }
    }
}
