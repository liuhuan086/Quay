// ServerRepository.swift
import Foundation

final class ServerRepository: @unchecked Sendable {
    private let key: String
    private let enc = JSONEncoder()
    private let dec = JSONDecoder()
    private let keychain: KeychainManager

    init(key: String = "swiftftp.v2.servers", keychain: KeychainManager = .shared) {
        self.key = key
        self.keychain = keychain
        enc.dateEncodingStrategy = .iso8601
        dec.dateDecodingStrategy = .iso8601
    }

    func fetchAll() -> [ServerConfig] {
        guard let data = UserDefaults.standard.data(forKey: key),
              var list = try? dec.decode([ServerConfig].self, from: data) else { return [] }
        var migratedLegacyPassword = false
        for i in list.indices {
            let account = credentialAccount(for: list[i].id)
            if !list[i].password.isEmpty {
                _ = try? keychain.savePassword(list[i].password, for: account)
                list[i].password = ""
                migratedLegacyPassword = true
            }
            list[i].password = (try? keychain.getPassword(for: account)) ?? ""
        }
        if migratedLegacyPassword {
            persist(list)
        }
        return list.sorted { $0.displayName < $1.displayName }
    }

    func save(_ c: ServerConfig) {
        persistCredential(for: c)
        var all = fetchAll()
        var stored = c
        stored.password = ""
        if let i = all.firstIndex(where: { $0.id == c.id }) { all[i] = stored } else { all.append(stored) }
        persist(all)
    }

    func update(_ c: ServerConfig) { save(c) }

    @discardableResult
    func updateLastConnected(for id: UUID, at date: Date) -> ServerConfig? {
        var all = fetchAll()
        guard let i = all.firstIndex(where: { $0.id == id }) else { return nil }
        all[i].lastConnectedAt = date
        let updated = all[i]
        persist(all)
        return updated
    }

    func delete(_ id: UUID) {
        keychain.deletePassword(for: credentialAccount(for: id))
        var all = fetchAll(); all.removeAll { $0.id == id }; persist(all)
    }

    func exportJSON() throws -> Data { try enc.encode(fetchAll()) }

    func importJSON(_ data: Data) throws {
        let incoming = try dec.decode([ServerConfig].self, from: data)
        var all = fetchAll()
        for c in incoming where !all.contains(where: { $0.id == c.id }) {
            persistCredential(for: c)
            var stored = c
            stored.password = ""
            all.append(stored)
        }
        persist(all)
    }

    private func persist(_ list: [ServerConfig]) {
        var sanitized = list
        for i in sanitized.indices {
            sanitized[i].password = ""
        }
        if let d = try? enc.encode(sanitized) { UserDefaults.standard.set(d, forKey: key) }
    }

    private func persistCredential(for config: ServerConfig) {
        let account = credentialAccount(for: config.id)
        if config.password.isEmpty {
            keychain.deletePassword(for: account)
        } else {
            _ = try? keychain.savePassword(config.password, for: account)
        }
    }

    private func credentialAccount(for id: UUID) -> String {
        id.uuidString
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
