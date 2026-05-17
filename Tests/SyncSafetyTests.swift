// SyncSafetyTests.swift — Guardrails for realtime sync rule creation.
// Run: Xcode → Product → Test (⌘U)
import XCTest
@testable import SwiftFTP

final class SyncPathValidatorTests: XCTestCase {

    // MARK: Forbidden local roots

    func test_forbiddenLocalRoot_systemSubtree() {
        XCTAssertEqual(
            SyncPathValidator.localRootStaticError("/usr/local/bin"),
            .forbiddenLocalRoot("/usr/local/bin")
        )
        // macOS firmlink: /private/var/db normalizes to /var/db.
        XCTAssertEqual(
            SyncPathValidator.localRootStaticError("/private/var/db"),
            .forbiddenLocalRoot("/var/db")
        )
    }

    func test_forbiddenLocalRoot_homeBroadFolder() {
        XCTAssertEqual(
            SyncPathValidator.localRootStaticError("/Users/alice/Documents"),
            .forbiddenLocalRoot("/Users/alice/Documents")
        )
        XCTAssertEqual(
            SyncPathValidator.localRootStaticError("/Users/alice/.ssh"),
            .forbiddenLocalRoot("/Users/alice/.ssh")
        )
    }

    func test_localTooShallow() {
        XCTAssertEqual(SyncPathValidator.localRootStaticError("/"), .localTooShallow("/"))
        XCTAssertEqual(SyncPathValidator.localRootStaticError("/tmp"), .localTooShallow("/tmp"))
        XCTAssertEqual(
            SyncPathValidator.localRootStaticError("/Users/alice"),
            .localTooShallow("/Users/alice")
        )
    }

    func test_emptyLocalPath() {
        XCTAssertEqual(SyncPathValidator.localRootStaticError("   "), .emptyLocalPath)
    }

    func test_safeLocalPath_passesStatic() {
        XCTAssertNil(SyncPathValidator.localRootStaticError("/Users/alice/projects/app"))
    }

    // MARK: Forbidden remote roots

    func test_forbiddenRemoteRoot_exact() {
        XCTAssertEqual(SyncPathValidator.remoteRootError("/"), .forbiddenRemoteRoot("/"))
        XCTAssertEqual(SyncPathValidator.remoteRootError("/usr"), .forbiddenRemoteRoot("/usr"))
        XCTAssertEqual(SyncPathValidator.remoteRootError("/var"), .forbiddenRemoteRoot("/var"))
    }

    func test_forbiddenRemoteRoot_subtree() {
        XCTAssertEqual(
            SyncPathValidator.remoteRootError("/etc/nginx/conf.d"),
            .forbiddenRemoteRoot("/etc/nginx/conf.d")
        )
    }

    func test_forbiddenRemoteRoot_windows() {
        XCTAssertEqual(SyncPathValidator.remoteRootError("C:\\"), .forbiddenRemoteRoot("C:\\"))
        XCTAssertEqual(
            SyncPathValidator.remoteRootError("C:\\Windows\\System32"),
            .forbiddenRemoteRoot("C:\\Windows\\System32")
        )
    }

    func test_remoteTooShallow() {
        XCTAssertEqual(
            SyncPathValidator.remoteRootError("/var/www"),
            .remoteTooShallow("/var/www")
        )
    }

    func test_remoteNotAbsolute() {
        XCTAssertEqual(
            SyncPathValidator.remoteRootError("relative/path/here"),
            .remoteNotAbsolute("relative/path/here")
        )
    }

    func test_emptyRemotePath() {
        XCTAssertEqual(SyncPathValidator.remoteRootError(""), .emptyRemotePath)
    }

    func test_safeRemotePath_passes() {
        XCTAssertNil(SyncPathValidator.remoteRootError("/var/www/html"))
        XCTAssertNil(SyncPathValidator.remoteRootError("/home/deploy/site"))
    }

    // MARK: Overlap

