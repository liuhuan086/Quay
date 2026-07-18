// FTPClient.swift
// Swift 6–compatible FTP/FTPS implementation.
// Uses a non-isolated class with an internal serial DispatchQueue for state safety
// instead of `actor`, which avoids the "conformance crosses actor-isolated code" error.
import Foundation
import Network
import Security

// MARK: - Internal state box (isolated by queue)
private final class FTPState: @unchecked Sendable {
    var controlConn: NWConnection?
    var isConnected: Bool = false
    var receiveBuffer = Data()
}

// MARK: - FTPClient
public final class FTPClient: AnyFTPClient {
    // MARK: Properties
    public let config: ServerConfig
    public let supportsResume: Bool = true

    // Internal queue owns all mutable state
    private let queue = DispatchQueue(label: "com.swiftftp.ftpclient", qos: .userInitiated)
    private let state = FTPState()

    // MARK: Init
    public init(config: ServerConfig) {
        self.config = config
    }

    // MARK: isConnected (async computed, safe to call from any context)
    public var isConnected: Bool {
        get async { await withCheckedContinuation { cont in
            queue.async { cont.resume(returning: self.state.isConnected) }
        }}
    }

    // MARK: - Connect
    public func connect(password: String) async throws {
        guard (1...65_535).contains(config.port) else {
            throw FTPError.connectionFailed("端口必须是 1–65535 之间的整数")
        }
        let params = makeConnectionParameters(useTLS: config.protocol_ == .ftps)

        let conn = NWConnection(
            host: .init(config.host),
            port: .init(integerLiteral: UInt16(config.port)),
            using: params
        )

        do {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                let box = ContinuationBox(cont)
                conn.stateUpdateHandler = { state in
                    switch state {
                    case .ready:            box.resume()
                    case .failed(let err):  box.resume(throwing: FTPError.friendly(err))
                    case .waiting:          break
                    case .cancelled:        box.resume(throwing: FTPError.connectionFailed("连接已被取消"))
                    default: break
                    }
                }
                self.queue.async {
                    self.state.controlConn = conn
                    conn.start(queue: self.queue)
                }
            }
        } catch {
            await invalidateConnection()
            throw FTPError.friendly(error)
        }

        do {
            let welcome = try await readControlResponse()
            guard welcome.hasPrefix("220") else { throw FTPError.badResponse(welcome) }

            try await sendCtrl("USER \(config.username)")
            let userResp = try await readControlResponse()

            if userResp.hasPrefix("331") {
                try await sendCtrl("PASS \(password)")
                let passResp = try await readControlResponse()
                guard passResp.hasPrefix("230") else { throw FTPError.authenticationFailed }
            } else if !userResp.hasPrefix("230") {
                throw FTPError.authenticationFailed
            }

            if config.protocol_ == .ftps {
                try await sendCtrl("PBSZ 0")
                let pbsz = try await readControlResponse()
                guard pbsz.hasPrefix("200") else { throw FTPError.badResponse(pbsz) }
                try await sendCtrl("PROT P")
                let protection = try await readControlResponse()
                guard protection.hasPrefix("200") else { throw FTPError.badResponse(protection) }
            }

            try await sendCtrl("TYPE I")
            let typeResponse = try await readControlResponse()
            guard typeResponse.hasPrefix("200") else { throw FTPError.badResponse(typeResponse) }
            try await sendCtrl("OPTS UTF8 ON")
            _ = try? await readControlResponse()
        } catch {
            // 登录阶段任何失败都应清理底层 socket，避免遗留半开连接
            await invalidateConnection()
            throw FTPError.friendly(error)
        }

