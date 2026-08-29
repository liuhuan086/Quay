// SwiftFTPv2Tests.swift — Comprehensive unit tests
// Run: Xcode → Product → Test  (⌘U)
import XCTest
import Security
import Darwin
@testable import SwiftFTP

// MARK: - Entities Tests
final class ServerConfigTests: XCTestCase {

    func test_defaultPort_sftp() {
        let c = ServerConfig(displayName: "T", host: "h.com", username: "u", protocol_: .sftp)
        XCTAssertEqual(c.port, 22)
    }

    func test_defaultPort_ftp() {
        let c = ServerConfig(displayName: "T", host: "h.com", username: "u", protocol_: .ftp)
        XCTAssertEqual(c.port, 21)
    }

    func test_defaultPort_ftpsUsesImplicitTLS() {
        let c = ServerConfig(displayName: "T", host: "h.com", username: "u", protocol_: .ftps)
        XCTAssertEqual(c.port, 990)
        XCTAssertEqual(ConnectionProtocol.ftps.displayName, "FTPS（隐式）")
    }

    func test_connectionSummary() {
        let c = ServerConfig(displayName: "T", host: "ftp.example.com",
                             port: 22, username: "admin", protocol_: .sftp)
        XCTAssertEqual(c.connectionSummary, "SFTP://admin@ftp.example.com:22")
    }

    func test_password_runtimeOnly_notEncoded() throws {
        let a = ServerConfig(displayName: "A", host: "a.com", username: "u", password: "secret123")
        XCTAssertEqual(a.password, "secret123")
        let data = try JSONEncoder().encode(a)
        let json = String(data: data, encoding: .utf8) ?? ""
        XCTAssertFalse(json.contains("secret123"))
        XCTAssertFalse(json.contains("\"password\""))
    }

    func test_sshKeyBookmark_persistsForSandboxAccess() throws {
        let bookmark = Data("bookmark-data".utf8)
        let a = ServerConfig(
            displayName: "A",
            host: "a.com",
            username: "u",
            useSSHKey: true,
            sshKeyPath: "/Users/test/.ssh/id_ed25519",
            sshKeyBookmark: bookmark
        )
        let data = try JSONEncoder().encode(a)
        let decoded = try JSONDecoder().decode(ServerConfig.self, from: data)
        XCTAssertEqual(decoded.sshKeyBookmark, bookmark)
    }

    func test_protocol_isSecure() {
        XCTAssertFalse(ConnectionProtocol.ftp.isSecure)
        XCTAssertTrue(ConnectionProtocol.ftps.isSecure)
        XCTAssertTrue(ConnectionProtocol.sftp.isSecure)
    }

    func test_allowSelfSignedTLS_defaultsFalse() {
        let c = ServerConfig(displayName: "T", host: "h.com", username: "u", protocol_: .ftps)
        XCTAssertFalse(c.allowSelfSignedTLS)
    }

    func test_legacySSHAlgorithmsDefaultToDisabledAndPersistWhenEnabled() throws {
        var config = ServerConfig(displayName: "T", host: "h.com", username: "u", protocol_: .sftp)
        XCTAssertFalse(config.allowLegacySSHAlgorithms)
        config.allowLegacySSHAlgorithms = true

        let decoded = try JSONDecoder().decode(ServerConfig.self, from: JSONEncoder().encode(config))
        XCTAssertTrue(decoded.allowLegacySSHAlgorithms)
    }

    func test_sendable_crossActor() async {
        // ServerConfig must be passable across actor boundaries (Sendable)
        let config = ServerConfig(displayName: "T", host: "h", username: "u")
        let result = await Task.detached { config.displayName }.value
        XCTAssertEqual(result, "T")
    }
}

// MARK: - TransferTask Tests
final class TransferTaskTests: XCTestCase {

    func test_statusEqualityIsReflexiveAndComparesAssociatedValues() {
        let progress = TransferStatus.inProgress(progress: 0.5, bytesPerSecond: 42)
        let failure = TransferStatus.failed(message: "network")

        XCTAssertEqual(progress, progress)
        XCTAssertEqual(failure, failure)
        XCTAssertNotEqual(progress, .inProgress(progress: 0.6, bytesPerSecond: 42))
        XCTAssertNotEqual(failure, .failed(message: "permission"))
    }

    func test_progressFraction_queued() {
        let t = makeTask()
        XCTAssertEqual(t.status.progressFraction, 0.0)
    }

    func test_progressFraction_inProgress() {
        var t = makeTask()
        t.status = .inProgress(progress: 0.65, bytesPerSecond: 1024)
        XCTAssertEqual(t.status.progressFraction, 0.65, accuracy: 0.001)
    }

    func test_progressFraction_completed() {
        var t = makeTask()
        t.status = .completed
        XCTAssertEqual(t.status.progressFraction, 1.0)
    }

    func test_displaySpeed_kb() {
        var t = makeTask()
        t.status = .inProgress(progress: 0.5, bytesPerSecond: 512_000)
        XCTAssertTrue(t.displaySpeed.contains("KB") || t.displaySpeed.contains("MB"),
                      "Expected KB or MB in: \(t.displaySpeed)")
    }

    func test_displaySpeed_mb() {
        var t = makeTask()
        t.status = .inProgress(progress: 0.5, bytesPerSecond: 10_485_760)
        XCTAssertTrue(t.displaySpeed.contains("MB"))
    }

    func test_eta_calculated() {
        var t = makeTask(size: 10_000_000)
        t.status = .inProgress(progress: 0.5, bytesPerSecond: 1_000_000)
        // 50% remaining = 5MB at 1MB/s = 5s
        XCTAssertNotNil(t.eta)
    }

    func test_pausedStatus_resumeOffset() {
        var t = makeTask()
        t.status = .paused(resumeOffset: 524_288)
        if case .paused(let off) = t.status {
            XCTAssertEqual(off, 524_288)
        } else {
            XCTFail("Expected paused status")
        }
    }

    private func makeTask(size: Int64 = 1_048_576) -> TransferTask {
        TransferTask(serverID: UUID(), serverName: "Test", direction: .upload,
                     localURL: URL(fileURLWithPath: "/tmp/test.dat"),
                     remotePath: "/remote/test.dat", fileSize: size)
    }
}

final class RemoteFileItemSafetyTests: XCTestCase {
    func test_safePathComponents() {
        XCTAssertTrue(RemoteFileItem.isSafePathComponent("报告 2026.txt"))
        XCTAssertFalse(RemoteFileItem.isSafePathComponent(""))
        XCTAssertFalse(RemoteFileItem.isSafePathComponent("."))
        XCTAssertFalse(RemoteFileItem.isSafePathComponent(".."))
        XCTAssertFalse(RemoteFileItem.isSafePathComponent("../escape"))
        XCTAssertFalse(RemoteFileItem.isSafePathComponent("nested/file"))
        XCTAssertFalse(RemoteFileItem.isSafePathComponent("name\r\nDELE /"))
    }
}

final class TransferFileStagingTests: XCTestCase {
    func test_commitAtomicallyReplacesExistingDestination() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftftp-staging-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let destination = directory.appendingPathComponent("download.txt")
        let staged = TransferFileStaging.downloadURL(for: destination)
        try Data("old".utf8).write(to: destination)
        try Data("complete".utf8).write(to: staged)

        try TransferFileStaging.commitDownload(from: staged, to: destination)

        XCTAssertEqual(try Data(contentsOf: destination), Data("complete".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path))
    }

    func test_discardRemovesOnlyStagedDownload() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftftp-staging-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let destination = directory.appendingPathComponent("download.txt")
        let staged = TransferFileStaging.downloadURL(for: destination)
        try Data("original".utf8).write(to: destination)
        try Data("partial".utf8).write(to: staged)

        TransferFileStaging.discardDownload(for: destination)

        XCTAssertEqual(try Data(contentsOf: destination), Data("original".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path))
    }
}

final class TransferEnginePathTests: XCTestCase {

    func test_remoteParentDirectories_absolutePath() {
        let directories = TransferEngine.remoteParentDirectories(
            for: "/Users/liuhuan/Downloads/docs/report.txt"
        )
        XCTAssertEqual(directories, [
            "/Users",
            "/Users/liuhuan",
            "/Users/liuhuan/Downloads",
            "/Users/liuhuan/Downloads/docs"
        ])
    }

    func test_remoteParentDirectories_relativePath() {
        let directories = TransferEngine.remoteParentDirectories(for: "docs/reports/report.txt")
        XCTAssertEqual(directories, ["docs", "docs/reports"])
    }

    func test_remoteParentDirectories_fileInCurrentDirectory() {
        XCTAssertEqual(TransferEngine.remoteParentDirectories(for: "report.txt"), [])
    }
}

final class TransferEngineQueueTests: XCTestCase {

