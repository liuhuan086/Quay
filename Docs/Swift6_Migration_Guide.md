# SwiftFTP v2 — Swift 6 并发安全升级指南

> 解决编译错误 + 连接池 + 断点续传 + SFTP 完整实现说明

---

## 一、Swift 6 两大编译错误的根因与解决方案

### 错误 1：`Conformance of 'FTPClient' to protocol 'AnyFTPClient' crosses into actor-isolated code`

**根因：**
```swift
// ❌ 问题代码
actor FTPClient: AnyFTPClient { ... }
```
当一个 `actor` 遵循协议时，Swift 6 要求协议中所有方法必须标记 `nonisolated`，
否则外部调用者无法在不切换隔离上下文的情况下调用协议方法——这就是"crosses into actor-isolated code"。

**解决方案：不使用 actor，改用普通 class + 内部 DispatchQueue：**
```swift
// ✅ 正确做法
public final class FTPClient: AnyFTPClient {
    // 内部用 serial queue 保护可变状态
    private let queue = DispatchQueue(label: "com.swiftftp.ftpclient", qos: .userInitiated)
    private let state = FTPState()  // 只在 queue 上访问
    
    // isConnected 作为 async computed property，safe from any context
    public var isConnected: Bool {
        get async { await withCheckedContinuation { cont in
            queue.async { cont.resume(returning: self.state.isConnected) }
        }}
    }
    
    public func connect(password: String) async throws { ... }
}
```

**关键原则：**
- 协议 `AnyFTPClient` 的所有方法都是 `async throws`，调用者必须 `await`
- `class` 内部用 `DispatchQueue` 序列化访问，效果等同于 `actor`
- 协议本身标记为 `Sendable`，允许跨并发边界传递

---

### 错误 2：`Reference to captured var 'resumed' in concurrently-executing code`

**根因：**
```swift
// ❌ 问题代码
try await withCheckedThrowingContinuation { cont in
    var resumed = false  // captured mutable var
    connection.stateUpdateHandler = { state in
        guard !resumed else { return }  // ❌ Swift 6: 并发捕获 mutable var 是错误
        resumed = true
        cont.resume()
    }
}
```
Swift 6 不允许在并发闭包中捕获可变变量（`var`），因为无法静态保证线程安全。

**解决方案：使用 `ContinuationBox`（内部用 NSLock 保证一次性 resume）：**
```swift
// ✅ 正确做法
private final class ContinuationBox<T>: @unchecked Sendable {
    private var cont: CheckedContinuation<T, Error>?
    private let lock = NSLock()

    init(_ cont: CheckedContinuation<T, Error>) { self.cont = cont }

    func resume(returning value: T) {
        lock.lock(); defer { lock.unlock() }
        cont?.resume(returning: value)
        cont = nil  // 置 nil 防止二次调用
    }

    func resume(throwing error: Error) {
        lock.lock(); defer { lock.unlock() }
        cont?.resume(throwing: error)
        cont = nil
    }
}

// 使用
try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
    let box = ContinuationBox(cont)  // box 是 Sendable，可以安全跨闭包
    connection.stateUpdateHandler = { state in
        switch state {
        case .ready:           box.resume(returning: ())
        case .failed(let err): box.resume(throwing: FTPError.connectionFailed(err.localizedDescription))
        default: break
        }
    }
    connection.start(queue: queue)
}
```

---

## 二、连接池（Connection Pool）设计

### 为什么需要连接池？

FTP 协议是单通道协议——一个控制连接同时只能执行一个命令。
FTP 并发传输需要独立的控制连接（每个连接 = 一个 FTPClient 实例）。当前 App 为每个服务器配置 9 个池槽：最多 8 个传输槽，加 1 个交互浏览保留量。

### 架构设计

