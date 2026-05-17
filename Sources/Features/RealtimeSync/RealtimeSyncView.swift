// RealtimeSyncView.swift — Real-time sync with FSEvents
import SwiftUI
import Combine
import AppKit

// MARK: - SyncManager (actor, owns the watcher)
actor SyncManager {
    private let watcher = FSEventWatcher()
    private var cancellables = Set<AnyCancellable>()
    private var scopedURLs: [URL] = []
    var onFileChange: (@Sendable (FileChangeEvent, SyncWatcher) -> Void)?
    var onBookmarkStale: (@Sendable (SyncWatcher) -> Void)?
    var onScanTruncated: (@Sendable (String, SyncWatcher, Int) -> Void)?
    var onMirrorDeleteThresholdExceeded: (@Sendable (SyncWatcher, Int, Int) -> Void)?
    private var mirrorLocalSnapshots: [UUID: [String: Bool]] = [:]

    private struct DirectoryScanResult: Sendable {
        let paths: [String]
        let wasTruncated: Bool
        let limit: Int
    }

    func start(watchers: [SyncWatcher]) -> Set<UUID> {
        stopAll()
        let active = watchers.filter { $0.isActive }
        guard !active.isEmpty else { return [] }

        var usableWatchers: [SyncWatcher] = []
        var paths: [String] = []
        for watcher in active {
            guard let bookmark = watcher.localPathBookmark else {
                onBookmarkStale?(watcher)
                continue
            }

            do {
                var isStale = false
                let url = try URL(
                    resolvingBookmarkData: bookmark,
                    options: [.withSecurityScope],
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                )
                guard !isStale else {
                    onBookmarkStale?(watcher)
                    continue
                }
                guard url.startAccessingSecurityScopedResource() else {
                    onBookmarkStale?(watcher)
                    continue
                }
                scopedURLs.append(url)
                usableWatchers.append(watcher)
                paths.append(url.path)
                if isMirrorDeleteEnabled(watcher) {
                    let matcher = ExclusionMatcher(
                        patterns: watcher.excludePatterns + SyncWatcher.mandatorySecretExcludes
                    )
                    mirrorLocalSnapshots[watcher.id] = localSnapshotIndex(
                        rootPath: url.path,
                        matcher: matcher
                    )
                }
            } catch {
                onBookmarkStale?(watcher)
            }
        }
        guard !paths.isEmpty else { return [] }
        let dispatchWatchers = usableWatchers

        watcher.eventPublisher
            .receive(on: RunLoop.main)
            .sink { [weak self] event in
                Task { [weak self] in
                    await self?.dispatch(event: event, watchers: dispatchWatchers)
                }
            }
            .store(in: &cancellables)

        guard watcher.startWatching(paths: paths) else {
            stopAll()
            usableWatchers.forEach { onBookmarkStale?($0) }
            return []
        }
        return Set(usableWatchers.map(\.id))
    }

    func stopAll() {
        watcher.stopWatching()
        cancellables.removeAll()
        for url in scopedURLs {
            url.stopAccessingSecurityScopedResource()
        }
        scopedURLs.removeAll()
        mirrorLocalSnapshots.removeAll()
    }

    private func dispatch(event: FileChangeEvent, watchers: [SyncWatcher]) {
        for w in watchers where isPath(event.path, containedIn: w.localPath) {
            // Mandatory secret excludes are always layered on top of the
            // user's patterns so a cleared exclude box can't leak keys.
            let matcher = ExclusionMatcher(
                patterns: w.excludePatterns + SyncWatcher.mandatorySecretExcludes
            )

            if event.kind == .deleted {
                dispatchMirrorDelete(event: event, watcher: w, matcher: matcher)
                continue
            }

            if event.isDirectory || isDirectory(at: event.path) {
                let scan = recentlyChangedFiles(in: event.path, matcher: matcher)
                if scan.wasTruncated {
                    onScanTruncated?(event.path, w, scan.limit)
                }
                for path in scan.paths {
                    onFileChange?(FileChangeEvent(path: path, kind: event.kind, isDirectory: false), w)
                }
            } else if shouldSyncFile(at: event.path, matcher: matcher) {
                onFileChange?(event, w)
            }

            if isMirrorDeleteEnabled(w) {
                dispatchMissedMirrorDeletes(watcher: w, matcher: matcher)
            }
        }
    }

    private func isPath(_ path: String, containedIn rootPath: String) -> Bool {
        let root = normalizedPath(rootPath)
        let candidate = normalizedPath(path)
        guard root != "/" else { return true }
        return candidate == root || candidate.hasPrefix(root + "/")
    }

    private func normalizedPath(_ path: String) -> String {
        let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
        guard normalized != "/" else { return normalized }
        return normalized.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private func shouldSyncFile(at path: String, matcher: ExclusionMatcher) -> Bool {
        let name = (path as NSString).lastPathComponent
        if isSwiftFTPTempName(name) { return false }
        if let values = try? URL(fileURLWithPath: path)
            .resourceValues(forKeys: [.isSymbolicLinkKey]),
           values.isSymbolicLink == true { return false }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              !isDirectory.boolValue else { return false }
        return !matcher.shouldExclude(path)
    }

    private func isDirectory(at path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    private func recentlyChangedFiles(in directoryPath: String, matcher: ExclusionMatcher) -> DirectoryScanResult {
        let burstLimit = 500
        let rootURL = URL(fileURLWithPath: directoryPath, isDirectory: true)
        let cutoff = Date().addingTimeInterval(-30)
        let keys: [URLResourceKey] = [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .contentModificationDateKey,
            .creationDateKey
        ]
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: keys,
            options: [.skipsPackageDescendants]
        ) else {
            return DirectoryScanResult(paths: [], wasTruncated: false, limit: burstLimit)
        }

        // Cap a single directory-event burst so a large move/extract can't
        // blast thousands of uploads in one go.
        var paths: [String] = []
        var wasTruncated = false
        for case let fileURL as URL in enumerator {
            if paths.count >= burstLimit {
                wasTruncated = true
                break
            }
            let path = fileURL.path
            if isSwiftFTPTempName((path as NSString).lastPathComponent) { continue }
            if matcher.shouldExclude(path) { continue }
            guard let values = try? fileURL.resourceValues(forKeys: Set(keys)),
                  values.isSymbolicLink != true,
                  values.isRegularFile == true else { continue }
            let modifiedRecently = values.contentModificationDate.map { $0 >= cutoff } ?? false
            let createdRecently = values.creationDate.map { $0 >= cutoff } ?? false
            if modifiedRecently || createdRecently {
                paths.append(path)
            }
        }
        return DirectoryScanResult(paths: paths, wasTruncated: wasTruncated, limit: burstLimit)
    }

    private func isSwiftFTPTempName(_ name: String) -> Bool {
        SwiftFTPTempFile.isTemporaryFileName(name)
    }

    private func isMirrorDeleteEnabled(_ watcher: SyncWatcher) -> Bool {
        watcher.mode == .oneWayMirror && watcher.mirrorDeleteEnabled
    }

    private func dispatchMirrorDelete(
        event: FileChangeEvent,
        watcher: SyncWatcher,
        matcher: ExclusionMatcher
    ) {
        guard isMirrorDeleteEnabled(watcher),
              let relativePath = relativePath(event.path, in: watcher.localPath),
              !relativePath.isEmpty,
              !SwiftFTPTempFile.isTemporaryPath(relativePath),
              !matcher.shouldExclude(relativePath) else { return }

        let previous = mirrorLocalSnapshots[watcher.id] ?? [:]
        let isDirectory = event.isDirectory || previous[relativePath] == true
        removeFromMirrorSnapshot(watcherID: watcher.id, relativePath: relativePath)
        onFileChange?(
            FileChangeEvent(
                path: localPath(root: watcher.localPath, relative: relativePath),
                kind: .deleted,
                isDirectory: isDirectory
            ),
            watcher
        )
    }

    private func dispatchMissedMirrorDeletes(
        watcher: SyncWatcher,
        matcher: ExclusionMatcher
    ) {
        let previous = mirrorLocalSnapshots[watcher.id] ?? [:]
        let current = localSnapshotIndex(rootPath: watcher.localPath, matcher: matcher)
        let candidates = MirrorLocalSnapshotDiff.deletedCandidates(
            previous: previous,
            current: current
        )
        mirrorLocalSnapshots[watcher.id] = current
        guard !candidates.isEmpty else { return }

        if candidates.count > MirrorDeleteSafetyPolicy.maxRealtimeDeletesPerMinute {
            onMirrorDeleteThresholdExceeded?(
                watcher,
                candidates.count,
                MirrorDeleteSafetyPolicy.maxRealtimeDeletesPerMinute
            )
            return
        }

        for candidate in candidates {
            onFileChange?(
                FileChangeEvent(
                    path: localPath(root: watcher.localPath, relative: candidate.relativePath),
                    kind: .deleted,
                    isDirectory: candidate.isDirectory
                ),
                watcher
            )
        }
    }

    private func localSnapshotIndex(
        rootPath: String,
        matcher: ExclusionMatcher,
        maxItems: Int = 10_000
    ) -> [String: Bool] {
        let rootURL = URL(fileURLWithPath: rootPath, isDirectory: true).standardizedFileURL
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: keys,
            options: [.skipsPackageDescendants]
        ) else { return [:] }

        var snapshot: [String: Bool] = [:]
        for case let fileURL as URL in enumerator {
            guard snapshot.count < maxItems,
                  let relative = relativePath(fileURL.path, in: rootPath),
                  !relative.isEmpty,
                  !SwiftFTPTempFile.isTemporaryPath(relative) else { continue }

            let values = try? fileURL.resourceValues(forKeys: Set(keys))
            let isDirectory = values?.isDirectory == true
            if values?.isSymbolicLink == true {
                if isDirectory { enumerator.skipDescendants() }
                continue
            }
            if matcher.shouldExclude(relative) {
                if isDirectory { enumerator.skipDescendants() }
                continue
            }
            if isDirectory || values?.isRegularFile == true {
                snapshot[relative] = isDirectory
            }
        }
        return snapshot
    }

    private func removeFromMirrorSnapshot(watcherID: UUID, relativePath: String) {
        guard var snapshot = mirrorLocalSnapshots[watcherID] else { return }
        snapshot = snapshot.filter { path, _ in
            path != relativePath && !path.hasPrefix(relativePath + "/")
        }
        mirrorLocalSnapshots[watcherID] = snapshot
    }

    private func relativePath(_ path: String, in rootPath: String) -> String? {
        let root = URL(fileURLWithPath: rootPath).standardizedFileURL.path
        let candidate = URL(fileURLWithPath: path).standardizedFileURL.path
        if candidate == root { return "" }
        let prefix = root.hasSuffix("/") ? root : root + "/"
        guard candidate.hasPrefix(prefix) else { return nil }
        return String(candidate.dropFirst(prefix.count))
    }

    private func localPath(root: String, relative: String) -> String {
        let cleanRoot = root.hasSuffix("/") ? String(root.dropLast()) : root
        let cleanRelative = relative.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return cleanRoot + "/" + cleanRelative
    }
}