        await withCheckedContinuation { continuation in
            queue.async {
                self.state.isConnected = true
                continuation.resume()
            }
        }
    }

    // MARK: - Disconnect
    public func disconnect() async {
        try? await sendCtrl("QUIT")
        await invalidateConnection()
    }

    private func invalidateConnection() async {
        await withCheckedContinuation { continuation in
            queue.async {
                self.state.controlConn?.stateUpdateHandler = nil
                self.state.controlConn?.cancel()
                self.state.controlConn = nil
                self.state.isConnected = false
                self.state.receiveBuffer.removeAll()
                continuation.resume()
            }
        }
    }

    private func makeConnectionParameters(useTLS: Bool) -> NWParameters {
        let params: NWParameters
        if useTLS {
            let tls = NWProtocolTLS.Options()
            sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, config.host)
            if config.allowSelfSignedTLS {
                let host = config.host
                sec_protocol_options_set_verify_block(
                    tls.securityProtocolOptions,
                    { _, trust, complete in
                        complete(Self.shouldAllowFTPSCertificateOverride(trust: trust, host: host))
                    },
                    queue
                )
            }
            params = NWParameters(tls: tls)
        } else {
            params = .tcp
        }
        if let tcp = params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.connectionTimeout = 15
        }
        return params
    }

    // MARK: - List Directory
    public func listDirectory(_ path: String) async throws -> [RemoteFileItem] {
        guard await isConnected else { throw FTPError.notConnected }
        do {
            let data = try await receiveListingData(command: "MLSD \(path)")
            if data.isEmpty { return [] }
            let listing = String(data: data, encoding: .utf8) ?? ""
            let parsed = Self.parseMLSD(listing, base: path)
            return parsed.isEmpty ? try await listFallback(path) : parsed
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return try await listFallback(path)
        }
    }

    private func listFallback(_ path: String) async throws -> [RemoteFileItem] {
        let data = try await receiveListingData(command: "LIST \(path)")
        let listing = String(data: data, encoding: .utf8) ?? ""
        return Self.parseLIST(listing, base: path)
    }

    // MARK: - Create Directory
    public func createDirectory(_ path: String) async throws {
        try await sendCtrl("MKD \(path)")
        let r = try await readControlResponse()
        guard r.hasPrefix("257") else { throw FTPError.badResponse(r) }
    }

    // MARK: - Delete
    public func delete(path: String, isDirectory: Bool) async throws {
        let cmd = isDirectory ? "RMD \(path)" : "DELE \(path)"
        try await sendCtrl(cmd)
        let r = try await readControlResponse()
        guard r.hasPrefix("250") else { throw FTPError.permissionDenied(path) }
    }

    // MARK: - Rename
    public func rename(from: String, to: String) async throws {
        try await sendCtrl("RNFR \(from)")
        let r1 = try await readControlResponse()
        guard r1.hasPrefix("350") else { throw FTPError.badResponse(r1) }
        try await sendCtrl("RNTO \(to)")
        let r2 = try await readControlResponse()
        guard r2.hasPrefix("250") else { throw FTPError.badResponse(r2) }
    }

    // MARK: - Set Permissions
    public func setPermissions(_ octal: Int, path: String) async throws {
        try await sendCtrl("SITE CHMOD \(String(octal, radix: 8)) \(path)")
        let response = try await readControlResponse()
        guard response.hasPrefix("200") else { throw FTPError.badResponse(response) }
    }

    // MARK: - File Size
    public func fileSize(at path: String) async throws -> Int64 {
        try await sendCtrl("SIZE \(path)")
        let r = try await readControlResponse()
        guard r.hasPrefix("213"),
              let size = Int64(r.dropFirst(4).trimmingCharacters(in: .whitespaces))
        else { return 0 }
        return size
    }

    // MARK: - Upload (with REST resume)
    public func upload(
        localURL: URL,
        remotePath: String,
        offset: Int64,
        onProgress: @Sendable @escaping (TransferProgress) -> Void
    ) async throws {
        guard await isConnected else { throw FTPError.notConnected }

        let attrs  = try FileManager.default.attributesOfItem(atPath: localURL.path)
        let total  = (attrs[.size] as? Int64) ?? 0
        guard offset >= 0, offset <= total else {
            throw FTPError.transferFailed("续传偏移量超过本地文件大小")
        }

        // Send REST to set resume offset
        if offset > 0 {
            let remoteSize = try await fileSize(at: remotePath)
            guard remoteSize == offset else { throw FTPError.resumeNotSupported }
            try await sendCtrl("REST \(offset)")
            let r = try await readControlResponse()
            guard r.hasPrefix("350") else { throw FTPError.resumeNotSupported }
        }

        let dataConn = try await openPASV()
        defer { dataConn.cancel() }
        do {
            try await withTaskCancellationHandler {
                try await sendCtrl("STOR \(remotePath)")
                let r = try await readControlResponse()
                guard r.hasPrefix("150") || r.hasPrefix("125") else { throw FTPError.badResponse(r) }

                let handle = try FileHandle(forReadingFrom: localURL)
                defer { try? handle.close() }
                if offset > 0 { try handle.seek(toOffset: UInt64(offset)) }

                var sent: Int64 = offset
                let chunkSize = 131_072   // 128 KB
                var lastTime = Date()
                var lastBytes = sent
                var bps: Int64 = 0

                while true {
                    try Task.checkCancellation()
                    let chunk = try handle.read(upToCount: chunkSize) ?? Data()
                    guard !chunk.isEmpty else { break }
                    try await send(data: chunk, on: dataConn)
                    sent += Int64(chunk.count)

                    let now = Date()
                    let elapsed = now.timeIntervalSince(lastTime)
                    if elapsed >= 0.3 {
                        bps = Int64(Double(sent - lastBytes) / elapsed)
                        lastBytes = sent; lastTime = now
                    }
                    onProgress(TransferProgress(bytesTransferred: sent, totalBytes: total, bytesPerSecond: bps))
                }

                try await finishSending(on: dataConn)
                try await readFinalTransferResponse()
                guard sent == total else {
                    throw FTPError.transferFailed("上传字节数不完整（\(sent)/\(total)）")
                }
                onProgress(TransferProgress(bytesTransferred: total, totalBytes: total, bytesPerSecond: 0))
            } onCancel: {
                dataConn.cancel()
            }
        } catch {
            await invalidateConnection()
            throw error
        }
    }

    // MARK: - Download (with REST resume)
    public func download(
        remotePath: String,
        localURL: URL,
        offset: Int64,
        onProgress: @Sendable @escaping (TransferProgress) -> Void
    ) async throws {
        guard await isConnected else { throw FTPError.notConnected }
        let total = try await fileSize(at: remotePath)
        let stagedURL = TransferFileStaging.downloadURL(for: localURL)
        guard offset >= 0, total == 0 || offset <= total else {
            throw FTPError.transferFailed("续传偏移量超过远端文件大小")
        }

        if offset > 0 {
            try await sendCtrl("REST \(offset)")
            let r = try await readControlResponse()
            guard r.hasPrefix("350") else { throw FTPError.resumeNotSupported }
        }

        let dataConn = try await openPASV()
        defer { dataConn.cancel() }
        do {
            try await withTaskCancellationHandler {
                try await sendCtrl("RETR \(remotePath)")
                let r = try await readControlResponse()
                guard r.hasPrefix("150") || r.hasPrefix("125") else { throw FTPError.fileNotFound(remotePath) }

                try FileManager.default.createDirectory(
                    at: localURL.deletingLastPathComponent(), withIntermediateDirectories: true)

                let handle: FileHandle
                if offset > 0 {
                    guard FileManager.default.fileExists(atPath: stagedURL.path),
                          let attributes = try? FileManager.default.attributesOfItem(atPath: stagedURL.path),
                          (attributes[.size] as? Int64) == offset else {
                        throw FTPError.transferFailed("本地续传文件与记录的偏移量不一致，请重新开始下载")
                    }
                    handle = try FileHandle(forWritingTo: stagedURL)
                    try handle.truncate(atOffset: UInt64(offset))
                    try handle.seek(toOffset: UInt64(offset))
                } else {
                    if !FileManager.default.fileExists(atPath: stagedURL.path) {
                        FileManager.default.createFile(atPath: stagedURL.path, contents: nil)
                    }
                    handle = try FileHandle(forWritingTo: stagedURL)
                    try handle.truncate(atOffset: 0)
                }
                defer { try? handle.close() }

                var received: Int64 = offset
                var lastTime = Date(); var lastBytes = received
                var bps: Int64 = 0

                try await stream(on: dataConn) { chunk in
                    try handle.write(contentsOf: chunk)
                    received += Int64(chunk.count)
                    let now = Date(); let elapsed = now.timeIntervalSince(lastTime)
                    if elapsed >= 0.3 { bps = Int64(Double(received - lastBytes) / elapsed); lastBytes = received; lastTime = now }
                    onProgress(TransferProgress(bytesTransferred: received, totalBytes: total, bytesPerSecond: bps))
                }

                try await readFinalTransferResponse()
                if total > 0, received != total {
                    throw FTPError.transferFailed("下载字节数不完整（\(received)/\(total)）")
                }
                try Task.checkCancellation()
                try handle.close()
                try TransferFileStaging.commitDownload(from: stagedURL, to: localURL)
                onProgress(TransferProgress(bytesTransferred: received, totalBytes: total, bytesPerSecond: 0))
            } onCancel: {
                dataConn.cancel()
            }
        } catch {
            await invalidateConnection()
            throw error
        }
    }

    // MARK: - Private: PASV
    private func openPASV() async throws -> NWConnection {
        let port: Int
        try await sendCtrl("EPSV")
        let epsvResponse = try await readControlResponse()
        if epsvResponse.hasPrefix("229") {
            port = try Self.parseEPSV(epsvResponse)
        } else {
            try await sendCtrl("PASV")
            let pasvResponse = try await readControlResponse()
            guard pasvResponse.hasPrefix("227") else { throw FTPError.badResponse(pasvResponse) }
            (_, port) = try Self.parsePASV(pasvResponse)
        }
        guard (1...65_535).contains(port) else {
            throw FTPError.badResponse("被动模式返回了无效端口：\(port)")
        }

        // Always connect the data socket back to the control-channel host. PASV's
        // advertised address is frequently wrong behind NAT and must not be allowed
        // to turn a remote FTP server into an arbitrary network connection primitive.
        let params = makeConnectionParameters(useTLS: config.protocol_ == .ftps)
        let conn = NWConnection(
            host: .init(config.host),
            port: .init(integerLiteral: UInt16(port)),
            using: params
        )
        return try await withCheckedThrowingContinuation { cont in
            let box = ContinuationBox(cont)
            conn.stateUpdateHandler = { st in
                switch st {
                case .ready:           box.resume(returning: conn)
                case .failed(let e):
                    let mapped = FTPError.friendly(e)
                    box.resume(throwing: FTPError.dataConnectionFailed(mapped.errorDescription ?? "未知错误"))
                case .waiting:
                    break
                case .cancelled:
                    box.resume(throwing: FTPError.dataConnectionFailed("连接已被取消"))
                default: break
                }
            }
            conn.start(queue: queue)
        }
    }

    private func receiveListingData(command: String) async throws -> Data {
        let dataConn = try await openPASV()
        defer { dataConn.cancel() }

        try await sendCtrl(command)
        let response = try await readControlResponse()
        guard response.hasPrefix("150") || response.hasPrefix("125") else {
            throw FTPError.badResponse(response)
        }

        do {
            return try await withTaskCancellationHandler {
                let captured = try await receiveAll(on: dataConn)
                try await readFinalTransferResponse()
                return captured
            } onCancel: {
                dataConn.cancel()
            }
        } catch {
            await invalidateConnection()
            throw error
        }
    }

    static func parsePASV(_ msg: String) throws -> (String, Int) {
        guard let s = msg.firstIndex(of: "("), let e = msg.firstIndex(of: ")") else {
            throw FTPError.badResponse("Invalid PASV: \(msg)")
        }
        let parts = String(msg[msg.index(after: s)..<e]).split(separator: ",").compactMap { Int($0) }
        guard parts.count == 6,
              parts.allSatisfy({ (0...255).contains($0) }) else {
            throw FTPError.badResponse("Bad PASV: \(msg)")
        }
        return ("\(parts[0]).\(parts[1]).\(parts[2]).\(parts[3])", parts[4]*256 + parts[5])
    }

    static func parseEPSV(_ msg: String) throws -> Int {
        guard let start = msg.firstIndex(of: "("),
              let end = msg[start...].firstIndex(of: ")") else {
            throw FTPError.badResponse("Invalid EPSV: \(msg)")
        }
        let payload = String(msg[msg.index(after: start)..<end])
        guard let delimiter = payload.first,
              payload.hasPrefix(String(repeating: delimiter, count: 3)),
              payload.hasSuffix(String(delimiter)) else {
            throw FTPError.badResponse("Bad EPSV: \(msg)")
        }
        let portText = payload.dropFirst(3).dropLast()
        guard let port = Int(portText), (1...65_535).contains(port) else {
            throw FTPError.badResponse("Bad EPSV: \(msg)")
        }
        return port
    }

    // MARK: - Private: Send / Receive
    private func sendCtrl(_ cmd: String) async throws {
        guard !cmd.unicodeScalars.contains(where: {
            $0.value == 0 || $0.value == 10 || $0.value == 13
        }) else {
            throw FTPError.unsupported("FTP 命令参数包含不允许的控制字符")
        }
        guard let conn = await withCheckedContinuation({ (cont: CheckedContinuation<NWConnection?, Never>) in
            queue.async { cont.resume(returning: self.state.controlConn) }
        }) else { throw FTPError.notConnected }

        let data = (cmd + "\r\n").data(using: .utf8)!
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.send(content: data, completion: .contentProcessed { err in
                if let err { cont.resume(throwing: err) } else { cont.resume() }
            })
        }
    }

    private func send(data: Data, on conn: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.send(content: data, completion: .contentProcessed { err in
                if let err {
                    let friendly = FTPError.friendly(err)
                    cont.resume(throwing: FTPError.transferFailed(friendly.errorDescription ?? "未知错误"))
                } else {
                    cont.resume()
                }
            })
        }
    }

    private func finishSending(on conn: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.send(
                content: nil,
                contentContext: .finalMessage,
                isComplete: true,
                completion: .contentProcessed { error in
                    if let error {
                        let friendly = FTPError.friendly(error)
                        cont.resume(throwing: FTPError.transferFailed(
                            friendly.errorDescription ?? "无法结束数据传输"
                        ))
                    } else {
                        cont.resume()
                    }
                }
            )
        }
    }

    private func readFinalTransferResponse() async throws {
        let response = try await readControlResponse()
        guard response.hasPrefix("226") || response.hasPrefix("250") else {
            throw FTPError.transferFailed("服务器未确认传输完成：\(response)")
        }
    }

    private func readControlResponse() async throws -> String {
        let first = try await readControlLine()
        guard first.count >= 4 else { return first }
        let code = String(first.prefix(3))
        guard code.allSatisfy(\.isNumber), first[first.index(first.startIndex, offsetBy: 3)] == "-" else {
            return first
        }

        var lines = [first]
        while true {
            let line = try await readControlLine()
            lines.append(line)
            if line.hasPrefix(code + " ") { return lines.joined(separator: "\n") }
        }
    }

    private func readControlLine() async throws -> String {
        while true {
            let buf = await withCheckedContinuation({ (cont: CheckedContinuation<Data, Never>) in
                queue.async { cont.resume(returning: self.state.receiveBuffer) }
            })
            if let range = buf.range(of: Data("\r\n".utf8)) {
                let line = buf.subdata(in: buf.startIndex..<range.lowerBound)
                queue.async { self.state.receiveBuffer.removeSubrange(self.state.receiveBuffer.startIndex..<range.upperBound) }
                return String(data: line, encoding: .utf8) ?? ""
            }
            guard let conn = await withCheckedContinuation({ (cont: CheckedContinuation<NWConnection?, Never>) in
                queue.async { cont.resume(returning: self.state.controlConn) }
            }) else { throw FTPError.notConnected }

            let chunk = try await recv(from: conn, min: 1, max: 4096)
            guard !chunk.isEmpty else {
                throw FTPError.connectionFailed("FTP 控制连接已被服务器关闭")
            }
            queue.async { self.state.receiveBuffer.append(chunk) }
        }
    }

    private func recv(from conn: NWConnection, min: Int, max: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { cont in
            conn.receive(minimumIncompleteLength: min, maximumLength: max) { data, _, isComplete, err in
                if let err { cont.resume(throwing: FTPError.friendly(err)) }
                else if let data, !data.isEmpty { cont.resume(returning: data) }
                else if isComplete { cont.resume(returning: Data()) }
                else { cont.resume(throwing: FTPError.connectionFailed("连接未返回数据且未正常结束")) }
            }
        }
    }

    private func receiveAll(on conn: NWConnection) async throws -> Data {
        var all = Data()
        while true {
            try Task.checkCancellation()
            let chunk = try await recv(from: conn, min: 1, max: 65536)
            if chunk.isEmpty { break }
            all.append(chunk)
        }
        return all
    }

    private func stream(on conn: NWConnection, handler: (Data) throws -> Void) async throws {
        while true {
            try Task.checkCancellation()
            let chunk = try await recv(from: conn, min: 1, max: 65536)
            if chunk.isEmpty { break }
            try handler(chunk)
        }
    }

    // MARK: - Parsers
    static func parseMLSD(_ raw: String, base: String) -> [RemoteFileItem] {
        raw.split(whereSeparator: \.isNewline).compactMap { line -> RemoteFileItem? in
            let s = String(line)
            guard let spaceIdx = s.firstIndex(of: " ") else { return nil }
            let facts = String(s[s.startIndex..<spaceIdx])
            let name = String(s[s.index(after: spaceIdx)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard RemoteFileItem.isSafePathComponent(name) else { return nil }

            var isDir = false; var size: Int64 = 0; var date: Date? = nil
            for fact in facts.split(separator: ";") {
                let kv = fact.split(separator: "=", maxSplits: 1)
                guard kv.count == 2 else { continue }
                switch kv[0].lowercased() {
                case "type":   isDir = kv[1].lowercased().contains("dir")
                case "size":   size  = Int64(kv[1]) ?? 0
                case "modify":
                    let f = DateFormatter(); f.dateFormat = "yyyyMMddHHmmss"
                    date = f.date(from: String(kv[1]))
                default: break
                }
            }
            return RemoteFileItem(name: name, path: joinedRemotePath(base: base, name: name),
                                  isDirectory: isDir, size: size, modifiedDate: date)
        }
    }

    static func parseLIST(_ raw: String, base: String) -> [RemoteFileItem] {
        raw.split(whereSeparator: \.isNewline).compactMap { line -> RemoteFileItem? in
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 9 else { return nil }
            let perm = String(parts[0]); let isDir = perm.hasPrefix("d")
            let size = Int64(parts[4]) ?? 0
            let name = parts[8...]
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard RemoteFileItem.isSafePathComponent(name) else { return nil }
            return RemoteFileItem(name: name, path: joinedRemotePath(base: base, name: name),
                                  isDirectory: isDir, size: size, permissions: perm)
        }
    }

    private static func joinedRemotePath(base: String, name: String) -> String {
        base.hasSuffix("/") ? base + name : base + "/" + name
    }

    // MARK: - FTPS trust exceptions
    static func shouldAllowFTPSCertificateOverride(errorCodes: Set<Int>, description: String) -> Bool {
        let lowercased = description.lowercased()
        let deniedCodes: Set<Int> = [
            Int(errSecHostNameMismatch),
            Int(errSSLHostNameMismatch),
            Int(errSecCertificateRevoked)
        ]
        let allowedCodes: Set<Int> = [
            Int(errSecCertificateExpired),
            Int(errSecCertificateNotValidYet),
            Int(errSecNotTrusted),
            Int(errSecInvalidCertAuthority)
        ]

        if !errorCodes.isDisjoint(with: deniedCodes) {
            return false
        }
        if lowercased.contains("host name")
            || lowercased.contains("hostname")
            || lowercased.contains("name mismatch")
            || lowercased.contains("revoked")
            || lowercased.contains("revocation") {
            return false
        }
        return !errorCodes.isDisjoint(with: allowedCodes)
    }

    private static func shouldAllowFTPSCertificateOverride(trust: sec_trust_t, host: String) -> Bool {
        let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
        SecTrustSetPolicies(secTrust, SecPolicyCreateSSL(true, host as CFString))

        var error: CFError?
        if SecTrustEvaluateWithError(secTrust, &error) {
            return true
        }
        guard let error else { return false }
        return shouldAllowFTPSCertificateOverride(
            errorCodes: trustErrorCodes(from: error),
            description: CFErrorCopyDescription(error) as String
        )
    }

    private static func trustErrorCodes(from error: CFError) -> Set<Int> {
        var codes = Set([Int(CFErrorGetCode(error))])
        let nsError = error as Error as NSError
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            codes.insert(underlying.code)
        }
        if let underlying = nsError.userInfo[kCFErrorUnderlyingErrorKey as String] as? NSError {
            codes.insert(underlying.code)
        }
        return codes
    }
}

// MARK: - ContinuationBox (one-shot resume guard)
/// Wraps a CheckedContinuation so it can only be resumed once,
/// even if NWConnection fires stateUpdateHandler multiple times.
final class ContinuationBox<T>: @unchecked Sendable {
    private var cont: CheckedContinuation<T, Error>?
    private let lock = NSLock()

    init(_ cont: CheckedContinuation<T, Error>) { self.cont = cont }

    func resume(returning value: sending T) {
        lock.lock(); defer { lock.unlock() }
        cont?.resume(returning: value); cont = nil
    }

    func resume(throwing error: Error) {
        lock.lock(); defer { lock.unlock() }
        cont?.resume(throwing: error); cont = nil
    }
}

// Overload for Void continuations
extension ContinuationBox where T == Void {
    func resume() { resume(returning: ()) }
}