    func test_clearUnfinishedReturnsOnlyRemovedUnfinishedTasks() async {
        let engine = TransferEngine(startsTasksAutomatically: false)
        let unfinished = makeTask(named: "unfinished")
        let cancelled = makeTask(named: "cancelled")

        await engine.enqueue(unfinished)
        await engine.enqueue(cancelled)
        await engine.cancel(id: cancelled.id)

        let removedIDs = await engine.clearUnfinished()
        let remaining = await engine.allTasks()

        XCTAssertEqual(removedIDs, Set([unfinished.id]))
        XCTAssertEqual(Set(remaining.map(\.id)), Set([cancelled.id]))
        XCTAssertEqual(remaining.first?.status, .cancelled)
    }

    func test_bulkPauseAndResumeKeepsQueuedTasksControlledBySelection() async {
        let engine = TransferEngine(startsTasksAutomatically: false)
        let first = makeTask(named: "first")
        let second = makeTask(named: "second")

        await engine.enqueue(first)
        await engine.enqueue(second)
        await engine.pause(ids: [first.id])

        var tasks = await engine.allTasks()
        XCTAssertTrue(tasks.contains { $0.id == second.id && $0.status == .queued })
        guard let paused = tasks.first(where: { $0.id == first.id }) else {
            XCTFail("Expected paused task")
            return
        }
        XCTAssertEqual(paused.status, .paused(resumeOffset: 0))

        await engine.resume(ids: [first.id])

        tasks = await engine.allTasks()
        XCTAssertTrue(tasks.allSatisfy { $0.status == .queued })
    }

    func test_removeReturnsOnlyExistingTaskIDs() async {
        let engine = TransferEngine(startsTasksAutomatically: false)
        let task = makeTask(named: "existing")
        let missingID = UUID()

        await engine.enqueue(task)

        let removedIDs = await engine.remove(ids: [task.id, missingID])
        let remaining = await engine.allTasks()

        XCTAssertEqual(removedIDs, Set([task.id]))
        XCTAssertTrue(remaining.isEmpty)
    }

    private func makeTask(named name: String) -> TransferTask {
        TransferTask(
            serverID: UUID(),
            serverName: "Test",
            direction: .upload,
            localURL: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("\(name).dat"),
            remotePath: "/remote/\(name).dat"
        )
    }
}

final class TransferEngineExecutionTests: XCTestCase {
    private enum WaitError: Error {
        case timedOut
    }

    func test_uploadCompletesAndCreatesRemoteParents() async throws {
        let server = makeServer()
        let client = FakeFTPClient(config: server)
        let localURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("upload.txt")
        let task = TransferTask(
            serverID: server.id,
            serverName: server.displayName,
            direction: .upload,
            localURL: localURL,
            remotePath: "/var/www/app/upload.txt",
            fileSize: 100
        )

        try await withRegisteredPool(server: server, client: client) {
            let engine = TransferEngine(retryDelay: 0.01)

            await engine.enqueue(task)
            let completed = try await waitForTask(task.id, in: engine, matching: isCompleted)

            XCTAssertEqual(completed.status, .completed)
            XCTAssertNotNil(completed.completedAt)
            XCTAssertEqual(client.createdDirectoryValues(), ["/var", "/var/www", "/var/www/app"])
            XCTAssertEqual(client.uploadCallValues(), [
                FakeTransferCall(localPath: localURL.path, remotePath: "/var/www/app/upload.txt", offset: 0)
            ])
        }
    }

    func test_downloadCompletesWithoutCreatingRemoteParents() async throws {
        let server = makeServer()
        let client = FakeFTPClient(config: server)
        let localURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("download.txt")
        let task = TransferTask(
            serverID: server.id,
            serverName: server.displayName,
            direction: .download,
            localURL: localURL,
            remotePath: "/var/www/app/download.txt",
            fileSize: 100
        )

        try await withRegisteredPool(server: server, client: client) {
            let engine = TransferEngine(retryDelay: 0.01)

            await engine.enqueue(task)
            let completed = try await waitForTask(task.id, in: engine, matching: isCompleted)

            XCTAssertEqual(completed.status, .completed)
            XCTAssertTrue(client.createdDirectoryValues().isEmpty)
            XCTAssertEqual(client.downloadCallValues(), [
                FakeTransferCall(localPath: localURL.path, remotePath: "/var/www/app/download.txt", offset: 0)
            ])
        }
    }

    func test_retriableUploadFailureRetriesAndCompletes() async throws {
        let server = makeServer()
        let client = FakeFTPClient(config: server)
        client.enqueueUploadOutcome(.fail(.connectionFailed("temporary reset")))
        let localURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("retry.txt")
        let task = TransferTask(
            serverID: server.id,
            serverName: server.displayName,
            direction: .upload,
            localURL: localURL,
            remotePath: "/retry.txt",
            fileSize: 100
        )

        try await withRegisteredPool(server: server, client: client) {
            let engine = TransferEngine(retryDelay: 0.01)

            await engine.enqueue(task)
            let completed = try await waitForTask(task.id, in: engine, matching: isCompleted)

            XCTAssertEqual(completed.status, .completed)
            XCTAssertEqual(completed.retryCount, 1)
            XCTAssertEqual(client.uploadCallValues().count, 2)
        }
    }

    func test_nonRetriableUploadFailureFailsWithoutRetry() async throws {
        let server = makeServer()
        let client = FakeFTPClient(config: server)
        client.enqueueUploadOutcome(.fail(.authenticationFailed))
        let task = TransferTask(
            serverID: server.id,
            serverName: server.displayName,
            direction: .upload,
            localURL: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("auth.txt"),
            remotePath: "/auth.txt",
            fileSize: 100
        )

        try await withRegisteredPool(server: server, client: client) {
            let engine = TransferEngine(retryDelay: 0.01)

            await engine.enqueue(task)
            let failed = try await waitForTask(task.id, in: engine, matching: isFailed)

            XCTAssertEqual(failed.retryCount, 0)
            XCTAssertEqual(client.uploadCallValues().count, 1)
            guard case .failed(let message) = failed.status else {
                return XCTFail("Expected failed status")
            }
            XCTAssertTrue(message.contains("用户名") || message.contains("密码"))
        }
    }

    func test_missingConnectionPoolFailsTaskWithoutClientWork() async throws {
        let server = makeServer()
        let engine = TransferEngine(retryDelay: 0.01)
        let task = TransferTask(
            serverID: server.id,
            serverName: server.displayName,
            direction: .upload,
            localURL: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("missing-pool.txt"),
            remotePath: "/missing-pool.txt",
            fileSize: 100
        )

        await ConnectionPoolRegistry.shared.removePool(for: server.id)
        await engine.enqueue(task)
        let failed = try await waitForTask(task.id, in: engine, matching: isFailed)

        guard case .failed(let message) = failed.status else {
            return XCTFail("Expected failed status")
        }
        XCTAssertTrue(message.contains("连接池不存在"))
    }

    func test_sameRemoteTargetNeverRunsConcurrently() async throws {
        let server = makeServer()
        let firstClient = FakeFTPClient(config: server)
        let secondClient = FakeFTPClient(config: server)
        firstClient.setUploadsBlocked(true)
        secondClient.setUploadsBlocked(true)
        let factory = FakeClientFactory([firstClient, secondClient])
        _ = await ConnectionPoolRegistry.shared.pool(
            for: server,
            maxSize: 2,
            clientFactory: factory.makeClient
        )

        let firstTask = TransferTask(
            serverID: server.id,
            serverName: server.displayName,
            direction: .upload,
            localURL: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("same-1.txt"),
            remotePath: "/same-target.txt",
            fileSize: 100
        )
        let secondTask = TransferTask(
            serverID: server.id,
            serverName: server.displayName,
            direction: .upload,
            localURL: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("same-2.txt"),
            remotePath: "/same-target.txt",
            fileSize: 100
        )
        let engine = TransferEngine(retryDelay: 0.01)
        await engine.updateConcurrent(2)

        do {
            await engine.enqueue(firstTask)
            await engine.enqueue(secondTask)
            _ = try await waitForTask(firstTask.id, in: engine) { task in
                if case .inProgress = task.status { return firstClient.uploadCallValues().count == 1 }
                return false
            }
            try await Task.sleep(nanoseconds: 30_000_000)

            XCTAssertEqual(
                firstClient.uploadCallValues().count + secondClient.uploadCallValues().count,
                1,
                "Two writes to the same remote target overlapped"
            )

            firstClient.setUploadsBlocked(false)
            _ = try await waitForTask(firstTask.id, in: engine, matching: isCompleted)
            _ = try await waitForTask(secondTask.id, in: engine, matching: isCompleted)
            await ConnectionPoolRegistry.shared.removePool(for: server.id)
        } catch {
            firstClient.setUploadsBlocked(false)
            secondClient.setUploadsBlocked(false)
            await ConnectionPoolRegistry.shared.removePool(for: server.id)
            throw error
        }
    }

