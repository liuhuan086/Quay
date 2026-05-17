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

final class RemoteDriftDetectorTests: XCTestCase {

    func test_reportDetectsRemoteMissingExtraAndOutdatedItems() {
        let base = Date(timeIntervalSince1970: 1_000_000)
        let report = RemoteDriftDetector.report(
            localItems: [
                SyncSnapshotItem(relativePath: "Sources", isDirectory: true),
                SyncSnapshotItem(relativePath: "Sources/App.swift", isDirectory: false, size: 10),
                SyncSnapshotItem(
                    relativePath: "README.md",
                    isDirectory: false,
                    size: 20,
                    modifiedDate: base.addingTimeInterval(20)
                )
            ],
            remoteItems: [
                SyncSnapshotItem(
                    relativePath: "README.md",
                    isDirectory: false,
                    size: 10,
                    modifiedDate: base
                ),
                SyncSnapshotItem(relativePath: "RemoteOnly", isDirectory: true),
                SyncSnapshotItem(relativePath: "RemoteOnly/log.txt", isDirectory: false, size: 1)
            ]
        )

        XCTAssertEqual(Set(report.remoteMissing.map(\.kind)), [.remoteMissingDirectory, .remoteMissingFile])
        XCTAssertEqual(report.remoteMissing.map(\.relativePath), ["Sources", "Sources/App.swift"])
        XCTAssertEqual(report.remoteOutdatedFiles.map(\.relativePath), ["README.md"])
        XCTAssertEqual(Set(report.remoteExtras.map(\.relativePath)), ["RemoteOnly", "RemoteOnly/log.txt"])
        XCTAssertTrue(report.conflicts.isEmpty)
    }

    func test_reportDetectsRemoteNewerTypeMismatchAndCaseFoldCollision() {
        let base = Date(timeIntervalSince1970: 1_000_000)
        let report = RemoteDriftDetector.report(
            localItems: [
                SyncSnapshotItem(relativePath: "config", isDirectory: false, size: 1),
                SyncSnapshotItem(relativePath: "Readme.md", isDirectory: false, size: 1),
                SyncSnapshotItem(
                    relativePath: "server.swift",
                    isDirectory: false,
                    size: 10,
                    modifiedDate: base
                )
            ],
            remoteItems: [
                SyncSnapshotItem(relativePath: "config", isDirectory: true),
                SyncSnapshotItem(relativePath: "README.md", isDirectory: false, size: 1),
                SyncSnapshotItem(
                    relativePath: "server.swift",
                    isDirectory: false,
                    size: 12,
                    modifiedDate: base.addingTimeInterval(20)
                )
            ]
        )

        XCTAssertTrue(report.issues.contains {
            $0.kind == .typeMismatch && $0.relativePath == "config"
        })
        XCTAssertTrue(report.issues.contains {
            $0.kind == .caseFoldCollision && $0.relativePath == "Readme.md ↔ README.md"
        })
        XCTAssertTrue(report.issues.contains {
            $0.kind == .remoteNewerFile && $0.relativePath == "server.swift"
        })
        XCTAssertTrue(report.remoteMissing.isEmpty)
        XCTAssertTrue(report.remoteExtras.isEmpty)
    }

