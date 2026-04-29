# SwiftFTP 上架整改 — Claude Code 执行手册

> 配合 `Docs/AppStore_Readiness.md` 使用。
> 每条 prompt 都是**自包含**的——可以直接在新会话里粘给 Claude Code（或当前会话），它能看懂上下文。
> 顺序按 **Phase 1（必修）→ Phase 2（体验）→ Phase 3（商业化）** 排列；建议**自上而下**逐个执行，不要跳。

---

## 使用方式

```
1. 在 Claude Code 里 cd 到项目根 /Users/liuhuan/Documents/SwiftFTPClaude
2. 按本文件顺序复制下面的 ⌘ Prompt 到对话框
3. 每完成一条，本地 git commit；commit 完跑 ⌘U 单测
4. 全部 Phase 1 完成后再做沙盒切换最终验证
```

---

# Phase 1 — 必修：上架前合规整改

## P1-01 把密码迁移到 Keychain

```
我们要把 SwiftFTP 的密码存储从 UserDefaults 迁移到 macOS Keychain，原因见
Docs/AppStore_Readiness.md §3.1 S1。

现状：
- ServerConfig.password: String 是 Codable 字段，整体 JSON 写进 UserDefaults
- TransferTask.serverPassword 也是 String，跟着任务持久化
- KeychainManager.swift 已实现但无人引用（死代码）
- TransferQueueView.swift:215 的设置文案还公开声称"不使用 钥匙串"

请：
1. 把 ServerConfig.password 改成不参与 Codable 的瞬态字段（用 CodingKeys 排除，
   或拆成 ServerConfig（持久）+ ServerCredential（运行时）两个结构体）
2. 在 ServerRepository.save / fetchAll 时通过 KeychainManager 读写密码，
   account = serverID.uuidString，service 沿用 com.swiftftp.app
3. 删除 TransferTask.serverPassword，TransferEngine.executeTask 里改成
   通过 task.serverID 现取密码（或在 enqueue 时把密码放进 actor 内的字典）
4. 写一个一次性迁移：检测到老 UserDefaults JSON 里有非空 password 时，
   写到 Keychain 后清空字段并回写
5. 修改 SettingsRootView 的安全页文案，改成"密码安全保存在 macOS 钥匙串中"
6. 跑 KeychainTests / ServerRepositoryTests，确保不回归
7. 输出迁移逻辑要写一个单测：构造老格式 JSON → fetchAll → 验证 Keychain 里有

不要破坏现有 SSH 私钥 passphrase 与密码共用 password 字段的行为；
迁移时把它们一起迁。
```

---

## P1-02 SFTP TOFU 主机密钥校验

```
SFTPClient.swift:367 当前用 hostKeyValidator: .acceptAnything()，存在中间人攻击
风险（Docs/AppStore_Readiness.md §3.1 S2）。同文件 :476 已经有
KnownHostsManager 实现 TOFU 但没接进去。

请：
1. 把 KnownHostsManager 接进 Citadel 的 hostKeyValidator
   - 首次连接：记录 fingerprint（SHA-256），返回 accept
   - 后续连接：fingerprint 一致 → accept；不一致 → 抛 FTPError.hostKeyMismatch
2. 在 hostKeyMismatch 被抛出时，AppState.connect 捕获并展示
   一个"主机密钥变更，是否信任新密钥？"的确认弹窗（NSAlert 也行）
   - 用户确认后调用 KnownHostsManager.store(fingerprint:for:) 更新指纹再重连
   - 拒绝则保持失败
3. KnownHostsManager 的 fileURL 在沙盒下会被重定向到容器内，确保
   第一次写入时 createDirectory(withIntermediateDirectories: true) 工作
4. 加测试：mock 一个 KnownHostsManager 协议，验证一致 / 不一致 / 首次 三种分支

确认 Citadel 的 SSHHostKeyValidator API（Citadel 0.7.x），如有变化按实际签名实现。
```

---