    private func withRegisteredPool(
        server: ServerConfig,
        client: FakeFTPClient,
        _ body: () async throws -> Void
    ) async throws {
        let factory = FakeClientFactory([client])
        _ = await ConnectionPoolRegistry.shared.pool(
            for: server,
            maxSize: 1,
            clientFactory: factory.makeClient
        )
        do {
            try await body()
            await ConnectionPoolRegistry.shared.removePool(for: server.id)
        } catch {
            await ConnectionPoolRegistry.shared.removePool(for: server.id)
            throw error
        }
    }

    private func waitForTask(
        _ id: UUID,
        in engine: TransferEngine,
        timeout: TimeInterval = 2,
        matching predicate: (TransferTask) -> Bool
    ) async throws -> TransferTask {
        let deadline = Date().addingTimeInterval(timeout)
        var lastTask: TransferTask?

        while Date() < deadline {
            let tasks = await engine.allTasks()
            if let task = tasks.first(where: { $0.id == id }) {
                lastTask = task
                if predicate(task) {
                    return task
                }
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTFail("Timed out waiting for task \(id). Last status: \(String(describing: lastTask?.status))")
        throw WaitError.timedOut
    }

    private func isCompleted(_ task: TransferTask) -> Bool {
        if case .completed = task.status { return true }
        return false
    }

    private func isFailed(_ task: TransferTask) -> Bool {
        if case .failed = task.status { return true }
        return false
    }

    private func makeServer() -> ServerConfig {
        ServerConfig(displayName: "EngineTest", host: "engine.test", username: "u", protocol_: .sftp)
    }
}

// MARK: - TransferProgress Tests
final class TransferProgressTests: XCTestCase {

    func test_fraction_zero_when_totalZero() {
        let p = TransferProgress(bytesTransferred: 100, totalBytes: 0, bytesPerSecond: 0)
        XCTAssertEqual(p.fraction, 0)
    }

    func test_fraction_clamped_to_one() {
        let p = TransferProgress(bytesTransferred: 2000, totalBytes: 1000, bytesPerSecond: 0)
        XCTAssertEqual(p.fraction, 1.0)
    }

    func test_fraction_midpoint() {
        let p = TransferProgress(bytesTransferred: 500, totalBytes: 1000, bytesPerSecond: 0)
        XCTAssertEqual(p.fraction, 0.5, accuracy: 0.001)
    }
}

// MARK: - Keychain Tests
final class KeychainTests: XCTestCase {
    let km = KeychainManager.shared
    let key = "swiftftp.test.\(UUID().uuidString)"

    override func setUpWithError() throws {
        try super.setUpWithError()
        let probeKey = "swiftftp.test.entitlement-probe.\(UUID().uuidString)"
        do {
            try km.savePassword("probe", for: probeKey)
            km.deletePassword(for: probeKey)
        } catch {
            if case KeychainError.saveFailed(let status) = error,
               status == errSecMissingEntitlement {
                throw XCTSkip("Keychain integration requires a signed test host with Keychain entitlement")
            }
            throw error
        }
    }

    override func tearDown() {
        km.deletePassword(for: key)
        super.tearDown()
    }

    func test_saveAndRetrieve() throws {
        try km.savePassword("s3cr3t!", for: key)
        XCTAssertEqual(try km.getPassword(for: key), "s3cr3t!")
    }

    func test_overwrite() throws {
        try km.savePassword("old", for: key)
        try km.savePassword("new", for: key)
        XCTAssertEqual(try km.getPassword(for: key), "new")
    }

    func test_deleteRemovesEntry() throws {
        try km.savePassword("pass", for: key)
        km.deletePassword(for: key)
        XCTAssertFalse(km.hasPassword(for: key))
    }

    func test_missingKeyReturnsNil() throws {
        let result = try km.getPassword(for: "swiftftp.definitely.not.exist.\(UUID())")
        XCTAssertNil(result)
    }

    func test_hasPassword_true() throws {
        try km.savePassword("x", for: key)
        XCTAssertTrue(km.hasPassword(for: key))
    }

    func test_unicodePassword() throws {
        let emoji = "密码🔐123"
        try km.savePassword(emoji, for: key)
        XCTAssertEqual(try km.getPassword(for: key), emoji)
    }
}

// MARK: - ServerRepository Tests
final class ServerRepositoryTests: XCTestCase {
    var repo: ServerRepository!
    var repoKey: String!
    private var repoKeychain: MemoryKeychain!

    override func setUp() {
        super.setUp()
        repoKey = "swiftftp.tests.servers.\(UUID().uuidString)"
        repoKeychain = MemoryKeychain()
        repo = ServerRepository(key: repoKey, keychain: repoKeychain)
    }

    override func tearDown() async throws {
        for server in repo.fetchAll() {
            await repo.delete(server.id)
        }
        UserDefaults.standard.removeObject(forKey: repoKey)
        UserDefaults.standard.removeObject(forKey: "\(repoKey!).blockedCredentialIDs")
        repo = nil
        repoKeychain = nil
        repoKey = nil
        try await super.tearDown()
    }

    func test_saveAndFetch() async throws {
        let c = makeCfg("Repo Test", password: "secret")
        try await repo.save(c)
        let fetched = repo.fetchAll().first(where: { $0.id == c.id })
        XCTAssertEqual(fetched?.password, "")
        let resolved = try await repo.password(for: c.id)
        XCTAssertEqual(resolved, "secret")
        let persisted = UserDefaults.standard.data(forKey: repoKey).flatMap {
            String(data: $0, encoding: .utf8)
        } ?? ""
        XCTAssertFalse(persisted.contains("secret"))
        XCTAssertFalse(persisted.contains("\"password\""))
    }

    func test_update() async throws {
        var c = makeCfg("Update Test")
        try await repo.save(c)
        c.displayName = "Updated"
        try await repo.update(c)
        XCTAssertEqual(repo.fetchAll().first(where: { $0.id == c.id })?.displayName, "Updated")
    }

    func test_updateLastConnectedPreservesDisplayName() async throws {
        var c = makeCfg("192.168.2.4")
        try await repo.save(c)

        c.displayName = "Mac"
        try await repo.update(c)

        let connectedAt = Date(timeIntervalSince1970: 1_770_000_000)
        await repo.updateLastConnected(for: c.id, at: connectedAt)

        let fetched = repo.fetchAll().first(where: { $0.id == c.id })
        XCTAssertEqual(fetched?.displayName, "Mac")
        XCTAssertEqual(fetched?.lastConnectedAt, connectedAt)
    }

    func test_delete() async throws {
        let c = makeCfg("Delete Test")
        try await repo.save(c)
        await repo.delete(c.id)
        XCTAssertFalse(repo.fetchAll().contains(where: { $0.id == c.id }))
    }

    func test_exportImport() async throws {
        let c = makeCfg("Export")
        try await repo.save(c)
        let data = try repo.exportJSON()
        XCTAssertFalse(data.isEmpty)
        await repo.delete(c.id)
        try await repo.importJSON(data)
        XCTAssertTrue(repo.fetchAll().contains(where: { $0.id == c.id }))
    }

    func test_exportJSONOmitsSecurityScopedSSHKeyBookmark() async throws {
        let c = ServerConfig(
            displayName: "Key Server",
            host: "key.local",
            username: "u",
            useSSHKey: true,
            sshKeyPath: "/Users/test/.ssh/id_ed25519",
            sshKeyBookmark: Data("local-bookmark".utf8)
        )
        try await repo.save(c)

        let stored = repo.fetchAll().first(where: { $0.id == c.id })
        XCTAssertEqual(stored?.sshKeyBookmark, Data("local-bookmark".utf8))

        let exported = try repo.exportJSON()
        let json = String(data: exported, encoding: .utf8) ?? ""
        XCTAssertFalse(json.contains("sshKeyBookmark"))
        XCTAssertFalse(json.contains("local-bookmark"))
    }

    func test_importJSONOmitsSecurityScopedSSHKeyBookmark() async throws {
        let c = ServerConfig(
            displayName: "Imported Key Server",
            host: "imported-key.local",
            username: "u",
            useSSHKey: true,
            sshKeyPath: "/Users/test/.ssh/id_ed25519",
            sshKeyBookmark: Data("foreign-bookmark".utf8)
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode([c])

        try await repo.importJSON(data)

        let imported = repo.fetchAll().first(where: { $0.id == c.id })
        XCTAssertEqual(imported?.sshKeyPath, "/Users/test/.ssh/id_ed25519")
        XCTAssertNil(imported?.sshKeyBookmark)
    }

    func test_legacyPasswordMigratesToKeychainAndIsRemovedFromDefaults() async throws {
        let id = UUID()
        let legacyJSON = """
        [{
          "id": "\(id.uuidString)",
          "displayName": "Legacy",
          "host": "legacy.local",
          "username": "u",
          "password": "legacy-secret"
        }]
        """
        UserDefaults.standard.set(Data(legacyJSON.utf8), forKey: repoKey)
        let fetched = repo.fetchAll()
        XCTAssertEqual(fetched.first?.password, "")
        let resolved = try await repo.password(for: id)
        XCTAssertEqual(resolved, "legacy-secret")
        XCTAssertEqual(try repoKeychain.getPassword(for: id.uuidString), "legacy-secret")

        let persisted = UserDefaults.standard.data(forKey: repoKey).flatMap {
            String(data: $0, encoding: .utf8)
        } ?? ""
        XCTAssertFalse(persisted.contains("legacy-secret"))
        XCTAssertFalse(persisted.contains("\"password\""))
    }

    func test_onDemandLegacyLookupDoesNotDropOtherLegacyPasswords() async throws {
        let id1 = UUID()
        let id2 = UUID()
        let legacyJSON = """
        [{
          "id": "\(id1.uuidString)",
          "displayName": "Legacy One",
          "host": "one.local",
          "username": "u",
          "password": "secret-one"
        },{
          "id": "\(id2.uuidString)",
          "displayName": "Legacy Two",
          "host": "two.local",
          "username": "u",
          "password": "secret-two"
        }]
        """
        UserDefaults.standard.set(Data(legacyJSON.utf8), forKey: repoKey)
        // On-demand lookup for the first server (before any bulk migration)
        // must not erase the second server's still-unmigrated password.
        let one = try await repo.password(for: id1)
        XCTAssertEqual(one, "secret-one")

        let two = try await repo.password(for: id2)
        XCTAssertEqual(two, "secret-two")
        XCTAssertEqual(try repoKeychain.getPassword(for: id2.uuidString), "secret-two")

        let persisted = UserDefaults.standard.data(forKey: repoKey).flatMap {
            String(data: $0, encoding: .utf8)
        } ?? ""
        XCTAssertFalse(persisted.contains("secret-one"))
        XCTAssertFalse(persisted.contains("secret-two"))
    }

    func test_unrelatedSaveDoesNotDropUnmigratedLegacyPassword() async throws {
        let legacyID = UUID()
        let legacyJSON = """
        [{
          "id": "\(legacyID.uuidString)",
          "displayName": "Legacy",
          "host": "legacy.local",
          "username": "u",
          "password": "legacy-secret"
        }]
        """
        UserDefaults.standard.set(Data(legacyJSON.utf8), forKey: repoKey)
        try await repo.save(makeCfg("New Server", password: "new-secret"))

        let resolved = try await repo.password(for: legacyID)
        XCTAssertEqual(resolved, "legacy-secret")
    }

    func test_deletePasswordRemovesLegacyPlaintextPassword() async throws {
        let legacyID = UUID()
        let legacyJSON = """
        [{
          "id": "\(legacyID.uuidString)",
          "displayName": "Legacy",
          "host": "legacy.local",
          "username": "u",
          "password": "legacy-secret"
        }]
        """
        UserDefaults.standard.set(Data(legacyJSON.utf8), forKey: repoKey)
        try await repo.deletePassword(for: legacyID)

        let resolved = try await repo.password(for: legacyID)
        XCTAssertEqual(resolved, "")
        let persisted = UserDefaults.standard.data(forKey: repoKey).flatMap {
            String(data: $0, encoding: .utf8)
        } ?? ""
        XCTAssertFalse(persisted.contains("legacy-secret"))
    }

    private struct AlwaysFailingKeychain: KeychainStoring {
        struct Failure: Error {}
        func savePassword(_ password: String, for key: String, label: String?) throws {
            throw Failure()
        }
        func getPassword(for key: String) throws -> String? { nil }
        @discardableResult
        func deletePassword(for key: String) -> Bool { true }
    }

    private struct DeleteFailingKeychain: KeychainStoring {
        func savePassword(_ password: String, for key: String, label: String?) throws {}
        func getPassword(for key: String) throws -> String? { nil }
        @discardableResult
        func deletePassword(for key: String) -> Bool { false }
    }

    private final class DeleteFailingMemoryKeychain: KeychainStoring, @unchecked Sendable {
        private let lock = NSLock()
        private var passwords: [String: String] = [:]

        func savePassword(_ password: String, for key: String, label: String?) throws {
            lock.lock()
            passwords[key] = password
            lock.unlock()
        }

        func getPassword(for key: String) throws -> String? {
            lock.lock()
            let password = passwords[key]
            lock.unlock()
            return password
        }

        @discardableResult
        func deletePassword(for key: String) -> Bool {
            false
        }
    }

    private final class MemoryKeychain: KeychainStoring, @unchecked Sendable {
        private let lock = NSLock()
        private var passwords: [String: String] = [:]

        func savePassword(_ password: String, for key: String, label: String?) throws {
            lock.lock()
            passwords[key] = password
            lock.unlock()
        }

        func getPassword(for key: String) throws -> String? {
            lock.lock()
            let password = passwords[key]
            lock.unlock()
            return password
        }

        @discardableResult
        func deletePassword(for key: String) -> Bool {
            lock.lock()
            passwords.removeValue(forKey: key)
            lock.unlock()
            return true
        }
    }

    private final class FailOnSecondSaveKeychain: KeychainStoring, @unchecked Sendable {
        struct Failure: Error {}
        private let lock = NSLock()
        private var saveCount = 0
        private var passwords: [String: String] = [:]

        func savePassword(_ password: String, for key: String, label: String?) throws {
            try lock.withLock {
                saveCount += 1
                if saveCount == 2 { throw Failure() }
                passwords[key] = password
            }
        }

        func getPassword(for key: String) throws -> String? {
            lock.withLock { passwords[key] }
        }

        @discardableResult
        func deletePassword(for key: String) -> Bool {
            lock.withLock {
                passwords.removeValue(forKey: key)
                return true
            }
        }
    }

    func test_unrelatedWritePreservesLegacyWhenKeychainMigrationFails() async throws {
        let failKey = "swiftftp.tests.failkc.\(UUID().uuidString)"
        let repo = ServerRepository(key: failKey, keychain: AlwaysFailingKeychain())
        defer { UserDefaults.standard.removeObject(forKey: failKey) }

        let idA = UUID()
        let idB = UUID()
        let legacyJSON = """
        [
          {"id":"\(idA.uuidString)","displayName":"A","host":"a.local","username":"u","password":"secret-A"},
          {"id":"\(idB.uuidString)","displayName":"B","host":"b.local","username":"u","password":"secret-B"}
        ]
        """
        UserDefaults.standard.set(Data(legacyJSON.utf8), forKey: failKey)

        // Unrelated write while every Keychain migration write fails.
        try await repo.save(makeCfg("New"))

        // Keychain holds nothing, so both pending legacy plaintexts must survive.
        let a = try await repo.password(for: idA)
        let b = try await repo.password(for: idB)
        XCTAssertEqual(a, "secret-A")
        XCTAssertEqual(b, "secret-B")

        let persisted = UserDefaults.standard.data(forKey: failKey).flatMap {
            String(data: $0, encoding: .utf8)
        } ?? ""
        XCTAssertTrue(persisted.contains("secret-A"))
        XCTAssertTrue(persisted.contains("secret-B"))
    }

    func test_newPasswordSaveFailsWhenKeychainWriteFails() async {
        let failKey = "swiftftp.tests.failkc.\(UUID().uuidString)"
        let repo = ServerRepository(key: failKey, keychain: AlwaysFailingKeychain())
        defer { UserDefaults.standard.removeObject(forKey: failKey) }

        do {
            try await repo.save(makeCfg("New", password: "new-secret"))
            XCTFail("Expected Keychain write failure to abort the save")
        } catch {
            // Expected: never report a saved credential unless Keychain accepted it.
        }

        XCTAssertTrue(repo.fetchAll().isEmpty)
        let persisted = UserDefaults.standard.data(forKey: failKey).flatMap {
            String(data: $0, encoding: .utf8)
        } ?? ""
        XCTAssertFalse(persisted.contains("new-secret"))
    }

    func test_deleteRemovesServerEvenWhenKeychainScrubFails() async {
        let failKey = "swiftftp.tests.faildel.\(UUID().uuidString)"
        let repo = ServerRepository(key: failKey, keychain: DeleteFailingKeychain())
        defer {
            UserDefaults.standard.removeObject(forKey: failKey)
            UserDefaults.standard.removeObject(forKey: "\(failKey).blockedCredentialIDs")
        }

        let id = UUID()
        let json = """
        [{"id":"\(id.uuidString)","displayName":"S","host":"s.local","username":"u"}]
        """
        UserDefaults.standard.set(Data(json.utf8), forKey: failKey)

        let credentialCleared = await repo.delete(id)

        // Server removal always succeeds; only the Keychain scrub failed.
        XCTAssertFalse(credentialCleared)
        XCTAssertFalse(repo.fetchAll().contains(where: { $0.id == id }))
    }

    func test_failedDeleteScrubDoesNotReuseStaleCredentialAfterReimport() async throws {
        let failKey = "swiftftp.tests.stale.\(UUID().uuidString)"
        let keychain = DeleteFailingMemoryKeychain()
        let repo = ServerRepository(key: failKey, keychain: keychain)
        defer {
            UserDefaults.standard.removeObject(forKey: failKey)
            UserDefaults.standard.removeObject(forKey: "\(failKey).blockedCredentialIDs")
        }

        let id = UUID()
        let original = ServerConfig(
            id: id,
            displayName: "Original",
            host: "old.local",
            username: "u",
            password: "old-secret"
        )
        try await repo.save(original)
        let originalPassword = try await repo.password(for: id)
        XCTAssertEqual(originalPassword, "old-secret")

        let credentialCleared = await repo.delete(id)
        XCTAssertFalse(credentialCleared)

        let reimportedJSON = """
        [{"id":"\(id.uuidString)","displayName":"Reimported","host":"new.local","username":"u"}]
        """
        try await repo.importJSON(Data(reimportedJSON.utf8))

        let blockedPassword = try await repo.password(for: id)
        XCTAssertEqual(blockedPassword, "")

        var updated = repo.fetchAll().first(where: { $0.id == id })!
        updated.password = "fresh-secret"
        try await repo.update(updated)
        let freshPassword = try await repo.password(for: id)
        XCTAssertEqual(freshPassword, "fresh-secret")
    }

    func test_updateWithEmptyPasswordPreservesExistingCredential() async throws {
        let isolatedKey = "swiftftp.tests.memory.\(UUID().uuidString)"
        let repo = ServerRepository(key: isolatedKey, keychain: MemoryKeychain())
        defer { UserDefaults.standard.removeObject(forKey: isolatedKey) }

        var config = makeCfg("Preserve Password", password: "old-secret")
        try await repo.save(config)

        config.displayName = "Renamed"
        config.password = ""
        try await repo.update(config)

        let password = try await repo.password(for: config.id)
        XCTAssertEqual(password, "old-secret")
        XCTAssertEqual(repo.fetchAll().first(where: { $0.id == config.id })?.displayName, "Renamed")
    }

    func test_replacePolicyWithEmptyPasswordDeletesExistingCredential() async throws {
        let isolatedKey = "swiftftp.tests.memory.\(UUID().uuidString)"
        let repo = ServerRepository(key: isolatedKey, keychain: MemoryKeychain())
        defer { UserDefaults.standard.removeObject(forKey: isolatedKey) }

        var config = makeCfg("Delete Password", password: "old-secret")
        try await repo.save(config)

        config.password = ""
        try await repo.save(config, credentialPolicy: .replace)

        let password = try await repo.password(for: config.id)
        XCTAssertEqual(password, "")
    }

    func test_importJSONMigratesPasswordToInjectedKeychainAndStripsDefaults() async throws {
        let isolatedKey = "swiftftp.tests.memory.\(UUID().uuidString)"
        let repo = ServerRepository(key: isolatedKey, keychain: MemoryKeychain())
        defer { UserDefaults.standard.removeObject(forKey: isolatedKey) }

        let id = UUID()
        let json = """
        [{"id":"\(id.uuidString)","displayName":"Imported","host":"import.local","username":"u","password":"import-secret"}]
        """

        try await repo.importJSON(Data(json.utf8))

        let password = try await repo.password(for: id)
        XCTAssertEqual(password, "import-secret")
        let persisted = UserDefaults.standard.data(forKey: isolatedKey).flatMap {
            String(data: $0, encoding: .utf8)
        } ?? ""
        XCTAssertFalse(persisted.contains("import-secret"))
        XCTAssertFalse(persisted.contains("\"password\""))
    }

    func test_sortedByDisplayName() async throws {
        let b = makeCfg("B-Server")
        let a = makeCfg("A-Server")
        try await repo.save(b); try await repo.save(a)
        let all = repo.fetchAll()
        let names = all.map { $0.displayName }
        if let ai = names.firstIndex(of: "A-Server"), let bi = names.firstIndex(of: "B-Server") {
            XCTAssertLessThan(ai, bi, "Should be sorted alphabetically")
        }
    }

    func test_concurrentSavesPreserveAllServers() async throws {
        let configs = (0..<25).map { makeCfg("Concurrent \($0)") }
        let repo = self.repo!

        try await withThrowingTaskGroup(of: Void.self) { group in
            for config in configs {
                group.addTask {
                    try await repo.save(config)
                }
            }
            try await group.waitForAll()
        }

        let savedIDs = Set(repo.fetchAll().map(\.id))
        XCTAssertTrue(configs.allSatisfy { savedIDs.contains($0.id) })
    }

    func test_saveRejectsInvalidPortWithoutPersistingAnything() async {
        let invalid = ServerConfig(
            displayName: "Invalid",
            host: "host.local",
            port: 0,
            username: "u"
        )

        await XCTAssertThrowsErrorAsync(try await repo.save(invalid))
        XCTAssertTrue(repo.fetchAll().isEmpty)
    }

    func test_importValidatesWholePayloadBeforeWriting() async throws {
        let valid = makeCfg("Valid")
        let invalid = ServerConfig(
            displayName: "Invalid",
            host: "host.local",
            port: 0,
            username: "u"
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode([valid, invalid])

        await XCTAssertThrowsErrorAsync(try await repo.importJSON(data))
        XCTAssertTrue(repo.fetchAll().isEmpty)
    }

    func test_importRollsBackCredentialsWhenLaterKeychainWriteFails() async throws {
        let isolatedKey = "swiftftp.tests.import-rollback.\(UUID().uuidString)"
        let keychain = FailOnSecondSaveKeychain()
        let repo = ServerRepository(key: isolatedKey, keychain: keychain)
        defer { UserDefaults.standard.removeObject(forKey: isolatedKey) }
        let first = makeCfg("First", password: "first-secret")
        let second = makeCfg("Second", password: "second-secret")
        let json = """
        [
          {"id":"\(first.id.uuidString)","displayName":"First","host":"first.local","username":"u","password":"first-secret"},
          {"id":"\(second.id.uuidString)","displayName":"Second","host":"second.local","username":"u","password":"second-secret"}
        ]
        """
        let data = Data(json.utf8)

        await XCTAssertThrowsErrorAsync(try await repo.importJSON(data))

        XCTAssertTrue(repo.fetchAll().isEmpty)
        XCTAssertNil(try keychain.getPassword(for: first.id.uuidString))
        XCTAssertNil(try keychain.getPassword(for: second.id.uuidString))
    }

    private func makeCfg(_ name: String, password: String = "") -> ServerConfig {
        ServerConfig(displayName: name, host: "test.local", username: "u", password: password)
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected expression to throw", file: file, line: line)
    } catch {
        // Expected.
    }
}

// MARK: - ExclusionMatcher Tests
final class ExclusionMatcherTests: XCTestCase {

    func test_excludes_node_modules() {
        let m = matcher(["node_modules"])
        XCTAssertTrue(m.shouldExclude("/project/node_modules/lodash/index.js"))
    }

    func test_excludes_git_dir() {
        let m = matcher([".git"])
        XCTAssertTrue(m.shouldExclude("/project/.git/config"))
    }

    func test_excludes_wildcard_log() {
        let m = matcher(["*.log"])
        XCTAssertTrue(m.shouldExclude("/var/log/access.log"))
        XCTAssertFalse(m.shouldExclude("/var/log/readme.txt"))
    }

    func test_excludes_wildcard_prefix() {
        let m = matcher(["*.swp"])
        XCTAssertTrue(m.shouldExclude("/tmp/.index.js.swp"))
    }

    func test_allows_normal_file() {
        let m = matcher(SyncWatcher.defaultExcludePatterns)
        XCTAssertFalse(m.shouldExclude("/project/src/main.swift"))
    }

    func test_allows_similar_name() {
        let m = matcher(["node_modules"])
        // Should NOT exclude if it's just a substring in the filename
        XCTAssertFalse(m.shouldExclude("/project/src/node_modules_backup.swift"))
    }

    func test_ds_store_excluded() {
        let m = matcher(SyncWatcher.defaultExcludePatterns)
        XCTAssertTrue(m.shouldExclude("/project/.DS_Store"))
    }

    private func matcher(_ patterns: [String]) -> ExclusionMatcher {
        ExclusionMatcher(patterns: patterns)
    }
}

// MARK: - SyncWatcher Bookmark Tests
final class SyncWatcherBookmarkTests: XCTestCase {

    func test_securityScopedBookmark_roundTripsPath() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftftp-bookmark-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let bookmark: Data
        do {
            bookmark = try directory.bookmarkData(
                options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        } catch {
            let ns = error as NSError
            if ns.domain == NSCocoaErrorDomain && ns.code == 256 {
                throw XCTSkip("Security-scoped bookmarks require a signed app-scope test host")
            }
            throw error
        }
        var stale = false
        let resolved = try URL(
            resolvingBookmarkData: bookmark,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )
        XCTAssertFalse(stale)
        XCTAssertEqual(resolved.standardizedFileURL.path, directory.standardizedFileURL.path)
    }
}

// MARK: - FTPError Tests
final class FTPErrorTests: XCTestCase {

    func test_errorDescriptions_not_nil() {
        let errors: [FTPError] = [
            .connectionFailed("timeout"),
            .authenticationFailed,
            .notConnected,
            .badResponse("500 Error"),
            .fileNotFound("/test"),
            .permissionDenied("/root"),
            .timeout,
            .resumeNotSupported
        ]
        for e in errors {
            XCTAssertNotNil(e.errorDescription, "nil description for \(e)")
            XCTAssertFalse(e.errorDescription!.isEmpty, "empty description for \(e)")
        }
    }

    func test_hostKeyMismatch_contains_host() {
        let e = FTPError.hostKeyMismatch("badserver.com")
        XCTAssertTrue(e.errorDescription?.contains("badserver.com") ?? false)
    }

    func test_hostReachabilityFailure_detects_posixHostUnreachable() {
        let error = POSIXError(POSIXErrorCode(rawValue: EHOSTUNREACH)!)
        XCTAssertTrue(FTPError.isHostReachabilityFailure(error))
    }

    func test_ftpsCertificateOverrideAllowsOnlyNarrowTrustFailures() {
        XCTAssertTrue(FTPClient.shouldAllowFTPSCertificateOverride(
            errorCodes: [Int(errSecCertificateExpired)],
            description: "certificate expired"
        ))
        XCTAssertTrue(FTPClient.shouldAllowFTPSCertificateOverride(
            errorCodes: [Int(errSecNotTrusted)],
            description: "self signed certificate"
        ))
        XCTAssertFalse(FTPClient.shouldAllowFTPSCertificateOverride(
            errorCodes: [Int(errSecHostNameMismatch)],
            description: "host name mismatch"
        ))
        XCTAssertFalse(FTPClient.shouldAllowFTPSCertificateOverride(
            errorCodes: [Int(errSecCertificateRevoked)],
            description: "certificate revoked"
        ))
        XCTAssertFalse(FTPClient.shouldAllowFTPSCertificateOverride(
            errorCodes: [Int(errSecNotTrusted), Int(errSecCertificateRevoked)],
            description: "certificate revoked and not trusted"
        ))
        XCTAssertFalse(FTPClient.shouldAllowFTPSCertificateOverride(
            errorCodes: [Int(errSecNotTrusted)],
            description: "certificate revocation check failed"
        ))
    }
}

final class NetworkClientValidationTests: XCTestCase {
    func test_ftpRejectsInvalidPortBeforeOpeningSocket() async {
        let config = ServerConfig(
            displayName: "Invalid FTP",
            host: "127.0.0.1",
            port: 0,
            username: "u",
            protocol_: .ftp
        )
        await XCTAssertThrowsErrorAsync(try await FTPClient(config: config).connect(password: ""))
    }

    func test_sftpRejectsInvalidPortBeforeOpeningSocket() async {
        let config = ServerConfig(
            displayName: "Invalid SFTP",
            host: "127.0.0.1",
            port: 65_536,
            username: "u",
            protocol_: .sftp
        )
        await XCTAssertThrowsErrorAsync(try await SFTPClient(config: config).connect(password: ""))
    }
}

final class FTPClientParserTests: XCTestCase {

    func test_parsePASVExtractsHostAndPort() throws {
        let (host, port) = try FTPClient.parsePASV("227 Entering Passive Mode (192,168,1,2,195,80)")

        XCTAssertEqual(host, "192.168.1.2")
        XCTAssertEqual(port, 50_000)
    }

    func test_parsePASVRejectsMalformedResponses() {
        XCTAssertThrowsError(try FTPClient.parsePASV("227 Passive Mode unavailable"))
        XCTAssertThrowsError(try FTPClient.parsePASV("227 Entering Passive Mode (192,168,1,2,195)"))
        XCTAssertThrowsError(try FTPClient.parsePASV("227 Entering Passive Mode (192,168,1,999,195,80)"))
    }

    func test_parseEPSVExtractsAndValidatesPort() throws {
        XCTAssertEqual(try FTPClient.parseEPSV("229 Entering Extended Passive Mode (|||50000|)"), 50_000)
        XCTAssertThrowsError(try FTPClient.parseEPSV("229 Entering Extended Passive Mode (|||0|)"))
        XCTAssertThrowsError(try FTPClient.parseEPSV("229 Entering Extended Passive Mode (||50000|)"))
    }

    func test_parseMLSDParsesFactsAndSkipsDotEntries() {
        let raw = """
        type=dir;modify=20260102030405; docs\r
        type=file;size=42;modify=20260102030506; report final.txt\r
        type=file;size=1; .\r
        type=file;size=1; ..\r
        type=file;size=1; ../escape\r
        type=file;size=1; nested/file\r
        """

        let items = FTPClient.parseMLSD(raw, base: "/public")

        XCTAssertEqual(items.map(\.name), ["docs", "report final.txt"])
        XCTAssertEqual(items.map(\.path), ["/public/docs", "/public/report final.txt"])
        XCTAssertTrue(items[0].isDirectory)
        XCTAssertFalse(items[1].isDirectory)
        XCTAssertEqual(items[1].size, 42)
        XCTAssertNotNil(items[1].modifiedDate)
    }

    func test_parseLISTParsesUnixListingsWithNamesContainingSpaces() {
        let raw = """
        drwxr-xr-x  2 owner group 4096 Jan 10 12:30 docs\r
        -rw-r--r--  1 owner group 1234 Feb  2  2025 report final.txt\r
        -rw-r--r--  1 owner group 1 Feb  2  2025 .\r
        -rw-r--r--  1 owner group 1 Feb  2  2025 ../escape\r
        """

        let items = FTPClient.parseLIST(raw, base: "/")

        XCTAssertEqual(items.map(\.name), ["docs", "report final.txt"])
        XCTAssertEqual(items.map(\.path), ["/docs", "/report final.txt"])
        XCTAssertEqual(items[0].permissions, "drwxr-xr-x")
        XCTAssertTrue(items[0].isDirectory)
        XCTAssertFalse(items[1].isDirectory)
        XCTAssertEqual(items[1].size, 1234)
    }
}

final class FTPClientIntegrationTests: XCTestCase {
    func test_uploadHalfClosesDataConnectionAndHandlesMultilineWelcome() async throws {
        let server = try LocalFTPServer()
        server.start()
        defer { server.stop() }

        let localURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftftp-upload-\(UUID().uuidString).txt")
        let payload = Data("complete upload".utf8)
        try payload.write(to: localURL)
        defer { try? FileManager.default.removeItem(at: localURL) }

        let config = ServerConfig(
            displayName: "Local FTP",
            host: "127.0.0.1",
            port: Int(server.port),
            username: "tester",
            protocol_: .ftp
        )
        let client = FTPClient(config: config)

        try await client.connect(password: "secret")
        try await client.upload(
            localURL: localURL,
            remotePath: "/upload.txt",
            offset: 0,
            onProgress: { _ in }
        )
        XCTAssertEqual(server.receivedData, payload)
        await client.disconnect()
    }
}

private final class LocalFTPServer: @unchecked Sendable {
    let port: UInt16

    private let listenerFD: Int32
    private let queue = DispatchQueue(label: "swiftftp.tests.local-ftp")
    private let lock = NSLock()
    private var controlFD: Int32 = -1
    private var dataListenerFD: Int32 = -1
    private var uploadedData = Data()

    var receivedData: Data {
        lock.lock()
        defer { lock.unlock() }
        return uploadedData
    }

    init() throws {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        listenerFD = descriptor

        var reuse: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout.size(ofValue: reuse)))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bindResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0, Darwin.listen(descriptor, 1) == 0 else {
            Darwin.close(descriptor)
            throw POSIXError(.EADDRINUSE)
        }

        var boundAddress = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &boundAddress) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &length)
            }
        }
        guard nameResult == 0 else {
            Darwin.close(descriptor)
            throw POSIXError(.EIO)
        }
        port = UInt16(bigEndian: boundAddress.sin_port)
    }

    func start() {
        queue.async { [weak self] in self?.serve() }
    }

    func stop() {
        lock.lock()
        let control = controlFD
        let dataListener = dataListenerFD
        controlFD = -1
        dataListenerFD = -1
        lock.unlock()
        if control >= 0 {
            Darwin.shutdown(control, SHUT_RDWR)
            Darwin.close(control)
        }
        if dataListener >= 0 {
            Darwin.shutdown(dataListener, SHUT_RDWR)
            Darwin.close(dataListener)
        }
        Darwin.shutdown(listenerFD, SHUT_RDWR)
        Darwin.close(listenerFD)
    }

    private func serve() {
        let control = Darwin.accept(listenerFD, nil, nil)
        guard control >= 0 else { return }
        lock.lock()
        controlFD = control
        lock.unlock()
        send("220-Quay local integration server\r\n220 Ready\r\n", to: control)

        while let command = readLine(from: control) {
            let verb = command.split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
            switch verb.uppercased() {
            case "USER": send("331 Password required\r\n", to: control)
            case "PASS": send("230 Logged in\r\n", to: control)
            case "TYPE", "OPTS": send("200 OK\r\n", to: control)
            case "EPSV":
                guard let endpoint = makeDataListener() else {
                    send("425 Cannot open data connection\r\n", to: control)
                    continue
                }
                send("229 Entering Extended Passive Mode (|||\(endpoint)|)\r\n", to: control)
            case "STOR":
                send("150 Opening data connection\r\n", to: control)
                receiveUpload()
                send("226 Transfer complete\r\n", to: control)
            case "QUIT":
                send("221 Goodbye\r\n", to: control)
                return
            default:
                send("502 Unsupported\r\n", to: control)
            }
        }
    }

    private func makeDataListener() -> UInt16? {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return nil }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bindResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0, Darwin.listen(descriptor, 1) == 0 else {
            Darwin.close(descriptor)
            return nil
        }
        var boundAddress = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &boundAddress) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &length)
            }
        }
        guard nameResult == 0 else {
            Darwin.close(descriptor)
            return nil
        }
        lock.lock()
        dataListenerFD = descriptor
        lock.unlock()
        return UInt16(bigEndian: boundAddress.sin_port)
    }

    private func receiveUpload() {
        lock.lock()
        let listener = dataListenerFD
        lock.unlock()
        guard listener >= 0 else { return }
        let dataFD = Darwin.accept(listener, nil, nil)
        guard dataFD >= 0 else { return }
        defer {
            Darwin.close(dataFD)
            Darwin.close(listener)
            lock.lock()
            if dataListenerFD == listener { dataListenerFD = -1 }
            lock.unlock()
        }

        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Darwin.read(dataFD, &buffer, buffer.count)
            if count <= 0 { break }
            result.append(buffer, count: count)
        }
        lock.lock()
        uploadedData = result
        lock.unlock()
    }

    private func readLine(from descriptor: Int32) -> String? {
        var bytes: [UInt8] = []
        var byte: UInt8 = 0
        while Darwin.read(descriptor, &byte, 1) == 1 {
            bytes.append(byte)
            if bytes.count >= 2, bytes.suffix(2) == [13, 10] {
                return String(bytes: bytes.dropLast(2), encoding: .utf8)
            }
        }
        return nil
    }

    private func send(_ string: String, to descriptor: Int32) {
        let bytes = Array(string.utf8)
        bytes.withUnsafeBytes { rawBuffer in
            var sent = 0
            while sent < rawBuffer.count {
                let count = Darwin.write(
                    descriptor,
                    rawBuffer.baseAddress!.advanced(by: sent),
                    rawBuffer.count - sent
                )
                guard count > 0 else { return }
                sent += count
            }
        }
    }
}