fileprivate struct PreparedSyncRule: Sendable {
    let localPath: String
    let localPathBookmark: Data
    let remotePath: String
    let excludePatterns: [String]
    let mode: SyncRuleMode
    let initialSyncPolicy: SyncInitialSyncPolicy
    let mirrorDeleteEnabled: Bool
    let plan: InitialSyncPlan
}

fileprivate struct PresentedRemoteDriftReport: Identifiable {
    let id = UUID()
    let watcher: SyncWatcher
    let report: RemoteDriftReport

    var canRepairRemote: Bool {
        !report.remoteMissingDirectories.isEmpty ||
            !report.repairUploadFiles.isEmpty ||
            (!report.remoteExtras.isEmpty &&
             watcher.mode == .oneWayMirror &&
             watcher.mirrorDeleteEnabled)
    }

    var message: String {
        var lines = [
            "本地：\(watcher.localPath)",
            "远程：\(watcher.remotePath)",
            "",
            "远程缺失：\(report.remoteMissing.count)",
            "远程额外：\(report.remoteExtras.count)",
            "远程较旧：\(report.remoteOutdatedFiles.count)",
            "远程较新：\(report.remoteNewerFiles.count)",
            "冲突：\(report.conflicts.count)"
        ]
        let preview = report.issues.prefix(10).map {
            "\(Self.issueLabel($0.kind))：\($0.relativePath)"
        }
        if !preview.isEmpty {
            lines.append("")
            lines.append("差异预览：")
            lines.append(contentsOf: preview)
            if report.issues.count > preview.count {
                lines.append("等 \(report.issues.count) 项")
            }
        }
        lines.append("")
        lines.append("修复只会写入远程，不会把远程变化同步回本地。")
        if !report.remoteExtras.isEmpty &&
            !(watcher.mode == .oneWayMirror && watcher.mirrorDeleteEnabled) {
            lines.append("远程额外项不会在实时上传规则中删除。")
        }
        return lines.joined(separator: "\n")
    }

    private static func issueLabel(_ kind: RemoteDriftIssueKind) -> String {
        switch kind {
        case .remoteMissingFile: return "远程缺失文件"
        case .remoteMissingDirectory: return "远程缺失目录"
        case .remoteExtraFile: return "远程额外文件"
        case .remoteExtraDirectory: return "远程额外目录"
        case .remoteOutdatedFile: return "远程较旧"
        case .remoteNewerFile: return "远程较新"
        case .typeMismatch: return "类型冲突"
        case .caseFoldCollision: return "大小写冲突"
        case .timestampUncertain: return "时间戳不确定"
        case .invalidRelativePath: return "路径无效"
        }
    }
}

fileprivate enum DriftDetectionPresentation {
    case manual
    case scheduled

    var showsNoDriftAlert: Bool {
        self == .manual
    }

    var showsErrors: Bool {
        self == .manual
    }
}

// MARK: - RealtimeSyncViewModel
@MainActor
final class RealtimeSyncViewModel: ObservableObject {
    @Published var watchers: [SyncWatcher] = []
    @Published var showAddSheet = false
    @Published var recentEvents: [(String, Date)] = []   // (filename, time)
    @Published var conflicts: [(String, Date)] = []      // skipped: remote newer
    @Published var scanWarnings: [(String, Date)] = []   // directory scan truncated
    @Published var driftWarnings: [(String, Date)] = []   // remote drift detected
    @Published var isValidating = false
    @Published fileprivate var pendingDriftReport: PresentedRemoteDriftReport?
    @Published private var runningWatcherIDs: Set<UUID> = []

    private let appState: AppState
    private let server: ServerConfig
    private let syncManager = SyncManager()
    private var mirrorDeleteHistory: [UUID: [Date]] = [:]
    private var driftAuditCancellable: AnyCancellable?
    private var driftAuditBootstrapTask: Task<Void, Never>?
    private var runningDriftAuditIDs: Set<UUID> = []

    var activeCount: Int { runningWatcherIDs.count }
    var hasFullAccess: Bool { appState.hasFullAccess }

    init(appState: AppState, server: ServerConfig) {
        self.appState = appState
        self.server = server
        self.watchers = appState.syncWatchers.values.filter { $0.serverID == server.id }
        wireSyncManager()
        startScheduledDriftAudits()
    }

