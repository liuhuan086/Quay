// Entities.swift — All domain value types
// All structs are Sendable by default (value semantics).
import Foundation

// MARK: - Connection Protocol
public enum ConnectionProtocol: String, Codable, CaseIterable, Identifiable, Sendable {
    case ftp  = "FTP"
    case ftps = "FTPS"
    case sftp = "SFTP"

    public var id: String { rawValue }
    public var defaultPort: Int { self == .sftp ? 22 : 21 }
    public var isSecure: Bool { self != .ftp }
    public var sfSymbol: String {
        switch self {
        case .ftp:  return "network"
        case .ftps: return "lock.icloud"
        case .sftp: return "lock.shield"
        }
    }
}

// MARK: - Server Color Label
public enum ServerColorLabel: String, Codable, CaseIterable, Identifiable, Sendable {
    case red, orange, yellow, green, blue, purple
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .red: return "生产"; case .orange: return "预发布"
        case .yellow: return "测试"; case .green: return "开发"
        case .blue: return "个人"; case .purple: return "其他"
        }
    }
}

// MARK: - ServerConfig
public struct ServerConfig: Identifiable, Codable, Equatable, Hashable, Sendable {
    public let id: UUID
    public var displayName: String
    public var host: String
    public var port: Int
    public var username: String
    public var protocol_: ConnectionProtocol
    public var initialPath: String
    public var encodingName: String
    public var groupName: String?
    public var colorLabel: ServerColorLabel?
    public var notes: String
    public var useSSHKey: Bool
    public var sshKeyPath: String?
    public var allowSelfSignedTLS: Bool
    // Runtime-only credential loaded from Keychain. Decoding accepts legacy JSON
    // passwords for migration, but encoding never persists this field.
    public var password: String
    public var createdAt: Date
    public var lastConnectedAt: Date?

    public var connectionSummary: String {
        "\(protocol_.rawValue)://\(username)@\(host):\(port)"
    }

    public init(
        id: UUID = UUID(),
        displayName: String, host: String, port: Int? = nil,
        username: String, protocol_: ConnectionProtocol = .sftp,
        initialPath: String = "/", encodingName: String = "utf-8",
        groupName: String? = nil, colorLabel: ServerColorLabel? = nil,
        notes: String = "", useSSHKey: Bool = false, sshKeyPath: String? = nil,
        allowSelfSignedTLS: Bool = false,
        password: String = "",
        createdAt: Date = Date(), lastConnectedAt: Date? = nil
    ) {
        self.id              = id
        self.displayName     = displayName
        self.host            = host
        self.port            = port ?? protocol_.defaultPort
        self.username        = username
        self.protocol_       = protocol_
        self.initialPath     = initialPath
        self.encodingName    = encodingName
        self.groupName       = groupName
        self.colorLabel      = colorLabel
        self.notes           = notes
        self.useSSHKey       = useSSHKey
        self.sshKeyPath      = sshKeyPath
        self.allowSelfSignedTLS = allowSelfSignedTLS
        self.password        = password
        self.createdAt       = createdAt
        self.lastConnectedAt = lastConnectedAt
    }

    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
    public static func == (l: ServerConfig, r: ServerConfig) -> Bool { l.id == r.id }