// MARK: - KnownHosts Tests
final class KnownHostsManagerTests: XCTestCase {
    private var fileURL: URL!
    private var manager: KnownHostsManager!

    override func setUp() {
        super.setUp()
        fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftftp-known-hosts-\(UUID().uuidString).json")
        manager = KnownHostsManager(fileURL: fileURL)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: fileURL)
        manager = nil
        fileURL = nil
        super.tearDown()
    }

    func test_firstValidationStoresFingerprint() throws {
        try manager.validate(fingerprint: "SHA256:first", for: "example.com:22")
        XCTAssertEqual(manager.fingerprint(for: "example.com:22"), "SHA256:first")
    }

    func test_matchingFingerprintIsAccepted() throws {
        try manager.validate(fingerprint: "SHA256:first", for: "example.com:22")
        XCTAssertNoThrow(try manager.validate(fingerprint: "SHA256:first", for: "example.com:22"))
    }

    func test_mismatchedFingerprintThrows() throws {
        try manager.validate(fingerprint: "SHA256:first", for: "example.com:22")
        XCTAssertThrowsError(try manager.validate(fingerprint: "SHA256:changed", for: "example.com:22")) { error in
            guard case FTPError.hostKeyMismatch(let host) = error else {
                return XCTFail("Expected hostKeyMismatch, got \(error)")
            }
            XCTAssertEqual(host, "example.com:22")
        }
    }

    func test_firstValidationFailsClosedWhenFingerprintCannotBePersisted() throws {
        let blockingParent = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftftp-known-hosts-blocked-\(UUID().uuidString)")
        try Data("not-a-directory".utf8).write(to: blockingParent)
        defer { try? FileManager.default.removeItem(at: blockingParent) }
        let manager = KnownHostsManager(fileURL: blockingParent.appendingPathComponent("known-hosts.json"))

        XCTAssertThrowsError(try manager.validate(
            fingerprint: "SHA256:first",
            for: "example.com:22"
        ))
        XCTAssertNil(manager.fingerprint(for: "example.com:22"))
    }
}