    // MARK: - Add watcher
    @discardableResult
    func addWatcher(
        localPath: String,
        localPathBookmark: Data,
        remotePath: String,
        excludePatterns: [String],
        mode: SyncRuleMode = .realtimeUpload,
        initialSyncPolicy: SyncInitialSyncPolicy = .futureOnly,
        mirrorDeleteEnabled: Bool = false,
        isActive: Bool = true,
        refresh: Bool = true
    ) -> SyncWatcher {
        let w = SyncWatcher(
            id: UUID(), serverID: server.id, serverName: server.displayName,
            localPath: localPath, localPathBookmark: localPathBookmark, remotePath: remotePath,
            excludePatterns: excludePatterns, mode: mode,
            initialSyncPolicy: initialSyncPolicy, mirrorDeleteEnabled: mirrorDeleteEnabled,
            isActive: isActive,
            lastSyncAt: nil, totalSynced: 0
        )
        watchers.append(w)
        appState.upsertSyncWatcher(w)
        if refresh { refreshWatcher() }
        return w
    }

    /// Full safety-gated creation: path validation → recursive dry-run plan.
    /// Returns a prepared rule only when creation is safe to confirm.
    fileprivate func prepareWatcher(
        localPath: String,
        localPathBookmark: Data,
        remotePath: String,
        excludePatterns: [String],
        mode: SyncRuleMode,
        initialSyncPolicy: SyncInitialSyncPolicy,
        mirrorDeleteEnabled: Bool = false
    ) async -> PreparedSyncRule? {
        isValidating = true
        defer { isValidating = false }

        let existing = watchers.map { (local: $0.localPath, remote: $0.remotePath) }
        if let error = SyncPathValidator.validate(
            localPath: localPath,
            remotePath: remotePath,
            existingRules: existing
        ) {
            appState.alertItem = AlertItem(title: "无法创建同步规则", message: error.message)
            return nil
        }

        let matcher = ExclusionMatcher(
            patterns: excludePatterns + SyncWatcher.mandatorySecretExcludes
        )
        let localItems: [SyncSnapshotItem]
        do {
            localItems = try localSnapshot(localPath: localPath, matcher: matcher)
        } catch {
            appState.alertItem = AlertItem(
                title: "无法创建同步规则",
                message: "无法读取本地文件夹「\(localPath)」的内容，请重新选择。"
            )
            return nil
        }

        let remoteItems: [SyncSnapshotItem]
        do {
            remoteItems = try await appState.remoteSnapshot(
                server: server,
                path: remotePath,
                matcher: matcher
            )
        } catch {
            appState.showError(error)
            return nil
        }

        let effectiveInitialSyncPolicy: SyncInitialSyncPolicy = mode == .oneWayMirror
            ? .uploadMissingAndNewer
            : initialSyncPolicy
        let plan = InitialSyncPlanner.plan(
            localItems: localItems,
            remoteItems: remoteItems,
            options: SyncRuleCreationPolicy.plannerOptions(
                mode: mode,
                remoteProtocol: server.protocol_,
                mirrorDeleteAcknowledged: mirrorDeleteEnabled
            )
        )

        if !plan.conflicts.isEmpty {
            appState.alertItem = AlertItem(
                title: "初始同步计划存在冲突",
                message: conflictMessage(for: plan)
            )
            return nil
        }

        if mode == .oneWayMirror &&
            plan.remoteDeletes.count > MirrorDeleteSafetyPolicy.maxRealtimeDeletesPerMinute {
            appState.alertItem = AlertItem(
                title: "镜像删除数量过多",
                message: "初始镜像计划需要移动 \(plan.remoteDeletes.count) 个远程项目到回收站，超过当前安全阈值 \(MirrorDeleteSafetyPolicy.maxRealtimeDeletesPerMinute) 个。请先清理远程目录，或选择一个空的专用目录。"
            )
            return nil
        }

        if mode == .realtimeUpload && effectiveInitialSyncPolicy == .futureOnly {
            let shared = SyncRuleCreationPolicy
                .existingRemoteContentBlockingFutureOnlyCreation(in: plan)
            if !shared.isEmpty {
                let shown = shared.prefix(8).map(\.relativePath).joined(separator: "、")
                let more = shared.count > 8 ? " 等 \(shared.count) 个" : ""
                appState.alertItem = AlertItem(
                    title: "远程目录已存在同路径内容",
                    message: "远程路径「\(remotePath)」中已存在与本地同路径的文件或文件夹：\(shown)\(more)。如要创建规则，请选择“先上传缺失和较新的本地文件”，或改用空的专用远程目录。"
                )
                return nil
            }
        }

        return PreparedSyncRule(
            localPath: localPath,
            localPathBookmark: localPathBookmark,
            remotePath: remotePath,
            excludePatterns: excludePatterns,
            mode: mode,
            initialSyncPolicy: effectiveInitialSyncPolicy,
            mirrorDeleteEnabled: mode == .oneWayMirror && mirrorDeleteEnabled,
            plan: plan
        )
    }

    fileprivate func commitPreparedWatcher(_ prepared: PreparedSyncRule) async {
        let startsActive = prepared.mode == .realtimeUpload
        let watcher = addWatcher(
            localPath: prepared.localPath,
            localPathBookmark: prepared.localPathBookmark,
            remotePath: prepared.remotePath,
            excludePatterns: prepared.excludePatterns,
            mode: prepared.mode,
            initialSyncPolicy: prepared.initialSyncPolicy,
            mirrorDeleteEnabled: prepared.mirrorDeleteEnabled,
            isActive: startsActive,
            refresh: startsActive
        )

        if prepared.mode == .oneWayMirror {
            do {
                try await appState.writeManagedMirrorRootMarker(server: server, watcher: watcher)
                _ = try await appState.verifyManagedMirrorRoot(
                    server: server,
                    watcher: watcher,
                    performCanary: true
                )
                activateWatcher(watcher)
            } catch {
                watchers.removeAll { $0.id == watcher.id }
                appState.removeSyncWatcher(watcher)
                appState.showError(error)
                refreshWatcher()
                return
            }
        }

        guard prepared.initialSyncPolicy == .uploadMissingAndNewer else { return }
        await appState.createRemoteDirectories(
            server: server,
            remoteRoot: prepared.remotePath,
            relativeDirectories: prepared.plan.createDirectories.map(\.relativePath)
        )
        let uploadActions = prepared.plan.uploads + prepared.plan.overwrites
        for action in uploadActions {
            guard let local = action.local, !local.isDirectory else { continue }
            await appState.enqueue(
                server: server,
                direction: .upload,
                localURL: URL(fileURLWithPath: prepared.localPath)
                    .appendingPathComponent(action.relativePath),
                remotePath: remotePath(root: prepared.remotePath, relative: action.relativePath),
                isAutoSync: true
            )
        }
        if prepared.mode == .oneWayMirror {
            for action in prepared.plan.remoteDeletes {
                let quarantinedPath = await appState.quarantineRemotePath(
                    server: server,
                    watcher: watcher,
                    targetRemotePath: remotePath(root: prepared.remotePath, relative: action.relativePath)
                )
                if quarantinedPath == nil {
                    syncWatcherFromAppState(watcher)
                    return
                }
            }
        }
    }

    private func localSnapshot(
        localPath: String,
        matcher: ExclusionMatcher,
        maxItems: Int = 10_000
    ) throws -> [SyncSnapshotItem] {
        let rootURL = URL(fileURLWithPath: localPath, isDirectory: true).standardizedFileURL
        let rootPath = rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/"
        let keys: [URLResourceKey] = [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
            .contentModificationDateKey
        ]
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: keys,
            options: [.skipsPackageDescendants]
        ) else {
            throw FTPError.fileNotFound(localPath)
        }

