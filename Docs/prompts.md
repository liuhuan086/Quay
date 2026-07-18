# SwiftFTP 上架整改 — Claude Code 执行手册

> 配合 `Docs/AppStore_Readiness.md` 使用。
> 每条 prompt 都是**自包含**的——可以直接在新会话里粘给 Claude Code（或当前会话），它能看懂上下文。
> 顺序按 **Phase 1（必修）→ Phase 2（体验）→ Phase 3（商业化）** 排列；建议**自上而下**逐个执行，不要跳。

---

## 使用方式

```
1. 在开发工具里进入当前仓库根目录（不要依赖某台机器的绝对路径）
2. 按本文件顺序复制下面的 ⌘ Prompt 到对话框
3. 每完成一条，本地 git commit；commit 完跑 ⌘U 单测
4. Phase 1 剩余项完成后做 Release 签名包、沙盒文件访问、StoreKit Sandbox 的最终验证
```

---

# Phase 1 — 必修：上架前合规整改

## P1-01 把密码迁移到 Keychain

> 状态（2026-05-09）：✅ 已完成。`ServerConfig.password` 已是运行时字段，`ServerRepository` 已读写 Keychain 并迁移旧 JSON 明文密码，`TransferTask.serverPassword` 不存在，相关 Keychain/Repository 单测已覆盖。

```
回归任务：
1. 跑 `xcodebuild test`，确认 KeychainTests / ServerRepositoryTests 仍通过
2. 手动验证：新建服务器保存密码 → 重启 → 连接；编辑为空密码 → Keychain 条目删除
3. 确认导出的 JSON 不包含 `"password"` 或明文密码
```

---

## P1-02 SFTP TOFU 主机密钥校验

> 状态（2026-07-18）：✅ TOFU 已接入并改为 fail-closed。首次指纹只有原子持久化成功后才接受；并发访问受锁保护；不一致会抛 `FTPError.hostKeyMismatch`。

```
后续 UX 增强（不降低默认安全性）：
1. 为显式“重置信任”流程设计 UI，并同时展示旧/新 SHA-256 指纹；不要在普通错误弹窗里一键静默覆盖。
2. 重置动作应只删除指定 `host:port` 的记录，要求二次确认并记录清晰的风险说明。
3. 补集成测试：首次连接、一致指纹、持久化失败、不一致指纹、用户显式重置五条路径。
4. 用真实 openssh-server 验证 known_hosts 文件在沙盒容器内可读写。
```

---

## P1-03 FTPS 严格 TLS（默认严格 + 高级开关）

> 状态（2026-07-18）：✅ 代码整改完成。产品仅支持隐式 FTPS（默认 990）；控制与数据通道均使用 TLS，并要求 `PBSZ 0` / `PROT P`。默认走系统校验；例外开关只允许自签/过期/未生效/未知 CA，不放行 hostname mismatch、revoked 或撤销检查失败。

```
剩余真实服务器验证：
1. 有效证书、自签、过期、未生效、域名不匹配、吊销证书六类。
2. 确认数据连接也使用 TLS，服务端拒绝 `PROT C`。
3. 确认 UI 和商店文案只写“隐式 FTPS”，不宣称支持显式 `AUTH TLS`。
```

---

## P1-04 启用 App Sandbox 与最小 entitlements

> 状态（2026-05-09）：✅ entitlements 已启用 App Sandbox，并包含 network client、user-selected read/write、app-scope bookmarks。`project.yml` 已改为 Apple Development / CODE_SIGNING_REQUIRED=YES，`DEVELOPMENT_TEAM` 仍需用户填写。

```
请：
1. 填写 `DEVELOPMENT_TEAM`
2. 用 Apple Development 签名运行一次 Debug 包，手动验证本地文件浏览/打开/拖放上传/实时同步
3. 用 Apple Distribution + MAS provisioning archive，确认 entitlements 在导出的 `.app` 内一致
4. 保持最小 entitlements；不要添加 Downloads 权限，除非产品明确固定写 Downloads
```

---

## P1-05 FSEvents 监控 + 安全作用域书签

