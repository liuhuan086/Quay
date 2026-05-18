// SwiftFTPv2Tests.swift — Comprehensive unit tests
// Run: Xcode → Product → Test  (⌘U)
import XCTest
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

    func test_protocol_isSecure() {
        XCTAssertFalse(ConnectionProtocol.ftp.isSecure)
        XCTAssertTrue(ConnectionProtocol.ftps.isSecure)
        XCTAssertTrue(ConnectionProtocol.sftp.isSecure)
    }

    func test_allowSelfSignedTLS_defaultsFalse() {
        let c = ServerConfig(displayName: "T", host: "h.com", username: "u", protocol_: .ftps)
        XCTAssertFalse(c.allowSelfSignedTLS)
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

    override func setUp() {
        super.setUp()
        repoKey = "swiftftp.tests.servers.\(UUID().uuidString)"
        repo = ServerRepository(key: repoKey)
    }

    override func tearDown() async throws {
        for server in repo.fetchAll() {
            try await repo.delete(server.id)
        }
        UserDefaults.standard.removeObject(forKey: repoKey)
        repo = nil
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
        try await repo.delete(c.id)
        XCTAssertFalse(repo.fetchAll().contains(where: { $0.id == c.id }))
    }

    func test_exportImport() async throws {
        let c = makeCfg("Export")
        try await repo.save(c)
        let data = try repo.exportJSON()
        XCTAssertFalse(data.isEmpty)
        try await repo.delete(c.id)
        try await repo.importJSON(data)
        XCTAssertTrue(repo.fetchAll().contains(where: { $0.id == c.id }))
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
        defer {
            KeychainManager.shared.deletePassword(for: id.uuidString)
        }

        let fetched = repo.fetchAll()
        XCTAssertEqual(fetched.first?.password, "")
        let resolved = try await repo.password(for: id)
        XCTAssertEqual(resolved, "legacy-secret")
        XCTAssertEqual(try KeychainManager.shared.getPassword(for: id.uuidString), "legacy-secret")

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
        defer {
            KeychainManager.shared.deletePassword(for: id1.uuidString)
            KeychainManager.shared.deletePassword(for: id2.uuidString)
        }

        // On-demand lookup for the first server (before any bulk migration)
        // must not erase the second server's still-unmigrated password.
        let one = try await repo.password(for: id1)
        XCTAssertEqual(one, "secret-one")

        let two = try await repo.password(for: id2)
        XCTAssertEqual(two, "secret-two")
        XCTAssertEqual(try KeychainManager.shared.getPassword(for: id2.uuidString), "secret-two")

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
        defer {
            KeychainManager.shared.deletePassword(for: legacyID.uuidString)
        }

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
        defer {
            KeychainManager.shared.deletePassword(for: legacyID.uuidString)
        }

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

    private func makeCfg(_ name: String, password: String = "") -> ServerConfig {
        ServerConfig(displayName: name, host: "test.local", username: "u", password: password)
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
final class ConnectionPoolTests: XCTestCase {

    func test_pool_creates_connection_up_to_max() async throws {
        // Can't easily test with real FTP server in unit tests.
        // Test the pool's eviction and state management.
        let config = ServerConfig(displayName: "PoolTest", host: "127.0.0.1",
                                  port: 9999, username: "u", protocol_: .ftp)
        let pool = ConnectionPool(serverConfig: config, maxSize: 2)

        // Disconnect all (no-op on empty pool)
        await pool.disconnectAll()
        let count = await pool.totalCount
        XCTAssertEqual(count, 0)
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
        for c in configs { try await repo.delete(c.id) }
        UserDefaults.standard.removeObject(forKey: key)
    }
}