        var snapshot: [SyncSnapshotItem] = []
        for case let fileURL as URL in enumerator {
            let path = fileURL.standardizedFileURL.path
            guard path.hasPrefix(rootPath) else { continue }
            let relativePath = String(path.dropFirst(rootPath.count))
            guard !relativePath.isEmpty else { continue }
            if SwiftFTPTempFile.isTemporaryPath(relativePath) { continue }

            let values = try? fileURL.resourceValues(forKeys: Set(keys))
            let isDirectory = values?.isDirectory == true
            if values?.isSymbolicLink == true {
                if isDirectory { enumerator.skipDescendants() }
                continue
            }
            if matcher.shouldExclude(relativePath) {
                if isDirectory { enumerator.skipDescendants() }
                continue
            }
            if isDirectory {
                snapshot.append(
                    SyncSnapshotItem(relativePath: relativePath, isDirectory: true)
                )
            } else if values?.isRegularFile == true {
                snapshot.append(
                    SyncSnapshotItem(
                        relativePath: relativePath,
                        isDirectory: false,
                        size: Int64(values?.fileSize ?? 0),
                        modifiedDate: values?.contentModificationDate
                    )
                )
            }
            guard snapshot.count <= maxItems else {
                throw FTPError.unsupported("本地目录文件过多（超过 \(maxItems) 项），请缩小同步范围。")
            }
        }
        return snapshot
    }

    private func conflictMessage(for plan: InitialSyncPlan) -> String {
        let shown = plan.conflicts.prefix(8).map { conflict in
            switch conflict.kind {
            case .invalidRelativePath:
                return "\(conflict.relativePath)：路径无效"
            case .caseFoldCollision:
                return "\(conflict.relativePath)：大小写冲突"
            case .typeMismatch:
                return "\(conflict.relativePath)：文件/文件夹类型不一致"
            case .remoteNewer:
                return "\(conflict.relativePath)：远程更新，未覆盖"
            case .timestampUncertain:
                return "\(conflict.relativePath)：时间戳不可靠，无法安全判断"
            }
        }.joined(separator: "\n")
        let more = plan.conflicts.count > 8 ? "\n等 \(plan.conflicts.count) 个冲突。" : ""
        return "已停止创建同步规则。请先处理以下冲突：\n\(shown)\(more)"
    }

    private func remotePath(root: String, relative: String) -> String {
        let cleanRoot = root.hasSuffix("/") ? String(root.dropLast()) : root
        let cleanRelative = relative.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return cleanRoot.isEmpty ? "/" + cleanRelative : cleanRoot + "/" + cleanRelative
    }

    // MARK: - Toggle active
    func toggle(_ watcher: SyncWatcher) {
        guard let idx = watchers.firstIndex(where: { $0.id == watcher.id }) else { return }
        watchers[idx].isActive.toggle()
        appState.upsertSyncWatcher(watchers[idx])
        refreshWatcher()
    }

    private func activateWatcher(_ watcher: SyncWatcher) {
        guard let idx = watchers.firstIndex(where: { $0.id == watcher.id }) else { return }
        watchers[idx].isActive = true
        appState.upsertSyncWatcher(watchers[idx])
        refreshWatcher()
    }

    private func pauseWatcher(_ watcher: SyncWatcher, title: String, message: String) {
        guard let idx = watchers.firstIndex(where: { $0.id == watcher.id }) else { return }
        watchers[idx].isActive = false
        appState.upsertSyncWatcher(watchers[idx])
        appState.alertItem = AlertItem(title: title, message: message)
        refreshWatcher()
    }

    private func syncWatcherFromAppState(_ watcher: SyncWatcher) {
        guard let updated = appState.syncWatchers[watcher.id],
              let idx = watchers.firstIndex(where: { $0.id == watcher.id }) else { return }
        watchers[idx] = updated
        refreshWatcher()
    }

    // MARK: - Remove watcher
    func remove(_ watcher: SyncWatcher) {
        watchers.removeAll { $0.id == watcher.id }
        appState.removeSyncWatcher(watcher)
        refreshWatcher()
    }

    func checkRemoteDrift(_ watcher: SyncWatcher) {
        let tracked = markDriftCheckStarted(watcherID: watcher.id, at: Date()) ?? watcher
        Task { [weak self] in
            guard let self else { return }
            await self.detectRemoteDrift(for: tracked, presentation: .manual)
        }
    }

    private func detectRemoteDrift(
        for watcher: SyncWatcher,
        presentation: DriftDetectionPresentation
    ) async {
        guard let bookmark = watcher.localPathBookmark else {
            if presentation.showsErrors {
                appState.alertItem = AlertItem(
                    title: "无法检测远端漂移",
                    message: "本地目录缺少沙盒授权，请重新添加同步规则。"
                )
            }
            return
        }

        let url: URL
        do {
            var isStale = false
            url = try URL(
                resolvingBookmarkData: bookmark,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            guard !isStale else {
                if presentation.showsErrors {
                    appState.alertItem = AlertItem(
                        title: "无法检测远端漂移",
                        message: "本地目录授权已过期，请重新添加同步规则。"
                    )
                }
                return
            }
        } catch {
            if presentation.showsErrors {
                appState.showError(error)
            }
            return
        }

        guard url.startAccessingSecurityScopedResource() else {
            if presentation.showsErrors {
                appState.alertItem = AlertItem(
                    title: "无法检测远端漂移",
                    message: "SwiftFTP 无法访问本地目录，请重新添加同步规则。"
                )
            }
            return
        }
        defer { url.stopAccessingSecurityScopedResource() }

        let matcher = ExclusionMatcher(patterns: driftExcludePatterns(for: watcher))
        do {
            let localItems = try localSnapshot(localPath: url.path, matcher: matcher)
            let remoteItems = try await appState.remoteSnapshot(
                server: server,
                path: watcher.remotePath,
                matcher: matcher
            )
            let report = RemoteDriftDetector.report(
                localItems: localItems,
                remoteItems: remoteItems,
                options: RemoteDriftDetectorOptions(
                    remoteTimestampQuality: SyncRuleCreationPolicy.remoteTimestampQuality(for: server.protocol_)
                )
            )
            if report.hasDrift {
                driftWarnings.insert((watcher.remotePath, Date()), at: 0)
                if driftWarnings.count > 20 { driftWarnings.removeLast() }
                if pendingDriftReport == nil {
                    pendingDriftReport = PresentedRemoteDriftReport(watcher: watcher, report: report)
                }
            } else if presentation.showsNoDriftAlert {
                appState.alertItem = AlertItem(
                    title: "未发现远端漂移",
                    message: "远程目录与本地源目录一致，未发现远程缺失、额外、更新或类型冲突。"
                )
            }
        } catch {
            if presentation.showsErrors {
                appState.showError(error)
            }
        }
    }

    private func startScheduledDriftAudits() {
        driftAuditCancellable = Timer.publish(every: 60, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] now in
                self?.runScheduledDriftAudits(now: now)
            }
        driftAuditBootstrapTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            await MainActor.run {
                self?.runScheduledDriftAudits(now: Date())
            }
        }
    }

    private func runScheduledDriftAudits(now: Date) {
        let dueWatchers = watchers.filter {
            SyncDriftAuditPolicy.shouldRun(watcher: $0, now: now) &&
                !runningDriftAuditIDs.contains($0.id)
        }
        for watcher in dueWatchers {
            let tracked = markDriftCheckStarted(watcherID: watcher.id, at: now) ?? watcher
            runningDriftAuditIDs.insert(watcher.id)
            Task { [weak self] in
                guard let self else { return }
                await self.detectRemoteDrift(for: tracked, presentation: .scheduled)
                self.runningDriftAuditIDs.remove(watcher.id)
            }
        }
    }

    private func markDriftCheckStarted(watcherID: UUID, at date: Date) -> SyncWatcher? {
        guard let idx = watchers.firstIndex(where: { $0.id == watcherID }) else { return nil }
        watchers[idx].lastDriftCheckAt = date
        appState.upsertSyncWatcher(watchers[idx])
        return watchers[idx]
    }

    fileprivate func repairRemoteDrift(_ presented: PresentedRemoteDriftReport) async {
        let watcher = presented.watcher
        let report = presented.report
        let missingDirectories = report.remoteMissingDirectories.map(\.relativePath)
        await appState.createRemoteDirectories(
            server: server,
            remoteRoot: watcher.remotePath,
            relativeDirectories: missingDirectories
        )

        for issue in report.repairUploadFiles {
            guard let local = issue.local, !local.isDirectory else { continue }
            await appState.enqueue(
                server: server,
                direction: .upload,
                localURL: URL(fileURLWithPath: watcher.localPath)
                    .appendingPathComponent(issue.relativePath),
                remotePath: remotePath(root: watcher.remotePath, relative: issue.relativePath),
                isAutoSync: true
            )
        }

        let remoteExtras = collapsedRemoteExtraIssues(report.remoteExtras)
        if !remoteExtras.isEmpty &&
            watcher.mode == .oneWayMirror &&
            watcher.mirrorDeleteEnabled {
            guard remoteExtras.count <= MirrorDeleteSafetyPolicy.maxRealtimeDeletesPerMinute else {
                pauseWatcher(
                    watcher,
                    title: "镜像同步已暂停",
                    message: "远端漂移修复需要移动 \(remoteExtras.count) 个额外项目到回收站，超过安全阈值 \(MirrorDeleteSafetyPolicy.maxRealtimeDeletesPerMinute) 个。请手动确认远端目录后再恢复规则。"
                )
                return
            }
            for issue in remoteExtras {
                let quarantinedPath = await appState.quarantineRemotePath(
                    server: server,
                    watcher: watcher,
                    targetRemotePath: remotePath(root: watcher.remotePath, relative: issue.relativePath)
                )
                if quarantinedPath == nil {
                    syncWatcherFromAppState(watcher)
                    return
                }
            }
        }

        let uploadCount = report.repairUploadFiles.count
        let quarantineCount = watcher.mode == .oneWayMirror && watcher.mirrorDeleteEnabled
            ? remoteExtras.count
            : 0
        if let idx = watchers.firstIndex(where: { $0.id == watcher.id }) {
            watchers[idx].lastSyncAt = Date()
            watchers[idx].totalSynced += missingDirectories.count + uploadCount + quarantineCount
            appState.upsertSyncWatcher(watchers[idx])
        }
        recentEvents.insert(("远端漂移修复", Date()), at: 0)
        if recentEvents.count > 20 { recentEvents.removeLast() }
        appState.alertItem = AlertItem(
            title: "已开始修复远程",
            message: "已创建 \(missingDirectories.count) 个目录，加入 \(uploadCount) 个上传任务，移动 \(quarantineCount) 个远端额外项目到回收站。本地文件没有被远端改动覆盖。"
        )
    }

    fileprivate func pauseDriftedWatcher(_ presented: PresentedRemoteDriftReport) {
        pauseWatcher(
            presented.watcher,
            title: "同步规则已暂停",
            message: "已按你的选择暂停该规则。处理远端漂移后，可以手动重新开启。"
        )
    }

    private func driftExcludePatterns(for watcher: SyncWatcher) -> [String] {
        watcher.excludePatterns +
            SyncWatcher.mandatorySecretExcludes +
            [ManagedMirrorRoot.markerFileName, ManagedMirrorRoot.trashDirectoryName]
    }

    private func collapsedRemoteExtraIssues(_ issues: [RemoteDriftIssue]) -> [RemoteDriftIssue] {
        let sorted = issues.sorted { lhs, rhs in
            let leftDepth = lhs.relativePath.split(separator: "/").count
            let rightDepth = rhs.relativePath.split(separator: "/").count
            return leftDepth == rightDepth
                ? lhs.relativePath < rhs.relativePath
                : leftDepth < rightDepth
        }
        var selected: [RemoteDriftIssue] = []
        for issue in sorted {
            if selected.contains(where: {
                issue.relativePath == $0.relativePath ||
                    issue.relativePath.hasPrefix($0.relativePath + "/")
            }) {
                continue
            }
            selected.append(issue)
        }
        return selected
    }

    // MARK: - Wire sync events
    private func wireSyncManager() {
        let initialWatchers = watchers
        Task {
            await syncManager.setCallback { [weak self] event, watcher in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let fileName = URL(fileURLWithPath: event.path).lastPathComponent
                    guard let relative = self.relativePath(localPath: event.path, root: watcher.localPath),
                          !relative.isEmpty else { return }
                    let remotePath = self.remotePath(root: watcher.remotePath, relative: relative)

                    if event.kind == .deleted {
                        await self.handleMirrorDelete(
                            event: event,
                            watcher: watcher,
                            remotePath: remotePath,
                            fileName: fileName
                        )
                        return
                    }

                    // Conflict-safe overwrite: if the remote copy is newer
                    // than this local file, skip the upload and surface a
                    // conflict instead of clobbering newer remote work.
                    // Best-effort: unknown remote mtime → proceed as before.
                    let localMod = try? URL(fileURLWithPath: event.path)
                        .resourceValues(forKeys: [.contentModificationDateKey])
                        .contentModificationDate
                    let remoteMod = await self.appState.remoteFileModifiedDate(
                        server: self.server, remotePath: remotePath
                    )
                    if SyncConflictDecision.shouldSkipUpload(
                        localModified: localMod, remoteModified: remoteMod
                    ) {
                        self.conflicts.insert((fileName, Date()), at: 0)
                        if self.conflicts.count > 20 { self.conflicts.removeLast() }
                        return
                    }

                    await self.appState.enqueue(
                        server: self.server, direction: .upload,
                        localURL: URL(fileURLWithPath: event.path),
                        remotePath: remotePath, isAutoSync: true
                    )

                    self.recentEvents.insert((fileName, Date()), at: 0)
                    if self.recentEvents.count > 20 { self.recentEvents.removeLast() }

                    // Update sync stats
                    if let i = self.watchers.firstIndex(where: { $0.id == watcher.id }) {
                        self.watchers[i].lastSyncAt = Date()
                        self.watchers[i].totalSynced += 1
                        self.appState.upsertSyncWatcher(self.watchers[i])
                    }
                    self.appState.notifications.sendSyncEvent(fileName: fileName, remotePath: remotePath)
                }
            }
            await syncManager.setBookmarkStaleCallback { [weak self] watcher in
                Task { @MainActor [weak self] in
                    self?.appState.alertItem = AlertItem(
                        title: "同步目录需要重新选择",
                        message: "\(watcher.localPath) 的访问权限已失效，请重新添加同步规则。"
                    )
                }
            }
            await syncManager.setScanTruncatedCallback { [weak self] path, _, limit in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let name = URL(fileURLWithPath: path).lastPathComponent
                    self.scanWarnings.insert((name, Date()), at: 0)
                    if self.scanWarnings.count > 20 { self.scanWarnings.removeLast() }
                    self.appState.alertItem = AlertItem(
                        title: "同步扫描已截断",
                        message: "目录「\(path)」一次变化超过 \(limit) 个近期文件，SwiftFTP 只处理了前 \(limit) 个。请运行一次手动初始同步，或重新保存剩余文件。"
                    )
                }
            }
            await syncManager.setMirrorDeleteThresholdCallback { [weak self] watcher, count, limit in
                Task { @MainActor [weak self] in
                    self?.pauseWatcher(
                        watcher,
                        title: "镜像同步已暂停",
                        message: "一次本地变化检测到 \(count) 个删除，超过安全阈值 \(limit) 个。请确认本地目录没有误删后，再手动恢复规则。"
                    )
                }
            }
            let runningIDs = await syncManager.start(watchers: initialWatchers)
            Task { @MainActor [weak self] in
                self?.runningWatcherIDs = runningIDs
            }
        }
    }

    private func refreshWatcher() {
        let currentWatchers = watchers
        Task { [weak self] in
            guard let self else { return }
            let runningIDs = await syncManager.start(watchers: currentWatchers)
            await MainActor.run {
                self.runningWatcherIDs = runningIDs
            }
        }
    }

    private func handleMirrorDelete(
        event: FileChangeEvent,
        watcher: SyncWatcher,
        remotePath: String,
        fileName: String
    ) async {
        guard watcher.mode == .oneWayMirror, watcher.mirrorDeleteEnabled else { return }
        let now = Date()
        let previous = mirrorDeleteHistory[watcher.id] ?? []
        if MirrorDeleteSafetyPolicy.exceedsRealtimeDeleteThreshold(
            previousDeleteTimestamps: previous,
            incomingDeleteCount: 1,
            now: now
        ) {
            pauseWatcher(
                watcher,
                title: "镜像同步已暂停",
                message: "一分钟内检测到超过 \(MirrorDeleteSafetyPolicy.maxRealtimeDeletesPerMinute) 个本地删除。为避免误删扩散，已暂停该规则。"
            )
            return
        }
        mirrorDeleteHistory[watcher.id] = previous
            .filter { now.timeIntervalSince($0) <= MirrorDeleteSafetyPolicy.realtimeDeleteWindow }
            + [now]

        guard let quarantinedPath = await appState.quarantineRemotePath(
            server: server,
            watcher: watcher,
            targetRemotePath: remotePath
        ) else {
            syncWatcherFromAppState(watcher)
            return
        }

        recentEvents.insert((fileName, Date()), at: 0)
        if recentEvents.count > 20 { recentEvents.removeLast() }
        if let i = watchers.firstIndex(where: { $0.id == watcher.id }) {
            watchers[i].lastSyncAt = Date()
            watchers[i].totalSynced += 1
            appState.upsertSyncWatcher(watchers[i])
        }
        appState.notifications.sendSyncEvent(fileName: fileName, remotePath: quarantinedPath)
    }

    private func relativePath(localPath: String, root: String) -> String? {
        let rootPath = URL(fileURLWithPath: root).standardizedFileURL.path
        let path = URL(fileURLWithPath: localPath).standardizedFileURL.path
        if path == rootPath { return "" }
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard path.hasPrefix(prefix) else { return nil }
        return String(path.dropFirst(prefix.count))
    }
}