    private enum CodingKeys: String, CodingKey {
        case id
        case displayName
        case host
        case port
        case username
        case protocol_
        case initialPath
        case encodingName
        case groupName
        case colorLabel
        case notes
        case useSSHKey
        case sshKeyPath
        case allowSelfSignedTLS
        case password
        case createdAt
        case lastConnectedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.displayName = try c.decode(String.self, forKey: .displayName)
        self.host = try c.decode(String.self, forKey: .host)
        self.port = try c.decodeIfPresent(Int.self, forKey: .port)
            ?? (try c.decodeIfPresent(ConnectionProtocol.self, forKey: .protocol_) ?? .sftp).defaultPort
        self.username = try c.decode(String.self, forKey: .username)
        self.protocol_ = try c.decodeIfPresent(ConnectionProtocol.self, forKey: .protocol_) ?? .sftp
        self.initialPath = try c.decodeIfPresent(String.self, forKey: .initialPath) ?? "/"
        self.encodingName = try c.decodeIfPresent(String.self, forKey: .encodingName) ?? "utf-8"
        self.groupName = try c.decodeIfPresent(String.self, forKey: .groupName)
        self.colorLabel = try c.decodeIfPresent(ServerColorLabel.self, forKey: .colorLabel)
        self.notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        self.useSSHKey = try c.decodeIfPresent(Bool.self, forKey: .useSSHKey) ?? false
        self.sshKeyPath = try c.decodeIfPresent(String.self, forKey: .sshKeyPath)
        self.allowSelfSignedTLS = try c.decodeIfPresent(Bool.self, forKey: .allowSelfSignedTLS) ?? false
        self.password = try c.decodeIfPresent(String.self, forKey: .password) ?? ""
        self.createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        self.lastConnectedAt = try c.decodeIfPresent(Date.self, forKey: .lastConnectedAt)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(displayName, forKey: .displayName)
        try c.encode(host, forKey: .host)
        try c.encode(port, forKey: .port)
        try c.encode(username, forKey: .username)
        try c.encode(protocol_, forKey: .protocol_)
        try c.encode(initialPath, forKey: .initialPath)
        try c.encode(encodingName, forKey: .encodingName)
        try c.encodeIfPresent(groupName, forKey: .groupName)
        try c.encodeIfPresent(colorLabel, forKey: .colorLabel)
        try c.encode(notes, forKey: .notes)
        try c.encode(useSSHKey, forKey: .useSSHKey)
        try c.encodeIfPresent(sshKeyPath, forKey: .sshKeyPath)
        try c.encode(allowSelfSignedTLS, forKey: .allowSelfSignedTLS)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encodeIfPresent(lastConnectedAt, forKey: .lastConnectedAt)
    }
}

// MARK: - RemoteFileItem
public struct RemoteFileItem: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public var path: String
    public var isDirectory: Bool
    public var size: Int64
    public var permissions: String
    public var modifiedDate: Date?
    public var owner: String?

    public init(name: String, path: String, isDirectory: Bool,
                size: Int64 = 0, permissions: String = "",
                modifiedDate: Date? = nil, owner: String? = nil) {
        self.id           = UUID()
        self.name         = name
        self.path         = path
        self.isDirectory  = isDirectory
        self.size         = size
        self.permissions  = permissions
        self.modifiedDate = modifiedDate
        self.owner        = owner
    }

    public var displaySize: String {
        isDirectory ? "—" : ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    public var sfSymbol: String {
        if isDirectory { return "folder.fill" }
        switch (name as NSString).pathExtension.lowercased() {
        case "jpg","jpeg","png","gif","webp","svg": return "photo"
        case "mp4","mov","avi","mkv":               return "film"
        case "mp3","wav","flac","aac":              return "music.note"
        case "pdf":                                 return "doc.richtext"
        case "zip","tar","gz","rar","7z":           return "archivebox"
        case "swift","py","js","ts","go","rs",
             "java","c","cpp","h","css","html":     return "chevron.left.forwardslash.chevron.right"
        default:                                     return "doc"
        }
    }
}

// MARK: - Transfer Task
public enum TransferDirection: String, Sendable { case upload, download }

public enum TransferStatus: Sendable, Equatable {
    case queued
    case inProgress(progress: Double, bytesPerSecond: Int64)
    case paused(resumeOffset: Int64)
    case completed
    case failed(message: String)
    case cancelled

    public static func == (l: TransferStatus, r: TransferStatus) -> Bool {
        switch (l, r) {
        case (.queued, .queued), (.completed, .completed), (.cancelled, .cancelled): return true
        case (.paused(let a), .paused(let b)): return a == b
        default: return false
        }
    }

    public var progressFraction: Double {
        if case .inProgress(let p, _) = self { return p }
        if case .completed = self { return 1.0 }
        return 0
    }