// MARK: - ContinuationBox Concurrency Tests
final class ContinuationBoxTests: XCTestCase {

    /// Verifies that ContinuationBox can only be resumed once (no double-resume crash)
    func test_resumeOnlyOnce() async throws {
        let result: Int = try await withCheckedThrowingContinuation { cont in
            let box = ContinuationBox(cont)
            // Multiple resume attempts — only first should count
            box.resume(returning: 42)
            box.resume(returning: 99)   // should be ignored
        }
        XCTAssertEqual(result, 42)
    }
}

// MARK: - ConnectionPool Tests
private struct FakeTransferCall: Equatable, Sendable {
    let localPath: String
    let remotePath: String
    let offset: Int64
}

private enum FakeTransferOutcome: Sendable {
    case succeed
    case fail(FTPError)
}

private final class FakeFTPClient: AnyFTPClient, @unchecked Sendable {
    let config: ServerConfig
    let supportsResume: Bool = true

    private let lock = NSLock()
    private var connected = false
    private var connectError: Error?
    private var connectPasswords: [String] = []
    private var disconnectCalls = 0
    private var createdDirectories: [String] = []
    private var uploadCalls: [FakeTransferCall] = []
    private var uploadOutcomes: [FakeTransferOutcome] = []
    private var downloadCalls: [FakeTransferCall] = []
    private var downloadOutcomes: [FakeTransferOutcome] = []
    private var uploadsBlocked = false
    private var uploadWaiters: [CheckedContinuation<Void, Never>] = []