extension SyncManager {
    func setCallback(_ callback: @Sendable @escaping (FileChangeEvent, SyncWatcher) -> Void) {
        onFileChange = callback
    }

    func setBookmarkStaleCallback(_ callback: @Sendable @escaping (SyncWatcher) -> Void) {
        onBookmarkStale = callback
    }

    func setScanTruncatedCallback(_ callback: @Sendable @escaping (String, SyncWatcher, Int) -> Void) {
        onScanTruncated = callback
    }

    func setMirrorDeleteThresholdCallback(_ callback: @Sendable @escaping (SyncWatcher, Int, Int) -> Void) {
        onMirrorDeleteThresholdExceeded = callback
    }
}

// MARK: - RealtimeSyncView
struct RealtimeSyncView: View {
    @ObservedObject var vm: RealtimeSyncViewModel
    @Environment(\.dismiss) private var dismiss

    // Add-sheet state
    @State private var localPath = ""
    @State private var localPathBookmark: Data?
    @State private var remotePath = ""
    @State private var excludeText = SyncWatcher.defaultExcludePatterns.joined(separator: "\n")
    @State private var syncMode: SyncRuleMode = .realtimeUpload
    @State private var initialSyncPolicy: SyncInitialSyncPolicy = .futureOnly
    @State private var acknowledged = false
    @State private var mirrorDeleteAcknowledged = false
    @State private var mirrorDedicatedRootAcknowledged = false
    @State private var showConfirm = false
    @State private var showPlanConfirm = false
    @State private var pendingCreation: PreparedSyncRule?