    func test_unreliableRemoteTimestampBecomesUncertainDrift() {
        let report = RemoteDriftDetector.report(
            localItems: [
                SyncSnapshotItem(relativePath: "file.txt", isDirectory: false, size: 1)
            ],
            remoteItems: [
                SyncSnapshotItem(relativePath: "file.txt", isDirectory: false, size: 1)
            ],
            options: RemoteDriftDetectorOptions(remoteTimestampQuality: .unreliable)
        )

        XCTAssertEqual(report.conflicts.map(\.kind), [.timestampUncertain])
        XCTAssertTrue(report.repairUploadFiles.isEmpty)
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

final class SwiftFTPTempFileTests: XCTestCase {

    func test_temporaryRemotePathAppendsMarkerToFinalPath() {
        XCTAssertEqual(
            SwiftFTPTempFile.temporaryRemotePath(for: "/Users/liuhuan/Downloads/docs/main.swift"),
            "/Users/liuhuan/Downloads/docs/main.swift.__swiftftp_tmp__"
        )
        XCTAssertEqual(
            SwiftFTPTempFile.temporaryRemotePath(for: "docs/main.swift"),
            "docs/main.swift.__swiftftp_tmp__"
        )
    }

    func test_finalRemotePathStripsTemporaryMarker() {
        XCTAssertEqual(
            SwiftFTPTempFile.finalRemotePath(
                forTemporaryPath: "/Users/liuhuan/Downloads/docs/main.swift.__swiftftp_tmp__"
            ),
            "/Users/liuhuan/Downloads/docs/main.swift"
        )
        XCTAssertNil(SwiftFTPTempFile.finalRemotePath(forTemporaryPath: "/Users/liuhuan/docs/main.swift"))
    }

    func test_temporaryNameDetectionHandlesPrefixSuffixAndCase() {
        XCTAssertTrue(SwiftFTPTempFile.isTemporaryFileName("main.swift.__swiftftp_tmp__"))
        XCTAssertTrue(SwiftFTPTempFile.isTemporaryFileName(".__swiftftp_tmp__uploading"))
        XCTAssertTrue(SwiftFTPTempFile.isTemporaryFileName("MAIN.SWIFT.__SWIFTFTP_TMP__"))
        XCTAssertFalse(SwiftFTPTempFile.isTemporaryFileName("main.swift"))
    }
}

final class ManagedMirrorRootTests: XCTestCase {

    func test_markerUsesCanonicalRemoteRootAndWatcherIdentity() {
        let id = UUID()
        let watcher = mirrorWatcher(id: id, remotePath: "/Users/LiuHuan/Downloads/docs/../docs")
        let createdAt = Date(timeIntervalSince1970: 1_000)

        let marker = ManagedMirrorRoot.marker(
            for: watcher,
            appVersion: "2.0.0",
            createdAt: createdAt
        )

        XCTAssertEqual(marker.schemaVersion, ManagedMirrorRootMarker.currentSchemaVersion)
        XCTAssertEqual(marker.appVersion, "2.0.0")
        XCTAssertEqual(marker.ruleID, id)
        XCTAssertEqual(marker.localRootDisplayPath, "/Users/huan/Downloads/docs")
        XCTAssertEqual(marker.canonicalRemoteRoot, "/users/liuhuan/downloads/docs")
        XCTAssertEqual(marker.createdAt, createdAt)
        XCTAssertEqual(marker.mode, .oneWayMirror)
    }

    func test_markerAndCanaryPathsStayInsideCanonicalRemoteRoot() {
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

        XCTAssertEqual(
            ManagedMirrorRoot.markerPath(remoteRoot: "/Users/liuhuan/Downloads/docs"),
            "/Users/liuhuan/Downloads/docs/.swiftftp-mirror.json"
        )
        XCTAssertEqual(
            ManagedMirrorRoot.canaryTemporaryPath(remoteRoot: "/Users/liuhuan/Downloads/docs", ruleID: id),
            "/Users/liuhuan/Downloads/docs/.swiftftp-canary-00000000-0000-0000-0000-000000000001.tmp"
        )
        XCTAssertEqual(
            ManagedMirrorRoot.canaryFinalPath(remoteRoot: "/Users/liuhuan/Downloads/docs", ruleID: id),
            "/Users/liuhuan/Downloads/docs/.swiftftp-canary-00000000-0000-0000-0000-000000000001.ok"
        )
    }

    func test_validateAcceptsMatchingMarker() throws {
        let watcher = mirrorWatcher(remotePath: "/Users/liuhuan/Downloads/docs")
        let marker = ManagedMirrorRoot.marker(
            for: watcher,
            appVersion: "2.0.0",
            createdAt: Date(timeIntervalSince1970: 1_000)
        )

        XCTAssertNoThrow(try ManagedMirrorRoot.validate(marker: marker, for: watcher))
    }

    func test_validateRejectsMismatchedRuleRootModeAndSchema() {
        let watcher = mirrorWatcher(remotePath: "/Users/liuhuan/Downloads/docs")

        var wrongRule = ManagedMirrorRoot.marker(for: watcher, appVersion: "2.0.0")
        wrongRule.ruleID = UUID()
        XCTAssertThrowsError(try ManagedMirrorRoot.validate(marker: wrongRule, for: watcher))

        var wrongRoot = ManagedMirrorRoot.marker(for: watcher, appVersion: "2.0.0")
        wrongRoot.canonicalRemoteRoot = "/users/liuhuan/downloads/other"
        XCTAssertThrowsError(try ManagedMirrorRoot.validate(marker: wrongRoot, for: watcher))

        var wrongMode = ManagedMirrorRoot.marker(for: watcher, appVersion: "2.0.0")
        wrongMode.mode = .realtimeUpload
        XCTAssertThrowsError(try ManagedMirrorRoot.validate(marker: wrongMode, for: watcher))

        var wrongSchema = ManagedMirrorRoot.marker(for: watcher, appVersion: "2.0.0")
        wrongSchema.schemaVersion = 999
        XCTAssertThrowsError(try ManagedMirrorRoot.validate(marker: wrongSchema, for: watcher))

        var realtimeWatcher = watcher
        realtimeWatcher.mode = .realtimeUpload
        realtimeWatcher.mirrorDeleteEnabled = false
        let realtimeMarker = ManagedMirrorRoot.marker(for: realtimeWatcher, appVersion: "2.0.0")
        XCTAssertThrowsError(try ManagedMirrorRoot.validate(marker: realtimeMarker, for: realtimeWatcher))
    }

    func test_destructiveTargetMustStayInsideManagedRoot() throws {
        let watcher = mirrorWatcher(remotePath: "/Users/liuhuan/Downloads/docs")
        let marker = ManagedMirrorRoot.marker(for: watcher, appVersion: "2.0.0")

        XCTAssertTrue(ManagedMirrorRoot.contains(
            "/Users/liuhuan/Downloads/docs/Sources/main.swift",
            inRemoteRoot: marker.canonicalRemoteRoot
        ))
        XCTAssertTrue(ManagedMirrorRoot.contains(
            "/Users/liuhuan/Downloads/docs",
            inRemoteRoot: marker.canonicalRemoteRoot
        ))
        XCTAssertFalse(ManagedMirrorRoot.contains(
            "/Users/liuhuan/Downloads/docs-backup/file.txt",
            inRemoteRoot: marker.canonicalRemoteRoot
        ))
        XCTAssertFalse(ManagedMirrorRoot.contains(
            "/etc/passwd",
            inRemoteRoot: marker.canonicalRemoteRoot
        ))

        XCTAssertNoThrow(try ManagedMirrorRoot.validateDestructiveTarget(
            "/Users/liuhuan/Downloads/docs/Sources/main.swift",
            for: marker
        ))
        XCTAssertThrowsError(try ManagedMirrorRoot.validateDestructiveTarget(
            "/Users/liuhuan/Downloads/docs-backup/file.txt",
            for: marker
        ))
    }

    func test_trashPathPreservesDisplayRootAndRejectsEscapes() throws {
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let timestamp = Date(timeIntervalSince1970: 0)

        let trashPath = try ManagedMirrorRoot.trashPath(
            remoteRoot: "/Users/liuhuan/Downloads/docs",
            ruleID: id,
            targetRemotePath: "/Users/liuhuan/Downloads/docs/Sources/Main.swift",
            timestamp: timestamp
        )

        XCTAssertEqual(
            trashPath,
            "/Users/liuhuan/Downloads/docs/.swiftftp-trash/00000000-0000-0000-0000-000000000002/19700101T000000.000Z/Sources/Main.swift"
        )
        XCTAssertThrowsError(try ManagedMirrorRoot.trashPath(
            remoteRoot: "/Users/liuhuan/Downloads/docs",
            ruleID: id,
            targetRemotePath: "/Users/liuhuan/Downloads/docs-backup/Main.swift",
            timestamp: timestamp
        ))
    }

    func test_trashPathPreservesTargetRelativeCaseForCaseOnlyRootMismatch() throws {
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
        let timestamp = Date(timeIntervalSince1970: 0)

        let trashPath = try ManagedMirrorRoot.trashPath(
            remoteRoot: "/Users/liuhuan/Downloads/docs",
            ruleID: id,
            targetRemotePath: "/users/liuhuan/downloads/docs/Sources/Main.swift",
            timestamp: timestamp
        )

        XCTAssertEqual(
            trashPath,
            "/Users/liuhuan/Downloads/docs/.swiftftp-trash/00000000-0000-0000-0000-000000000003/19700101T000000.000Z/Sources/Main.swift"
        )
    }

    private func mirrorWatcher(
        id: UUID = UUID(),
        remotePath: String
    ) -> SyncWatcher {
        SyncWatcher(
            id: id,
            serverID: UUID(),
            serverName: "Mac",
            localPath: "/Users/huan/Downloads/docs",
            localPathBookmark: nil,
            remotePath: remotePath,
            excludePatterns: [],
            mode: .oneWayMirror,
            initialSyncPolicy: .uploadMissingAndNewer,
            mirrorDeleteEnabled: true,
            isActive: true,
            lastSyncAt: nil,
            totalSynced: 0
        )
    }
}

final class MirrorLocalSnapshotDiffTests: XCTestCase {

    func test_deletedCandidatesCollapseChildrenOfDeletedDirectories() {
        let previous = [
            "Sources": true,
            "Sources/Main.swift": false,
            "Sources/Views": true,
            "Sources/Views/AppView.swift": false,
            "Docs/guide.md": false,
            "README.md": false
        ]
        let current = [
            "README.md": false
        ]

        XCTAssertEqual(
            MirrorLocalSnapshotDiff.deletedCandidates(previous: previous, current: current),
            [
                MirrorDeleteCandidate(relativePath: "Sources", isDirectory: true),
                MirrorDeleteCandidate(relativePath: "Docs/guide.md", isDirectory: false)
            ]
        )
    }

    func test_deletedCandidatesAreEmptyWhenSnapshotOnlyGainsFiles() {
        XCTAssertEqual(
            MirrorLocalSnapshotDiff.deletedCandidates(
                previous: ["README.md": false],
                current: ["README.md": false, "Sources/Main.swift": false]
            ),
            []
        )
    }
}

final class MirrorDeleteSafetyPolicyTests: XCTestCase {

    func test_exceedsRealtimeDeleteThresholdCountsOnlyRecentEvents() {
        let now = Date(timeIntervalSince1970: 1_000)
        let previous = [
            now.addingTimeInterval(-10),
            now.addingTimeInterval(-20),
            now.addingTimeInterval(-70)
        ]

        XCTAssertEqual(
            MirrorDeleteSafetyPolicy.recentDeleteCount(previous, now: now),
            2
        )
        XCTAssertFalse(
            MirrorDeleteSafetyPolicy.exceedsRealtimeDeleteThreshold(
                previousDeleteTimestamps: previous,
                incomingDeleteCount: 8,
                now: now
            )
        )
        XCTAssertTrue(
            MirrorDeleteSafetyPolicy.exceedsRealtimeDeleteThreshold(
                previousDeleteTimestamps: previous,
                incomingDeleteCount: 9,
                now: now
            )
        )
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
        XCTAssertEqual(watchers.first?.runtimeState, .running)
        XCTAssertNil(watchers.first?.lastDriftCheckAt)
    }

    func test_watcherModeRoundTrips() throws {
        let lastDriftCheck = Date(timeIntervalSince1970: 2_000)
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
            runtimeState: .driftDetected,
            lastSyncAt: nil,
            lastDriftCheckAt: lastDriftCheck,
            totalSynced: 0
        )

        let data = try JSONEncoder().encode([watcher])
        let decoded = try JSONDecoder().decode([SyncWatcher].self, from: data)
        XCTAssertEqual(decoded.first?.mode, .oneWayMirror)
        XCTAssertEqual(decoded.first?.initialSyncPolicy, .uploadMissingAndNewer)
        XCTAssertEqual(decoded.first?.mirrorDeleteEnabled, true)
        XCTAssertEqual(decoded.first?.runtimeState, .driftDetected)
        XCTAssertEqual(decoded.first?.lastDriftCheckAt, lastDriftCheck)
    }

    func test_legacyInactiveWatcherDecodesAsPaused() throws {
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
          "isActive": false,
          "totalSynced": 0
        }]
        """.data(using: .utf8)!

        let watchers = try JSONDecoder().decode([SyncWatcher].self, from: json)
        XCTAssertEqual(watchers.first?.runtimeState, .paused)
    }
}

final class SyncWatcherRuntimeStateTests: XCTestCase {

    func test_defaultStateFollowsActiveFlag() {
        XCTAssertEqual(SyncWatcherRuntimeState.defaultState(isActive: true), .running)
        XCTAssertEqual(SyncWatcherRuntimeState.defaultState(isActive: false), .paused)
    }

    func test_displayNamesAreUserVisible() {
        XCTAssertEqual(SyncWatcherRuntimeState.running.displayName, "监控中")
        XCTAssertEqual(SyncWatcherRuntimeState.paused.displayName, "已暂停")
        XCTAssertEqual(SyncWatcherRuntimeState.checkingDrift.displayName, "检查远端")
        XCTAssertEqual(SyncWatcherRuntimeState.driftDetected.displayName, "发现漂移")
        XCTAssertEqual(SyncWatcherRuntimeState.permissionLost.displayName, "权限失效")
        XCTAssertEqual(SyncWatcherRuntimeState.error.displayName, "需要处理")
    }
}

final class SyncDriftAuditPolicyTests: XCTestCase {

    func test_activeWatcherWithoutPriorCheckIsDue() {
        let watcher = makeWatcher(isActive: true, lastDriftCheckAt: nil)

        XCTAssertTrue(SyncDriftAuditPolicy.shouldRun(
            watcher: watcher,
            now: Date(timeIntervalSince1970: 1_000)
        ))
    }

    func test_inactiveWatcherIsNeverDue() {
        let watcher = makeWatcher(isActive: false, lastDriftCheckAt: nil)

        XCTAssertFalse(SyncDriftAuditPolicy.shouldRun(
            watcher: watcher,
            now: Date(timeIntervalSince1970: 1_000)
        ))
    }

    func test_respectsMinimumInterval() {
        let last = Date(timeIntervalSince1970: 1_000)
        let watcher = makeWatcher(isActive: true, lastDriftCheckAt: last)

        XCTAssertFalse(SyncDriftAuditPolicy.shouldRun(
            watcher: watcher,
            now: last.addingTimeInterval(299),
            minimumInterval: 300
        ))
        XCTAssertTrue(SyncDriftAuditPolicy.shouldRun(
            watcher: watcher,
            now: last.addingTimeInterval(300),
            minimumInterval: 300
        ))
    }

    private func makeWatcher(
        isActive: Bool,
        lastDriftCheckAt: Date?
    ) -> SyncWatcher {
        SyncWatcher(
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
            isActive: isActive,
            lastSyncAt: nil,
            lastDriftCheckAt: lastDriftCheckAt,
            totalSynced: 0
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

    func test_mandatoryExcludes_areCaseInsensitive() {
        let m = ExclusionMatcher(patterns: SyncWatcher.mandatorySecretExcludes)
        XCTAssertTrue(m.shouldExclude("/proj/.SSH/ID_RSA"))
        XCTAssertTrue(m.shouldExclude("/proj/.Env"))
        XCTAssertTrue(m.shouldExclude("/proj/.AWS/credentials"))
        XCTAssertTrue(m.shouldExclude("/proj/PRIVATE.KEY"))
    }
}