## P1-03 FTPS 严格 TLS（默认严格 + 高级开关）

```
FTPClient.swift:43-46 用 sec_protocol_options_set_verify_block 直接 complete(true)，
等于关闭 TLS 校验。需要：

1. ServerConfig 增加字段：var allowSelfSignedTLS: Bool = false
2. FTPClient.connect 里：当 allowSelfSignedTLS == false（默认）时，
   不设置 verify block，让系统走标准链校验
3. 当用户勾选时，用 SecTrustEvaluateWithError 显式调用，遇错也只放行
   "证书过期 / 自签名" 这两类，不放行域名不匹配
4. ServerEditView 的「高级」Tab 加一个开关：
   "允许自签名 / 不受信证书（FTPS）"，默认关，旁边一个 (?) tooltip 说明风险
5. 切换该字段时，立即在 testConnection() 里生效

注意：Network.framework 的 sec_protocol_options 是 nw_protocol_options 衍生，
不能简单 complete(true) 后再回到默认；改成只在用户允许时才设置 verify block。
```

---

## P1-04 启用 App Sandbox 与最小 entitlements

```
当前 Sources/Resources/SwiftFTP.entitlements 的 com.apple.security.app-sandbox = false。
要切到 true 并保持现有功能可用。

请：
1. 修改 entitlements 为最小集：
   - com.apple.security.app-sandbox = true
   - com.apple.security.network.client = true
   - com.apple.security.files.user-selected.read-write = true
   - com.apple.security.files.bookmarks.app-scope = true
   - 默认不要加 com.apple.security.files.downloads.read-write；只有确认需要固定写 Downloads 且能向审核说明时再加
2. 修改 project.yml：
   - CODE_SIGN_IDENTITY 改为 "Apple Development"
   - CODE_SIGNING_REQUIRED = YES
   - DEVELOPMENT_TEAM 留 TODO 由用户填
3. 沙盒下会破坏的代码点要打 fix-it 注释：
   - FSEventWatcher：监控的目录必须先有 security-scoped bookmark
   - NSWorkspace.shared.open(item.url) ：只能开过 panel 选过的 URL
   - KnownHostsManager.fileURL 写入 ~/Library/Application Support/SwiftFTP/
     在沙盒下会自动重定向到容器内，验证写权限
   - 拖入 ItemProvider 给的 URL：调用 startAccessingSecurityScopedResource()
4. 跑一次 xcodebuild build，列出所有沙盒相关警告 / 错误
5. 不要在这一步就解决所有问题，只做沙盒开启 + 编译通过；
   FSEvents 的 bookmark 化放到 P1-05

完成后让我看 git diff 与编译结果。
```

---

## P1-05 FSEvents 监控 + 安全作用域书签

```
沙盒开启后（P1-04），FSEventWatcher 监控用户外的目录会失败。需要把监控目录
改成必须由用户通过 NSOpenPanel 选择，并把 URL 转成 security-scoped bookmark
持久化。

请：
1. SyncWatcher 增加字段：var localPathBookmark: Data?
   localPath 仍保留作为人类可读路径
2. RealtimeSyncView 的 addSheet 里"选择…"按钮：
   - NSOpenPanel.canCreateDirectories = true
   - 选定后立即调 url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess])
   - 把 bookmark 写进 SyncWatcher，UserDefaults 持久化
   - 拖入路径不能直接信任，必须用户再点"选择…"确认（沙盒下没有书签的拖入路径
     无法稳定持续访问）
3. SyncManager.start 里：
   - 解析每个 watcher 的 bookmark 拿到 URL
   - 调 startAccessingSecurityScopedResource()，记录引用计数
   - 把 URL.path 给 FSEventWatcher.startWatching(paths:)
   - stopAll 时配对 stopAccessingSecurityScopedResource
4. 处理 bookmark stale（用户重命名了文件夹）的情况：
   解析时检测 isStale → 弹窗提示用户重新选择
5. 加测试：构造一个 bookmark → 解析 → 验证 path 一致

跑完后手动验证一遍：在 ~/Desktop 建一个测试目录，加同步规则，
碰文件 → 看是否能上传。
```