```
用户请求上传 3 个文件
        ↓
  TransferEngine (actor)
  - maxConcurrent = 3
  - 从 ConnectionPool 借用 3 个 client
        ↓
  ConnectionPool (actor, per server)
  ┌──────────────────────────┐
  │ Entry 0: client A (in use)│  ← 上传 file1.jpg
  │ Entry 1: client B (in use)│  ← 上传 file2.png
  │ Entry 2: client C (in use)│  ← 上传 file3.zip
  │ Entry 3: idle             │
  └──────────────────────────┘
        ↓ 完成后 returnClient
  Pool 回收，分配给下一个任务
```

### 核心代码片段

```swift
// 借用连接
let client = try await pool.borrowClient(password: password)
defer { Task { await pool.returnClient(client) } }

// 使用连接（上传/下载）
try await client.upload(...)

// Pool 内部：创建新连接或等待
func borrowClient(password: String) async throws -> any AnyFTPClient {
    // 1. 找空闲连接
    if let idle = entries.first(where: { !$0.inUse && isAlive($0.client) }) {
        return idle.client  // 复用
    }
    // 2. 创建新连接（未到上限）
    if entries.count < maxSize {
        let c = ClientFactory.makeClient(for: config)
        try await c.connect(password: password)
        return c
    }
    // 3. 等待（挂起 + 加入 waiters 队列）
    return try await withCheckedThrowingContinuation { cont in
        waiters.append(cont)
    }
}
```

---

## 三、断点续传（REST + Resume）

### FTP 断点续传

FTP 使用 `REST` 命令（RESTart）指定偏移量：

```
Client → Server: REST 1048576     # 从 1MB 处开始
Server → Client: 350 Restarting   # 服务器确认
Client → Server: STOR /path/file  # 开始传输（从偏移处）
```

**实现要点：**
```swift
func upload(localURL: URL, remotePath: String, offset: Int64, ...) async throws {
    // 1. 发送 REST 设置偏移
    if offset > 0 {
        try await sendCtrl("REST \(offset)")
        let r = try await readControlLine()
        guard r.hasPrefix("350") else { throw FTPError.resumeNotSupported }
    }
    
    // 2. 打开数据连接 + 发送 STOR
    let dataConn = try await openPASV()
    try await sendCtrl("STOR \(remotePath)")
    
    // 3. 本地文件跳到对应偏移
    let handle = try FileHandle(forReadingFrom: localURL)
    if offset > 0 { try handle.seek(toOffset: UInt64(offset)) }
    
    // 4. 传输剩余数据
    // ...
}
```

**本地文件写入（下载续传）：**
```swift
// 追加写入（不覆盖已下载部分）
if offset > 0, FileManager.default.fileExists(atPath: localURL.path) {
    let handle = try FileHandle(forWritingTo: localURL)
    try handle.seekToEnd()  // 从末尾追加
} else {
    FileManager.default.createFile(atPath: localURL.path, contents: nil)
}
```

### 暂停与恢复流程

```
状态机：
queued → inProgress → paused(offset: N) → queued → inProgress(继续)

TransferEngine.pause(id:)
    ├── 取消 running Task（触发 CancellationError）
    └── 设置 status = .paused(resumeOffset: task.bytesTransferred)

TransferEngine.resume(id:password:)
    ├── 读取 resumeOffset
    ├── 设置 status = .queued
    └── drainQueue() → executeTask() → client.upload(offset: resumeOffset)
```

---

## 四、SFTP 实现说明（Citadel）

### 集成步骤

```
1. SFTP 依赖已在 project.yml 中声明：
   Citadel:
     url: https://github.com/orlandos-nl/Citadel.git
     from: "0.7.0"

2. 重新生成/打开 Xcode project 后，SwiftPM 会解析 Citadel 及其 SwiftNIO 相关依赖。

3. SFTPClient.swift 直接 import Citadel / NIOSSH / NIO，不需要 Objective-C Bridging Header。
```

### 关键实现细节

**Citadel/NIO 状态隔离：**
```swift
// SFTPClient 使用 serial queue 管理 SSH/SFTP handle 状态，
// 避免协议 conformance 跨 actor isolation 的 Swift 6 问题。
private let queue = DispatchQueue(label: "com.swiftftp.sftp.\(UUID())", qos: .userInitiated)
```

