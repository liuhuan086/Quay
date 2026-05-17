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
        loadSyncWatchers()
        wireEngine()
        wireStore()
        wireTrialTimer()
        applyTransferConcurrency()
    }

    // MARK: - Server Management
    func loadServers() { servers = repository.fetchAll() }

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

    func saveServer(_ config: ServerConfig) {
        guard hasFullAccess || servers.contains(where: { $0.id == config.id }) else {
            alertItem = AlertItem(title: "试用已结束", message: "请购买 Pro 后保存服务器配置。")
            return
        }
        repository.save(config)
        loadServers()
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
            let pool = await ConnectionPoolRegistry.shared.pool(for: server, maxSize: 5)
            let client = try await pool.borrowClient(password: server.password)
            connectionStates[server.id] = .connected(client: client)
            selectedServerID = server.id
            repository.updateLastConnected(for: server.id, at: Date())
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

    // MARK: - Remote inspection (used by sync safety checks)

    /// Lists a remote directory, borrowing/returning a pooled connection.
    /// A missing directory is reported as empty (no collision) rather than
    /// an error, so a brand-new dedicated remote target is allowed.
    func remoteDirectoryNames(server: ServerConfig, path: String) async throws -> Set<String> {
        let pool = await ConnectionPoolRegistry.shared.pool(for: server, maxSize: 5)
        let client = try await pool.borrowClient(password: server.password)
        defer { Task { await pool.returnClient(client) } }
        do {
            let items = try await client.listDirectory(path)
            return Set(items.map { $0.name })
        } catch where Self.isRemoteMissingDirectoryError(error) {
            return []
        }
    }

    func remoteSnapshot(
        server: ServerConfig,
        path: String,
        matcher: ExclusionMatcher,
        maxItems: Int = 10_000
    ) async throws -> [SyncSnapshotItem] {
        let pool = await ConnectionPoolRegistry.shared.pool(for: server, maxSize: 5)
        let client = try await pool.borrowClient(password: server.password)
        defer { Task { await pool.returnClient(client) } }

        var snapshot: [SyncSnapshotItem] = []

        func walk(remotePath: String, relativePrefix: String) async throws {
            let items: [RemoteFileItem]
            do {
                items = try await client.listDirectory(remotePath)
            } catch where relativePrefix.isEmpty && Self.isRemoteMissingDirectoryError(error) {
                return
            }

            for item in items where item.name != "." && item.name != ".." {
                let relativePath = relativePrefix.isEmpty
                    ? item.name
                    : relativePrefix + "/" + item.name
                if matcher.shouldExclude(relativePath) { continue }
                snapshot.append(
                    SyncSnapshotItem(
                        relativePath: relativePath,
                        isDirectory: item.isDirectory,
                        size: item.size,
                        modifiedDate: item.modifiedDate
                    )
                )
                guard snapshot.count <= maxItems else {
                    throw FTPError.unsupported("远程目录文件过多（超过 \(maxItems) 项），请缩小同步范围。")
                }
                if item.isDirectory {
                    try await walk(remotePath: item.path, relativePrefix: relativePath)
                }
            }
        }

        try await walk(remotePath: path, relativePrefix: "")
        return snapshot
    }

    func createRemoteDirectories(
        server: ServerConfig,
        remoteRoot: String,
        relativeDirectories: [String]
    ) async {
        guard !relativeDirectories.isEmpty else { return }
        do {
            let pool = await ConnectionPoolRegistry.shared.pool(for: server, maxSize: 5)
            let client = try await pool.borrowClient(password: server.password)
            defer { Task { await pool.returnClient(client) } }
            for relative in relativeDirectories.sorted(by: Self.pathDepthAscending) {
                do {
                    try await client.createDirectory(Self.joinRemotePath(root: remoteRoot, relative: relative))
                } catch {
                    // Existing directories commonly surface as errors. File uploads will still
                    // report real permission or missing-parent failures through TransferEngine.
                }
            }
        } catch {
            showError(error)
        }
    }

    /// Best-effort remote modification date for a single file. Returns nil on
    /// any failure so the caller can fall back to normal upload behavior
    /// instead of stalling the user's workflow.
    func remoteFileModifiedDate(server: ServerConfig, remotePath: String) async -> Date? {
        let parent = (remotePath as NSString).deletingLastPathComponent
        let name = (remotePath as NSString).lastPathComponent
        guard !name.isEmpty else { return nil }
        do {
            let pool = await ConnectionPoolRegistry.shared.pool(for: server, maxSize: 5)
            let client = try await pool.borrowClient(password: server.password)
            defer { Task { await pool.returnClient(client) } }
            let items = try await client.listDirectory(parent.isEmpty ? "/" : parent)
            return items.first(where: { $0.name == name })?.modifiedDate
        } catch {
            return nil
        }
    }

    private static func isRemoteMissingDirectoryError(_ error: Error) -> Bool {
        if case FTPError.fileNotFound = error { return true }
        guard case FTPError.badResponse(let message) = error else { return false }
        let lower = message.lowercased()
        return lower.contains("550") && (
            lower.contains("not found") ||
            lower.contains("no such") ||
            lower.contains("not exist") ||
            lower.contains("failed to change directory")
        )
    }

    private static func joinRemotePath(root: String, relative: String) -> String {
        let cleanRoot = root.hasSuffix("/") ? String(root.dropLast()) : root
        let cleanRelative = relative.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return cleanRoot.isEmpty ? "/" + cleanRelative : cleanRoot + "/" + cleanRelative
    }

    private static func pathDepthAscending(_ lhs: String, _ rhs: String) -> Bool {
        let leftDepth = lhs.split(separator: "/").count
        let rightDepth = rhs.split(separator: "/").count
        return leftDepth == rightDepth ? lhs < rhs : leftDepth < rightDepth
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