---

## P1-06 修菜单空动作 / 失效快捷键

```
MainViews.swift:438-441 的 AppMenuCommands 里：
  Button("新建连接…") {}
  Button("显示传输队列") {}

是空闭包占位，App Review 可重现。请：

1. 把 AppMenuCommands 改成接受 AppState 与触发动作的 closure
2. SwiftFTPApp 把 appState 注入 AppMenuCommands
3. "新建连接…" → 触发 SidebarView 的 showAdd（用 NotificationCenter
   或者把 showAdd 提升到 AppState.showAddSheet 然后绑定）
4. "显示传输队列" → 触发 TransferBadgePopoverAnchor 的 popover 展开
5. 顺手加几个常用项：
   - 文件菜单：导入/导出服务器配置 JSON（已有 ServerRepository.exportJSON / importJSON）
   - 视图菜单：⌘⇧L 切换显示隐藏文件（绑定到 @AppStorage showHidden）
6. 验证 ⌘⇧N、⌘⇧T 在运行时确实弹出对应 UI
```

---

## P1-07 SFTP 大文件流式上传

```
SFTPClient.swift:217 的 upload 函数：
  let fileData = try Data(contentsOf: localURL)

把整个文件读进内存，>500MB 必崩。请改成流式：

1. 用 FileHandle(forReadingFrom: localURL) + read(upToCount: 32768) 循环
2. 每读一块就 file.write(buffer, at: offset) 到 SFTP；
   写完后 offset += chunk.count
3. 进度回调按已写字节数计算
4. defer 关掉文件句柄；任何抛错都要保证句柄关闭
5. 同步增加 ContentRange 风格的断点续传（如果 Citadel 支持，
   .write + 指定 offset）—— 把 supportsResume 改成 true
6. 加一个集成测试（可选）：本机起 sshd / 用 Docker linuxserver/openssh-server
   传 1GB 文件验证内存峰值 < 100MB

注意 Citadel 的 SFTPFile.write API 接受 ByteBuffer，需要 ByteBuffer(data:)
包装；不要每个 chunk 都重新分配大 buffer，复用同一个 var buffer。
```

---

## P1-08 修死开关：verifyMD5 + maxConcurrent 启动加载

```
TransferQueueView.swift:195 的 @AppStorage("verifyMD5") 没有任何代码读它。
TransferQueueView.swift:192 的 maxConcurrent 启动时不会同步到 TransferEngine。

请：
1. AppState.init 末尾：
   let n = UserDefaults.standard.integer(forKey: "maxConcurrent")
   Task { await engine.updateConcurrent(n > 0 ? n : 3) }
2. 实现 verifyMD5：
   - TransferTask 增加 expectedMD5: String? 与 verifyMD5: Bool
   - 上传：传完后调用一次 SITE / SFTP 服务器端 hash（FTP 没标准命令，
     可省略；SFTP 通过 sftp.openssh-com 的 check-file 扩展 —— 多数服务器
     不支持）
   - 现实选择：MD5 校验在 FTP/SFTP 协议层支持差，建议**移除这个开关**，
     避免误导。我倾向移除，请直接删 verifyMD5 开关与 @AppStorage 字段
3. 把 showHidden 接进 LocalFileVM / RemoteFileVM 的 sortedItems 过滤
4. 把 debounce 接进 FSEventWatcher 的防抖延迟

完成后 Settings 里所有可见开关都必须真生效，否则就删除。
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

```
评审员 30 秒内看不到价值就拒。当前启动后只有空 sidebar + WelcomeView，
门槛高。加个 3 步引导：

