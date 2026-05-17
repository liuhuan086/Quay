// SyncSafety.swift — Pure, Sendable, unit-testable guardrails for realtime sync.
//
// This is the "treat the user as someone who can make a fatal mistake" layer.
// It rejects obviously dangerous sync roots before a rule is ever created and
// decides when an upload would clobber newer remote work. None of it performs
// I/O except the explicit filesystem checks in `localRootFilesystemError`.
//
// Before changing anything here, read Docs/RealtimeSync_Mirror_Design.md.
import Foundation

// MARK: - Validation errors

public enum SyncRuleValidationError: Error, Equatable, Sendable {
    case emptyLocalPath
    case emptyRemotePath
    case localTooShallow(String)
    case remoteTooShallow(String)
    case forbiddenLocalRoot(String)
    case forbiddenRemoteRoot(String)
    case localPathMissing(String)
    case localRootIsSymlink(String)
    case remoteNotAbsolute(String)
    case overlapsExistingRule(existing: String)

    /// User-facing Chinese message — specific enough that the user knows
    /// exactly what to change.
    public var message: String {
        switch self {
        case .emptyLocalPath:
            return "请先选择本地监控文件夹。"
        case .emptyRemotePath:
            return "请填写远程目标路径。"
        case .localTooShallow(let p):
            return "本地路径「\(p)」层级过浅。请选择至少三级目录（例如 /Users/你的用户名/项目名），不要直接同步用户主目录或磁盘根目录。"
        case .remoteTooShallow(let p):
            return "远程路径「\(p)」层级过浅。请使用至少三级目录（例如 /var/www/网站名），不要同步到服务器根目录或系统目录。"
        case .forbiddenLocalRoot(let p):
            return "本地路径「\(p)」是系统目录或主目录中的关键文件夹，同步它可能导致系统或个人数据损坏。请改用一个专门用于同步的子文件夹。"
        case .forbiddenRemoteRoot(let p):
            return "远程路径「\(p)」是服务器系统目录，写入它可能导致服务器无法启动。请改用专门的部署目录（例如 /var/www/...）。"
        case .localPathMissing(let p):
            return "本地路径「\(p)」不存在或不是文件夹，请重新选择。"
        case .localRootIsSymlink(let p):
            return "本地路径「\(p)」是一个符号链接。为避免同步范围意外越界，请直接选择真实文件夹。"
        case .remoteNotAbsolute(let p):
            return "远程路径「\(p)」必须是以 / 开头，或 Windows 盘符开头的绝对路径。"
        case .overlapsExistingRule(let existing):
            return "该路径与已存在的同步规则「\(existing)」重叠（相同、或互为上下级目录）。重叠规则会造成重复同步甚至循环，请选择不重叠的目录。"
        }
    }
}

// MARK: - Path validator

public enum SyncPathValidator {

    /// Minimum number of path components a sync root must have.
    /// `/Users/name/project` = 3 (ok). `/Users/name` = 2 (reject).
    public static let minimumDepth = 3

    // Absolute system roots that must never be a local sync root, nor have a
    // sync root nested inside them (subtree-forbidden). Written in the form
    // `normalize` produces: macOS rewrites the firmlinked `/private/var`,
    // `/private/etc`, `/private/tmp` to `/var`, `/etc`, `/tmp`.
    private static let forbiddenLocalSubtrees: [String] = [
        "/system", "/library", "/applications", "/bin", "/sbin", "/usr",
        "/opt", "/etc", "/var/db", "/var/root", "/cores", "/network", "/.vol"
    ]

    // Broad folders directly under a user home that must not be a sync root.
    private static let forbiddenHomeChildren: Set<String> = [
        "desktop", "documents", "downloads", "library", "movies", "music",
        "pictures", "public", "applications", "sites",
        ".ssh", ".gnupg", ".aws", ".kube", ".config"
    ]

    // These home descendants are never safe, even when the selected root is
    // deeper than the broad-folder check. Project folders under Documents or
    // Downloads may be allowed; credential stores and app data are not.
    private static let forbiddenHomeSubtrees: Set<String> = [
        "library", ".ssh", ".gnupg", ".aws", ".kube", ".config",
        ".docker", ".azure", ".gcloud", ".local"
    ]

