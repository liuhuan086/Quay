# Quay — Swift 6 并发与传输实现说明

本文按当前开源主线整理，替代早期迁移草稿中的示意代码。具体行为以源码和测试为准。

## 隔离边界

`AnyFTPClient` 是 `AnyObject, Sendable` 协议。网络操作是异步方法，
`isConnected` 是异步 getter，`config` 和 `supportsResume` 是同步属性。
当前 `FTPClient` 和 `SFTPClient` 使用 class 与内部串行队列管理状态；
连接池和传输引擎使用 actor；UI 状态由 `@MainActor AppState` 管理。

这是一套项目实现选择，不能概括成“actor 不能遵循协议”或“所有协议方法必须
nonisolated”。修改隔离方式时，应逐项检查协议要求、可变状态和跨隔离调用。
`@unchecked Sendable` 也不自动带来线程安全，必须核对对应的队列或锁。

FTP 回调通过 `ContinuationBox` 持有 continuation，并用 `NSLock` 保证只恢复一次。
不要用多个并发闭包捕获并修改同一个局部 `var resumed` 替代它。
进度回调使用 `@Sendable` 闭包；更新 UI 时切回 MainActor。

## 连接池与取消

`ConnectionPoolRegistry` 按服务器 UUID 管理 `ConnectionPool`。
AppState 为每个服务器配置 9 个连接槽，支持最多 8 个传输和交互浏览。

借用连接的调用者必须在成功、失败和取消路径归还连接。actor 中的 `await`
允许重入，因此连接槽必须在挂起前预留；不能仅凭挂起前的连接数量判断容量。
等待连接的任务必须可取消。相关回归在 `ConnectionPoolTests` 中。

`TransferEngine` 管理队列、暂停、恢复、重试和同目标串行执行。
取消底层任务后，必须等待其 I/O 清理结束再释放运行槽，避免同一目标重复写入。
`TransferTask.maxRetries` 当前为 3。具体调度边界见 `TransferEngineExecutionTests`。

## 断点续传与文件完整性

暂停记录已传字节数；恢复把 offset 交给协议客户端。FTP 续传使用 `REST`，
服务器拒绝时应报告不支持；SFTP 使用文件 offset 读写。

下载写入目标同目录下的隐藏暂存文件（`.<文件名>.quay-download`），成功后才
通过 `TransferFileStaging` 提交。恢复时检查暂存文件和 offset，不能直接向最终
目标文件盲目追加。失败或取消不能破坏原有目标文件。

SFTP 上传分块读取本地文件，避免一次性把大文件加载进内存。
FTP 上传结束需要半关闭数据连接，再等待最终成功响应并核对发送字节数。

## SFTP 与主机指纹

Citadel 通过 `project.yml` 和 Xcode SwiftPM 集成。
`KnownHostsManager` 用锁保护指纹存储和首次验证，并原子写入 known_hosts JSON。
当前 TOFU 实现会在首次成功持久化指纹后接受连接，没有首次确认弹窗。
已存指纹不匹配或首次保存失败都会拒绝连接。

SSH 私钥由用户选择并保存安全作用域书签。默认不启用旧式 SHA-1 算法集合；
兼容开关应保持用户显式选择。

## 验证入口

- [项目指南](../AGENTS.md)：目录和工程约束。
- [构建与测试](../README.md#build-and-test)：Xcode 与命令行入口。
- [发布验证](Release_Verification.md)：协议、Keychain、沙盒和人工检查。

Swift 6/Complete 并发检查可能产生编译错误，不能视为仅提示模式。
静态分析使用 Product → Analyze；运行时竞争检查使用 Xcode scheme 的 Thread Sanitizer。