    init(config: ServerConfig) {
        self.config = config
    }

    var isConnected: Bool {
        get async { locked { connected } }
    }

    func setConnectError(_ error: Error?) {
        locked { connectError = error }
    }

    func connectPasswordValues() -> [String] {
        locked { connectPasswords }
    }

    func disconnectCallCount() -> Int {
        locked { disconnectCalls }
    }

    func createdDirectoryValues() -> [String] {
        locked { createdDirectories }
    }

    func uploadCallValues() -> [FakeTransferCall] {
        locked { uploadCalls }
    }

    func downloadCallValues() -> [FakeTransferCall] {
        locked { downloadCalls }
    }

    func enqueueUploadOutcome(_ outcome: FakeTransferOutcome) {
        locked { uploadOutcomes.append(outcome) }
    }

    func enqueueDownloadOutcome(_ outcome: FakeTransferOutcome) {
        locked { downloadOutcomes.append(outcome) }
    }

    func setUploadsBlocked(_ blocked: Bool) {
        let waiters = locked { () -> [CheckedContinuation<Void, Never>] in
            uploadsBlocked = blocked
            guard !blocked else { return [] }
            let current = uploadWaiters
            uploadWaiters.removeAll()
            return current
        }
        waiters.forEach { $0.resume() }
    }