1. AppState 增加 @AppStorage("hasSeenOnboarding") + 对应 @Published
2. 新建 Sources/Features/Onboarding/OnboardingView.swift：
   - Step 1 - 欢迎：logo + slogan "极简、安全、Swift 原生的 SFTP 客户端"
   - Step 2 - 演示新建连接：截图或 Lottie 演示从 + 按钮到表单
   - Step 3 - 演示拖拽上传 + 实时同步：动图或视频
   - 底部有 ←/→ 按钮 + 跳过
3. RootView 在 hasSeenOnboarding == false 时全屏覆盖 Onboarding
4. 完成最后一步设置 hasSeenOnboarding = true
5. Settings 加一个"重新观看引导"按钮以便复测

视觉风格参考 Things 3 / Bear，不要用太多动画；纯静态截图 + 标题 + 副标题
即可。截图先放占位 SF Symbols，等真截图出来再替换。
```

---

## P1-11 About 面板 + 第三方致谢

```
Citadel 是 BSD-2-Clause，必须在 About 里署名。当前没有 About 面板。请：

1. 新建 Sources/Features/About/AboutView.swift：
   - logo + App 名 + 版本（CFBundleShortVersionString + Build）
   - "关于 SwiftFTP" 一段简介
   - 链接：官网 / 隐私政策 / 用户协议（先放占位 URL）
   - 致谢按钮 → 弹一个 sheet 列出：
     - Citadel (BSD-2-Clause) © Joannis Orlandos
     - SwiftNIO (Apache 2.0) © Apple Inc.
     - Crypto / NIOSSH 等
2. 在 AppMenuCommands 里替换默认 About 项，调用 NSApp.orderFrontStandardAboutPanel
   或者用 SwiftUI 自定义 sheet
3. 自动从 SPM Package.resolved 提取依赖列表写进 Bundle 资源（也可以手写一个
   acknowledgements.json）
4. 文案中文为主，第三方许可保留英文原文
```

---

## P1-12 StoreKit 2 + IAP 解锁（如果选 MAS）

```
如果走 MAS 路径，需要 IAP 实现"免费下载 → IAP 解锁完整版"，否则没法做试用。

商业模型：
- 免费版：1 个服务器 / 关闭实时同步 / 关闭多并发
- Pro 版（IAP $4.99 一次性）：无限服务器 + 实时同步 + 多并发
- 不做订阅（工具类用户讨厌订阅）

请：
1. 新建 Sources/Core/Billing/StoreManager.swift：
   - actor StoreManager
   - 加载 productID = "com.swiftftp.app.pro"
   - 监听 Transaction.updates
   - 暴露 @MainActor @Published var isPro: Bool
2. AppState 持有 StoreManager；isPro = false 时：
   - SidebarView 添加新连接前检查 servers.count < 1 || appState.isPro
   - RealtimeSyncView 整体在 !isPro 时显示"升级到 Pro 解锁"占位
3. SettingsRootView 加"购买 / 恢复购买"页签
4. 提交 ASC 时配置 IAP 产品（Non-Consumable, $4.99 / Tier 5）
5. 评审账号：开发者账号下创建 Sandbox tester，文档里准备试玩流程

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

## P2-04 FTP Active 模式 + SFTP 续传 + Proxy

合并到一个 PR，因为这三个改动都在 Network 层。

```
请按以下三个独立任务依次实现：

任务 A：FTP Active 模式
- ServerConfig 加 dataMode: enum { passive, active }
- FTPClient 增加 openPORT()：监听一个本地端口，给服务器发 PORT 命令
  注意客户端公网 IP 获取与 NAT 穿透——简单实现先在直连场景跑通

任务 B：SFTP 断点续传
- SFTPClient.supportsResume = true
- upload(offset:) 用 file.write(buffer, at: offset) 从中间写
- download(offset:) 用 file.read(from: offset, length:) 从中间读

任务 C：HTTP / SOCKS5 代理
- ServerConfig 加 proxyConfig: ProxyConfig?
- FTPClient 用 NWParameters.tcp + setProxyConfiguration
- SFTPClient 通过 NIO 自定义 ChannelHandler 注入代理握手

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
