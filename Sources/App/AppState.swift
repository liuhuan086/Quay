// AppState.swift — Swift 6 @MainActor global state
import SwiftUI
import Combine

@MainActor
final class TransferBadgeState: ObservableObject {
    @Published private(set) var activeCount = 0
    @Published private(set) var presentationRequestID: UUID?

    func update(from transfers: [TransferTask]) {
        let count = transfers.filter {
            if case .inProgress = $0.status { return true }
            return false
        }.count
        guard count != activeCount else { return }
        activeCount = count
    }

    func requestPresentation() {
        presentationRequestID = UUID()
    }
}

@MainActor
final class AppState: ObservableObject {
    // MARK: - Published
    @Published var servers: [ServerConfig] = []
    @Published var connectionStates: [UUID: ConnectionState] = [:]
    @Published var transfers: [TransferTask] = []
    @Published var transferBatches: [TransferBatch] = []
    @Published var syncWatchers: [UUID: SyncWatcher] = [:]
    @Published var selectedServerID: UUID?
    @Published var alertItem: AlertItem?
    @Published var lastCompletedTransferServerID: UUID?
    @Published var isAddServerPresented = false
    @Published var isAboutPresented = false
    @Published var isPro = false
    @Published var trialStartedAt: Date? {
        didSet {
            if let trialStartedAt {
                UserDefaults.standard.set(trialStartedAt, forKey: trialStartedAtKey)
            } else {
                UserDefaults.standard.removeObject(forKey: trialStartedAtKey)
            }
        }
    }
    @Published private var entitlementRefreshDate = Date()
    @Published var hasSeenOnboarding: Bool {
        didSet { UserDefaults.standard.set(hasSeenOnboarding, forKey: hasSeenOnboardingKey) }
    }

    // MARK: - Services
    let repository  = ServerRepository()
    let notifications = NotificationService()
    let transferBadgeState = TransferBadgeState()
    let storeManager = StoreManager()
    private let syncWatchersKey = "swiftftp.v2.syncWatchers"
    private let hasSeenOnboardingKey = "hasSeenOnboarding"
    private let trialStartedAtKey = "trialStartedAt"
    private let trialLength: TimeInterval = 7 * 24 * 60 * 60

    // Transfer engine (actor)
    let engine = TransferEngine()

    private var cancellables = Set<AnyCancellable>()

    // MARK: - Init
    init() {
        hasSeenOnboarding = UserDefaults.standard.bool(forKey: hasSeenOnboardingKey)
        trialStartedAt = UserDefaults.standard.object(forKey: trialStartedAtKey) as? Date
        loadServers()
        Task { await migrateLegacyServerPasswordsIfNeeded() }
        loadSyncWatchers()
        wireEngine()
        wireStore()
        wireTrialTimer()
        applyTransferConcurrency()
    }

    // MARK: - Server Management
    func loadServers() { servers = repository.fetchAll() }

    private func migrateLegacyServerPasswordsIfNeeded() async {
        await repository.migrateLegacyPasswordsIfNeeded()
        loadServers()
    }

    func presentAddServer() {
        guard hasFullAccess else {
            alertItem = AlertItem(
                title: "试用已结束",
                message: "SwiftFTP 不提供永久免费版。请开始 7 天试用或购买 Pro 后继续使用。"
            )
            return
        }
        isAddServerPresented = true
    }

    func presentAbout() {
        isAboutPresented = true
    }

    func completeOnboarding() {
        hasSeenOnboarding = true
    }

    func resetOnboarding() {
        hasSeenOnboarding = false
    }

    @discardableResult
    func saveServer(_ config: ServerConfig) async -> Bool {
        guard hasFullAccess || servers.contains(where: { $0.id == config.id }) else {
            alertItem = AlertItem(title: "试用已结束", message: "请购买 Pro 后保存服务器配置。")
            return false
        }
        do {
            try await repository.save(config, credentialPolicy: .replace)
            loadServers()
            return true
        } catch {
            showError(error)
            return false
        }
    }

    var hasFullAccess: Bool {
        isPro || isTrialActive
    }

    var isTrialActive: Bool {
        guard let trialStartedAt else { return false }
        _ = entitlementRefreshDate
        return Date().timeIntervalSince(trialStartedAt) < trialLength
    }