> 状态（2026-05-09）：✅ 基础实现已完成。`SyncWatcher.localPathBookmark` 已持久化；添加规则必须通过选择器拿 security-scoped bookmark；`SyncManager.start` 会解析、startAccessing 并在 stopAll 配对释放；已有 bookmark round-trip 单测。

```
剩余手动验证：
1. 在 `~/Desktop` 建测试目录，通过“选择...”添加同步规则
2. 修改文件，确认 FSEvents 触发上传
3. 重启 App 后确认 bookmark 恢复监控
4. 重命名/移动目录后确认 stale 提示可见
```

---

## P1-06 修菜单空动作 / 失效快捷键

> 状态（2026-05-09）：✅ 已完成。`AppMenuCommands` 已接入 `AppState` 和闭包；新建连接、显示传输队列、导入/导出、显示隐藏文件都有实际动作。

```
回归任务：
1. 运行 App，验证 ⌘⇧N 弹出新建连接
2. 验证 ⌘⇧T 展开传输队列 popover
3. 验证导入/导出 JSON 在沙盒签名包内可读写用户选择的位置
4. 验证 ⌘⇧L 能切换本地/远端隐藏文件显示
```

---

## P1-07 SFTP 大文件流式上传

> 状态（2026-05-09）：✅ 已完成。SFTP upload 使用 `FileHandle.read(upToCount:)` + 复用 `ByteBuffer` 分块写入，支持 offset；SFTP download 也已按 offset 续传，并在循环中检查取消。

```
剩余验证：
1. 本机起 sshd / 用 Docker linuxserver/openssh-server
   传 1GB 文件验证内存峰值 < 100MB
2. 手动验证上传/下载暂停后恢复，确认远端/本地文件内容一致
```

---

## P1-08 修死开关：verifyMD5 + maxConcurrent 启动加载

> 状态（2026-05-09）：✅ 可见设置项已接线。`verifyMD5` 死开关已不存在；`AppState.init` 会应用 `maxConcurrent`；`showHidden` 和 `debounce` 已接到对应 VM / watcher。

```
回归任务：
1. 设置最大并发为 1/3/8，重启后确认 TransferEngine 生效
2. 切换显示隐藏文件，确认本地和远端列表同时变化
3. 调整同步防抖延迟，确认 FSEvents 使用新的 UserDefaults 值
```

---

## P1-09 复核 AppIcon 全套并验证显示

```
当前 Sources/Resources/Assets.xcassets/AppIcon.appiconset 已有 16/32/64/128/256/512/1024 图标。
请：

1. 检查 AppIcon.appiconset/Contents.json 是否覆盖 macOS 需要的 16-1024 尺寸
2. 检查每个 PNG 文件是否存在、尺寸正确、没有透明边距过大或模糊
3. 在 Info.plist 已经有 CFBundleIconName = AppIcon，验证打出来的 .app
   在 Finder / Dock 显示正确
4. Archive / export 后再复核 App Store Connect 上传预检是否接受图标
5. 给个 ASCII Tree 列出最终目录结构

如果发现尺寸缺失或图标质量不够，再从 logo/img.png 重新生成，不要硬提交模糊版本。
```

---

## P1-10 首次启动引导（Onboarding）

> 状态（2026-05-09）：✅ 已完成。`AppState.hasSeenOnboarding`、`OnboardingView` 和 Settings 里的“重新观看引导”已存在。

```
回归任务：
1. 清空 `hasSeenOnboarding`，确认首次启动展示 Onboarding
2. 完成/跳过后确认不再弹出
3. Settings 点击“重新观看引导”后确认可复测
4. MAS 截图前把占位视觉复核成最终素材
```

---

## P1-11 About 面板 + 第三方致谢

> 状态（2026-05-09）：✅ 基础完成。`AboutView`、`Acknowledgements.json` 和 App 菜单入口已存在；仍需补真实官网/隐私政策/用户协议 URL。

```
回归任务：
1. 运行 App，打开“关于 Quay”，确认版本/build、致谢列表和链接显示正常
2. 把官网 / 隐私政策 / 用户协议替换成公开 HTTPS URL
3. 对照 `Package.resolved` 复核致谢列表是否包含 Citadel、SwiftNIO、Crypto、NIOSSH 等主要依赖
```

---

