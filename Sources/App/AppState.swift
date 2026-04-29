// AppState.swift — Swift 6 @MainActor global state
import SwiftUI
import Combine

@MainActor
final class TransferBadgeState: ObservableObject {
    @Published private(set) var activeCount = 0

    func update(from transfers: [TransferTask]) {
        let count = transfers.filter {
            if case .inProgress = $0.status { return true }
            return false
        }.count
        guard count != activeCount else { return }
        activeCount = count
    }
}

@MainActor
final class AppState: ObservableObject {
    // MARK: - Published
    @Published var servers: [ServerConfig] = []
    @Published var connectionStates: [UUID: ConnectionState] = [:]
    @Published var transfers: [TransferTask] = []
    @Published var syncWatchers: [UUID: SyncWatcher] = [:]
    @Published var selectedServerID: UUID?
    @Published var alertItem: AlertItem?
    @Published var lastCompletedTransferServerID: UUID?

    // MARK: - Services
    let repository  = ServerRepository()
    let notifications = NotificationService()
    let transferBadgeState = TransferBadgeState()
    private let syncWatchersKey = "swiftftp.v2.syncWatchers"

    // Transfer engine (actor)
    let engine = TransferEngine()

    private var cancellables = Set<AnyCancellable>()

    // MARK: - Init
    init() {
        loadServers()
        loadSyncWatchers()
        wireEngine()
    }

    // MARK: - Server Management
    func loadServers() { servers = repository.fetchAll() }

    func saveServer(_ config: ServerConfig) {
        repository.save(config)
        loadServers()
    }

    func updateServer(_ config: ServerConfig) {
        repository.update(config)
        loadServers()
    }

    func deleteServer(_ config: ServerConfig) async {
        await ConnectionPoolRegistry.shared.removePool(for: config.id)
        repository.delete(config.id)
        connectionStates.removeValue(forKey: config.id)
        syncWatchers = syncWatchers.filter { $0.value.serverID != config.id }
        persistSyncWatchers()
        loadServers()
        if selectedServerID == config.id { selectedServerID = nil }
    }

    // MARK: - Sync Watchers
    func upsertSyncWatcher(_ watcher: SyncWatcher) {
        syncWatchers[watcher.id] = watcher
        persistSyncWatchers()
    }

    func removeSyncWatcher(_ watcher: SyncWatcher) {
        syncWatchers.removeValue(forKey: watcher.id)
        persistSyncWatchers()
    }

    private func loadSyncWatchers() {
        guard let data = UserDefaults.standard.data(forKey: syncWatchersKey),
              let decoded = try? JSONDecoder().decode([SyncWatcher].self, from: data) else { return }
        syncWatchers = Dictionary(uniqueKeysWithValues: decoded.map { ($0.id, $0) })
    }

    private func persistSyncWatchers() {
        let list = Array(syncWatchers.values)
        if let data = try? JSONEncoder().encode(list) {
            UserDefaults.standard.set(data, forKey: syncWatchersKey)
        }
    }

    // MARK: - Connection
    func connect(to server: ServerConfig) async {
        connectionStates[server.id] = .connecting
        do {
            let pool = await ConnectionPoolRegistry.shared.pool(for: server, maxSize: 5)
            let client = try await pool.borrowClient(password: server.password)
            connectionStates[server.id] = .connected(client: client)
            selectedServerID = server.id
            var updated = server; updated.lastConnectedAt = Date()
            updateServer(updated)
        } catch {
            connectionStates[server.id] = .failed(error)
            showError(error)
        }
    }

    func disconnect(from server: ServerConfig) async {
        await ConnectionPoolRegistry.shared.removePool(for: server.id)
        connectionStates[server.id] = .disconnected
    }

    // MARK: - Enqueue Transfer
    func enqueue(
        server: ServerConfig,
        direction: TransferDirection,
        localURL: URL,
        remotePath: String,
        isAutoSync: Bool = false
    ) async {
        let attrs = try? FileManager.default.attributesOfItem(atPath: localURL.path)
        let size  = (attrs?[.size] as? Int64) ?? 0
        let task  = TransferTask(
            serverID: server.id, serverName: server.displayName,
            direction: direction, localURL: localURL, remotePath: remotePath,
            fileSize: size, isAutoSync: isAutoSync
        )
        transfers.append(task)
        transferBadgeState.update(from: transfers)
        await engine.enqueue(task)
    }

    // MARK: - Engine wiring
    private func wireEngine() {
        let engine = self.engine
        Task {
            await engine.setCallbacks(
                onUpdate: { [weak self] task in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        if let i = self.transfers.firstIndex(where: { $0.id == task.id }) {
                            self.transfers[i] = task
                            self.transferBadgeState.update(from: self.transfers)
                        }
                    }
                },
                onComplete: { [weak self] task in
                    Task { @MainActor [weak self] in
                        self?.notifications.sendTransferComplete(
                            fileName: task.fileName, direction: task.direction)
                        self?.lastCompletedTransferServerID = task.serverID
                    }
                },
                onFailure: { [weak self] task in
                    Task { @MainActor [weak self] in
                        guard case .failed(let message) = task.status else { return }
                        self?.alertItem = AlertItem(
                            title: "传输失败",
                            message: "\(task.fileName)：\(message)"
                        )
                    }
                }
            )
        }
    }

    // MARK: - Alerts
    func showError(_ error: Error) {
        let friendly = FTPError.friendly(error)
        alertItem = AlertItem(title: "错误", message: friendly.errorDescription ?? error.localizedDescription)
    }
}

// MARK: - AlertItem
struct AlertItem: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

// MARK: - TransferEngine callback helper (avoid crossing actor boundary in wireEngine)
extension TransferEngine {
    func setCallbacks(
        onUpdate: @Sendable @escaping (TransferTask) -> Void,
        onComplete: @Sendable @escaping (TransferTask) -> Void,
        onFailure: @Sendable @escaping (TransferTask) -> Void
    ) async {
        self.onUpdate   = onUpdate
        self.onComplete = onComplete
        self.onFailure  = onFailure
    }
}