    var trialEndsAt: Date? {
        trialStartedAt?.addingTimeInterval(trialLength)
    }

    var trialDaysRemaining: Int {
        guard let trialEndsAt else { return 0 }
        _ = entitlementRefreshDate
        let remaining = trialEndsAt.timeIntervalSince(Date())
        return max(0, Int(ceil(remaining / (24 * 60 * 60))))
    }

    func startTrial() {
        guard trialStartedAt == nil else { return }
        trialStartedAt = Date()
        entitlementRefreshDate = Date()
        applyTransferConcurrency()
    }

    func updateTransferConcurrencyPreference(_ value: Int) {
        UserDefaults.standard.set(value, forKey: "maxConcurrent")
        applyTransferConcurrency()
    }

    func updateServer(_ config: ServerConfig) async {
        do {
            try await repository.update(config, credentialPolicy: .replaceIfNonEmpty)
            if !config.password.isEmpty {
                await ConnectionPoolRegistry.shared.updateCachedPassword(config.password, forServerID: config.id)
            }
            loadServers()
        } catch {
            showError(error)
        }
    }

    func clearSavedPasswords() async {
        // Best-effort across every server: a single Keychain failure must not
        // leave the rest of the saved passwords on disk. Clear what we can,
        // drop every pool's cached credential, then surface the first failure.
        let serverIDs = servers.map(\.id)
        var firstError: Error?
        for id in serverIDs {
            do {
                try await repository.deletePassword(for: id)
            } catch {
                if firstError == nil { firstError = error }
            }
            await ConnectionPoolRegistry.shared.updateCachedPassword("", forServerID: id)
        }
        loadServers()
        if let firstError {
            showError(firstError)
        }
    }

    func deleteServer(_ config: ServerConfig) async {
        await ConnectionPoolRegistry.shared.removePool(for: config.id)
        let credentialCleared = await repository.delete(config.id)
        connectionStates.removeValue(forKey: config.id)
        syncWatchers = syncWatchers.filter { $0.value.serverID != config.id }
        persistSyncWatchers()
        loadServers()
        if selectedServerID == config.id { selectedServerID = nil }
        if !credentialCleared {
            alertItem = AlertItem(
                title: "服务器已删除",
                message: "已移除该服务器，但保存在 Keychain 中的密码未能清除。SwiftFTP 会阻止该残留项被自动复用，你也可以在“钥匙串访问”中手动删除。"
            )
        }
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

    private func wireStore() {
        storeManager.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        storeManager.$isPro
            .receive(on: RunLoop.main)
            .sink { [weak self] value in
                self?.isPro = value
                self?.applyTransferConcurrency()
            }
            .store(in: &cancellables)
    }

    private func wireTrialTimer() {
        Timer.publish(every: 60, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] now in
                self?.entitlementRefreshDate = now
                self?.applyTransferConcurrency()
            }
            .store(in: &cancellables)
    }

    private func applyTransferConcurrency() {
        let saved = UserDefaults.standard.integer(forKey: "maxConcurrent")
        let requested = saved > 0 ? saved : 3
        let effective = hasFullAccess ? requested : 1
        Task { await engine.updateConcurrent(effective) }
    }

