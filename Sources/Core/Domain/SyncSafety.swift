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
            return "远程路径「\(p)」必须是以 / 开头的绝对路径。"
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

    // Remote subtrees that should never receive synced files (writing into
    // them can break a server / OS). `/var` is deliberately NOT here so the
    // canonical `/var/www/...` deploy target keeps working.
    // Compared against the backslash→slash canonical form, lowercased.
    private static let forbiddenRemoteSubtrees: [String] = [
        "/etc", "/bin", "/sbin", "/boot", "/sys", "/proc", "/dev",
        "/system", "/private/etc", "/var/db",
        "c:/windows", "c:/program files"
    ]

    // Shallow remote roots rejected outright (depth also catches most).
    private static let forbiddenRemoteExact: Set<String> = [
        "/", "/usr", "/var", "/root", "/lib", "/lib64", "/opt", "/srv",
        "/system", "/library", "c:/", "c:"
    ]

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

    /// True when `a` and `b` are the same path or one contains the other
    /// (component-aware, so `/a/bc` does not "contain" `/a/b`).
    public static func isSameOrNested(_ a: String, _ b: String) -> Bool {
        let na = normalize(a).lowercased()
        let nb = normalize(b).lowercased()
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

        let isWindows = trimmed.count >= 2 &&
            trimmed[trimmed.index(trimmed.startIndex, offsetBy: 1)] == ":"
        guard trimmed.hasPrefix("/") || isWindows else {
            return .remoteNotAbsolute(trimmed)
        }

        let collapsed = trimmed.replacingOccurrences(of: "//", with: "/")
        let norm = (collapsed.count > 1 && collapsed.hasSuffix("/"))
            ? String(collapsed.dropLast())
            : collapsed
        // Canonical form: backslash → slash, lowercased. Lets one set of
        // rules cover both POSIX and Windows-style remote paths.
        let canonical = norm.replacingOccurrences(of: "\\", with: "/").lowercased()

        if forbiddenRemoteExact.contains(canonical) {
            return .forbiddenRemoteRoot(norm)
        }
        for sub in forbiddenRemoteSubtrees
        where canonical == sub || canonical.hasPrefix(sub + "/") {
            return .forbiddenRemoteRoot(norm)
        }
        if components(canonical).count < minimumDepth {
            return .remoteTooShallow(norm)
        }
        return nil
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
            if isSameOrNested(remotePath, rule.remote) {
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