    // Remote subtrees that should never receive synced files (writing into
    // them can break a server / OS). `/var` is deliberately NOT here so the
    // canonical `/var/www/...` deploy target keeps working.
    // Compared against the backslash→slash canonical form, lowercased.
    private static let forbiddenRemoteSubtrees: [String] = [
        "/etc", "/bin", "/sbin", "/boot", "/sys", "/proc", "/dev",
        "/run", "/system", "/library", "/applications", "/private/etc",
        "/private/var/db", "/usr", "/opt", "/root", "/lib", "/lib64",
        "/srv", "/var/db", "/var/lib", "/var/log", "/var/cache",
        "/var/spool", "/var/run", "/var/root",
        "c:/windows", "c:/program files", "c:/program files (x86)",
        "c:/programdata", "c:/documents and settings"
    ]

    // Shallow remote roots rejected outright (depth also catches most).
    private static let forbiddenRemoteExact: Set<String> = [
        "/", "/usr", "/var", "/root", "/lib", "/lib64", "/opt", "/srv",
        "/system", "/library", "/home", "/users", "c:/", "c:"
    ]

    private static let remoteHomeRoots: Set<String> = ["home", "users"]
    private static let forbiddenWindowsHomeSubtrees: Set<String> = forbiddenHomeSubtrees
        .union(["appdata"])
    private static let posixLocale = Locale(identifier: "en_US_POSIX")

    // MARK: Normalization

    /// Expand `~`, resolve `.`/`..`, strip trailing slashes. Case preserved
    /// for display; comparisons are done on the lowercased form.
    public static func normalize(_ raw: String) -> String {
        let expanded = (raw as NSString).expandingTildeInPath
        let std = URL(fileURLWithPath: expanded).standardizedFileURL.path
        if std != "/" , std.hasSuffix("/") {
            return String(std.dropLast())
        }
        return std
    }

    public static func components(_ normalized: String) -> [String] {
        normalized.split(separator: "/").map(String.init)
    }