    func test_overlap_identicalAndNested() {
        let existing = [(local: "/Users/a/proj", remote: "/srv/site")]
        XCTAssertEqual(
            SyncPathValidator.overlapError(
                localPath: "/Users/a/proj/sub", remotePath: "/srv/other",
                existingRules: existing),
            .overlapsExistingRule(existing: "/Users/a/proj")
        )
        XCTAssertEqual(
            SyncPathValidator.overlapError(
                localPath: "/Users/a/elsewhere", remotePath: "/srv/site/deep",
                existingRules: existing),
            .overlapsExistingRule(existing: "/srv/site")
        )
    }

    func test_overlap_siblingsAllowed() {
        let existing = [(local: "/Users/a/proj", remote: "/srv/site")]
        XCTAssertNil(
            SyncPathValidator.overlapError(
                localPath: "/Users/a/other", remotePath: "/srv/other",
                existingRules: existing)
        )
    }

    func test_isSameOrNested_componentAware() {
        XCTAssertTrue(SyncPathValidator.isSameOrNested("/a/b", "/a/b/c"))
        XCTAssertTrue(SyncPathValidator.isSameOrNested("/a/b", "/a/b"))
        // "/a/bc" must NOT be considered nested under "/a/b"
        XCTAssertFalse(SyncPathValidator.isSameOrNested("/a/bc", "/a/b"))
    }

    // MARK: Filesystem checks

    func test_localPathMissing() {
        let missing = "/this/path/should/not/exist/\(UUID().uuidString)"
        XCTAssertEqual(
            SyncPathValidator.localRootFilesystemError(missing),
            .localPathMissing(missing)
        )
    }

    func test_realDirectoryPassesFilesystemCheck() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftftp-safe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertNil(SyncPathValidator.localRootFilesystemError(dir.path))
    }

    func test_symlinkRootRejected() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftftp-sym-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let real = base.appendingPathComponent("real", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let link = base.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        defer { try? FileManager.default.removeItem(at: base) }

        XCTAssertEqual(
            SyncPathValidator.localRootFilesystemError(link.path),
            .localRootIsSymlink(SyncPathValidator.normalize(link.path))
        )
    }
}

final class SyncConflictDecisionTests: XCTestCase {

    func test_skips_whenRemoteNewerBeyondSkew() {
        let local = Date(timeIntervalSince1970: 1_000_000)
        let remote = local.addingTimeInterval(10)
        XCTAssertTrue(
            SyncConflictDecision.shouldSkipUpload(localModified: local, remoteModified: remote)
        )
    }

    func test_uploads_whenWithinSkew() {
        let local = Date(timeIntervalSince1970: 1_000_000)
        let remote = local.addingTimeInterval(1) // < 2s default skew
        XCTAssertFalse(
            SyncConflictDecision.shouldSkipUpload(localModified: local, remoteModified: remote)
        )
    }

    func test_uploads_whenLocalNewer() {
        let local = Date(timeIntervalSince1970: 1_000_000)
        let remote = local.addingTimeInterval(-30)
        XCTAssertFalse(
            SyncConflictDecision.shouldSkipUpload(localModified: local, remoteModified: remote)
        )
    }

    func test_uploads_whenRemoteUnknown() {
        XCTAssertFalse(
            SyncConflictDecision.shouldSkipUpload(localModified: Date(), remoteModified: nil)
        )
    }

    func test_uploads_whenLocalUnknown() {
        XCTAssertFalse(
            SyncConflictDecision.shouldSkipUpload(localModified: nil, remoteModified: Date())
        )
    }
}

final class MandatorySecretExcludeTests: XCTestCase {

    /// Even with an empty user pattern set, the mandatory layer must still
    /// stop private keys / credentials from being synced.
    func test_mandatoryExcludes_blockSecretsWithNoUserPatterns() {
        let m = ExclusionMatcher(patterns: SyncWatcher.mandatorySecretExcludes)
        XCTAssertTrue(m.shouldExclude("/proj/.ssh/id_rsa"))
        XCTAssertTrue(m.shouldExclude("/proj/id_ed25519"))
        XCTAssertTrue(m.shouldExclude("/proj/server.pem"))
        XCTAssertTrue(m.shouldExclude("/proj/.env"))
        XCTAssertTrue(m.shouldExclude("/proj/private.key"))
        XCTAssertFalse(m.shouldExclude("/proj/Sources/main.swift"))
    }
}