## P1-12 StoreKit 2 + IAP 解锁（如果选 MAS）

> 状态（2026-05-09）：🟡 基础完成。`StoreManager`、购买/恢复 UI、试用状态和 Pro 功能限制已存在；剩余是 StoreKit config / Sandbox tester 的真实购买恢复验证。

```
请：
1. 提交 ASC 前配置 IAP 产品（Non-Consumable, `com.swiftftp.app.pro`，$4.99 / Tier 5）
2. 创建 Sandbox tester，跑通购买、恢复、取消、pending、失败态
3. 准备 App Review 说明：试用/购买入口、评审账号、如何验证 Pro 解锁
4. 复核免费/试用结束状态：不能产生 App Review 认为“功能不可用且无清晰购买路径”的体验

不要尝试做收据本地校验绕过——MAS 内购走 StoreKit 2 的 Transaction.verify
就够了，苹果会处理。
```

---

# Phase 2 — 体验提升（上架后）

## P2-01 多窗口（多服务器并排）

```
当前 WindowGroup { RootView } 只支持单窗口单服务器。请改成：

1. WindowGroup(for: ServerSession.self) { $session in ... }
2. 把 selectedServerID 从 AppState 移到 WindowState；AppState 仅保管
   servers 列表
3. SidebarView 在没有 session 时表现为"启动器"（双击服务器 → 开新窗口）
4. ⌘N 新窗口；⌘W 关闭窗口；窗口标题 = 服务器 displayName
5. ConnectionPoolRegistry 已经按 serverID 分池，无需改

注意 SwiftUI 的多窗口生命周期与 actor 引用，AppState 仍是唯一的，
但 RootView 内部状态需要随窗口走。
```

## P2-02 远端 → 本地 拖拽

```
FileBrowserView 当前只能从本地 → 远端拖拽上传。加远端 → 本地：

1. RemoteFileList 的每个 row 加 .onDrag {
   NSItemProvider(object: PromiseProvider(...)) }
2. 用 NSFilePromiseProvider 实现「拖到 Finder 时再下载」
3. 拖到本地 LocalFileList 时直接走现有 download 流程

测试：拖到桌面、拖到 Finder 窗口、拖到第三方 App（如 Sublime）。
```

## P2-03 英文本地化

```
1. 新建 Sources/Resources/zh-Hans.lproj/Localizable.strings 与
   Sources/Resources/en.lproj/Localizable.strings
2. 提取所有 SwiftUI 中字符串字面量为 LocalizedStringKey
3. 用 xcstringstool 或手工迁移到 .xcstrings（Xcode 15+ 推荐）
4. 翻译 100+ 字符串，遇到术语保持一致（Server / Connection / Transfer / Sync）
5. CFBundleDevelopmentRegion 改为 en，CFBundleLocalizations 加 zh-Hans
6. ASC 上架时双语描述

请按 SwiftUI 标准做法重构，不要引入第三方本地化库。
```

## P2-04 FTP Active 模式 + Proxy

合并到一个 PR，因为两个改动都在 Network 层。SFTP upload/download 断点续传已完成，保留为回归测试项。

```
请按以下两个独立任务依次实现：

任务 A：FTP Active 模式
- ServerConfig 加 dataMode: enum { passive, active }
- FTPClient 增加 openPORT()：监听一个本地端口，给服务器发 PORT 命令
  注意客户端公网 IP 获取与 NAT 穿透——简单实现先在直连场景跑通

任务 B：HTTP / SOCKS5 代理
- ServerConfig 加 proxyConfig: ProxyConfig?
- FTPClient 用 NWParameters.tcp + setProxyConfiguration
- SFTPClient 通过 NIO 自定义 ChannelHandler 注入代理握手

回归：保留 SFTP upload/download offset 续传测试，防止 Network 层改动破坏暂停/恢复。
每个任务一个 commit，互不依赖。
```

---

# Phase 3 — 商业化加分

## P3-01 Sparkle 自动更新（仅直营版）

