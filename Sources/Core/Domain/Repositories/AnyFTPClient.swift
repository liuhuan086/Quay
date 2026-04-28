// AnyFTPClient.swift
// Swift 6 safe: uses Sendable + nonisolated to avoid actor-crossing issues
import Foundation
#if canImport(Network)
import Network
#endif
#if canImport(Darwin)
import Darwin
#endif

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
        case .connectionFailed(let m):     return m
        case .authenticationFailed:        return "用户名或密码错误，请检查后重试"
        case .notConnected:                return "尚未连接到服务器，请先建立连接"
        case .badResponse(let r):          return "服务器响应异常：\(r)"
        case .dataConnectionFailed(let m): return "数据通道建立失败：\(m)"
        case .transferFailed(let m):       return "传输失败：\(m)"
        case .fileNotFound(let p):         return "文件不存在：\(p)"
        case .permissionDenied(let p):     return "没有权限访问：\(p)"
        case .unsupported(let o):          return "当前协议不支持该操作：\(o)"
        case .sshKeyLoadFailed(let m):     return "SSH 密钥加载失败：\(m)"
        case .hostKeyMismatch(let h):      return "主机密钥不匹配（\(h)），可能存在中间人攻击，请谨慎连接"
        case .timeout:                     return "连接超时，请检查服务器地址、端口与网络是否畅通"
        case .resumeNotSupported:          return "服务器不支持断点续传"
        }
    }
}

// MARK: - Friendly Error Mapping
public extension FTPError {
    /// Convert any low-level error (NWError / POSIXError / NIO connect error / Citadel auth error / NSError)
    /// into a user-friendly Chinese message wrapped in `FTPError`.
    static func friendly(_ error: Error) -> FTPError {
        if let ftp = error as? FTPError { return ftp }
        if error is CancellationError { return .connectionFailed("操作已取消") }

        #if canImport(Network)
        if let nw = error as? NWError {
            return mapNWError(nw)
        }
        #endif

        if let posix = error as? POSIXError {
            return mapPOSIX(posix.code.rawValue)
        }

        let ns = error as NSError

        // URLError-style
        if ns.domain == NSURLErrorDomain {
            switch ns.code {
            case NSURLErrorTimedOut:
                return .timeout
            case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed:
                return .connectionFailed("无法解析主机名，请检查服务器地址是否正确")
            case NSURLErrorCannotConnectToHost:
                return .connectionFailed("无法连接到服务器，请检查地址与端口是否正确，以及服务器是否在线")
            case NSURLErrorNotConnectedToInternet:
                return .connectionFailed("当前未连接到网络，请检查本机网络")
            case NSURLErrorNetworkConnectionLost:
                return .connectionFailed("网络连接已中断，请稍后重试")
            default: break
            }
        }

        // POSIX errno embedded in NSError userInfo (NIO often does this)
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError,
           underlying.domain == NSPOSIXErrorDomain {
            return mapPOSIX(Int32(underlying.code))
        }
        if ns.domain == NSPOSIXErrorDomain {
            return mapPOSIX(Int32(ns.code))
        }

        if ns.domain == NSCocoaErrorDomain {
            switch ns.code {
            case NSFileReadNoSuchFileError:
                return .fileNotFound(ns.localizedDescription)
            case NSFileReadNoPermissionError, NSFileWriteNoPermissionError:
                return .permissionDenied(ns.localizedDescription)
            case NSFileWriteOutOfSpaceError:
                return .transferFailed("本地磁盘空间不足，无法写入文件")
            case NSFileWriteFileExistsError:
                return .transferFailed("本地文件已存在，无法覆盖：\(ns.localizedDescription)")
            case NSFileWriteUnknownError, NSFileWriteInvalidFileNameError,
                 NSFileWriteUnsupportedSchemeError, NSFileWriteVolumeReadOnlyError:
                return .transferFailed("本地文件写入失败：\(ns.localizedDescription)")
            case NSFileReadUnknownError, NSFileReadTooLargeError,
                 NSFileReadInapplicableStringEncodingError,
                 NSFileReadUnsupportedSchemeError:
                return .transferFailed("本地文件读取失败：\(ns.localizedDescription)")
            default:
                break
            }
        }

        // Fall back to fuzzy text matching on the error description / type name.
        // NIO's `NIOConnectionError` aggregates inner POSIX errors that NSError doesn't expose,
        // so we read its `description` / `debugDescription` to recover the cause.
        let typeName = String(reflecting: type(of: error)).lowercased()
        let combined = (typeName + " "
                        + String(describing: error) + " "
                        + ns.localizedDescription + " "
                        + ns.debugDescription).lowercased()

        if combined.contains("operation not permitted") || combined.contains("not permitted") {
            return .permissionDenied("权限不足，无法访问本地文件或目录")
        }
        if combined.contains("permission denied") {
            return .permissionDenied("权限不足，无法访问本地文件、目录或远端路径")
        }
        if combined.contains("no space left") || combined.contains("disk full") {
            return .transferFailed("本地磁盘空间不足，无法写入文件")
        }
        if combined.contains("connection refused") || combined.contains("econnrefused") {
            return .connectionFailed("连接被拒绝，请确认服务器端口是否正确以及服务器是否在线")
        }
        if combined.contains("timed out") || combined.contains("timeout") || combined.contains("etimedout") {
            return .timeout
        }
        if combined.contains("no route to host") || combined.contains("ehostunreach") || combined.contains("host is unreachable") {
            return .connectionFailed("无法访问主机，请检查服务器地址与本机网络")
        }
        if combined.contains("network is unreachable") || combined.contains("enetunreach") {
            return .connectionFailed("网络不可达，请检查本机网络连接")
        }
        if combined.contains("connection reset") || combined.contains("econnreset") {
            return .connectionFailed("连接被服务器重置，请稍后重试")
        }
        if combined.contains("broken pipe") || combined.contains("epipe") {
            return .connectionFailed("连接已断开，请重试")
        }
        if combined.contains("nodename nor servname")
            || combined.contains("hostname")
            || combined.contains("dns")
            || combined.contains("name or service not known") {
            return .connectionFailed("无法解析主机名，请检查服务器地址是否正确")
        }
        if combined.contains("authentication") || combined.contains("auth failed") || combined.contains("password") {
            return .authenticationFailed
        }
        if combined.contains("tls") || combined.contains("ssl") || combined.contains("certificate") {
            return .connectionFailed("加密握手失败，请确认端口是否支持加密以及证书设置")
        }
        if combined.contains("nioconnectionerror") || typeName.contains("connectionerror") {
            return .connectionFailed("无法连接到服务器，请检查地址、端口和网络后再试")
        }
        if combined.contains("cancel") {
            return .connectionFailed("操作已取消")
        }

        return .connectionFailed("连接失败，请检查服务器地址、端口和网络后再试")
    }

