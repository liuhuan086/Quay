// FTPClient.swift
// Swift 6–compatible FTP/FTPS implementation.
// Uses a non-isolated class with an internal serial DispatchQueue for state safety
// instead of `actor`, which avoids the "conformance crosses actor-isolated code" error.
import Foundation
import Network

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
        let params: NWParameters
        if config.protocol_ == .ftps {
            let tls = NWProtocolTLS.Options()
            sec_protocol_options_set_verify_block(
                tls.securityProtocolOptions,
                { _, _, complete in complete(true) },   // allow self-signed for now
                queue
            )
            params = NWParameters(tls: tls)
        } else {
            params = .tcp
        }

        let conn = NWConnection(
            host: .init(config.host),
            port: .init(integerLiteral: UInt16(config.port)),
            using: params
        )

        // Use checked throwing continuation; capture `conn` not `self` to be Sendable
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            // Use a simple flag protected by the continuation itself
            let box = ContinuationBox(cont)
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:            box.resume()
                case .failed(let err):  box.resume(throwing: FTPError.connectionFailed(err.localizedDescription))
                case .waiting(let err): box.resume(throwing: FTPError.connectionFailed(err.localizedDescription))
                default: break
                }
            }
            conn.start(queue: queue)
            self.queue.async { self.state.controlConn = conn }
        }

        let welcome = try await readControlLine()
        guard welcome.hasPrefix("220") else { throw FTPError.badResponse(welcome) }

        try await sendCtrl("USER \(config.username)")
        let userResp = try await readControlLine()

        if userResp.hasPrefix("331") {
            try await sendCtrl("PASS \(password)")
            let passResp = try await readControlLine()
            guard passResp.hasPrefix("230") else { throw FTPError.authenticationFailed }
        } else if !userResp.hasPrefix("230") {
            throw FTPError.authenticationFailed
        }

        try await sendCtrl("TYPE I");   _ = try await readControlLine()
        try await sendCtrl("OPTS UTF8 ON"); _ = try? await readControlLine()

        queue.async { self.state.isConnected = true }
    }

    // MARK: - Disconnect
    public func disconnect() async {
        try? await sendCtrl("QUIT")
        queue.async {
            self.state.controlConn?.cancel()
            self.state.controlConn = nil
            self.state.isConnected = false
            self.state.receiveBuffer.removeAll()
        }
    }

    // MARK: - List Directory
    public func listDirectory(_ path: String) async throws -> [RemoteFileItem] {
        guard await isConnected else { throw FTPError.notConnected }
        let data = try await transferData { dataConn in
            // Try MLSD first
            try await self.sendCtrl("MLSD \(path)")
            let r = try await self.readControlLine()
            guard r.hasPrefix("150") || r.hasPrefix("125") else {
                throw FTPError.badResponse(r)
            }
            _ = try await self.receiveAll(on: dataConn)
        }
        let listing = String(data: data, encoding: .utf8) ?? ""
        return parseMLSD(listing, base: path).isEmpty
             ? try await listFallback(path)   // fallback to LIST
             : parseMLSD(listing, base: path)
    }

    private func listFallback(_ path: String) async throws -> [RemoteFileItem] {
        let data = try await transferData { dataConn in
            try await self.sendCtrl("LIST \(path)")
            let r = try await self.readControlLine()
            guard r.hasPrefix("150") || r.hasPrefix("125") else { throw FTPError.badResponse(r) }
            _ = try await self.receiveAll(on: dataConn)
        }
        let listing = String(data: data, encoding: .utf8) ?? ""
        return parseLIST(listing, base: path)
    }

    // MARK: - Create Directory
    public func createDirectory(_ path: String) async throws {
        try await sendCtrl("MKD \(path)")
        let r = try await readControlLine()
        guard r.hasPrefix("257") else { throw FTPError.badResponse(r) }
    }

    // MARK: - Delete
    public func delete(path: String, isDirectory: Bool) async throws {
        let cmd = isDirectory ? "RMD \(path)" : "DELE \(path)"
        try await sendCtrl(cmd)
        let r = try await readControlLine()
        guard r.hasPrefix("250") else { throw FTPError.permissionDenied(path) }
    }

    // MARK: - Rename
    public func rename(from: String, to: String) async throws {
        try await sendCtrl("RNFR \(from)")
        let r1 = try await readControlLine()
        guard r1.hasPrefix("350") else { throw FTPError.badResponse(r1) }
        try await sendCtrl("RNTO \(to)")
        let r2 = try await readControlLine()
        guard r2.hasPrefix("250") else { throw FTPError.badResponse(r2) }
    }

    // MARK: - Set Permissions
    public func setPermissions(_ octal: Int, path: String) async throws {
        try await sendCtrl("SITE CHMOD \(String(octal, radix: 8)) \(path)")
        _ = try await readControlLine()
    }

    // MARK: - File Size
    public func fileSize(at path: String) async throws -> Int64 {
        try await sendCtrl("SIZE \(path)")
        let r = try await readControlLine()
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

        // Send REST to set resume offset
        if offset > 0 {
            try await sendCtrl("REST \(offset)")
            let r = try await readControlLine()
            guard r.hasPrefix("350") else { throw FTPError.resumeNotSupported }
        }

        let dataConn = try await openPASV()
        try await sendCtrl("STOR \(remotePath)")
        let r = try await readControlLine()
        guard r.hasPrefix("150") || r.hasPrefix("125") else { throw FTPError.badResponse(r) }

        let handle = try FileHandle(forReadingFrom: localURL)
        defer { try? handle.close() }
        if offset > 0 { try handle.seek(toOffset: UInt64(offset)) }

        var sent: Int64 = offset
        let chunkSize = 131_072   // 128 KB
        var lastTime = Date()
        var lastBytes = sent

        while true {
            let chunk = handle.readData(ofLength: chunkSize)
            guard !chunk.isEmpty else { break }
            try await send(data: chunk, on: dataConn)
            sent += Int64(chunk.count)

            let now = Date()
            let elapsed = now.timeIntervalSince(lastTime)
            var bps: Int64 = 0
            if elapsed >= 0.3 {
                bps = Int64(Double(sent - lastBytes) / elapsed)
                lastBytes = sent; lastTime = now
            }
            onProgress(TransferProgress(bytesTransferred: sent, totalBytes: total, bytesPerSecond: bps))
        }

        dataConn.cancel()
        _ = try await readControlLine()   // 226
        onProgress(TransferProgress(bytesTransferred: total, totalBytes: total, bytesPerSecond: 0))
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

        if offset > 0 {
            try await sendCtrl("REST \(offset)")
            let r = try await readControlLine()
            guard r.hasPrefix("350") else { throw FTPError.resumeNotSupported }
        }

        let dataConn = try await openPASV()
        try await sendCtrl("RETR \(remotePath)")
        let r = try await readControlLine()
        guard r.hasPrefix("150") || r.hasPrefix("125") else { throw FTPError.fileNotFound(remotePath) }

        try FileManager.default.createDirectory(
            at: localURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        let handle: FileHandle
        if offset > 0, FileManager.default.fileExists(atPath: localURL.path) {
            handle = try FileHandle(forWritingTo: localURL)
            try handle.seekToEnd()
        } else {
            FileManager.default.createFile(atPath: localURL.path, contents: nil)
            handle = try FileHandle(forWritingTo: localURL)
        }
        defer { try? handle.close() }

        var received: Int64 = offset
        var lastTime = Date(); var lastBytes = received

        try await stream(on: dataConn) { chunk in
            handle.write(chunk)
            received += Int64(chunk.count)
            let now = Date(); let elapsed = now.timeIntervalSince(lastTime)
            var bps: Int64 = 0
            if elapsed >= 0.3 { bps = Int64(Double(received - lastBytes) / elapsed); lastBytes = received; lastTime = now }
            onProgress(TransferProgress(bytesTransferred: received, totalBytes: total, bytesPerSecond: bps))
        }

        dataConn.cancel()
        _ = try await readControlLine()
        onProgress(TransferProgress(bytesTransferred: total, totalBytes: total, bytesPerSecond: 0))
    }

    // MARK: - Private: PASV
    private func openPASV() async throws -> NWConnection {
        try await sendCtrl("PASV")
        let r = try await readControlLine()
        guard r.hasPrefix("227") else { throw FTPError.badResponse(r) }
        let (host, port) = try parsePASV(r)
        let conn = NWConnection(host: .init(host), port: .init(integerLiteral: UInt16(port)), using: .tcp)
        return try await withCheckedThrowingContinuation { cont in
            let box = ContinuationBox(cont)
            conn.stateUpdateHandler = { st in
                switch st {
                case .ready:           box.resume(returning: conn)
                case .failed(let e):   box.resume(throwing: FTPError.dataConnectionFailed(e.localizedDescription))
                default: break
                }
            }
            conn.start(queue: queue)
        }
    }

    /// Helper to run a data-channel transfer and always read the trailing "226"
    private func transferData(_ block: (NWConnection) async throws -> Void) async throws -> Data {
        var captured = Data()
        let dataConn = try await openPASV()
        do {
            try await block(dataConn)
            // block is expected to have already received data; re-read if needed
        } catch {
            dataConn.cancel(); throw error
        }
        // Read 226 Transfer complete
        _ = try? await readControlLine()
        dataConn.cancel()
        return captured
    }

    private func parsePASV(_ msg: String) throws -> (String, Int) {
        guard let s = msg.firstIndex(of: "("), let e = msg.firstIndex(of: ")") else {
            throw FTPError.badResponse("Invalid PASV: \(msg)")
        }
        let parts = String(msg[msg.index(after: s)..<e]).split(separator: ",").compactMap { Int($0) }
        guard parts.count == 6 else { throw FTPError.badResponse("Bad PASV: \(msg)") }
        return ("\(parts[0]).\(parts[1]).\(parts[2]).\(parts[3])", parts[4]*256 + parts[5])
    }

    // MARK: - Private: Send / Receive
    private func sendCtrl(_ cmd: String) async throws {
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
                if let err { cont.resume(throwing: FTPError.transferFailed(err.localizedDescription)) }
                else { cont.resume() }
            })
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
            queue.async { self.state.receiveBuffer.append(chunk) }
        }
    }

    private func recv(from conn: NWConnection, min: Int, max: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { cont in
            conn.receive(minimumIncompleteLength: min, maximumLength: max) { data, _, isComplete, err in
                if let err { cont.resume(throwing: err) }
                else if let data, !data.isEmpty { cont.resume(returning: data) }
                else { cont.resume(returning: Data()) }
            }
        }
    }

    private func receiveAll(on conn: NWConnection) async throws -> Data {
        var all = Data()
        while true {
            let chunk = try await recv(from: conn, min: 1, max: 65536)
            if chunk.isEmpty { break }
            all.append(chunk)
        }
        return all
    }

    private func stream(on conn: NWConnection, handler: (Data) throws -> Void) async throws {
        while true {
            let chunk = try await recv(from: conn, min: 1, max: 65536)
            if chunk.isEmpty { break }
            try handler(chunk)
        }
    }

    // MARK: - Parsers
    private func parseMLSD(_ raw: String, base: String) -> [RemoteFileItem] {
        raw.split(separator: "\n").compactMap { line -> RemoteFileItem? in
            let s = String(line)
            guard let spaceIdx = s.firstIndex(of: " ") else { return nil }
            let facts = String(s[s.startIndex..<spaceIdx])
            let name  = String(s[s.index(after: spaceIdx)...]).trimmingCharacters(in: .whitespaces)
            guard name != "." && name != ".." else { return nil }

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
            return RemoteFileItem(name: name, path: "\(base)/\(name)",
                                  isDirectory: isDir, size: size, modifiedDate: date)
        }
    }

    private func parseLIST(_ raw: String, base: String) -> [RemoteFileItem] {
        raw.split(separator: "\n").compactMap { line -> RemoteFileItem? in
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 9 else { return nil }
            let perm = String(parts[0]); let isDir = perm.hasPrefix("d")
            let size = Int64(parts[4]) ?? 0
            let name = parts[8...].joined(separator: " ")
            guard name != "." && name != ".." else { return nil }
            return RemoteFileItem(name: name, path: "\(base)/\(name)",
                                  isDirectory: isDir, size: size, permissions: perm)
        }
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
