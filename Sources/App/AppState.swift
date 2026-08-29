// AppState.swift — Swift 6 @MainActor global state
import SwiftUI
import ServiceManagement

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

enum LaunchAtLoginState: Equatable {
    case disabled
    case enabled
    case requiresApproval
    case unavailable

    var isToggleOn: Bool {
        switch self {
        case .enabled, .requiresApproval:
            return true
        case .disabled, .unavailable:
            return false
        }
    }

    var needsApproval: Bool {
        self == .requiresApproval
    }

    var message: String {
        switch self {
        case .disabled:
            return "Quay 不会在你登录 macOS 时自动启动。"
        case .enabled:
            return "Quay 会在你登录 macOS 时自动启动。"
        case .requiresApproval:
            return "已请求登录时启动，但还需要在系统设置的登录项中允许。"
        case .unavailable:
            return "当前系统无法读取登录项状态。"
        }
    }

    static func current() -> LaunchAtLoginState {
        switch SMAppService.mainApp.status {
        case .notRegistered:
            return .disabled
        case .enabled:
            return .enabled
        case .requiresApproval:
            return .requiresApproval
        case .notFound:
            return .unavailable
        @unknown default:
            return .unavailable
        }
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
    @Published var launchAtLoginState: LaunchAtLoginState = .current()
    @Published var hasSeenOnboarding: Bool {
        didSet { UserDefaults.standard.set(hasSeenOnboarding, forKey: hasSeenOnboardingKey) }
    }

    // MARK: - Services
    let repository  = ServerRepository()
    let notifications = NotificationService()
    let transferBadgeState = TransferBadgeState()
    private let syncWatchersKey = "swiftftp.v2.syncWatchers"
    private let hasSeenOnboardingKey = "hasSeenOnboarding"

    // Transfer engine (actor)
    let engine = TransferEngine()

    private var scopedTransferAccessURLsByTaskID: [UUID: URL] = [:]
    private var activeScopedTransferURLsByTaskID: [UUID: URL] = [:]

    // MARK: - Init
    init() {
        hasSeenOnboarding = UserDefaults.standard.bool(forKey: hasSeenOnboardingKey)
        loadServers()
        Task { await migrateLegacyServerPasswordsIfNeeded() }
        loadSyncWatchers()
        wireEngine()
        applyTransferConcurrency()
        refreshLaunchAtLoginStatus()
    }

    // MARK: - Server Management
    func loadServers() { servers = repository.fetchAll() }

    private func migrateLegacyServerPasswordsIfNeeded() async {
        await repository.migrateLegacyPasswordsIfNeeded()
        loadServers()
    }

    func presentAddServer() {
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
        do {
            try await repository.save(config, credentialPolicy: .replace)
            loadServers()
            return true
        } catch {
            showError(error)
            return false
        }
    }

    var shouldShowOnboarding: Bool {
        !hasSeenOnboarding
    }

    func updateTransferConcurrencyPreference(_ value: Int) {
        UserDefaults.standard.set(value, forKey: "maxConcurrent")
        applyTransferConcurrency()
    }

    func refreshLaunchAtLoginStatus() {
        launchAtLoginState = .current()
    }

    func setLaunchAtLoginEnabled(_ isEnabled: Bool) {
        do {
            if isEnabled {
                if launchAtLoginState != .enabled && launchAtLoginState != .requiresApproval {
                    try SMAppService.mainApp.register()
                }
            } else if launchAtLoginState != .disabled && launchAtLoginState != .unavailable {
                try SMAppService.mainApp.unregister()
            }
            refreshLaunchAtLoginStatus()
            if launchAtLoginState.needsApproval {
                alertItem = AlertItem(
                    title: "需要允许登录项",
                message: "请在系统设置的“登录项”中允许 Quay，之后它会在登录 macOS 时自动启动。"
                )
            }
        } catch {
            refreshLaunchAtLoginStatus()
            alertItem = AlertItem(
                title: "登录项设置失败",
                message: error.localizedDescription
            )
        }
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    func updateServer(_ config: ServerConfig) async {
        do {
            let previous = servers.first { $0.id == config.id }
            try await repository.update(config, credentialPolicy: .replaceIfNonEmpty)
            if let previous, connectionSettingsChanged(from: previous, to: config) {
                await ConnectionPoolRegistry.shared.removePool(for: config.id)
                if connectionStates[config.id] != nil {
                    connectionStates[config.id] = .disconnected
                }
            } else if !config.password.isEmpty {
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
        let transferIDs = Set(transfers.filter { $0.serverID == config.id }.map(\.id))
        if !transferIDs.isEmpty {
            let removedIDs = await engine.remove(ids: transferIDs)
            let removedTransfers = transfers.filter { removedIDs.contains($0.id) }
            forgetLocalTransferAccessIfNeeded(for: removedTransfers)
            transfers.removeAll { removedIDs.contains($0.id) }
            pruneBatchesAfterTaskRemoval()
            transferBadgeState.update(from: transfers)
        }
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
                message: "已移除该服务器，但保存在 Keychain 中的密码未能清除。Quay 会阻止该残留项被自动复用，你也可以在“钥匙串访问”中手动删除。"
            )
        }
    }

    private func connectionSettingsChanged(from old: ServerConfig, to new: ServerConfig) -> Bool {
        old.host != new.host
            || old.port != new.port
            || old.username != new.username
            || old.protocol_ != new.protocol_
            || old.useSSHKey != new.useSSHKey
            || old.sshKeyPath != new.sshKeyPath
            || old.sshKeyBookmark != new.sshKeyBookmark
            || old.allowLegacySSHAlgorithms != new.allowLegacySSHAlgorithms
            || old.allowSelfSignedTLS != new.allowSelfSignedTLS
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

    private func applyTransferConcurrency() {
        let saved = UserDefaults.standard.integer(forKey: "maxConcurrent")
        let requested = saved > 0 ? saved : 3
        Task { await engine.updateConcurrent(requested) }
    }

    // MARK: - Connection
    func connect(to server: ServerConfig) async {
        if connectionStates[server.id]?.isConnected == true {
            selectedServerID = server.id
            return
        }
        connectionStates[server.id] = .connecting
        do {
            var connectionConfig = server
            if connectionConfig.password.isEmpty {
                connectionConfig.password = try await repository.password(for: server.id)
            }
            // One client remains reserved for interactive browsing; the other
            // eight match TransferEngine's documented concurrency ceiling.
            let pool = await ConnectionPoolRegistry.shared.pool(for: connectionConfig, maxSize: 9)
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
        batchID: UUID? = nil,
        securityScopedURL: URL? = nil
    ) async {
        if isAutoSync {
            let superseded = transfers.filter {
                $0.isAutoSync
                    && $0.serverID == server.id
                    && $0.direction == direction
                    && $0.remotePath == remotePath
                    && $0.status.isUnfinished
            }
            if !superseded.isEmpty {
                let ids = Set(superseded.map(\.id))
                _ = await engine.remove(ids: ids)
                forgetLocalTransferAccessIfNeeded(for: superseded)
                transfers.removeAll { ids.contains($0.id) }
            }
        }
        let size = fileSize ?? localFileSize(
            for: localURL,
            securityScopedURL: direction == .upload ? securityScopedURL : nil
        )
        let task  = TransferTask(
            serverID: server.id, serverName: server.displayName,
            direction: direction, localURL: localURL, remotePath: remotePath,
            fileSize: size, isAutoSync: isAutoSync, batchID: batchID
        )
        beginLocalTransferAccessIfNeeded(for: task, securityScopedURL: securityScopedURL)
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
        let removedTransfers = transfers.filter { $0.status.isCompletedOrCancelled }
        await engine.clearCompleted()
        forgetLocalTransferAccessIfNeeded(for: removedTransfers)
        transfers.removeAll { $0.status.isCompletedOrCancelled }
        transferBatches.removeAll { batchIDsToRemove.contains($0.id) }
        transferBadgeState.update(from: transfers)
    }

    func clearUnfinishedTransfers() async {
        let removedIDs = await engine.clearUnfinished()
        forgetLocalTransferAccessIfNeeded(for: transfers.filter { removedIDs.contains($0.id) })
        transfers.removeAll { removedIDs.contains($0.id) }
        pruneBatchesAfterTaskRemoval()
        transferBadgeState.update(from: transfers)
    }

    func clearAllTransfers() async {
        await engine.clearAll()
        forgetLocalTransferAccessIfNeeded(for: transfers)
        transfers.removeAll()
        transferBatches.removeAll()
        transferBadgeState.update(from: transfers)
    }

    func removeTransfers(matching selection: Set<UUID>) async {
        let taskIDs = taskIDs(matching: selection)
        let removedTaskIDs = await engine.remove(ids: taskIDs)
        forgetLocalTransferAccessIfNeeded(for: transfers.filter { removedTaskIDs.contains($0.id) })
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
        let ids = taskIDs(matching: selection)
        beginLocalTransferAccessIfNeeded(for: transfers.filter { ids.contains($0.id) })
        await engine.startOrRetry(ids: ids)
    }

    func startOrRetryUnfinishedTransfers() async {
        let ids = Set(transfers.filter { $0.status.isUnfinished }.map(\.id))
        beginLocalTransferAccessIfNeeded(for: transfers.filter { ids.contains($0.id) })
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
                        if task.status == .cancelled {
                            self.forgetLocalTransferAccessIfNeeded(for: task)
                        }
                    }
                },
                onComplete: { [weak self] task in
                    Task { @MainActor [weak self] in
                        self?.endLocalTransferAccessIfNeeded(for: task)
                        self?.notifications.sendTransferComplete(
                            fileName: task.fileName, direction: task.direction)
                        if task.isAutoSync {
                            self?.recordAutoSyncCompletion(task)
                        }
                        self?.lastCompletedTransferServerID = task.serverID
                    }
                },
                onFailure: { [weak self] task in
                    Task { @MainActor [weak self] in
                        self?.endLocalTransferAccessIfNeeded(for: task)
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

    private func beginLocalTransferAccessIfNeeded(for tasks: [TransferTask]) {
        for task in tasks {
            beginLocalTransferAccessIfNeeded(for: task)
        }
    }

    private func beginLocalTransferAccessIfNeeded(for task: TransferTask, securityScopedURL: URL? = nil) {
        guard task.direction == .upload else { return }
        if let securityScopedURL {
            scopedTransferAccessURLsByTaskID[task.id] = securityScopedURL
        }
        guard activeScopedTransferURLsByTaskID[task.id] == nil else { return }
        // Must be the exact URL delivered by the open panel / drag-drop.
        // Standardizing resolves symlinks (e.g. /var→/private/var, /tmp,
        // external volumes) into a path the sandbox extension does not
        // cover, which silently denies access for queued uploads.
        let url = scopedTransferAccessURLsByTaskID[task.id] ?? task.localURL
        if url.startAccessingSecurityScopedResource() {
            scopedTransferAccessURLsByTaskID[task.id] = url
            activeScopedTransferURLsByTaskID[task.id] = url
        }
    }

    private func endLocalTransferAccessIfNeeded(for tasks: [TransferTask]) {
        for task in tasks {
            endLocalTransferAccessIfNeeded(for: task)
        }
    }

    private func endLocalTransferAccessIfNeeded(for task: TransferTask) {
        guard let url = activeScopedTransferURLsByTaskID.removeValue(forKey: task.id) else { return }
        url.stopAccessingSecurityScopedResource()
    }

    private func forgetLocalTransferAccessIfNeeded(for tasks: [TransferTask]) {
        for task in tasks {
            forgetLocalTransferAccessIfNeeded(for: task)
        }
    }

    private func forgetLocalTransferAccessIfNeeded(for task: TransferTask) {
        endLocalTransferAccessIfNeeded(for: task)
        scopedTransferAccessURLsByTaskID.removeValue(forKey: task.id)
        if task.direction == .download && task.status != .completed {
            TransferFileStaging.discardDownload(for: task.localURL)
        }
    }

    private func localFileSize(for localURL: URL, securityScopedURL: URL?) -> Int64 {
        let didStartAccessing = securityScopedURL?.startAccessingSecurityScopedResource() ?? false
        defer {
            if didStartAccessing {
                securityScopedURL?.stopAccessingSecurityScopedResource()
            }
        }
        let attrs = try? FileManager.default.attributesOfItem(atPath: localURL.path)
        return (attrs?[.size] as? Int64) ?? 0
    }

    private func recordAutoSyncCompletion(_ task: TransferTask) {
        let localPath = task.localURL.standardizedFileURL.path
        let candidates = syncWatchers.values.filter { watcher in
            guard watcher.serverID == task.serverID else { return false }
            let root = URL(fileURLWithPath: watcher.localPath, isDirectory: true).standardizedFileURL.path
            return localPath == root || localPath.hasPrefix(root.hasSuffix("/") ? root : root + "/")
        }
        guard let watcher = candidates.max(by: { $0.localPath.count < $1.localPath.count }),
              var updated = syncWatchers[watcher.id] else { return }
        updated.lastSyncAt = Date()
        updated.totalSynced += 1
        syncWatchers[updated.id] = updated
        persistSyncWatchers()
        notifications.sendSyncEvent(fileName: task.fileName, remotePath: task.remotePath)
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