**主机密钥 TOFU（首次信任）：**
```swift
let fingerprint = /* Citadel/NIOSSH host key SHA-256 fingerprint */
if let stored = KnownHostsManager.shared.fingerprint(for: host) {
    guard stored == fingerprint else { throw FTPError.hostKeyMismatch(host) }
} else {
    // 首次连接：弹窗让用户确认，确认后存储
    KnownHostsManager.shared.store(fingerprint: fingerprint, for: host)
}
```

**SFTP 大文件上传（分块）：**
```swift
// Citadel SFTP 写入应流式读取本地文件，避免 Data(contentsOf:) 读完整文件导致 OOM。
let chunkSize = 32_768
while true {
    let chunk = handle.readData(ofLength: chunkSize)
    guard !chunk.isEmpty else { break }
    var buffer = ByteBuffer(data: chunk)
    try await file.write(buffer, at: offset)
    offset += UInt64(chunk.count)
}
```

---

## 五、Swift 6 并发编程最佳实践总结

### 规则速查表

| 场景 | 错误做法 | 正确做法 |
|------|---------|---------|
| 状态隔离 | `actor` 遵循协议 | `class` + `DispatchQueue` |
| 一次性回调 | `var resumed = false` | `ContinuationBox` + `NSLock` |
| 主线程更新 | `DispatchQueue.main.async { }` | `await MainActor.run { }` 或 `@MainActor` |
| 跨边界传递闭包 | 普通闭包 | `@Sendable` 闭包 |
| 跨边界传递对象 | 普通 class | `Sendable` class / `@unchecked Sendable` |
| 并发可变状态 | 多处直接修改 | 通过 actor 序列化修改 |
| 结构体跨边界 | 含非 Sendable 属性 | 所有属性为值类型或 Sendable |

### 常用诊断方式

```bash
# 开启 Swift 6 严格并发检查（不会真正报错，用于发现问题）
# Build Settings → Swift Compiler → Swift Language Version = Swift 6
# 或
# Build Settings → Swift Strict Concurrency = Complete

# Xcode → Product → Analyze  (静态分析)
# Instruments → Thread Sanitizer  (运行时竞争检测)
```

---

## 六、项目文件说明（v2）

```
Sources/
├── App/
│   └── AppState.swift              # @MainActor 全局状态，管理连接/传输/服务器
├── Core/
│   ├── Domain/
│   │   ├── Entities/Entities.swift # 所有值类型（Sendable struct/enum）
│   │   └── Repositories/
│   │       └── AnyFTPClient.swift  # 协议定义（Sendable, async）
│   ├── Data/
│   │   └── ServerRepository.swift  # UserDefaults 持久化 + NotificationService
│   └── Infrastructure/
│       ├── Network/
│       │   ├── FTPClient.swift     # FTP/FTPS 实现（class + DispatchQueue）
│       │   ├── SFTPClient.swift    # SFTP 实现（Citadel）
│       │   ├── ConnectionPool.swift# 连接池 actor（AppState 配置 9 slots/server）
│       │   ├── TransferEngine.swift# 传输引擎 actor（队列/并发/重试/恢复）
│       │   └── ClientFactory.swift # 工厂方法（根据协议创建 client）
│       ├── FileSystem/
│       │   └── FSEventWatcher.swift# 实时文件监控（FSEvents + 防抖）
│       └── Security/
│           └── KeychainManager.swift# macOS Keychain（Sendable）
└── Features/
    ├── MainViews.swift             # @main App + RootView + Sidebar + StatusBar
    ├── FileBrowser/
    │   ├── Views/FileBrowserView.swift    # 双栏浏览器 + 拖放
    │   └── ViewModels/FileViewModels.swift # LocalFileVM + RemoteFileVM
    ├── TransferQueue/
    │   └── TransferQueueView.swift # 传输列表 + 暂停/恢复/取消
    └── ConnectionManager/
        └── Views/ServerEditView.swift # 新建/编辑服务器表单
```

---

*SwiftFTP v2 — Swift 6 + SwiftUI + Network.framework + Citadel*