    private static func caseFold(_ value: String) -> String {
        value
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: posixLocale
            )
            .lowercased()
    }

    /// True when `a` and `b` are the same path or one contains the other
    /// (component-aware, so `/a/bc` does not "contain" `/a/b`).
    public static func isSameOrNested(_ a: String, _ b: String) -> Bool {
        let na = normalize(a).lowercased()
        let nb = normalize(b).lowercased()
        return componentAwareSameOrNested(na, nb)
    }

    /// Remote-aware variant for POSIX and Windows-style remote paths. Unlike
    /// local `normalize`, this never asks macOS to interpret a remote string.
    public static func isRemoteSameOrNested(_ a: String, _ b: String) -> Bool {
        let na = canonicalRemotePath(a)
        let nb = canonicalRemotePath(b)
        return componentAwareSameOrNested(na, nb)
    }

    private static func componentAwareSameOrNested(_ na: String, _ nb: String) -> Bool {
        if na == nb { return true }
        let ca = components(na)
        let cb = components(nb)
        let shorter = ca.count < cb.count ? ca : cb
        let longer  = ca.count < cb.count ? cb : ca
        return Array(longer.prefix(shorter.count)) == shorter
    }

    // MARK: Local root — pure static checks (no filesystem)

    public static func localRootStaticError(_ raw: String) -> SyncRuleValidationError? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .emptyLocalPath }

        let norm = normalize(trimmed)
        let lower = norm.lowercased()
        let comps = components(norm)

        // Forbidden checks run before the depth check so the user gets the
        // accurate "this is a system/home directory" message instead of a
        // generic "too shallow" — both reject, but the reason matters.
        for sub in forbiddenLocalSubtrees where lower == sub || lower.hasPrefix(sub + "/") {
            return .forbiddenLocalRoot(norm)
        }
        // Home-broad-folder check: `/Users/<name>/<broad>` (exactly depth 3).
        let lowerComps = comps.map { $0.lowercased() }
        if lowerComps.count == 3, lowerComps[0] == "users",
           forbiddenHomeChildren.contains(lowerComps[2]) {
            return .forbiddenLocalRoot(norm)
        }
        if lowerComps.count >= 3, lowerComps[0] == "users",
           forbiddenHomeSubtrees.contains(lowerComps[2]) {
            return .forbiddenLocalRoot(norm)
        }
        if comps.count < minimumDepth {
            return .localTooShallow(norm)
        }
        return nil
    }

    // MARK: Local root — filesystem checks

    public static func localRootFilesystemError(
        _ raw: String,
        fileManager: FileManager = .default
    ) -> SyncRuleValidationError? {
        let norm = normalize(raw.trimmingCharacters(in: .whitespacesAndNewlines))

        if let values = try? URL(fileURLWithPath: norm)
            .resourceValues(forKeys: [.isSymbolicLinkKey]),
           values.isSymbolicLink == true {
            return .localRootIsSymlink(norm)
        }

        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: norm, isDirectory: &isDir),
              isDir.boolValue else {
            return .localPathMissing(norm)
        }
        return nil
    }

    // MARK: Remote root

    public static func remoteRootError(_ raw: String) -> SyncRuleValidationError? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .emptyRemotePath }

        guard isRemoteAbsolutePath(trimmed) else {
            return .remoteNotAbsolute(trimmed)
        }

        let norm = displayRemotePath(trimmed)
        let canonical = canonicalRemotePath(trimmed)

        if forbiddenRemoteExact.contains(canonical) {
            return .forbiddenRemoteRoot(norm)
        }
        for sub in forbiddenRemoteSubtrees
        where canonical == sub || canonical.hasPrefix(sub + "/") {
            return .forbiddenRemoteRoot(norm)
        }
        if isForbiddenRemoteHomeRoot(canonical) {
            return .forbiddenRemoteRoot(norm)
        }
        if components(canonical).count < minimumDepth {
            return .remoteTooShallow(norm)
        }
        return nil
    }

    public static func canonicalRemotePath(_ raw: String) -> String {
        normalizeRemotePath(raw, foldCase: true)
    }

    private static func displayRemotePath(_ raw: String) -> String {
        normalizeRemotePath(raw, foldCase: false)
    }

    private static func normalizeRemotePath(_ raw: String, foldCase: Bool) -> String {
        var value = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\", with: "/")
        while value.contains("//") {
            value = value.replacingOccurrences(of: "//", with: "/")
        }
        if isSlashPrefixedWindowsPath(value) {
            value.removeFirst()
        }

        if let drive = windowsDrivePrefix(value) {
            let rest = String(value.dropFirst(2))
            let parts = normalizedRemoteSegments(rest, foldCase: foldCase)
            let drivePart = foldCase ? caseFold(drive) : drive
            return parts.isEmpty ? "\(drivePart)/" : "\(drivePart)/\(parts.joined(separator: "/"))"
        }

        let rest = value.hasPrefix("/") ? String(value.dropFirst()) : value
        let parts = normalizedRemoteSegments(rest, foldCase: foldCase)
        return parts.isEmpty ? "/" : "/" + parts.joined(separator: "/")
    }

    private static func normalizedRemoteSegments(_ raw: String, foldCase: Bool) -> [String] {
        var parts: [String] = []
        for segment in raw.split(separator: "/", omittingEmptySubsequences: true) {
            let part = String(segment)
            if part == "." { continue }
            if part == ".." {
                if !parts.isEmpty { parts.removeLast() }
                continue
            }
            parts.append(foldCase ? caseFold(part) : part)
        }
        return parts
    }

    private static func isRemoteAbsolutePath(_ raw: String) -> Bool {
        let value = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\", with: "/")
        return value.hasPrefix("/") || windowsDrivePrefix(value) != nil
    }

    private static func windowsDrivePrefix(_ value: String) -> String? {
        guard value.count >= 3,
              let first = character(at: 0, in: value),
              isASCIIAlpha(first),
              character(at: 1, in: value) == ":",
              character(at: 2, in: value) == "/" else {
            return nil
        }
        return String(value.prefix(2))
    }

    private static func isSlashPrefixedWindowsPath(_ value: String) -> Bool {
        guard value.count >= 4,
              character(at: 0, in: value) == "/",
              let drive = character(at: 1, in: value),
              isASCIIAlpha(drive),
              character(at: 2, in: value) == ":",
              character(at: 3, in: value) == "/" else {
            return false
        }
        return true
    }

    private static func character(at offset: Int, in value: String) -> Character? {
        guard let index = value.index(value.startIndex, offsetBy: offset, limitedBy: value.endIndex),
              index < value.endIndex else {
            return nil
        }
        return value[index]
    }

    private static func isASCIIAlpha(_ character: Character) -> Bool {
        guard character.unicodeScalars.count == 1,
              let scalar = character.unicodeScalars.first else {
            return false
        }
        return (65...90).contains(Int(scalar.value)) || (97...122).contains(Int(scalar.value))
    }

    private static func isForbiddenRemoteHomeRoot(_ canonical: String) -> Bool {
        let comps = components(canonical)
        if comps.count >= 2, remoteHomeRoots.contains(comps[0]) {
            if comps.count == 2 { return true }
            let child = comps[2]
            if comps.count == 3, forbiddenHomeChildren.contains(child) { return true }
            if forbiddenHomeSubtrees.contains(child) { return true }
        }

        guard comps.count >= 2,
              comps[0].hasSuffix(":"),
              comps[1] == "users" else {
            return false
        }
        if comps.count <= 3 { return true }
        let child = comps[3]
        if comps.count == 4, forbiddenHomeChildren.contains(child) { return true }
        if forbiddenWindowsHomeSubtrees.contains(child) { return true }
        return false
    }

    // MARK: Overlap

    /// `existingRules` is a list of (localPath, remotePath) already configured
    /// for the same server. A new rule may not share, contain, or be contained
    /// by either side of an existing rule.
    public static func overlapError(
        localPath: String,
        remotePath: String,
        existingRules: [(local: String, remote: String)]
    ) -> SyncRuleValidationError? {
        for rule in existingRules {
            if isSameOrNested(localPath, rule.local) {
                return .overlapsExistingRule(existing: rule.local)
            }
            if isRemoteSameOrNested(remotePath, rule.remote) {
                return .overlapsExistingRule(existing: rule.remote)
            }
        }
        return nil
    }

    // MARK: Combined entry point

    /// Runs cheap deterministic checks first, then filesystem checks, then
    /// overlap. Returns the first failure, or nil when the rule is safe.
    public static func validate(
        localPath: String,
        remotePath: String,
        existingRules: [(local: String, remote: String)],
        fileManager: FileManager = .default
    ) -> SyncRuleValidationError? {
        if let e = localRootStaticError(localPath) { return e }
        if let e = remoteRootError(remotePath) { return e }
        if let e = localRootFilesystemError(localPath, fileManager: fileManager) { return e }
        if let e = overlapError(localPath: localPath,
                                remotePath: remotePath,
                                existingRules: existingRules) { return e }
        return nil
    }
}