    static func isHostReachabilityFailure(_ error: Error) -> Bool {
        if case .connectionFailed(let message) = error as? FTPError {
            return message.contains("无法访问主机") || message.contains("网络不可达")
        }

        #if canImport(Network)
        if let nw = error as? NWError, case .posix(let code) = nw {
            return code.rawValue == EHOSTUNREACH || code.rawValue == ENETUNREACH
        }
        #endif

        if let posix = error as? POSIXError {
            return posix.code.rawValue == EHOSTUNREACH || posix.code.rawValue == ENETUNREACH
        }

        let ns = error as NSError
        if ns.domain == NSPOSIXErrorDomain {
            return Int32(ns.code) == EHOSTUNREACH || Int32(ns.code) == ENETUNREACH
        }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError,
           underlying.domain == NSPOSIXErrorDomain {
            return Int32(underlying.code) == EHOSTUNREACH || Int32(underlying.code) == ENETUNREACH
        }

        let typeName = String(reflecting: type(of: error)).lowercased()
        let combined = (typeName + " "
                        + String(describing: error) + " "
                        + ns.localizedDescription + " "
                        + ns.debugDescription).lowercased()
        return combined.contains("no route to host")
            || combined.contains("ehostunreach")
            || combined.contains("host is unreachable")
            || combined.contains("network is unreachable")
            || combined.contains("enetunreach")
    }

    #if canImport(Network)
    private static func mapNWError(_ nw: NWError) -> FTPError {
        switch nw {
        case .posix(let p):
            return mapPOSIX(p.rawValue)
        case .dns:
            return .connectionFailed("无法解析主机名，请检查服务器地址是否正确")
        case .tls:
            return .connectionFailed("加密握手失败，请确认端口是否支持加密以及证书设置")
        default:
            return .connectionFailed("网络错误，请稍后重试")
        }
    }
    #endif

    private static func mapPOSIX(_ rawCode: Int32) -> FTPError {
        switch rawCode {
        case ECONNREFUSED: return .connectionFailed("连接被拒绝，请确认服务器端口是否正确以及服务器是否在线")
        case ETIMEDOUT:    return .timeout
        case EHOSTUNREACH: return .connectionFailed("无法访问主机，请检查服务器地址与本机网络")
        case ENETUNREACH:  return .connectionFailed("网络不可达，请检查本机网络连接")
        case ECONNRESET:   return .connectionFailed("连接被服务器重置，请稍后重试")
        case EHOSTDOWN:    return .connectionFailed("服务器主机已关机，请联系管理员")
        case ENETDOWN:     return .connectionFailed("本机网络已断开")
        case EPIPE:        return .connectionFailed("连接已断开，请重试")
        case EADDRNOTAVAIL:return .connectionFailed("网络地址不可用，请检查网络配置")
        case EACCES, EPERM:return .connectionFailed("权限不足，无法建立连接")
        case ECONNABORTED: return .connectionFailed("连接被中止，请重试")
        default:
            let msg = String(cString: strerror(rawCode))
            return .connectionFailed("网络错误（\(msg)），请稍后重试")
        }
    }
}
