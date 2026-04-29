// TransferEngine.swift
// Drives the transfer queue: parallel workers, resume, auto-retry.
// Swift 6–safe actor.
import Foundation

// MARK: - TransferEngine
actor TransferEngine {
    // MARK: Config
    var maxConcurrent: Int = 3
    private let retryDelay: TimeInterval = 2.0

    // MARK: State
    private var tasks: [TransferTask] = []
    private var runningIDs: Set<UUID> = []
    private var runningTasks: [UUID: Task<Void, Never>] = [:]

    // MARK: Callbacks (Sendable closures → safe across actors)
    var onUpdate: (@Sendable (TransferTask) -> Void)?
    var onComplete: (@Sendable (TransferTask) -> Void)?
    var onFailure: (@Sendable (TransferTask) -> Void)?

    // MARK: - Enqueue
    func enqueue(_ task: TransferTask) {
        tasks.append(task)
        drainQueue()
    }

    func updateConcurrent(_ n: Int) {
        maxConcurrent = min(max(n, 1), 8)
        drainQueue()
    }

    // MARK: - Pause / Cancel
    func cancel(id: UUID) {
        runningTasks[id]?.cancel()
        runningTasks.removeValue(forKey: id)
        runningIDs.remove(id)
        if let idx = tasks.firstIndex(where: { $0.id == id }) {
            tasks[idx].status = .cancelled
            notifyUpdate(tasks[idx])
        }
        drainQueue()
    }

    func pause(id: UUID) {
        runningTasks[id]?.cancel()
        runningTasks.removeValue(forKey: id)
        runningIDs.remove(id)
        if let idx = tasks.firstIndex(where: { $0.id == id }) {
            tasks[idx].status = .paused(resumeOffset: tasks[idx].bytesTransferred)
            notifyUpdate(tasks[idx])
        }
    }

    func resume(id: UUID) {
        guard let idx = tasks.firstIndex(where: { $0.id == id }),
              case .paused(let offset) = tasks[idx].status else { return }
        tasks[idx].resumeOffset = offset
        tasks[idx].status = .queued
        notifyUpdate(tasks[idx])
        drainQueue()
    }

    func allTasks() -> [TransferTask] { tasks }

    func clearCompleted() {
        tasks.removeAll { $0.status == .completed || $0.status == .cancelled }
    }

    // MARK: - Internal queue drain
    private func drainQueue() {
        let queued = tasks.filter {
            if case .queued = $0.status { return true }; return false
        }
        for task in queued {
            guard runningIDs.count < maxConcurrent else { break }
            guard !runningIDs.contains(task.id) else { continue }
            startTask(task)
        }
    }

    private func startTask(_ task: TransferTask) {
        runningIDs.insert(task.id)
        let t = Task {
            await executeTask(id: task.id)
        }
        runningTasks[task.id] = t
    }

    // MARK: - Execute one task
    private func executeTask(id: UUID) async {
        guard let idx = tasks.firstIndex(where: { $0.id == id }) else { return }
        var task = tasks[idx]
        task.startedAt = Date()
        task.status = .inProgress(progress: 0, bytesPerSecond: 0)
        tasks[idx] = task
        notifyUpdate(task)

        let password = (try? KeychainManager.shared.getPassword(for: task.serverID.uuidString)) ?? ""
        guard let pool = await ConnectionPoolRegistry.shared.existingPool(forServerID: task.serverID) else {
            markFailed(id: id, message: "连接池不存在，请先连接服务器")
            return
        }

        do {
            let client = try await pool.borrowClient(password: password)
            defer { Task { await pool.returnClient(client) } }

            let offset = tasks.first(where: { $0.id == id })?.resumeOffset ?? 0

            if task.direction == .upload {
                try await client.upload(
                    localURL: task.localURL,
                    remotePath: task.remotePath,
                    offset: offset
                ) { [weak self] progress in
                    guard let self else { return }
                    Task { await self.updateProgress(id: id, progress: progress) }
                }
            } else {
                try await client.download(
                    remotePath: task.remotePath,
                    localURL: task.localURL,
                    offset: offset
                ) { [weak self] progress in
                    guard let self else { return }
                    Task { await self.updateProgress(id: id, progress: progress) }
                }
            }

            markCompleted(id: id)

        } catch is CancellationError {
            // Task was cancelled / paused — state already set by caller
        } catch {
            await handleError(id: id, error: error)
        }
    }

    // MARK: - Error handling + auto-retry
    private func handleError(id: UUID, error: Error) async {
        guard let idx = tasks.firstIndex(where: { $0.id == id }) else { return }
        let friendly = FTPError.friendly(error)

        // 鉴权失败、文件不存在、权限不足、不支持等错误重试也无意义，立即报错
        if !Self.isRetriable(friendly) {
            markFailed(id: id, message: friendly.errorDescription ?? "传输失败")
            return
        }

        if tasks[idx].retryCount < TransferTask.maxRetries {
            tasks[idx].retryCount += 1
            tasks[idx].status = .queued
            runningIDs.remove(id)
            runningTasks.removeValue(forKey: id)
            notifyUpdate(tasks[idx])
            try? await Task.sleep(nanoseconds: UInt64(retryDelay * 1_000_000_000))
            drainQueue()
        } else {
            markFailed(id: id, message: friendly.errorDescription ?? "传输失败")
        }
    }

    private static func isRetriable(_ error: FTPError) -> Bool {
        switch error {
        case .authenticationFailed,
             .fileNotFound,
             .permissionDenied,
             .transferFailed,
             .unsupported,
             .sshKeyLoadFailed,
             .hostKeyMismatch,
             .resumeNotSupported,
             .badResponse:
            return false
        default:
            return true
        }
    }

    // MARK: - State helpers
    private func updateProgress(id: UUID, progress: TransferProgress) {
        guard let idx = tasks.firstIndex(where: { $0.id == id }) else { return }
        // Only update if still in progress — avoid overwriting completed/failed/cancelled status
        guard case .inProgress = tasks[idx].status else { return }
        tasks[idx].status = .inProgress(progress: progress.fraction, bytesPerSecond: progress.bytesPerSecond)
        tasks[idx].bytesTransferred = progress.bytesTransferred
        notifyUpdate(tasks[idx])
    }

    private func markCompleted(id: UUID) {
        guard let idx = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[idx].status = .completed
        tasks[idx].completedAt = Date()
        runningIDs.remove(id)
        runningTasks.removeValue(forKey: id)
        let task = tasks[idx]
        notifyUpdate(task)
        onComplete?(task)
        drainQueue()
    }

    private func markFailed(id: UUID, message: String) {
        guard let idx = tasks.firstIndex(where: { $0.id == id }),
              tasks[idx].status != .completed else { return }
        tasks[idx].status = .failed(message: message)
        runningIDs.remove(id)
        runningTasks.removeValue(forKey: id)
        let task = tasks[idx]
        notifyUpdate(task)
        onFailure?(task)
        drainQueue()
    }

    private func notifyUpdate(_ task: TransferTask) {
        onUpdate?(task)
    }
}
