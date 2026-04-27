// AnyFTPClient.swift
// Swift 6 safe: uses Sendable + nonisolated to avoid actor-crossing issues
import Foundation

// MARK: - Protocol

/// Non-isolated, Sendable protocol so any actor can call it without crossing isolation.
/// Implementations use an internal serial queue or actor for their own state.
public protocol AnyFTPClient: AnyObject, Sendable {
    var isConnected: Bool { get async }
    var config: ServerConfig { get }
    var supportsResume: Bool { get }

    func connect(password: String) async throws
    func disconnect() async

    func listDirectory(_ path: String) async throws -> [RemoteFileItem]
    func createDirectory(_ path: String) async throws
    func delete(path: String, isDirectory: Bool) async throws
    func rename(from: String, to: String) async throws
    func setPermissions(_ octal: Int, path: String) async throws

    /// Upload with resume support (offset = 0 → full upload).
    func upload(
        localURL: URL,
        remotePath: String,
        offset: Int64,
        onProgress: @Sendable @escaping (TransferProgress) -> Void
    ) async throws

    /// Download with resume support (offset = 0 → full download).
    func download(
        remotePath: String,
        localURL: URL,
        offset: Int64,
        onProgress: @Sendable @escaping (TransferProgress) -> Void
    ) async throws

    /// Returns the remote file size (needed for resume).
    func fileSize(at path: String) async throws -> Int64
}

// MARK: - Default no-ops
extension AnyFTPClient {
    public func setPermissions(_ octal: Int, path: String) async throws {
        throw FTPError.unsupported("setPermissions not supported by \(type(of: self))")
    }
}

// MARK: - Transfer Progress
public struct TransferProgress: Sendable {
    public let bytesTransferred: Int64
    public let totalBytes: Int64
    public let bytesPerSecond: Int64

    public var fraction: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1.0, Double(bytesTransferred) / Double(totalBytes))
    }
}

// MARK: - FTP Errors
public enum FTPError: LocalizedError, Sendable {
    case connectionFailed(String)
    case authenticationFailed
    case notConnected
    case badResponse(String)
    case dataConnectionFailed(String)
    case transferFailed(String)
    case fileNotFound(String)
    case permissionDenied(String)
    case unsupported(String)
    case sshKeyLoadFailed(String)
    case hostKeyMismatch(String)
    case timeout
    case resumeNotSupported

    public var errorDescription: String? {
        switch self {
        case .connectionFailed(let m):     return "连接失败：\(m)"
        case .authenticationFailed:        return "用户名或密码错误"
        case .notConnected:                return "未连接到服务器"
        case .badResponse(let r):          return "服务器响应异常：\(r)"
        case .dataConnectionFailed(let m): return "数据连接失败：\(m)"
        case .transferFailed(let m):       return "传输失败：\(m)"
        case .fileNotFound(let p):         return "文件不存在：\(p)"
        case .permissionDenied(let p):     return "权限拒绝：\(p)"
        case .unsupported(let o):          return "不支持：\(o)"
        case .sshKeyLoadFailed(let m):     return "SSH 密钥加载失败：\(m)"
        case .hostKeyMismatch(let h):      return "主机密钥不匹配（\(h)）— 可能存在中间人攻击！"
        case .timeout:                     return "连接超时"
        case .resumeNotSupported:          return "服务器不支持断点续传"
        }
    }
}