    // MARK: - Connection
    func connect(to server: ServerConfig) async {
        connectionStates[server.id] = .connecting
        do {
            var connectionConfig = server
            if connectionConfig.password.isEmpty {
                connectionConfig.password = try await repository.password(for: server.id)
            }
            let pool = await ConnectionPoolRegistry.shared.pool(for: connectionConfig, maxSize: 5)
            let client = try await pool.borrowClient(password: connectionConfig.password)
            connectionStates[server.id] = .connected(client: client)
            selectedServerID = server.id
            await repository.updateLastConnected(for: server.id, at: Date())
            loadServers()
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
        isAutoSync: Bool = false,
        fileSize: Int64? = nil,
        batchID: UUID? = nil
    ) async {
        let attrs = try? FileManager.default.attributesOfItem(atPath: localURL.path)
        let size  = fileSize ?? (attrs?[.size] as? Int64) ?? 0
        let task  = TransferTask(
            serverID: server.id, serverName: server.displayName,
            direction: direction, localURL: localURL, remotePath: remotePath,
            fileSize: size, isAutoSync: isAutoSync, batchID: batchID
        )
        transfers.append(task)
        transferBadgeState.update(from: transfers)
        await engine.enqueue(task)
    }

    @discardableResult
    func beginTransferBatch(
        server: ServerConfig,
        direction: TransferDirection,
        name: String,
        localRootURL: URL,
        remoteRootPath: String
    ) -> UUID {
        let batch = TransferBatch(
            serverID: server.id,
            serverName: server.displayName,
            direction: direction,
            name: name,
            localRootURL: localRootURL,
            remoteRootPath: remoteRootPath
        )
        transferBatches.append(batch)
        return batch.id
    }

    func finishTransferBatch(id: UUID, expectedFileCount: Int) {
        guard let idx = transferBatches.firstIndex(where: { $0.id == id }) else { return }
        transferBatches[idx].expectedFileCount = expectedFileCount
        transferBatches[idx].isPrepared = true
    }

    func clearCompletedTransfers() async {
        let batchIDsToRemove = Set(transferBatches.filter { isCompletedOrCancelledBatch($0) }.map(\.id))
        await engine.clearCompleted()
        transfers.removeAll { $0.status.isCompletedOrCancelled }
        transferBatches.removeAll { batchIDsToRemove.contains($0.id) }
        transferBadgeState.update(from: transfers)
    }

    func clearUnfinishedTransfers() async {
        let removedIDs = await engine.clearUnfinished()
        transfers.removeAll { removedIDs.contains($0.id) }
        pruneBatchesAfterTaskRemoval()
        transferBadgeState.update(from: transfers)
    }

    func clearAllTransfers() async {
        await engine.clearAll()
        transfers.removeAll()
        transferBatches.removeAll()
        transferBadgeState.update(from: transfers)
    }

    func removeTransfers(matching selection: Set<UUID>) async {
        let taskIDs = taskIDs(matching: selection)
        let removedTaskIDs = await engine.remove(ids: taskIDs)
        transfers.removeAll { removedTaskIDs.contains($0.id) }
        transferBatches.removeAll { selection.contains($0.id) }
        pruneBatchesAfterTaskRemoval()
        transferBadgeState.update(from: transfers)
    }

    func pauseTransfers(matching selection: Set<UUID>) async {
        await engine.pause(ids: taskIDs(matching: selection))
    }

    func resumeTransfers(matching selection: Set<UUID>) async {
        await engine.resume(ids: taskIDs(matching: selection))
    }

    func cancelTransfers(matching selection: Set<UUID>) async {
        await engine.cancel(ids: taskIDs(matching: selection))
    }

    func startOrRetryTransfers(matching selection: Set<UUID>) async {
        await engine.startOrRetry(ids: taskIDs(matching: selection))
    }

    func startOrRetryUnfinishedTransfers() async {
        let ids = Set(transfers.filter { $0.status.isUnfinished }.map(\.id))
        await engine.startOrRetry(ids: ids)
    }

    func discardEmptyTransferBatches(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        let activeBatchIDs = Set(transfers.compactMap(\.batchID))
        transferBatches.removeAll { ids.contains($0.id) && !activeBatchIDs.contains($0.id) }
    }

    private func taskIDs(matching selection: Set<UUID>) -> Set<UUID> {
        guard !selection.isEmpty else { return [] }
        let selectedBatchIDs = Set(transferBatches.map(\.id)).intersection(selection)
        return Set(transfers.filter { task in
            selection.contains(task.id) || task.batchID.map { selectedBatchIDs.contains($0) } == true
        }.map(\.id))
    }

    private func isCompletedOrCancelledBatch(_ batch: TransferBatch) -> Bool {
        guard batch.isPrepared else { return false }
        let tasks = transfers.filter { $0.batchID == batch.id }
        if batch.expectedFileCount == 0 {
            return true
        }
        return !tasks.isEmpty && tasks.allSatisfy { $0.status.isCompletedOrCancelled }
    }

    private func pruneBatchesAfterTaskRemoval() {
        let activeBatchIDs = Set(transfers.compactMap(\.batchID))
        transferBatches.removeAll { batch in
            batch.isPrepared && batch.expectedFileCount > 0 && !activeBatchIDs.contains(batch.id)
        }
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
        if let localized = error as? LocalizedError,
           let description = localized.errorDescription {
            alertItem = AlertItem(title: "错误", message: description)
            return
        }
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
