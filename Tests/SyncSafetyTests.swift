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

    func test_forbiddenLocalRoot_sensitiveHomeDescendants() {
        XCTAssertEqual(
            SyncPathValidator.localRootStaticError("/Users/alice/Library/Application Support/App"),
            .forbiddenLocalRoot("/Users/alice/Library/Application Support/App")
        )
        XCTAssertEqual(
            SyncPathValidator.localRootStaticError("/Users/alice/.aws/profiles"),
            .forbiddenLocalRoot("/Users/alice/.aws/profiles")
        )
        XCTAssertNil(SyncPathValidator.localRootStaticError("/Users/alice/Downloads/project"))
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
        XCTAssertEqual(
            SyncPathValidator.remoteRootError("/usr/local/bin"),
            .forbiddenRemoteRoot("/usr/local/bin")
        )
        XCTAssertEqual(
            SyncPathValidator.remoteRootError("/opt/app/bin"),
            .forbiddenRemoteRoot("/opt/app/bin")
        )
    }

    func test_forbiddenRemoteRoot_windows() {
        XCTAssertEqual(SyncPathValidator.remoteRootError("C:\\"), .forbiddenRemoteRoot("C:/"))
        XCTAssertEqual(
            SyncPathValidator.remoteRootError("C:\\Windows\\System32"),
            .forbiddenRemoteRoot("C:/Windows/System32")
        )
    }

    func test_forbiddenRemoteRoot_homeKnownFolders() {
        XCTAssertEqual(
            SyncPathValidator.remoteRootError("/Users/alice/Downloads"),
            .forbiddenRemoteRoot("/Users/alice/Downloads")
        )
        XCTAssertEqual(
            SyncPathValidator.remoteRootError("/home/alice/.ssh/configs"),
            .forbiddenRemoteRoot("/home/alice/.ssh/configs")
        )
        XCTAssertNil(SyncPathValidator.remoteRootError("/Users/alice/Downloads/project"))
        XCTAssertNil(SyncPathValidator.remoteRootError("/home/alice/project"))
    }

    func test_forbiddenRemoteRoot_windowsKnownFolders() {
        XCTAssertEqual(
            SyncPathValidator.remoteRootError("C:\\Users\\Alice"),
            .forbiddenRemoteRoot("C:/Users/Alice")
        )
        XCTAssertEqual(
            SyncPathValidator.remoteRootError("C:\\Users\\Alice\\Downloads"),
            .forbiddenRemoteRoot("C:/Users/Alice/Downloads")
        )
        XCTAssertEqual(
            SyncPathValidator.remoteRootError("C:\\Users\\Alice\\AppData\\Roaming"),
            .forbiddenRemoteRoot("C:/Users/Alice/AppData/Roaming")
        )
        XCTAssertNil(SyncPathValidator.remoteRootError("C:\\Users\\Alice\\Downloads\\project"))
    }

    func test_remoteCanonicalPath_resolvesDotSegments() {
        XCTAssertEqual(
            SyncPathValidator.canonicalRemotePath("/home/user/project/../../etc"),
            "/home/etc"
        )
        XCTAssertEqual(
            SyncPathValidator.canonicalRemotePath("/C:/Users/Alice/Downloads/../Project"),
            "c:/users/alice/project"
        )
        XCTAssertNotNil(SyncPathValidator.remoteRootError("/home/user/project/../../etc"))
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

    func test_overlap_remoteCanonicalized() {
        let existing = [(local: "/Users/a/proj", remote: "/home/a/project")]
        XCTAssertEqual(
            SyncPathValidator.overlapError(
                localPath: "/Users/a/elsewhere",
                remotePath: "/home/a/project/../project/src",
                existingRules: existing
            ),
            .overlapsExistingRule(existing: "/home/a/project")
        )

        let windows = [(local: "/Users/a/windows", remote: "C:\\Users\\Alice\\Downloads\\project")]
        XCTAssertEqual(
            SyncPathValidator.overlapError(
                localPath: "/Users/a/elsewhere",
                remotePath: "C:/Users/Alice/Downloads/project/sub",
                existingRules: windows
            ),
            .overlapsExistingRule(existing: "C:\\Users\\Alice\\Downloads\\project")
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

final class InitialSyncPlannerTests: XCTestCase {

    func test_uploadModePlansLocalOnlyAndSkipsRemoteOnly() {
        let plan = InitialSyncPlanner.plan(
            localItems: [
                SyncSnapshotItem(relativePath: "Sources", isDirectory: true),
                SyncSnapshotItem(relativePath: "Sources/main.swift", isDirectory: false, size: 10)
            ],
            remoteItems: [
                SyncSnapshotItem(relativePath: "remote-only.txt", isDirectory: false, size: 5)
            ]
        )

        XCTAssertEqual(plan.createDirectories.map(\.relativePath), ["Sources"])
        XCTAssertEqual(plan.uploads.map(\.relativePath), ["Sources/main.swift"])
        XCTAssertEqual(plan.skipped.map(\.kind), [.skipRemoteOnly])
        XCTAssertTrue(plan.conflicts.isEmpty)
    }

    func test_sharedFilesPlanOverwriteSkipAndRemoteNewerConflict() {
        let base = Date(timeIntervalSince1970: 1_000_000)
        let plan = InitialSyncPlanner.plan(
            localItems: [
                SyncSnapshotItem(
                    relativePath: "newer.swift",
                    isDirectory: false,
                    size: 20,
                    modifiedDate: base.addingTimeInterval(20)
                ),
                SyncSnapshotItem(
                    relativePath: "same.swift",
                    isDirectory: false,
                    size: 10,
                    modifiedDate: base
                ),
                SyncSnapshotItem(
                    relativePath: "remote-newer.swift",
                    isDirectory: false,
                    size: 10,
                    modifiedDate: base
                )
            ],
            remoteItems: [
                SyncSnapshotItem(
                    relativePath: "newer.swift",
                    isDirectory: false,
                    size: 10,
                    modifiedDate: base
                ),
                SyncSnapshotItem(
                    relativePath: "same.swift",
                    isDirectory: false,
                    size: 10,
                    modifiedDate: base.addingTimeInterval(1)
                ),
                SyncSnapshotItem(
                    relativePath: "remote-newer.swift",
                    isDirectory: false,
                    size: 12,
                    modifiedDate: base.addingTimeInterval(20)
                )
            ]
        )

        XCTAssertEqual(plan.overwrites.map(\.relativePath), ["newer.swift"])
        XCTAssertEqual(plan.skipped.map(\.relativePath), ["same.swift"])
        XCTAssertEqual(plan.conflicts.map(\.kind), [.remoteNewer])
        XCTAssertEqual(plan.conflicts.map(\.relativePath), ["remote-newer.swift"])
    }

    func test_allowLocalWinsTurnsRemoteNewerIntoOverwrite() {
        let base = Date(timeIntervalSince1970: 1_000_000)
        let plan = InitialSyncPlanner.plan(
            localItems: [
                SyncSnapshotItem(relativePath: "file.txt", isDirectory: false, size: 1, modifiedDate: base)
            ],
            remoteItems: [
                SyncSnapshotItem(
                    relativePath: "file.txt",
                    isDirectory: false,
                    size: 2,
                    modifiedDate: base.addingTimeInterval(20)
                )
            ],
            options: InitialSyncPlannerOptions(allowLocalWins: true)
        )

        XCTAssertEqual(plan.overwrites.map(\.relativePath), ["file.txt"])
        XCTAssertTrue(plan.conflicts.isEmpty)
    }

    func test_typeMismatchStopsPlanningForThatPath() {
        let plan = InitialSyncPlanner.plan(
            localItems: [
                SyncSnapshotItem(relativePath: "config", isDirectory: false, size: 10)
            ],
            remoteItems: [
                SyncSnapshotItem(relativePath: "config", isDirectory: true)
            ]
        )

        XCTAssertEqual(plan.conflicts.map(\.kind), [.typeMismatch])
        XCTAssertTrue(plan.overwrites.isEmpty)
        XCTAssertTrue(plan.uploads.isEmpty)
    }

    func test_mirrorModePlansRemoteOnlyDeletesWithoutExecuting() {
        let plan = InitialSyncPlanner.plan(
            localItems: [],
            remoteItems: [
                SyncSnapshotItem(relativePath: "old", isDirectory: true),
                SyncSnapshotItem(relativePath: "old/file.txt", isDirectory: false, size: 10)
            ],
            options: InitialSyncPlannerOptions(mode: .oneWayMirror(deleteRemote: true))
        )

        XCTAssertEqual(Set(plan.remoteDeletes.map(\.relativePath)), ["old", "old/file.txt"])
        XCTAssertEqual(Set(plan.remoteDeletes.map(\.kind)), [.deleteRemoteDirectory, .deleteRemoteFile])
        XCTAssertTrue(plan.skipped.isEmpty)
    }

    func test_caseFoldCollisionsBecomeConflicts() {
        let localCollision = InitialSyncPlanner.plan(
            localItems: [
                SyncSnapshotItem(relativePath: "Readme.md", isDirectory: false),
                SyncSnapshotItem(relativePath: "README.md", isDirectory: false)
            ],
            remoteItems: []
        )
        XCTAssertEqual(localCollision.conflicts.map(\.kind), [.caseFoldCollision])
        XCTAssertTrue(localCollision.uploads.isEmpty)

        let crossSideCollision = InitialSyncPlanner.plan(
            localItems: [
                SyncSnapshotItem(relativePath: "Readme.md", isDirectory: false)
            ],
            remoteItems: [
                SyncSnapshotItem(relativePath: "README.md", isDirectory: false)
            ]
        )
        XCTAssertEqual(crossSideCollision.conflicts.map(\.kind), [.caseFoldCollision])
    }

    func test_unreliableRemoteTimestampBecomesConflictUnlessLocalWins() {
        let plan = InitialSyncPlanner.plan(
            localItems: [
                SyncSnapshotItem(relativePath: "file.txt", isDirectory: false, size: 1)
            ],
            remoteItems: [
                SyncSnapshotItem(relativePath: "file.txt", isDirectory: false, size: 1)
            ],
            options: InitialSyncPlannerOptions(remoteTimestampQuality: .unreliable)
        )

        XCTAssertEqual(plan.conflicts.map(\.kind), [.timestampUncertain])
        XCTAssertTrue(plan.overwrites.isEmpty)
    }

    func test_invalidRelativePathIsConflict() {
        let plan = InitialSyncPlanner.plan(
            localItems: [
                SyncSnapshotItem(relativePath: "../escape.txt", isDirectory: false)
            ],
            remoteItems: []
        )

        XCTAssertEqual(plan.conflicts.map(\.kind), [.invalidRelativePath])
        XCTAssertTrue(plan.uploads.isEmpty)
    }
}

final class SyncRuleCreationPolicyTests: XCTestCase {

    func test_futureOnlyBlocksOnlySharedLocalRemoteContent() {
        var plan = InitialSyncPlan()
        plan.uploads = [
            InitialSyncPlanAction(kind: .uploadNewFile, relativePath: "local-only.txt")
        ]
        plan.overwrites = [
            InitialSyncPlanAction(kind: .overwriteRemoteFile, relativePath: "changed.txt")
        ]
        plan.skipped = [
            InitialSyncPlanAction(kind: .skipIdentical, relativePath: "same.txt"),
            InitialSyncPlanAction(kind: .skipRemoteOnly, relativePath: "remote-only.txt")
        ]

        let blocking = SyncRuleCreationPolicy
            .existingRemoteContentBlockingFutureOnlyCreation(in: plan)

        XCTAssertEqual(blocking.map(\.relativePath), ["changed.txt", "same.txt"])
    }

    func test_remoteTimestampQualityMatchesProtocolCapabilities() {
        XCTAssertEqual(SyncRuleCreationPolicy.remoteTimestampQuality(for: .sftp), .reliable)
        XCTAssertEqual(SyncRuleCreationPolicy.remoteTimestampQuality(for: .ftp), .unreliable)
        XCTAssertEqual(SyncRuleCreationPolicy.remoteTimestampQuality(for: .ftps), .unreliable)
    }

    func test_plannerOptionsPreserveMirrorDeleteAcknowledgement() {
        let uploadOptions = SyncRuleCreationPolicy.plannerOptions(
            mode: .realtimeUpload,
            remoteProtocol: .sftp
        )
        XCTAssertEqual(uploadOptions.mode, .realtimeUpload)
        XCTAssertEqual(uploadOptions.remoteTimestampQuality, .reliable)

        let mirrorOptions = SyncRuleCreationPolicy.plannerOptions(
            mode: .oneWayMirror,
            remoteProtocol: .ftp,
            mirrorDeleteAcknowledged: true
        )
        XCTAssertEqual(mirrorOptions.mode, .oneWayMirror(deleteRemote: true))
        XCTAssertEqual(mirrorOptions.remoteTimestampQuality, .unreliable)
    }
}

final class SyncWatcherCodingTests: XCTestCase {

    func test_legacyWatcherDecodesWithSafeDefaults() throws {
        let id = UUID()
        let serverID = UUID()
        let json = """
        [{
          "id": "\(id.uuidString)",
          "serverID": "\(serverID.uuidString)",
          "serverName": "Mac",
          "localPath": "/Users/alice/project",
          "remotePath": "/home/alice/project",
          "excludePatterns": [],
          "isActive": true,
          "totalSynced": 0
        }]
        """.data(using: .utf8)!

        let watchers = try JSONDecoder().decode([SyncWatcher].self, from: json)
        XCTAssertEqual(watchers.first?.mode, .realtimeUpload)
        XCTAssertEqual(watchers.first?.initialSyncPolicy, .futureOnly)
        XCTAssertEqual(watchers.first?.mirrorDeleteEnabled, false)
    }

    func test_watcherModeRoundTrips() throws {
        let watcher = SyncWatcher(
            id: UUID(),
            serverID: UUID(),
            serverName: "Mac",
            localPath: "/Users/alice/project",
            localPathBookmark: nil,
            remotePath: "/home/alice/project",
            excludePatterns: [],
            mode: .oneWayMirror,
            initialSyncPolicy: .uploadMissingAndNewer,
            mirrorDeleteEnabled: true,
            isActive: true,
            lastSyncAt: nil,
            totalSynced: 0
        )

        let data = try JSONEncoder().encode([watcher])
        let decoded = try JSONDecoder().decode([SyncWatcher].self, from: data)
        XCTAssertEqual(decoded.first?.mode, .oneWayMirror)
        XCTAssertEqual(decoded.first?.initialSyncPolicy, .uploadMissingAndNewer)
        XCTAssertEqual(decoded.first?.mirrorDeleteEnabled, true)
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

    func test_mandatoryExcludes_areCaseInsensitive() {
        let m = ExclusionMatcher(patterns: SyncWatcher.mandatorySecretExcludes)
        XCTAssertTrue(m.shouldExclude("/proj/.SSH/ID_RSA"))
        XCTAssertTrue(m.shouldExclude("/proj/.Env"))
        XCTAssertTrue(m.shouldExclude("/proj/.AWS/credentials"))
        XCTAssertTrue(m.shouldExclude("/proj/PRIVATE.KEY"))
    }
}