// MARK: - Conflict-safe overwrite decision

public enum SyncConflictDecision {

    /// Default clock-skew / mtime-truncation tolerance. FTP `LIST` only has
    /// minute precision and may report server-local time, so this absorbs
    /// small differences; a genuinely newer remote file (edited elsewhere)
    /// will exceed it and be protected.
    public static let defaultSkew: TimeInterval = 2

    /// Returns true when the upload should be SKIPPED because the remote copy
    /// is newer than the local one (a stale local file would otherwise
    /// destroy newer remote work). Unknown remote/local mtime → never skip
    /// (fall back to the existing upload behavior; never silently stall the
    /// user's own workflow).
    public static func shouldSkipUpload(
        localModified: Date?,
        remoteModified: Date?,
        skew: TimeInterval = defaultSkew
    ) -> Bool {
        guard let remoteModified, let localModified else { return false }
        return remoteModified.timeIntervalSince(localModified) > skew
    }
}

// MARK: - Initial sync planner

public enum InitialSyncMode: Sendable, Equatable {
    case realtimeUpload
    case oneWayMirror(deleteRemote: Bool)

    var plansRemoteDeletes: Bool {
        if case .oneWayMirror(deleteRemote: true) = self { return true }
        return false
    }
}

public enum RemoteTimestampQuality: Sendable, Equatable {
    case reliable
    case unreliable
}

public struct InitialSyncPlannerOptions: Sendable, Equatable {
    public var mode: InitialSyncMode
    public var timestampTolerance: TimeInterval
    public var remoteTimestampQuality: RemoteTimestampQuality
    public var allowLocalWins: Bool

    public init(
        mode: InitialSyncMode = .realtimeUpload,
        timestampTolerance: TimeInterval = SyncConflictDecision.defaultSkew,
        remoteTimestampQuality: RemoteTimestampQuality = .reliable,
        allowLocalWins: Bool = false
    ) {
        self.mode = mode
        self.timestampTolerance = timestampTolerance
        self.remoteTimestampQuality = remoteTimestampQuality
        self.allowLocalWins = allowLocalWins
    }
}

public struct SyncSnapshotItem: Sendable, Equatable {
    public var relativePath: String
    public var isDirectory: Bool
    public var size: Int64
    public var modifiedDate: Date?