```
对 MAS 版本不需要；对 Developer ID 直营版必须。请：

1. SPM 引入 Sparkle 2.x
2. 准备 EdDSA 签名密钥对（generate_keys 工具）
3. Info.plist 加 SUFeedURL 与 SUPublicEDKey
4. 加更新 menu item："检查更新…"
5. 用 #if APPSTORE / #if !APPSTORE 编译宏区分两个分发版本
6. 写一个 GitHub Actions：tag 推送 → xcodebuild archive →
   notarytool 公证 → 生成 appcast.xml → 推到 GitHub Pages

完整生产级集成参见 https://sparkle-project.org/documentation/
```

## P3-02 Cloud Storage 协议（核心升档卖点）

```
v2 不做，v3 做。规划：

1. 协议层抽象：把 AnyFTPClient 重命名为 AnyRemoteClient
2. 新增 S3Client（用 SotoS3）、B2Client、AliyunOSSClient
3. UI 层：ServerEditView 增加 Storage 类型选择器（FTP/SFTP/FTPS/S3/B2/OSS）
4. 不同协议显示不同字段（S3 需要 Access Key / Secret / Region）
5. 这是从 ¥68 升档到 ¥128 的核心理由——做完前先别涨价

依赖：SotoS3 体积约 5MB，会让 App 体积明显变大；考虑做 plugin 加载或
分两个版本（Lite / Pro Cloud）。
```

---

# 提交检查 prompt（每次发版前跑）

## R-01 Pre-submission 自检

```
我准备提交 SwiftFTP 到 App Store。请按 Docs/AppStore_Readiness.md
§7 的清单逐项核查我的项目，列出：

1. 已完成 ✅
2. 未完成 ❌（必须给出文件路径或证据）
3. 不适用 ⏸（说明原因）

不要修代码，只输出 markdown 报告。
重点核查：
- entitlements 是否启用沙盒
- 所有 password / passphrase 是否走 Keychain
- 是否还有空闭包菜单或假开关
- AppIcon 是否完整（16-1024 全套）
- About 面板是否含第三方致谢
- 隐私政策 URL 是否在代码里硬编码（应放可配置）
- CFBundleVersion 是否比上次提交大

最后给一个总结：「现在能否提交」/「还差 N 项」。
```

## R-02 公证（直营版）

```
我已经完成 archive 出 SwiftFTP.app，路径在
/tmp/swiftftp-build/DerivedData/Build/Products/Release/SwiftFTP.app。

请帮我：
1. 用 codesign --deep 验证签名
2. 生成 zip 提交 notarytool（用 xcrun notarytool submit --wait）
3. 公证通过后 staple
4. 重新打 DMG（沿用 README.md 里的 hdiutil 流程）
5. 输出最终 DMG 的 SHA256

我的 Apple ID：<XXX>，App-specific Password：<XXX>，
Team ID：<XXX>。如果信息不全先停下问我，不要硬编码。
```

---

# 出错排查 prompt 模板

## D-01 沙盒导致的功能失效

```
启用沙盒（P1-04）后 <某功能> 不再工作，控制台输出：
<贴 console 错误>

请定位是哪个 entitlement 缺失 / 哪个 API 在沙盒下不可用，
给出最小修复方案；不要建议关闭沙盒。
```

## D-02 审核被拒

```
我的 SwiftFTP 提交被 App Review 以 Guideline <X.Y.Z> 拒绝，
拒绝原文：

<贴 ASC 审核员原文>

请：
1. 解释这条 Guideline 通常意味着什么
2. 对照我项目的代码 / 物料找到最可能的触发点
3. 给出修复 + 申诉文案（中英双语）
4. 评估是否可以在 ASC 直接 Reply（不重新提交）解决
```

---

# Cheatsheet（常用单条命令）

```bash
# 一键 archive
xcodebuild -project SwiftFTP.xcodeproj -scheme SwiftFTP -configuration Release \
  -archivePath /tmp/SwiftFTP.xcarchive archive

# 公证（替换 <…>）
xcrun notarytool submit /tmp/SwiftFTP.zip \
  --apple-id <id> --team-id <team> --password <app-specific> --wait

# 钉到 DMG
xcrun stapler staple build/SwiftFTP_v2.0.0.dmg

# 查 Keychain 是否真的写进去了（开发期）
security find-generic-password -s "com.swiftftp.app" -a "<server-uuid>"
```
