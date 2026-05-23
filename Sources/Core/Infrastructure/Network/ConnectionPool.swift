// ConnectionPool.swift
// Manages a pool of FTP/SFTP connections per server for concurrent transfers.
// Swift 6–safe: actor-isolated.
import Foundation

// MARK: - Pool Entry
private struct PoolEntry {
    let client: any AnyFTPClient
    var inUse: Bool
    var lastUsed: Date
}

typealias ConnectionClientFactory = @Sendable (ServerConfig) -> any AnyFTPClient

// MARK: - ConnectionPool
/// Provides a fixed-size pool of reusable connections to a single server.
/// Callers `borrow` a client, use it, then `return` it.
actor ConnectionPool {
    // MARK: Config
    private let serverConfig: ServerConfig
    private let maxSize: Int
    private let idleTimeout: TimeInterval
    private let clientFactory: ConnectionClientFactory
    private var password: String

    // MARK: State
    private var entries: [PoolEntry] = []
    private var waiters: [CheckedContinuation<any AnyFTPClient, Error>] = []

    // MARK: Init
    init(
        serverConfig: ServerConfig,
        maxSize: Int = 5,
        idleTimeout: TimeInterval = 120,
        clientFactory: @escaping ConnectionClientFactory = ClientFactory.makeClient
    ) {
        self.serverConfig = serverConfig
        self.maxSize      = maxSize
        self.idleTimeout  = idleTimeout
        self.clientFactory = clientFactory
        self.password     = serverConfig.password
    }

    // MARK: - Borrow a connection
    /// Returns an available client, or waits until one becomes free.
    /// Caller MUST call `returnClient(_:)` after use.
    ///
    /// Important: Actor reentrancy means multiple `borrowClient` calls can interleave
    /// at every `await` point. To avoid two callers grabbing the same connection or
    /// exceeding `maxSize`, every slot is reserved synchronously (within one actor turn)
    /// before any `await`.
    func borrowClient(password newPassword: String? = nil) async throws -> any AnyFTPClient {
        if let newPassword {
            updateCachedPassword(newPassword)
        }

        while true {
            // 1. Try to find an idle, connected entry — reserve it synchronously first.
            if let idx = entries.indices.first(where: { !entries[$0].inUse }) {
                entries[idx].inUse = true
                entries[idx].lastUsed = Date()
                let candidate = entries[idx].client

                let alive = await candidate.isConnected
                if alive {
                    return candidate
                }
                // Stale — drop it and retry the loop.
                if let i = entries.firstIndex(where: { $0.client === (candidate as AnyObject) }) {
                    entries.remove(at: i)
                }
                continue
            }

            // 2. Pool not full — reserve a slot synchronously, then connect.
            if entries.count < maxSize {
                let client = clientFactory(serverConfig)
                let placeholder = PoolEntry(client: client, inUse: true, lastUsed: Date())
                entries.append(placeholder)
                do {
                    try await client.connect(password: password)
                    return client
                } catch {
                    if let i = entries.firstIndex(where: { $0.client === (client as AnyObject) }) {
                        entries.remove(at: i)
                    }
                    throw error
                }
            }

            // 3. Pool full — wait for a return.
            return try await withCheckedThrowingContinuation { cont in
                waiters.append(cont)
            }
        }
    }

    func updateCachedPassword(_ newPassword: String) {
        password = newPassword
    }

    // MARK: - Return a connection
    func returnClient(_ client: any AnyFTPClient) {
        guard let idx = entries.firstIndex(where: { $0.client === (client as AnyObject) }) else { return }
        if !waiters.isEmpty {
            // Hand directly to next waiter
            let cont = waiters.removeFirst()
            entries[idx].lastUsed = Date()
            cont.resume(returning: client)
        } else {
            entries[idx].inUse    = false
            entries[idx].lastUsed = Date()
        }
    }

    // MARK: - Evict idle connections
    func evictIdle() async {
        let cutoff = Date().addingTimeInterval(-idleTimeout)
        var toRemove: [Int] = []
        for (i, entry) in entries.enumerated() {
            if !entry.inUse && entry.lastUsed < cutoff {
                toRemove.append(i)
            }
        }
        for i in toRemove.reversed() {
            await entries[i].client.disconnect()
            entries.remove(at: i)
        }
    }

    // MARK: - Disconnect all
    func disconnectAll() async {
        for entry in entries { await entry.client.disconnect() }
        entries.removeAll()
        // Cancel all waiters
        for cont in waiters {
            cont.resume(throwing: FTPError.notConnected)
        }
        waiters.removeAll()
    }

    var activeCount: Int { entries.filter { $0.inUse }.count }
    var totalCount: Int  { entries.count }
}

// MARK: - Pool Registry (one pool per server)
actor ConnectionPoolRegistry {
    static let shared = ConnectionPoolRegistry()
    private var pools: [UUID: ConnectionPool] = [:]

    func pool(
        for server: ServerConfig,
        maxSize: Int = 5,
        clientFactory: @escaping ConnectionClientFactory = ClientFactory.makeClient
    ) -> ConnectionPool {
        if let existing = pools[server.id] { return existing }
        let pool = ConnectionPool(serverConfig: server, maxSize: maxSize, clientFactory: clientFactory)
        pools[server.id] = pool
        return pool
    }

    func existingPool(forServerID id: UUID) -> ConnectionPool? {
        pools[id]
    }

    func updateCachedPassword(_ password: String, forServerID id: UUID) async {
        guard let pool = pools[id] else { return }
        await pool.updateCachedPassword(password)
    }

    func removePool(for serverID: UUID) async {
        if let pool = pools.removeValue(forKey: serverID) {
            await pool.disconnectAll()
        }
    }

    func disconnectAll() async {
        for pool in pools.values { await pool.disconnectAll() }
        pools.removeAll()
    }
}