    var body: some View {
        if !vm.hasFullAccess {
            proLockedView
        } else {
            syncContent
        }
    }

    private var proLockedView: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("试用或购买 Pro 后使用实时同步")
                .font(.headline)
            Text("SwiftFTP 不提供永久免费版。7 天试用期内可使用全部功能；试用结束后需要购买 Pro。")
                .font(.callout)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var syncContent: some View {
        VStack(spacing: 0) {
            // ── Header ──
            HStack {
                Label {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("实时同步").font(.headline)
                        Text(vm.activeCount > 0
                             ? "\(vm.activeCount) 条规则监控中"
                             : "监控已停止")
                            .font(.caption).foregroundColor(vm.activeCount > 0 ? .green : .secondary)
                    }
                } icon: {
                    Image(systemName: vm.activeCount > 0
                          ? "arrow.triangle.2.circlepath.circle.fill"
                          : "arrow.triangle.2.circlepath.circle")
                        .foregroundColor(vm.activeCount > 0 ? .green : .secondary)
                        .font(.title2)
                }
                Spacer()
                HStack(spacing: 8) {
                    Button { vm.showAddSheet = true } label: {
                        Label("添加规则", systemImage: "plus")
                    }
                    .buttonStyle(RealtimeSyncHeaderGhostButtonStyle())

                    Button { dismiss() } label: {
                        Label("关闭", systemImage: "xmark")
                    }
                    .buttonStyle(RealtimeSyncHeaderGhostButtonStyle())
                    .help("关闭")
                }
            }
            .padding()

            Divider()

            // ── Watcher list ──
            if vm.watchers.isEmpty {
                emptyState
            } else {
                List(vm.watchers) { w in
                    WatcherRow(watcher: w,
                               onToggle: { vm.toggle(w) },
                               onCheckDrift: { vm.checkRemoteDrift(w) },
                               onDelete: { vm.remove(w) })
                }
                .listStyle(.inset)
            }

            // ── Recent events log ──
            if !vm.recentEvents.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    Text("最近同步").font(.caption).foregroundColor(.secondary).padding(.horizontal, 12)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(vm.recentEvents.prefix(8), id: \.1) { name, date in
                                HStack {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(.green).font(.caption2)
                                    Text(name).font(.caption).lineLimit(1)
                                    Spacer()
                                    Text(date.formatted(date: .omitted, time: .shortened))
                                        .font(.caption2).foregroundColor(.secondary)
                                }
                                .padding(.horizontal, 12)
                            }
                        }
                    }
                    .frame(maxHeight: 120)
                }
                .padding(.vertical, 6)
                .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
            }
            // ── Conflicts (skipped: remote newer) ──
            if !vm.conflicts.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    Text("已跳过（远程更新，未覆盖）")
                        .font(.caption).foregroundColor(.orange).padding(.horizontal, 12)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(vm.conflicts.prefix(6), id: \.1) { name, date in
                                HStack {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .foregroundColor(.orange).font(.caption2)
                                    Text(name).font(.caption).lineLimit(1)
                                    Spacer()
                                    Text(date.formatted(date: .omitted, time: .shortened))
                                        .font(.caption2).foregroundColor(.secondary)
                                }
                                .padding(.horizontal, 12)
                            }
                        }
                    }
                    .frame(maxHeight: 90)
                }
                .padding(.vertical, 6)
                .background(Color.orange.opacity(0.06))
            }
            // -- Scan warnings (directory event capped) --
            if !vm.scanWarnings.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    Text("扫描已截断")
                        .font(.caption).foregroundColor(.orange).padding(.horizontal, 12)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(vm.scanWarnings.prefix(6), id: \.1) { name, date in
                                HStack {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .foregroundColor(.orange).font(.caption2)
                                    Text(name).font(.caption).lineLimit(1)
                                    Spacer()
                                    Text(date.formatted(date: .omitted, time: .shortened))
                                        .font(.caption2).foregroundColor(.secondary)
                                }
                                .padding(.horizontal, 12)
                            }
                        }
                    }
                    .frame(maxHeight: 90)
                }
                .padding(.vertical, 6)
                .background(Color.orange.opacity(0.06))
            }
            // -- Remote drift reports --
            if !vm.driftWarnings.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    Text("远端漂移")
                        .font(.caption).foregroundColor(.orange).padding(.horizontal, 12)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(vm.driftWarnings.prefix(6), id: \.1) { name, date in
                                HStack {
                                    Image(systemName: "exclamationmark.arrow.triangle.2.circlepath")
                                        .foregroundColor(.orange).font(.caption2)
                                    Text(name).font(.caption).lineLimit(1)
                                    Spacer()
                                    Text(date.formatted(date: .omitted, time: .shortened))
                                        .font(.caption2).foregroundColor(.secondary)
                                }
                                .padding(.horizontal, 12)
                            }
                        }
                    }
                    .frame(maxHeight: 90)
                }
                .padding(.vertical, 6)
                .background(Color.orange.opacity(0.06))
            }
        }
        .sheet(isPresented: $vm.showAddSheet) { addSheet }
        .sheet(item: $vm.pendingDriftReport) { report in
            RemoteDriftReportSheet(
                report: report,
                onRepair: {
                    vm.pendingDriftReport = nil
                    Task { await vm.repairRemoteDrift(report) }
                },
                onPause: {
                    vm.pendingDriftReport = nil
                    vm.pauseDriftedWatcher(report)
                },
                onIgnore: {
                    vm.pendingDriftReport = nil
                }
            )
        }
    }

    private var baseAcknowledgementText: String {
        if syncMode == .realtimeUpload {
            return "我已了解：创建时会先检查现有文件，有冲突会停止创建。"
        }
        return "我已了解：镜像模式会把本地删除同步到远程回收站。"
    }

    private var canCreateSelectedMode: Bool {
        syncMode == .realtimeUpload ||
            (mirrorDeleteAcknowledged && mirrorDedicatedRootAcknowledged)
    }

    // MARK: - Empty state
    var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "eye.slash").font(.system(size: 40)).foregroundColor(.secondary)
            Text("尚未配置同步规则").font(.callout)
            Text("添加规则后，本地文件保存时会自动上传到远程服务器")
                .font(.caption).foregroundColor(.secondary).multilineTextAlignment(.center)
            Button("添加第一条规则") { vm.showAddSheet = true }
                .buttonStyle(.borderedProminent)
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Add sheet
    var addSheet: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("添加同步规则").font(.title3).bold()

            // Local path
            VStack(alignment: .leading, spacing: 4) {
                Text("本地监控文件夹").font(.caption).foregroundColor(.secondary)
                HStack {
                    FileDropContainer { urls in
                        guard let url = urls.first else { return }
                        localPath = url.path
                        localPathBookmark = nil
                    } content: {
                        TextField("拖入文件夹或点击选择", text: $localPath)
                            .textFieldStyle(.roundedBorder)
                    }
                    Button("选择…") {
                        let p = NSOpenPanel()
                        p.canChooseFiles = false; p.canChooseDirectories = true
                        p.canCreateDirectories = true
                        p.begin { response in
                            guard response == .OK else { return }
                            guard let url = p.url else { return }
                            localPath = url.path
                            localPathBookmark = try? url.bookmarkData(
                                options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                                includingResourceValuesForKeys: nil,
                                relativeTo: nil
                            )
                        }
                    }
                }
                if !localPath.isEmpty && localPathBookmark == nil {
                    Text("请点击“选择…”授予沙盒访问权限；拖入或手动输入的路径不能在重启后稳定监控。")
                        .font(.caption2)
                        .foregroundColor(.orange)
                }
            }

            // Remote path
            VStack(alignment: .leading, spacing: 4) {
                Text("远程目标路径").font(.caption).foregroundColor(.secondary)
                TextField("/var/www/html", text: $remotePath).textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("同步模式").font(.caption).foregroundColor(.secondary)
                Picker("", selection: $syncMode) {
                    Text(SyncRuleMode.realtimeUpload.displayName).tag(SyncRuleMode.realtimeUpload)
                    Text(SyncRuleMode.oneWayMirror.displayName).tag(SyncRuleMode.oneWayMirror)
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                if syncMode == .realtimeUpload {
                    Picker("创建时", selection: $initialSyncPolicy) {
                        ForEach(SyncInitialSyncPolicy.allCases) { policy in
                            Text(policy.displayName).tag(policy)
                        }
                    }
                    .pickerStyle(.menu)
                    .font(.caption)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("镜像模式会创建 marker，并把远程删除先移动到 SwiftFTP 回收站。")
                            .font(.caption2)
                            .foregroundColor(.orange)
                        Toggle(isOn: $mirrorDeleteAcknowledged) {
                            Text("我理解：镜像模式中本地删除会移动远程对应文件。")
                                .font(.caption)
                        }
                        .toggleStyle(.checkbox)
                        Toggle(isOn: $mirrorDedicatedRootAcknowledged) {
                            Text("我确认远程目录是专用于此规则的目录。")
                                .font(.caption)
                        }
                        .toggleStyle(.checkbox)
                    }
                }
            }

            // Exclude patterns
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("排除规则（每行一条，支持 * 通配符）")
                        .font(.caption).foregroundColor(.secondary)
                    Spacer()
                    Button("重置默认") {
                        excludeText = SyncWatcher.defaultExcludePatterns.joined(separator: "\n")
                    }.font(.caption)
                }
                TextEditor(text: $excludeText)
                    .font(.system(.caption, design: .monospaced))
                    .frame(height: 90)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
            }

            // Honest behavior + risk disclosure
            VStack(alignment: .leading, spacing: 5) {
                if syncMode == .realtimeUpload {
                    Label("本规则仅上传：本地文件保存后会上传到远程。", systemImage: "arrow.up.circle")
                    Label("不会删除远程文件；空文件夹与文件夹改名不会被实时同步。", systemImage: "trash.slash")
                    Label("创建时会先生成 dry-run 计划；有冲突会停止创建。", systemImage: "exclamationmark.triangle")
                } else {
                    Label("单向镜像会让本地作为唯一源。", systemImage: "arrow.right.circle")
                    Label("本地删除会把远程对应文件移动到 SwiftFTP 回收站。", systemImage: "trash")
                    Label("删除执行前会校验 marker、canary 与删除阈值。", systemImage: "exclamationmark.triangle")
                }
            }
            .font(.caption2)
            .foregroundColor(.secondary)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))

            Toggle(isOn: $acknowledged) {
                Text(baseAcknowledgementText)
                    .font(.caption)
            }
            .toggleStyle(.checkbox)

            Spacer()

            HStack {
                Button("取消") { vm.showAddSheet = false }
                Spacer()
                if vm.isValidating {
                    ProgressView().controlSize(.small).padding(.trailing, 6)
                }
                Button("添加") { showConfirm = true }
                .buttonStyle(.borderedProminent)
                .disabled(
                    localPath.isEmpty || localPathBookmark == nil ||
                    remotePath.isEmpty || !acknowledged || !canCreateSelectedMode || vm.isValidating
                )
            }
        }
        .padding(24)
        .frame(width: 560, height: 660)
        .alert("再次确认同步规则", isPresented: $showConfirm) {
            Button("取消", role: .cancel) {}
            Button("生成计划") {
                let patterns = excludeText.split(separator: "\n")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                guard let bookmark = localPathBookmark else { return }
                Task {
                    if let prepared = await vm.prepareWatcher(
                        localPath: localPath,
                        localPathBookmark: bookmark,
                        remotePath: remotePath,
                        excludePatterns: patterns,
                        mode: syncMode,
                        initialSyncPolicy: initialSyncPolicy,
                        mirrorDeleteEnabled: syncMode == .oneWayMirror
                            && mirrorDeleteAcknowledged
                            && mirrorDedicatedRootAcknowledged
                    ) {
                        pendingCreation = prepared
                        showPlanConfirm = true
                    }
                }
            }
        } message: {
            Text(confirmMessage)
        }
        .alert("确认同步计划", isPresented: $showPlanConfirm) {
            Button("取消", role: .cancel) {
                pendingCreation = nil
            }
            Button("创建规则") {
                guard let prepared = pendingCreation else { return }
                Task {
                    await vm.commitPreparedWatcher(prepared)
                    resetAddSheet()
                }
            }
        } message: {
            Text(planMessage)
        }
    }

    private var confirmMessage: String {
        var lines = [
            "本地：\(localPath)",
            "远程：\(remotePath)",
            "模式：\(syncMode.displayName)"
        ]
        if syncMode == .realtimeUpload {
            lines.append("创建时：\(initialSyncPolicy.displayName)")
        } else {
            lines.append("远程删除：已要求双重确认")
        }
        lines.append("")
        lines.append("下一步只生成 dry-run 计划；有冲突会停止创建。")
        return lines.joined(separator: "\n")
    }

    private var planMessage: String {
        guard let prepared = pendingCreation else { return "" }
        let plan = prepared.plan
        var lines = [
            "将创建规则：\(prepared.mode.displayName)",
            "创建目录：\(plan.createDirectories.count)",
            "上传新文件：\(plan.uploads.count)",
            "覆盖远程文件：\(plan.overwrites.count)"
        ]
        if prepared.mode == .oneWayMirror {
            lines.append("计划移入远程回收站：\(plan.remoteDeletes.count)")
        }
        lines.append("跳过：\(plan.skipped.count)")
        if prepared.initialSyncPolicy == .uploadMissingAndNewer {
            lines.append("")
            if prepared.mode == .oneWayMirror {
                lines.append("确认后会写入 marker，执行 canary，把远程独有项目移入 SwiftFTP 回收站，并把上传任务加入传输队列。")
            } else {
                lines.append("确认后会把上传任务加入传输队列。")
            }
        } else {
            lines.append("")
            lines.append("确认后只监控后续修改，不上传现有文件。")
        }
        return lines.joined(separator: "\n")
    }

    private func resetAddSheet() {
        vm.showAddSheet = false
        localPath = ""
        localPathBookmark = nil
        remotePath = ""
        syncMode = .realtimeUpload
        initialSyncPolicy = .futureOnly
        acknowledged = false
        mirrorDeleteAcknowledged = false
        mirrorDedicatedRootAcknowledged = false
        pendingCreation = nil
        excludeText = SyncWatcher.defaultExcludePatterns.joined(separator: "\n")
    }
}

