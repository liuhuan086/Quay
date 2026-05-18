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

    init(key: String = "swiftftp.v2.servers", keychain: KeychainManager = .shared) {
        self.key = key
        self.store = ServerRepositoryStore(key: key, keychain: keychain)
    }

    func fetchAll() -> [ServerConfig] {
        Self.fetchAll(from: key)
    }

    func migrateLegacyPasswordsIfNeeded() async {
        await store.migrateLegacyPasswordsIfNeeded()
    }

    func password(for id: UUID) async -> String {
        await store.password(for: id)
    }

    func deletePassword(for id: UUID) async {
        await store.deletePassword(for: id)
    }

    func save(_ c: ServerConfig, credentialPolicy: CredentialPolicy = .replace) async {
        await store.save(c, credentialPolicy: credentialPolicy)
    }

    func update(_ c: ServerConfig, credentialPolicy: CredentialPolicy = .replaceIfNonEmpty) async {
        await store.update(c, credentialPolicy: credentialPolicy)
    }

    @discardableResult
    func updateLastConnected(for id: UUID, at date: Date) async -> ServerConfig? {
        await store.updateLastConnected(for: id, at: date)
    }

    func delete(_ id: UUID) async {
        await store.delete(id)
    }

    func exportJSON() throws -> Data {
        try Self.makeEncoder().encode(fetchAll())
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

    private static func persist(_ list: [ServerConfig], key: String) {
        var sanitized = list
        for i in sanitized.indices {
            sanitized[i].password = ""
        }
        if let data = try? makeEncoder().encode(sanitized) {
            UserDefaults.standard.set(data, forKey: key)
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
        private let keychain: KeychainManager

        init(key: String, keychain: KeychainManager) {
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

        func password(for id: UUID) -> String {
            let account = credentialAccount(for: id)
            if let password = try? keychain.getPassword(for: account) {
                return password
            }

            // No Keychain entry yet — run the all-or-nothing legacy migration
            // (never a per-entry persist, which would drop other legacy
            // credentials), then read back.
            migrateLegacyPasswordsIfNeeded()
            if let password = try? keychain.getPassword(for: account) {
                return password
            }

            // Migration could not reach the Keychain (e.g. locked). Fall back
            // to the still-present legacy plaintext so the connection can
            // proceed, without mutating storage.
            return loadList().first(where: { $0.id == id })?.password ?? ""
        }

        func deletePassword(for id: UUID) {
            keychain.deletePassword(for: credentialAccount(for: id))
        }

        func save(_ config: ServerConfig, credentialPolicy: CredentialPolicy) {
            persistCredential(for: config, policy: credentialPolicy)
            var all = loadList()
            var stored = config
            stored.password = ""
            if let index = all.firstIndex(where: { $0.id == config.id }) {
                all[index] = stored
            } else {
                all.append(stored)
            }
            persist(all)
        }

        func update(_ config: ServerConfig, credentialPolicy: CredentialPolicy) {
            save(config, credentialPolicy: credentialPolicy)
        }

        @discardableResult
        func updateLastConnected(for id: UUID, at date: Date) -> ServerConfig? {
            var all = loadList()
            guard let index = all.firstIndex(where: { $0.id == id }) else { return nil }
            all[index].lastConnectedAt = date
            let updated = all[index]
            persist(all)
            return updated
        }

        func delete(_ id: UUID) {
            keychain.deletePassword(for: credentialAccount(for: id))
            var all = loadList()
            all.removeAll { $0.id == id }
            persist(all)
        }

        func importJSON(_ data: Data) throws {
            let incoming = try ServerRepository.makeDecoder().decode([ServerConfig].self, from: data)
            var all = loadList()
            for config in incoming where !all.contains(where: { $0.id == config.id }) {
                persistCredential(for: config, policy: .replace)
                var stored = config
                stored.password = ""
                all.append(stored)
            }
            persist(all)
        }

        private func loadList() -> [ServerConfig] {
            ServerRepository.loadList(from: key)
        }

        private func persist(_ list: [ServerConfig]) {
            ServerRepository.persist(list, key: key)
        }

        private func persistCredential(for config: ServerConfig, policy: CredentialPolicy) {
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
                keychain.deletePassword(for: account)
            } else {
                try? keychain.savePassword(config.password, for: account, label: config.displayName)
            }
        }

        private func credentialAccount(for id: UUID) -> String {
            id.uuidString
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