    func connect(password: String) async throws {
        let error = locked { () -> Error? in
            connectPasswords.append(password)
            return connectError
        }
        if let error { throw error }
        locked { connected = true }
    }

    func disconnect() async {
        locked {
            connected = false
            disconnectCalls += 1
        }
    }

    func listDirectory(_ path: String) async throws -> [RemoteFileItem] { [] }
    func createDirectory(_ path: String) async throws {
        locked { createdDirectories.append(path) }
    }
    func delete(path: String, isDirectory: Bool) async throws {}
    func rename(from: String, to: String) async throws {}
    func setPermissions(_ octal: Int, path: String) async throws {}

    func upload(
        localURL: URL,
        remotePath: String,
        offset: Int64,
        onProgress: @Sendable @escaping (TransferProgress) -> Void
    ) async throws {
        let outcome = locked { () -> FakeTransferOutcome in
            uploadCalls.append(FakeTransferCall(
                localPath: localURL.path,
                remotePath: remotePath,
                offset: offset
            ))
            return uploadOutcomes.isEmpty ? .succeed : uploadOutcomes.removeFirst()
        }
        switch outcome {
        case .succeed:
            if locked({ uploadsBlocked }) {
                await withCheckedContinuation { continuation in
                    let resumeImmediately = locked { () -> Bool in
                        guard uploadsBlocked else { return true }
                        uploadWaiters.append(continuation)
                        return false
                    }
                    if resumeImmediately { continuation.resume() }
                }
            }
            onProgress(TransferProgress(bytesTransferred: 100, totalBytes: 100, bytesPerSecond: 50))
        case .fail(let error):
            throw error
        }
    }