private struct FileDropContainer<Content: View>: NSViewRepresentable {
    let onDrop: ([URL]) -> Void
    let content: Content

    init(onDrop: @escaping ([URL]) -> Void, @ViewBuilder content: () -> Content) {
        self.onDrop = onDrop
        self.content = content()
    }

    func makeNSView(context: Context) -> FileDropHostingView<Content> {
        FileDropHostingView(rootView: content, onDrop: onDrop)
    }

    func updateNSView(_ nsView: FileDropHostingView<Content>, context: Context) {
        nsView.rootView = content
        nsView.onDrop = onDrop
    }
}

private final class FileDropHostingView<Root: View>: NSHostingView<Root> {
    var onDrop: ([URL]) -> Void

    init(rootView: Root, onDrop: @escaping ([URL]) -> Void) {
        self.onDrop = onDrop
        super.init(rootView: rootView)
        registerForDraggedTypes([.fileURL])
    }

    @MainActor @preconcurrency required dynamic init(rootView: Root) {
        self.onDrop = { _ in }
        super.init(rootView: rootView)
        registerForDraggedTypes([.fileURL])
    }

    @MainActor @preconcurrency required dynamic init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        Self.fileURLs(from: sender).isEmpty ? [] : .copy
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let urls = Self.fileURLs(from: sender)
        guard !urls.isEmpty else { return false }
        // FIXME(AppSandbox): dropped folders are not durable permissions.
        // Persist a security-scoped bookmark from NSOpenPanel before watching.
        onDrop(urls)
        return true
    }

    private static func fileURLs(from sender: any NSDraggingInfo) -> [URL] {
        sender.draggingPasteboard.pasteboardItems?.compactMap { item in
            item.string(forType: .fileURL)
                .flatMap { URL(string: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        } ?? []
    }
}

private struct RealtimeSyncHeaderGhostButtonStyle: ButtonStyle {
    var foreground: Color = .primary

    func makeBody(configuration: Configuration) -> some View {
        RealtimeSyncHeaderGhostButton(
            configuration: configuration,
            foreground: foreground
        )
    }
}

private struct RealtimeSyncHeaderGhostButton: View {
    let configuration: ButtonStyle.Configuration
    let foreground: Color
    @State private var isHovering = false

    var body: some View {
        configuration.label
            .font(.subheadline)
            .foregroundColor(foreground)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(backgroundColor)
            )
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .onHover { isHovering = $0 }
    }

    private var backgroundColor: Color {
        if configuration.isPressed {
            Color.primary.opacity(0.12)
        } else if isHovering {
            Color.primary.opacity(0.07)
        } else {
            Color.clear
        }
    }
}