    public init(
        relativePath: String,
        isDirectory: Bool,
        size: Int64 = 0,
        modifiedDate: Date? = nil
    ) {
        self.relativePath = relativePath
        self.isDirectory = isDirectory
        self.size = size
        self.modifiedDate = modifiedDate
    }
}

public enum InitialSyncPlanActionKind: Sendable, Equatable {
    case createRemoteDirectory
    case uploadNewFile
    case overwriteRemoteFile
    case deleteRemoteFile
    case deleteRemoteDirectory
    case skipIdentical
    case skipRemoteOnly
}

public struct InitialSyncPlanAction: Sendable, Equatable {
    public var kind: InitialSyncPlanActionKind
    public var relativePath: String
    public var local: SyncSnapshotItem?
    public var remote: SyncSnapshotItem?

    public init(
        kind: InitialSyncPlanActionKind,
        relativePath: String,
        local: SyncSnapshotItem? = nil,
        remote: SyncSnapshotItem? = nil
    ) {
        self.kind = kind
        self.relativePath = relativePath
        self.local = local
        self.remote = remote
    }
}

public enum InitialSyncPlanConflictKind: Sendable, Equatable {
    case invalidRelativePath
    case caseFoldCollision
    case typeMismatch
    case remoteNewer
    case timestampUncertain
}

public struct InitialSyncPlanConflict: Sendable, Equatable {
    public var kind: InitialSyncPlanConflictKind
    public var relativePath: String
    public var local: SyncSnapshotItem?
    public var remote: SyncSnapshotItem?

    public init(
        kind: InitialSyncPlanConflictKind,
        relativePath: String,
        local: SyncSnapshotItem? = nil,
        remote: SyncSnapshotItem? = nil
    ) {
        self.kind = kind
        self.relativePath = relativePath
        self.local = local
        self.remote = remote
    }
}

public struct InitialSyncPlan: Sendable, Equatable {
    public var createDirectories: [InitialSyncPlanAction] = []
    public var uploads: [InitialSyncPlanAction] = []
    public var overwrites: [InitialSyncPlanAction] = []
    public var remoteDeletes: [InitialSyncPlanAction] = []
    public var skipped: [InitialSyncPlanAction] = []
    public var conflicts: [InitialSyncPlanConflict] = []

    public var hasConflicts: Bool { !conflicts.isEmpty }
    public var uploadWorkCount: Int {
        createDirectories.count + uploads.count + overwrites.count
    }
}

public enum InitialSyncPlanner {
    private struct IndexedItem {
        var relativePath: String
        var foldedPath: String
        var item: SyncSnapshotItem
    }

    private struct IndexResult {
        var items: [String: IndexedItem]
        var conflicts: [InitialSyncPlanConflict]
    }

    public static func plan(
        localItems: [SyncSnapshotItem],
        remoteItems: [SyncSnapshotItem],
        options: InitialSyncPlannerOptions = InitialSyncPlannerOptions()
    ) -> InitialSyncPlan {
        var plan = InitialSyncPlan()
        var localIndex = index(localItems)
        var remoteIndex = index(remoteItems)
        plan.conflicts.append(contentsOf: localIndex.conflicts)
        plan.conflicts.append(contentsOf: remoteIndex.conflicts)

        for key in Set(localIndex.items.keys).intersection(remoteIndex.items.keys).sorted() {
            guard let local = localIndex.items[key],
                  let remote = remoteIndex.items[key],
                  local.relativePath != remote.relativePath else {
                continue
            }
            plan.conflicts.append(
                InitialSyncPlanConflict(
                    kind: .caseFoldCollision,
                    relativePath: "\(local.relativePath) ↔ \(remote.relativePath)",
                    local: local.item,
                    remote: remote.item
                )
            )
            localIndex.items.removeValue(forKey: key)
            remoteIndex.items.removeValue(forKey: key)
        }

        let keys = Set(localIndex.items.keys).union(remoteIndex.items.keys).sorted()
        for key in keys {
            let local = localIndex.items[key]
            let remote = remoteIndex.items[key]
            switch (local, remote) {
            case let (local?, nil):
                appendLocalOnly(local, to: &plan)
            case let (nil, remote?):
                appendRemoteOnly(remote, options: options, to: &plan)
            case let (local?, remote?):
                appendShared(local: local, remote: remote, options: options, to: &plan)
            case (nil, nil):
                continue
            }
        }

        sort(&plan)
        return plan
    }