    func download(
        remotePath: String,
        localURL: URL,
        offset: Int64,
        onProgress: @Sendable @escaping (TransferProgress) -> Void
    ) async throws {
        let outcome = locked { () -> FakeTransferOutcome in
            downloadCalls.append(FakeTransferCall(
                localPath: localURL.path,
                remotePath: remotePath,
                offset: offset
            ))
            return downloadOutcomes.isEmpty ? .succeed : downloadOutcomes.removeFirst()
        }
        switch outcome {
        case .succeed:
            onProgress(TransferProgress(bytesTransferred: 100, totalBytes: 100, bytesPerSecond: 50))
        case .fail(let error):
            throw error
        }
    }

    func fileSize(at path: String) async throws -> Int64 { 0 }

    @discardableResult
    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

private final class FakeClientFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var queuedClients: [FakeFTPClient]
    private var createdCount = 0

    init(_ clients: [FakeFTPClient]) {
        self.queuedClients = clients
    }

    func makeClient(for config: ServerConfig) -> any AnyFTPClient {
        lock.lock()
        defer { lock.unlock() }
        createdCount += 1
        if !queuedClients.isEmpty {
            return queuedClients.removeFirst()
        }
        return FakeFTPClient(config: config)
    }

    func makeCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return createdCount
    }
}

final class ConnectionPoolTests: XCTestCase {

    func test_pool_reusesReturnedConnectedClient() async throws {
        let config = makeConfig()
        let client = FakeFTPClient(config: config)
        let factory = FakeClientFactory([client])
        let pool = ConnectionPool(serverConfig: config, maxSize: 2, clientFactory: factory.makeClient)

        let borrowed = try await pool.borrowClient(password: "secret")
        XCTAssertTrue((borrowed as AnyObject) === client)
        await pool.returnClient(borrowed)

        let borrowedAgain = try await pool.borrowClient()
        XCTAssertTrue((borrowedAgain as AnyObject) === client)
        XCTAssertEqual(factory.makeCount(), 1)
        let totalCount = await pool.totalCount
        XCTAssertEqual(totalCount, 1)
        XCTAssertEqual(client.connectPasswordValues(), ["secret"])
    }

    func test_pool_handsReturnedClientToNextWaiterWhenFull() async throws {
        let config = makeConfig()
        let client = FakeFTPClient(config: config)
        let pool = ConnectionPool(
            serverConfig: config,
            maxSize: 1,
            clientFactory: FakeClientFactory([client]).makeClient
        )

        let borrowed = try await pool.borrowClient()
        let waitingBorrow = Task { try await pool.borrowClient() }

        try await Task.sleep(nanoseconds: 20_000_000)
        let activeCountBeforeReturn = await pool.activeCount
        XCTAssertEqual(activeCountBeforeReturn, 1)

        await pool.returnClient(borrowed)
        let handedOff = try await waitingBorrow.value

        XCTAssertTrue((handedOff as AnyObject) === client)
        let activeCountAfterHandoff = await pool.activeCount
        XCTAssertEqual(activeCountAfterHandoff, 1)

        await pool.returnClient(handedOff)
        let activeCountAfterReturn = await pool.activeCount
        XCTAssertEqual(activeCountAfterReturn, 0)
    }

    func test_pool_replacesDisconnectedIdleClient() async throws {
        let config = makeConfig()
        let staleClient = FakeFTPClient(config: config)
        let replacement = FakeFTPClient(config: config)
        let factory = FakeClientFactory([staleClient, replacement])
        let pool = ConnectionPool(serverConfig: config, maxSize: 1, clientFactory: factory.makeClient)

        let borrowed = try await pool.borrowClient()
        await pool.returnClient(borrowed)
        await staleClient.disconnect()

        let borrowedAgain = try await pool.borrowClient()

        XCTAssertTrue((borrowedAgain as AnyObject) === replacement)
        XCTAssertEqual(factory.makeCount(), 2)
        let totalCount = await pool.totalCount
        XCTAssertEqual(totalCount, 1)
    }

    func test_pool_removesReservedSlotWhenConnectFails() async throws {
        let config = makeConfig()
        let client = FakeFTPClient(config: config)
        client.setConnectError(FTPError.authenticationFailed)
        let factory = FakeClientFactory([client])
        let pool = ConnectionPool(serverConfig: config, maxSize: 1, clientFactory: factory.makeClient)

        do {
            _ = try await pool.borrowClient(password: "bad-password")
            XCTFail("Expected connect failure")
        } catch FTPError.authenticationFailed {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let totalCount = await pool.totalCount
        let activeCount = await pool.activeCount
        XCTAssertEqual(totalCount, 0)
        XCTAssertEqual(activeCount, 0)
        XCTAssertEqual(factory.makeCount(), 1)
        XCTAssertEqual(client.connectPasswordValues(), ["bad-password"])
    }

    func test_disconnectAllResumesWaitersWithNotConnected() async throws {
        let config = makeConfig()
        let client = FakeFTPClient(config: config)
        let pool = ConnectionPool(
            serverConfig: config,
            maxSize: 1,
            clientFactory: FakeClientFactory([client]).makeClient
        )

        _ = try await pool.borrowClient()
        let waitingBorrow = Task { try await pool.borrowClient() }

        try await Task.sleep(nanoseconds: 20_000_000)
        await pool.disconnectAll()

        do {
            _ = try await waitingBorrow.value
            XCTFail("Expected waiter to be resumed with notConnected")
        } catch FTPError.notConnected {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let isConnected = await client.isConnected
        XCTAssertFalse(isConnected)
        XCTAssertEqual(client.disconnectCallCount(), 1)
        let totalCount = await pool.totalCount
        XCTAssertEqual(totalCount, 0)
    }

    func test_cancelledWaiterDoesNotRequireAClientReturn() async throws {
        let config = makeConfig()
        let client = FakeFTPClient(config: config)
        let pool = ConnectionPool(
            serverConfig: config,
            maxSize: 1,
            clientFactory: FakeClientFactory([client]).makeClient
        )

        let borrowed = try await pool.borrowClient()
        let waitingBorrow = Task { try await pool.borrowClient() }
        try await Task.sleep(nanoseconds: 20_000_000)

        waitingBorrow.cancel()
        do {
            _ = try await waitingBorrow.value
            XCTFail("Expected CancellationError")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let activeCountWhileBorrowed = await pool.activeCount
        XCTAssertEqual(activeCountWhileBorrowed, 1)
        await pool.returnClient(borrowed)
        let activeCountAfterReturn = await pool.activeCount
        XCTAssertEqual(activeCountAfterReturn, 0)
    }

    private func makeConfig() -> ServerConfig {
        ServerConfig(
            displayName: "PoolTest",
            host: "pool.test",
            username: "u",
            protocol_: .sftp
        )
    }
}

// MARK: - Performance Tests
final class PerformanceTests: XCTestCase {

    func test_exclusionMatcher_performance() {
        let m = ExclusionMatcher(patterns: SyncWatcher.defaultExcludePatterns)
        let paths = (0..<1000).map { "/project/src/file\($0).swift" }
        measure {
            for path in paths { _ = m.shouldExclude(path) }
        }
    }

    func test_repository_fetchAll_performance() async throws {
        let key = "swiftftp.tests.performance.\(UUID().uuidString)"
        let repo = ServerRepository(key: key)
        // Pre-populate
        let configs = (0..<20).map {
            ServerConfig(displayName: "Server \($0)", host: "host\($0).com", username: "u")
        }
        for c in configs { try await repo.save(c) }
        measure { _ = repo.fetchAll() }
        for c in configs { await repo.delete(c.id) }
        UserDefaults.standard.removeObject(forKey: key)
    }
}
