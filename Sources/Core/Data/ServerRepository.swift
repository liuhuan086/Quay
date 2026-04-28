// ServerRepository.swift
import Foundation

final class ServerRepository: @unchecked Sendable {
    private let key = "swiftftp.v2.servers"
    private let enc = JSONEncoder()
    private let dec = JSONDecoder()

    init() {
        enc.dateEncodingStrategy = .iso8601
        dec.dateDecodingStrategy = .iso8601
    }

    func fetchAll() -> [ServerConfig] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let list = try? dec.decode([ServerConfig].self, from: data) else { return [] }
        return list.sorted { $0.displayName < $1.displayName }
    }

    func save(_ c: ServerConfig) {
        var all = fetchAll()
        if let i = all.firstIndex(where: { $0.id == c.id }) { all[i] = c } else { all.append(c) }
        persist(all)
    }

    func update(_ c: ServerConfig) { save(c) }

    func delete(_ id: UUID) {
        var all = fetchAll(); all.removeAll { $0.id == id }; persist(all)
    }

    func exportJSON() throws -> Data { try enc.encode(fetchAll()) }

    func importJSON(_ data: Data) throws {
        let incoming = try dec.decode([ServerConfig].self, from: data)
        var all = fetchAll()
        for c in incoming where !all.contains(where: { $0.id == c.id }) { all.append(c) }
        persist(all)
    }

    private func persist(_ list: [ServerConfig]) {
        if let d = try? enc.encode(list) { UserDefaults.standard.set(d, forKey: key) }
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