    private static func appendLocalOnly(_ local: IndexedItem, to plan: inout InitialSyncPlan) {
        let kind: InitialSyncPlanActionKind = local.item.isDirectory
            ? .createRemoteDirectory
            : .uploadNewFile
        let action = InitialSyncPlanAction(
            kind: kind,
            relativePath: local.relativePath,
            local: local.item
        )
        if local.item.isDirectory {
            plan.createDirectories.append(action)
        } else {
            plan.uploads.append(action)
        }
    }

    private static func appendRemoteOnly(
        _ remote: IndexedItem,
        options: InitialSyncPlannerOptions,
        to plan: inout InitialSyncPlan
    ) {
        guard options.mode.plansRemoteDeletes else {
            plan.skipped.append(
                InitialSyncPlanAction(
                    kind: .skipRemoteOnly,
                    relativePath: remote.relativePath,
                    remote: remote.item
                )
            )
            return
        }
        let kind: InitialSyncPlanActionKind = remote.item.isDirectory
            ? .deleteRemoteDirectory
            : .deleteRemoteFile
        plan.remoteDeletes.append(
            InitialSyncPlanAction(
                kind: kind,
                relativePath: remote.relativePath,
                remote: remote.item
            )
        )
    }

    private static func appendShared(
        local: IndexedItem,
        remote: IndexedItem,
        options: InitialSyncPlannerOptions,
        to plan: inout InitialSyncPlan
    ) {
        guard local.item.isDirectory == remote.item.isDirectory else {
            plan.conflicts.append(
                InitialSyncPlanConflict(
                    kind: .typeMismatch,
                    relativePath: local.relativePath,
                    local: local.item,
                    remote: remote.item
                )
            )
            return
        }
        guard !local.item.isDirectory else {
            plan.skipped.append(
                InitialSyncPlanAction(
                    kind: .skipIdentical,
                    relativePath: local.relativePath,
                    local: local.item,
                    remote: remote.item
                )
            )
            return
        }
        appendSharedFile(local: local, remote: remote, options: options, to: &plan)
    }

    private static func appendSharedFile(
        local: IndexedItem,
        remote: IndexedItem,
        options: InitialSyncPlannerOptions,
        to plan: inout InitialSyncPlan
    ) {
        guard options.remoteTimestampQuality == .reliable,
              let localModified = local.item.modifiedDate,
              let remoteModified = remote.item.modifiedDate else {
            appendUncertainFile(local: local, remote: remote, options: options, to: &plan)
            return
        }

        let delta = localModified.timeIntervalSince(remoteModified)
        if remote.item.size == local.item.size,
           abs(delta) <= options.timestampTolerance {
            plan.skipped.append(
                InitialSyncPlanAction(
                    kind: .skipIdentical,
                    relativePath: local.relativePath,
                    local: local.item,
                    remote: remote.item
                )
            )
        } else if delta > options.timestampTolerance || options.allowLocalWins {
            plan.overwrites.append(
                InitialSyncPlanAction(
                    kind: .overwriteRemoteFile,
                    relativePath: local.relativePath,
                    local: local.item,
                    remote: remote.item
                )
            )
        } else if remoteModified.timeIntervalSince(localModified) > options.timestampTolerance {
            plan.conflicts.append(
                InitialSyncPlanConflict(
                    kind: .remoteNewer,
                    relativePath: local.relativePath,
                    local: local.item,
                    remote: remote.item
                )
            )
        } else {
            plan.conflicts.append(
                InitialSyncPlanConflict(
                    kind: .timestampUncertain,
                    relativePath: local.relativePath,
                    local: local.item,
                    remote: remote.item
                )
            )
        }
    }

    private static func appendUncertainFile(
        local: IndexedItem,
        remote: IndexedItem,
        options: InitialSyncPlannerOptions,
        to plan: inout InitialSyncPlan
    ) {
        if options.allowLocalWins {
            plan.overwrites.append(
                InitialSyncPlanAction(
                    kind: .overwriteRemoteFile,
                    relativePath: local.relativePath,
                    local: local.item,
                    remote: remote.item
                )
            )
        } else {
            plan.conflicts.append(
                InitialSyncPlanConflict(
                    kind: .timestampUncertain,
                    relativePath: local.relativePath,
                    local: local.item,
                    remote: remote.item
                )
            )
        }
    }

