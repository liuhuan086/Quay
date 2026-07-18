# Quay — Mac App Store 上架就绪度

**复核日期**：2026-07-18
**结论口径**：只记录能从当前代码、自动化测试或明确的人工发布门禁验证的事实。

## 结论

Quay 的主要代码级安全与可靠性阻断项已经修复，可以进入发布候选阶段；但在完成 Apple Distribution/MAS 签名包、StoreKit Sandbox、真实 FTPS/SFTP 服务器和 App Sandbox 文件访问验证前，不能宣称“已可提交”或“审核一定通过”。

当前仍是一个聚焦的本地文件传输工具：FTP、隐式 FTPS、SFTP、双栏浏览、传输队列、断点续传和本地实时同步。商业价格、竞品价格、销量或收入预测不属于工程事实，应在提交前另做有日期和来源的市场调研，不在本文给出保证性数字。

## 已实现的协议边界

| 协议 | 默认端口 | 当前实现 |
| --- | ---: | --- |
| FTP | 21 | 明文控制/数据通道；EPSV 优先、PASV 回退 |
| FTPS | 990 | **仅隐式 FTPS**；控制与数据通道均为 TLS；登录后要求 `PBSZ 0` / `PROT P` |
| SFTP | 22 | Citadel/NIOSSH；密码或用户选择的私钥；TOFU 主机指纹 |

明确不支持：显式 FTPS（`AUTH TLS`）、FTP Active 模式、代理、多服务器多窗口。UI 与宣传材料必须使用“隐式 FTPS”，不能把这些能力写成已支持。

## 已关闭的高风险问题

- 密码只写入 macOS Keychain；服务器 JSON 导出不含密码或 security-scoped bookmark；导入在任何持久化前验证整批配置。
- FTP 可解析多行控制响应；MLSD 被拒绝时回退 LIST；被动端口范围受校验，PASV 返回的主机地址不会被用来连接第三方主机。
- FTP 上传完成后显式半关闭数据连接，再等待 `226/250`，并校验发送字节数；本地集成测试覆盖这一握手。
- FTP/FTPS 数据连接与控制连接使用一致的 TLS 策略；FTPS 证书例外仅能由用户显式开启，且不放行 hostname mismatch 或 revoked。
- FTP 命令参数拒绝 CR/LF/NUL；远端文件名拒绝 `.`, `..`, `/` 和控制字符；下载目标再次做父目录边界检查。
- FTP 与 SFTP 下载先写同目录隐藏暂存文件，完整性确认后再原子替换目标，失败或取消不会破坏原文件。
- SFTP 首次主机指纹只有成功原子持久化后才接受；持久化失败时 fail closed。默认 SSH 算法不启用 SHA-1 兼容集合，旧式算法必须由用户显式开启。
- 连接池 waiter 可取消；传输取消后要等底层 I/O 真正退出才释放运行槽。同一服务器、方向和目标路径的写入不会并发执行。
- 自动同步对同一目标合并未完成任务，统计只在传输成功后更新；试用/Pro 权益失效时停止 FSEvents 监控。
- 端口在 UI、仓储和 FTP 连接入口均限制为 `1...65535`，不再由强制整数转换触发崩溃。

## 自动化验证基线

无签名测试命令：

```bash
xcodebuild test \
  -project SwiftFTP.xcodeproj \
  -scheme SwiftFTP \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /private/tmp/SwiftFTPDerivedData \
  CODE_SIGNING_ALLOWED=NO
```

2026-07-18 结果：**103 tests，97 passed，6 skipped，0 failed**。6 个跳过项全部是直接访问 Data Protection Keychain 的集成测试；无签名宿主缺少 Keychain entitlement 时会明确跳过。仓储逻辑测试使用注入的内存 Keychain，因此不会把签名问题伪装成业务测试失败。

目前自动化覆盖：实体编码与安全边界、仓储原子校验、FTP 响应与目录解析、FTP 本地上传握手、多行欢迎响应、下载暂存替换、Known Hosts fail-closed、连接池取消、TransferEngine 重试/取消/同目标串行、security-scoped bookmark 和权益模型。

仍缺少自动化的真实服务器矩阵：隐式 FTPS 证书场景、SFTP 密码/私钥/host-key 变更、大文件断点续传、App Sandbox 跨重启文件授权、StoreKit Sandbox 和 UI/辅助功能。

## 发布前阻断项

以下项目需要真实签名、外部服务或人工交互，本次代码审查不能替代：

- [ ] 用 Apple Development 签名运行完整测试，确认 103 项全执行且 Keychain 6 项不跳过。
- [ ] 用 Apple Distribution + Mac App Store provisioning profile 归档，并核对最终 app 的 sandbox、network、user-selected files、app-scope bookmarks、Keychain access group entitlements。
- [ ] 在真实隐式 FTPS 服务器验证：有效证书、自签、过期、hostname mismatch、revoked，以及大文件上传/下载 checksum。
- [ ] 在真实 SFTP 服务器验证：密码、私钥、带 passphrase 私钥、host key 首次信任/变更、默认算法与旧式算法 opt-in。
- [ ] 手测文件选择、拖放上传、下载、打开本地文件、同步规则跨重启恢复及 bookmark stale 路径。
- [ ] 在 StoreKit Configuration 与干净 Sandbox Apple Account 中验证 trial、Pro、restore、cancel、pending、unfinished 和离线/验证失败状态。
- [ ] 完成 App Store Connect 的 Bundle ID、IAP、截图、隐私问卷、支持/隐私 URL 和 Review Notes。
- [ ] 将仓库内最新 Privacy/Terms 发布到公开 Pages，并核对正文与生效日期；URL 返回 200 不代表内容已经同步。
- [ ] 完成 VoiceOver、键盘操作、深浅色、简体中文文案和至少英文商店元数据检查。

## StoreKit 合规口径

当前“Tier 0 Non-Consumable `7-Day Trial` + 付费 Non-Consumable `Quay Pro`”方向符合 Apple 对非订阅 app 时间试用的公开规则：试用商品名称应遵循 `XX-day Trial`，开始前必须清楚披露时长、到期后失去的内容/服务和完整解锁费用。规则可能变化，提交当天仍需复核 [App Review Guidelines 3.1.1](https://developer.apple.com/app-store/review/guidelines/)。

Family Sharing 是否开启必须在提交前明确决定；Apple 说明 IAP 一旦开启 Family Sharing 就不能关闭，见 [App Store Connect Help](https://developer.apple.com/help/app-store-connect/configure-in-app-purchase-settings/turn-on-family-sharing-for-in-app-purchases/)。

## 发布判断

代码层面已不再保留本轮审查发现的 P0/P1 缺陷。下一步应执行 `Docs/Release_Verification.md`，用签名包和真实服务器取得证据。任何“审核必过”“预计收入”或未经实时调研的竞品价格都不应进入发布决策或对外文案。