private struct RemoteDriftReportSheet: View {
    let report: PresentedRemoteDriftReport
    let onRepair: () -> Void
    let onPause: () -> Void
    let onIgnore: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.arrow.triangle.2.circlepath")
                    .font(.title2)
                    .foregroundColor(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("远端漂移检测")
                        .font(.headline)
                    Text("只展示远端差异；不会把远端变化写回本地。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
            }

            ScrollView {
                Text(report.message)
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(minHeight: 220)
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(NSColor.controlBackgroundColor).opacity(0.65))
            )

            HStack {
                Button("忽略一次", action: onIgnore)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("暂停规则", role: .destructive, action: onPause)
                if report.canRepairRemote {
                    Button("修复远程", action: onRepair)
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(22)
        .frame(width: 540, height: 430)
    }
}

// MARK: - Watcher Row
struct WatcherRow: View {
    let watcher: SyncWatcher
    let onToggle: () -> Void
    let onCheckDrift: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Toggle("", isOn: .init(get: { watcher.isActive }, set: { _ in onToggle() }))
                .toggleStyle(.switch).labelsHidden()

            VStack(alignment: .leading, spacing: 3) {
                Text(watcher.localPath)
                    .font(.system(size: 12, weight: .medium)).lineLimit(1)
                    .truncationMode(.head)
                HStack(spacing: 4) {
                    Image(systemName: "arrow.right").font(.caption2).foregroundColor(.secondary)
                    Text(watcher.remotePath).font(.caption).foregroundColor(.secondary).lineLimit(1)
                }
                if let statusText {
                    Text(statusText)
                        .font(.caption2).foregroundColor(.secondary)
                }
            }

            Spacer()

            if watcher.isActive {
                HStack(spacing: 3) {
                    Circle().fill(Color.green).frame(width: 6, height: 6)
                    Text("监控中").font(.caption2).foregroundColor(.green)
                }
            }

            Button(action: onCheckDrift) {
                Image(systemName: "exclamationmark.arrow.triangle.2.circlepath")
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help("检测远端漂移")

            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash").foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
    }

    private var statusText: String? {
        var parts: [String] = []
        if let last = watcher.lastSyncAt {
            parts.append("最后同步：\(last.formatted(date: .omitted, time: .shortened))")
            parts.append("共 \(watcher.totalSynced) 次")
        }
        if let lastDriftCheck = watcher.lastDriftCheckAt {
            parts.append("远端检查：\(lastDriftCheck.formatted(date: .omitted, time: .shortened))")
        }
        return parts.isEmpty ? nil : parts.joined(separator: "  ·  ")
    }
}