    private static func index(_ items: [SyncSnapshotItem]) -> IndexResult {
        var groups: [String: [IndexedItem]] = [:]
        var conflicts: [InitialSyncPlanConflict] = []
        for item in items {
            guard let relativePath = canonicalRelativePath(item.relativePath) else {
                conflicts.append(
                    InitialSyncPlanConflict(
                        kind: .invalidRelativePath,
                        relativePath: item.relativePath,
                        local: item
                    )
                )
                continue
            }
            let foldedPath = caseFoldedPath(relativePath)
            groups[foldedPath, default: []].append(
                IndexedItem(relativePath: relativePath, foldedPath: foldedPath, item: item)
            )
        }

        var indexed: [String: IndexedItem] = [:]
        for (foldedPath, entries) in groups {
            if entries.count == 1 {
                indexed[foldedPath] = entries[0]
                continue
            }
            let paths = entries.map(\.relativePath).sorted().joined(separator: " ↔ ")
            conflicts.append(
                InitialSyncPlanConflict(
                    kind: .caseFoldCollision,
                    relativePath: paths,
                    local: entries.first?.item
                )
            )
        }
        return IndexResult(items: indexed, conflicts: conflicts)
    }

    private static func canonicalRelativePath(_ raw: String) -> String? {
        var parts: [String] = []
        let normalized = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\", with: "/")
        guard !normalized.isEmpty, !normalized.hasPrefix("/") else { return nil }
        for segment in normalized.split(separator: "/", omittingEmptySubsequences: true) {
            let part = String(segment)
            if part == "." { continue }
            if part == ".." {
                guard !parts.isEmpty else { return nil }
                parts.removeLast()
                continue
            }
            parts.append(part)
        }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: "/")
    }

    private static func caseFoldedPath(_ path: String) -> String {
        path
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            .lowercased()
    }

    private static func sort(_ plan: inout InitialSyncPlan) {
        plan.createDirectories.sort { lhs, rhs in
            (pathDepth(lhs.relativePath), lhs.relativePath) < (pathDepth(rhs.relativePath), rhs.relativePath)
        }
        plan.uploads.sort { $0.relativePath < $1.relativePath }
        plan.overwrites.sort { $0.relativePath < $1.relativePath }
        plan.remoteDeletes.sort { lhs, rhs in
            (pathDepth(lhs.relativePath), lhs.relativePath) > (pathDepth(rhs.relativePath), rhs.relativePath)
        }
        plan.skipped.sort { $0.relativePath < $1.relativePath }
        plan.conflicts.sort { $0.relativePath < $1.relativePath }
    }

    private static func pathDepth(_ path: String) -> Int {
        path.split(separator: "/").count
    }
}

public enum SyncRuleCreationPolicy {
    public static func plannerOptions(
        mode: SyncRuleMode,
        remoteProtocol: ConnectionProtocol,
        mirrorDeleteAcknowledged: Bool = false
    ) -> InitialSyncPlannerOptions {
        InitialSyncPlannerOptions(
            mode: mode == .oneWayMirror
                ? .oneWayMirror(deleteRemote: mirrorDeleteAcknowledged)
                : .realtimeUpload,
            remoteTimestampQuality: remoteTimestampQuality(for: remoteProtocol)
        )
    }

    public static func remoteTimestampQuality(
        for remoteProtocol: ConnectionProtocol
    ) -> RemoteTimestampQuality {
        remoteProtocol == .sftp ? .reliable : .unreliable
    }

    public static func existingRemoteContentBlockingFutureOnlyCreation(
        in plan: InitialSyncPlan
    ) -> [InitialSyncPlanAction] {
        (plan.overwrites + plan.skipped).filter {
            $0.kind == .overwriteRemoteFile || $0.kind == .skipIdentical
        }
    }
}

public enum SwiftFTPTempFile {
    public static let marker = ".__swiftftp_tmp__"

    public static func temporaryRemotePath(for remotePath: String) -> String {
        remotePath + marker
    }

    public static func finalRemotePath(forTemporaryPath temporaryPath: String) -> String? {
        guard temporaryPath.lowercased().hasSuffix(marker) else { return nil }
        return String(temporaryPath.dropLast(marker.count))
    }

    public static func isTemporaryFileName(_ name: String) -> Bool {
        let normalized = name
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            .lowercased()
        return normalized.hasPrefix(marker) || normalized.hasSuffix(marker)
    }

    public static func isTemporaryPath(_ path: String) -> Bool {
        isTemporaryFileName((path as NSString).lastPathComponent)
    }
}