    public var isCompletedOrCancelled: Bool {
        switch self {
        case .completed, .cancelled:
            return true
        default:
            return false
        }
    }

    public var isUnfinished: Bool {
        !isCompletedOrCancelled
    }
}

public struct TransferBatch: Identifiable, Sendable {
    public let id: UUID
    public let serverID: UUID
    public let serverName: String
    public let direction: TransferDirection
    public let name: String
    public let localRootURL: URL
    public let remoteRootPath: String
    public let createdAt: Date
    public var expectedFileCount: Int
    public var isPrepared: Bool

    public init(
        id: UUID = UUID(),
        serverID: UUID,
        serverName: String,
        direction: TransferDirection,
        name: String,
        localRootURL: URL,
        remoteRootPath: String,
        expectedFileCount: Int = 0,
        isPrepared: Bool = false,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.serverID = serverID
        self.serverName = serverName
        self.direction = direction
        self.name = name
        self.localRootURL = localRootURL
        self.remoteRootPath = remoteRootPath
        self.expectedFileCount = expectedFileCount
        self.isPrepared = isPrepared
        self.createdAt = createdAt
    }
}

public struct TransferTask: Identifiable, Sendable {
    public let id: UUID
    public let serverID: UUID
    public let serverName: String
    public let direction: TransferDirection
    public let localURL: URL
    public let remotePath: String
    public var status: TransferStatus
    public var fileSize: Int64
    public var bytesTransferred: Int64
    public var resumeOffset: Int64          // for resume
    public var startedAt: Date?
    public var completedAt: Date?
    public var isAutoSync: Bool
    public var retryCount: Int
    public var batchID: UUID?
    public static let maxRetries = 3

    public var fileName: String { localURL.lastPathComponent }

    public var displaySpeed: String {
        if case .inProgress(_, let bps) = status, bps > 0 {
            return ByteCountFormatter.string(fromByteCount: bps, countStyle: .file) + "/s"
        }
        return ""
    }

    public var eta: String? {
        guard case .inProgress(let p, let bps) = status,
              p > 0, bps > 0, fileSize > 0 else { return nil }
        let remaining = Int64(Double(fileSize) * (1.0 - p))
        let secs = remaining / max(bps, 1)
        return secs < 60 ? "\(secs)s" : "\(secs / 60)m \(secs % 60)s"
    }

    public init(serverID: UUID, serverName: String, direction: TransferDirection,
                localURL: URL, remotePath: String, fileSize: Int64 = 0,
                isAutoSync: Bool = false, batchID: UUID? = nil) {
        self.id              = UUID()
        self.serverID        = serverID
        self.serverName      = serverName
        self.direction       = direction
        self.localURL        = localURL
        self.remotePath      = remotePath
        self.status          = .queued
        self.fileSize        = fileSize
        self.bytesTransferred = 0
        self.resumeOffset    = 0
        self.isAutoSync      = isAutoSync
        self.retryCount      = 0
        self.batchID         = batchID
    }
}

// MARK: - Connection State  (NOT Sendable because AnyFTPClient is a reference)
public enum ConnectionState {
    case connecting
    case connected(client: any AnyFTPClient)
    case failed(Error)
    case disconnected

    public var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }

    public var label: String {
        switch self {
        case .connecting:    return "连接中…"
        case .connected:     return "已连接"
        case .failed:        return "连接失败"
        case .disconnected:  return "未连接"
        }
    }
}

// MARK: - Sync Watcher
public struct SyncWatcher: Identifiable, Codable, Sendable {
    public let id: UUID
    public let serverID: UUID
    public let serverName: String
    public var localPath: String
    public var localPathBookmark: Data?
    public var remotePath: String
    public var excludePatterns: [String]
    public var isActive: Bool
    public var lastSyncAt: Date?
    public var totalSynced: Int

    public static let defaultExcludePatterns = [
        "node_modules", ".git", ".DS_Store", "*.log",
        ".env", "dist", "build", ".next", "__pycache__",
        "*.swp", "Thumbs.db", ".idea", ".vscode"
    ]
}
