# SwiftFTP — 上架 App Store 可行性 / 定价 / 整改清单

**审阅人视角**：iOS/macOS 应用架构师 + App Review 经验 + 独立开发者商业化角度
**版本**：v2.0.0（构建产物：`build/SwiftFTP_v2.0.0.dmg`）
**评估日期**：2026-05-19（已同步当前代码状态）
**仓库规模**：约 5k 行 Swift（含 66 个单测） / 单人开发

> 📌 变现 / IAP / 试用 / 门控相关改动，**必须先读** `Docs/Monetization_Compliance_Plan.md`（含给 AI 的硬约束、权益模型、过期态边界、分步执行与测试矩阵）。

---

## 0. 一句话结论

**可以做成「小而美」的付费 FTP/SFTP 客户端，当前代码已经补上了一批早期阻断项：App Sandbox、Keychain 密码存储、SFTP TOFU、StoreKit 2 基础付费、首次引导、About/致谢、SFTP 流式上传与续传、FTPS 证书例外收窄、SFTP 私钥 bookmark。** 距离 MAS 审核通过仍建议预留 **1–2 周** 集中收尾，主要卡点变成**ASC 物料、StoreKit Sandbox、真实协议集成测试、沙盒文件访问手测、最终 App Store 分发签名**。

如果只走 **Developer ID + DMG 直售**（绕开 MAS），当前功能已经接近可打包试卖，仍需要公证、Sparkle/更新策略、隐私政策和真实服务器冒烟验证。

---

## 1. 产品 / 市场角度

### 1.1 它"小而美"吗？

✅ **符合「小而美」气质的部分**
- 单一聚焦：FTP / FTPS / SFTP 三协议客户端，没塞乱七八糟的功能。
- 双栏文件浏览 + 拖拽上传 + 实时同步监控 + 断点续传，是这个赛道的"刚需四件套"。
- SwiftUI + Swift 6 严格并发 + actor 模型，技术栈现代，启动和内存表现会比 Electron/Java 系（如 FileZilla）有明显优势。
- 中文一级菜单与提示，中文用户体验流畅，差异化卖点。

⚠️ **不够"美"或不够"小"的部分**
- 单窗口单服务器，**不能同时打开多个服务器并排操作**——Transmit / ForkLift 都支持；这是这类工具的高频诉求。
- 没有从远端「拖出到 Finder」的反向拖拽；只有拖入。
- 只有 PASV，没有 Active 模式；公司/校园网常需要切换。
- 没有「最近连接」/ 收藏 / 快速连接 URL。
- 菜单与安全页早期问题已修复：命令菜单有实际动作，密码说明已改为 Keychain。

### 1.2 竞品定位

| 产品                | 定价（美元）           | 强项 |
|--------------------|----------------------|------|
| Transmit 5（Panic） | $45 永久许可          | 行业标杆，多窗口、多协议（含 S3/Backblaze） |
| ForkLift 4         | $29.95 / 升级 $19.95 | 双栏+本地文件管理一体 |
| Cyberduck          | 免费 / MAS $39.99    | 老牌、协议最多但 UI 老旧 |
| Yummy FTP Pro      | $9.99（精简版）/ $59.99 | 价格分层 |
| FileZilla          | 免费                | 老牌但 UI 极差 |

**SwiftFTP 的定位空档**：现代 SwiftUI / 中文优化 / 价格亲民的 SFTP 工具——介于免费但难用的 FileZilla 与重量级的 Transmit 之间，对**国内独立开发者、运维、Web 开发者**有吸引力。

### 1.3 定价建议

| 模式 | 推荐价 | 说明 |
|------|--------|------|
| **一次性买断（推荐）** | **¥68 / $9.99** | 比 ForkLift 便宜一档；新品期可做 ¥38 / $4.99 限时入门价 |
| 一次性买断（高线） | ¥128 / $14.99 | 仅当你做完 2.x 多窗口、Cloud Storage（S3）才上 |
| 订阅制 | $1.99/月 或 $14.99/年 | 对工具类不推荐，差评率高，除非加入"持续同步云" |
| 免费 + IAP 解锁 | 免费下载，¥38 解锁多服务器/同步 | 在 MAS 转化率最高的方案 |

**最稳的方案**：MAS 上 **首发 ¥38 / $4.99，3 个月后调到 ¥68 / $9.99**，搭配 7 天免费试用（用 StoreKit 2 + 受限模式：免费版限制 1 个服务器、关闭实时同步）。

> ⚠️ **重要前提**：MAS 不允许应用本身提供「免费试用 → 到期变残疾」式的时间限制；必须以 IAP 解锁或显式划分功能等级实现。

---

## 2. 技术架构角度

### 2.1 写得好的部分（可以拿出来作卖点）

| 项 | 位置 | 评价 |
|----|------|------|
| Swift 6 严格并发完整通过 | `project.yml:47` | 同期同类小工具罕见，加分项 |
| 自研 `ContinuationBox`（NSLock + 一次性 resume） | `FTPClient.swift:474` | 解决 `NWConnection.stateUpdateHandler` 多次回调导致的 double-resume 崩溃，写得规范 |
| `actor ConnectionPool` + 借/还语义 + waiter 队列 | `ConnectionPool.swift` | 处理 actor reentrancy 的注释清晰，工程质量高 |
| 错误友好化映射 `FTPError.friendly()` | `AnyFTPClient.swift:107` | 把 NWError / POSIX / NIO / Cocoa 错误统一中文化，体验比绝大多数 FTP 软件好 |
| FSEvents + 排除规则（节点/git/build 等） | `FSEventWatcher.swift`、`Entities.swift:249` | 实时同步默认排除得体 |
| Keychain-backed credential storage | `ServerRepository.swift`、`KeychainManager.swift` | `ServerConfig.password` 是运行时字段，编码时不落盘，支持旧 JSON 明文迁移 |
| SFTP TOFU host-key 校验 | `SFTPClient.swift`、`KnownHostsManager` | 首次信任后保存 SHA-256 指纹，后续不一致会抛 `hostKeyMismatch` |
| SFTP/FTP 可取消传输与 SFTP 续传 | `SFTPClient.swift`、`FTPClient.swift`、`TransferEngine.swift` | 大文件流式读写，暂停/取消更及时，SFTP download 已按 offset 恢复 |

### 2.2 重大技术风险（必须修，影响上架或体验）

| # | 问题 | 文件 | 严重度 |
|---|------|------|-------|
| T1 | FTP 控制通道只读单行响应，严格 FTP 多行响应（如 `220-...` / `211-...`）兼容性不足 | `FTPClient.swift` | 🟡 部分服务器欢迎语/特性响应可能解析异常 |
| T2 | FTP 仅支持 PASV，没有 Active 模式 | `FTPClient.swift` | 🟡 部分企业网/老服务器无法连接 |
| T3 | 单窗口架构：`WindowGroup { RootView }` 没有多服务器多窗口路由 | `MainViews.swift` | 🟡 影响产品力，不影响审核 |
| T4 | 真实 FTP/SFTP 端到端测试缺失 | `Tests/` | 🟡 当前单测覆盖值类型/仓储/Keychain，缺少协议级回归网 |
| T5 | 本地文件打开/拖入上传在沙盒下仍有 TODO：需逐个验证 `startAccessingSecurityScopedResource()` 覆盖面 | `FileBrowserView.swift`、`FileViewModels.swift` | 🟡 MAS 审核前必须手测 |
| T6 | FTPS 的「允许不受信证书」已收窄到自签/过期/未生效/未知 CA；hostname mismatch 与 revoked 不放行 | `FTPClient.swift` | 🟢 仍需真实 FTPS 服务器 smoke test |

### 2.3 测试覆盖

- 现有 66 个单测，覆盖 `Entities` / `TransferTask` / `Keychain` / `Repository` / `ExclusionMatcher` / `FTPError` / `KnownHostsManager` / `ContinuationBox` / `ConnectionPool` / security-scoped bookmark / FTPS 证书例外 / SFTP 私钥 bookmark 导入导出回归。
- **缺失**：FTPClient 协议解析（MLSD/LIST/PASV/多行响应）单测、TransferEngine 状态机测试、UI 测试、真实 FTP/SFTP 端到端测试（推荐用 Docker pure-ftpd + openssh-server 起本地服务器跑集成测）。
- 验证命令：`xcodebuild test -project SwiftFTP.xcodeproj -scheme SwiftFTP -destination 'platform=macOS' -derivedDataPath /private/tmp/SwiftFTPDerivedDataSigned -clonedSourcePackagesDirPath /private/tmp/SwiftFTPSourcePackages`，当前 66 tests 通过。Keychain 相关测试需要开发签名与 entitlements；`CODE_SIGNING_ALLOWED=NO` 会触发 `errSecMissingEntitlement (-34018)`，不再作为完整测试口径。

---

## 3. 安全 / 隐私角度（**这是上架最大的拦路虎**）

### 3.1 🔴 阻断级安全问题（必须修，否则审核必拒或被苹果下架）

#### S1. 密码存储：已改为 Keychain
- `ServerConfig.password` 保留为运行时字段，`encode(to:)` 不写出 `password`。
- `ServerRepository.fetchAll()` 会读取 Keychain，并迁移旧 UserDefaults JSON 中的明文密码后回写清理。
- `TransferTask` 不再携带 `serverPassword`，`TransferEngine` 通过 `serverID` 临时读取 Keychain。
- 状态：✅ 已完成；仍需在 Release build 中手动验证首次保存/编辑/清空密码流程。

#### S2. SFTP host-key TOFU：已接入
- `SFTPClient` 使用 `TOFUHostKeyValidator` + `KnownHostsManager`。
- 首次连接记录 SHA-256 指纹；后续不一致抛 `FTPError.hostKeyMismatch`。
- 状态：✅ 基础安全模型已完成；下一步可补“用户确认后更新指纹再重连”的 UI 流程。

#### S3. FTPS TLS：默认严格，例外模式需收窄
- 默认不设置 verify block，走系统标准证书链校验。
- 用户显式开启 `allowSelfSignedTLS` 时会放行不受信证书，用于内网/自签服务器。
- 状态：🟡 默认安全已完成；MAS 前建议把例外模式从“全部放行”收窄到只放行自签/过期，不放行域名不匹配。

### 3.2 🟡 中风险

| # | 问题 | 修复 |
|---|------|------|
| S4 | 本地文件浏览/拖放上传仍需完整沙盒手测，确保所有打开/读取路径都来自用户选择或 security-scoped URL | 补 `startAccessingSecurityScopedResource()` 覆盖面和手测清单 |
| S5 | 私钥 passphrase 直接复用 `password` 字段，UI 上没区分密码与 passphrase，混用容易误存 | `ServerEditView` 已有"密钥密码"独立 placeholder，但底层仍是同一个 `password` 字段 |
| S6 | About/致谢已有基础实现，但公开隐私政策 URL 仍缺 | MAS 提交前补公开 HTTPS 隐私政策 |
| S7 | `NotificationService.send` 在 `notDetermined` 时即时申请权限——首次运行就弹，且未做 `usageDescription` 文案 | 改为延迟到首个传输完成时再请求 |

### 3.3 沙盒 (App Sandbox)

**当前**：`Sources/Resources/SwiftFTP.entitlements` 已启用 App Sandbox，并包含 network client、user-selected read/write、app-scope bookmarks。

MAS 上架仍需用 Apple Distribution/MAS provisioning profile 归档验证；当前开发签名下 Debug build/test 可通过，但不等同于可提交包。不要用 `CODE_SIGNING_ALLOWED=NO` 验证 Keychain 流程。

切到沙盒后会破坏的现有功能：
- ✅ FSEventWatcher 监控用户外的目录 → 已通过 `NSOpenPanel` 保存 security-scoped bookmark；
- ✋ `NSWorkspace.shared.open(item.url)` 打开任意路径 → 沙盒下只能开通过 panel 选过的、有书签的；
- ✋ 拖入文件 → ItemProvider 给的是 sandbox-friendly 的临时 URL，需要 `startAccessingSecurityScopedResource()`；
- ✅ 写到 `~/Library/Application Support/SwiftFTP/known_hosts.json` → 沙盒下会重定向到容器内，`KnownHostsManager` 会创建目录；仍需 Release 沙盒包手测。

**建议 entitlements（最小集优先）**：
```xml
<key>com.apple.security.app-sandbox</key><true/>
<key>com.apple.security.network.client</key><true/>
<key>com.apple.security.files.user-selected.read-write</key><true/>
<key>com.apple.security.files.bookmarks.app-scope</key><true/>
```

`com.apple.security.files.downloads.read-write` 只有在有明确的"下载到 Downloads"功能且审核说明能解释时再加；优先使用用户选择目录 + security-scoped bookmarks。

---

## 4. App Store / 上架机制角度

### 4.1 阻断项

| # | 问题 | 状态 |
|---|------|------|
| A1 | App Sandbox | ✅ 已启用；仍需 Release 签名包手测文件访问 |
| A2 | 签名/描述文件 | 🟡 `DEVELOPMENT_TEAM` 已配置，`xcodebuild archive` 通过；最终上传仍需 Xcode Organizer 用 Apple Distribution + MAS 描述文件导出/上传 |
| A3 | Apple Developer Account | ✅ 已有 |
| A4 | Bundle ID `com.swiftftp.app` 未在 App Store Connect 注册 | 🔴 |
| A5 | AppIcon Set 已存在（16–1024），但提交前仍需在 Release `.app`、Finder、Dock、App Store Connect 截图中复核显示效果 | 🟢/复核 |
| A6 | 没有 App Store Connect 物料：截图、副标题、关键字、宣传文本、隐私问卷 | 🔴 |
| A7 | StoreKit 2 / 试用 | 🟡 基础 IAP/试用 UI 已有；必须在 StoreKit config 或 Sandbox 账号里跑通购买/恢复 |
| A8 | `LSApplicationCategoryType` 已设为 `utilities`（OK） | ✅ |
| A9 | `CFBundleShortVersionString = 2.0.0`，但 `CFBundleVersion = 1`——MAS 每次提交需要单调递增 build | 🟡 |
| A10 | 首次启动引导 | ✅ 已有 Onboarding；仍需截图和文案复核 |

### 4.2 隐私问卷 (Privacy Nutrition Label) 预填

提交时苹果会问"是否收集数据"，按目前实现回答：
- Data Linked to User：**None**
- Data Not Linked to User：**Diagnostics（仅崩溃日志，如启用）**
- Data Used to Track You：**None**

只要不集成第三方分析 SDK，可以勾选 **Data Not Collected**。这是好事，**保持这个状态作为差异化**（"零数据收集"是国内注重隐私用户群体的卖点）。

### 4.3 法律 / 许可

| 项 | 现状 | 应做 |
|----|------|------|
| Citadel (BSD-2-Clause) | `project.yml:18` 引入 | 加进 About → "致谢" 列表 |
| swift-nio 等子依赖 | Citadel 间接引入 | 同上 |
| 隐私政策 URL | 缺 | 必须有公开 URL（GitHub Pages 即可） |
| 用户协议/EULA | 缺 | MAS 用 Apple 标准 EULA 即可，直营版需自写 |
| 公司主体 / 个人开发者抬头 | 未确认 | 决定 Apple Developer 账号注册类型 |
| 软著（中国大陆） | 缺 | 若计划在国区销售强烈推荐先办软著，避免被举报下架 |

### 4.4 直营 (Developer ID) vs MAS 路径对比

| 维度 | Mac App Store | Developer ID + DMG 直售 |
|------|---------------|--------------------------|
| 沙盒 | 强制 | 可选（建议加） |
| 公证 | 自动 | 必须 `notarytool` 公证 |
| 支付 | Apple 抽 30% / 15% | Paddle / Gumroad / Stripe，自留约 95% |
| 试用 | 不能时间限制，需 IAP 拆分 | 任意（推荐 14 天免费试用） |
| 更新 | 苹果推送 | 集成 [Sparkle 2](https://sparkle-project.org) |
| 用户量 | 大（被搜索到） | 小（需自己导流） |
| 评审 | 1–7 天，可能被拒 | 仅公证（数分钟） |

**建议**：**先走 Developer ID 直营 1.0**（DMG + Sparkle + Gumroad/爱发电），跑 1–2 个月反馈和口碑，然后**同步上 MAS**作为 2.0。这样：
- 早期不被审核卡；
- 直营版可以保留更高级权限（不受沙盒限制）；
- MAS 版可以做"轻量版"或"标准版"，借助苹果商店导流。

---

## 5. UX / UI 角度

| 严重 | 问题 | 文件 |
|------|------|------|
| 🟡 | 启动后只有"未连接"空状态，**没有 Welcome / 引导**——首次使用门槛高 | `MainViews.swift:84` `WelcomeView` 只在没选择服务器时显示 |
| 🟡 | 仅简体中文（`CFBundleDevelopmentRegion = zh-Hans`），**没英文 Localization** → 海外卖不动 | `Info.plist:6` |
| 🟡 | 拖拽提示视觉反馈很弱（仅靠 NSHostingView + drop type 注册，没有 hover-highlight） | `FileBrowserView.swift:402` |
| 🟡 | 没有键盘多选 / Shift+点击区间选 / ⌘A 全选行为完全靠 SwiftUI Table 默认 | |
| 🟡 | 没有空状态/错误状态的插画——竞品都有 | |
| 🟢 | 文件浏览器图标系统漂亮（`RemoteFileItem.sfSymbol`），但**缺少图片缩略图预览** | `Entities.swift:120` |
| 🟢 | 主侧栏没有 macOS 标准的 Icon-Only Toolbar 切换 / 只有 +、断开 | |
| 🟢 | 没有最近访问 / 收藏路径 | |
| 🟢 | 没有命令行集成（`swiftftp://` URL scheme）—— Transmit 有 `transmit://` | |
| 🟢 | 没有快捷键面板，全靠拖拽 | |

---

## 6. 上架 SwiftFTP 的整改路线图

### Phase 1 — 必做才能进 App Review（约 2–3 周）

> 这一阶段做完后，MAS 审核**有把握通过**。

- [x] **S1: 切换密码到 Keychain**（含旧明文迁移与单测）
- [x] **S2: SFTP TOFU host-key 验证**（基础校验已接入）
- [x] **S3: FTPS 默认严格 TLS + 高级开关**（例外模式仍建议收窄）
- [x] **A1: 启用 App Sandbox + 最小 entitlements**
- [ ] **A2: 用 Xcode Organizer 做 Apple Distribution / MAS provisioning 导出或上传**（`DEVELOPMENT_TEAM` 已配置，CLI archive 已通过）
- [x] **沙盒下的 FSEvents**：security-scoped bookmark 持久化
- [x] **T1: SFTP 大文件分块上传**
- [x] **T2/T3: 修菜单空动作 / 移除死开关 / maxConcurrent 启动加载**
- [ ] **A5: 复核 AppIcon Set**（当前已有 1024–16 全套）；确认 Release `.app`、Finder、Dock、ASC 均显示正确 ⏱ 0.25d
- [ ] **A6: App Store Connect 物料**（5 张截图、副标题、关键字、宣传文案、12+ 评级、隐私政策 URL）⏱ 1d
- [ ] **A7: StoreKit 2 Sandbox 验证**（购买/恢复/失败态）
- [x] **首次启动引导**（Onboarding 已有）
- [x] **License/About 面板**（含致谢 JSON）
- [ ] **真实 FTP/SFTP 集成测试与 MAS 沙盒手测**（文件选择、拖放、同步、Keychain、known_hosts）

### Phase 2 — 上架后体验提升（4–6 周）

- [ ] 多窗口（多服务器并排） ⏱ 2d
- [ ] 远端→本地拖出（drag out）⏱ 1d
- [ ] 英文本地化（提交时选 zh + en）⏱ 1d
- [ ] FTP Active 模式 ⏱ 1d
- [x] SFTP 断点续传（upload/download offset 已实现）
- [ ] 文件预览（QuickLook 集成） ⏱ 1d
- [ ] 收藏路径 / 最近连接 ⏱ 1d
- [ ] 代理（SOCKS5 / HTTP） ⏱ 2d
- [ ] 集成测试套件（pure-ftpd + openssh-server 起 Docker，跑 CI）⏱ 2d

### Phase 3 — 商业化加分（1–2 个月）

- [ ] Sparkle 自动更新（仅直营版）
- [ ] Cloud Storage 协议（S3 / Backblaze B2 / 阿里云 OSS / 七牛 / 腾讯 COS）—— 这是 **¥68 → ¥128 的核心升档卖点**
- [ ] CLI 工具 `swiftftp`（直营版）
- [ ] URL Scheme `sftp://user@host` 系统集成
- [ ] Universal Clipboard（在 iPhone 上点链接，Mac 端自动连接）
- [ ] iPad 版（Catalyst 或重写 SwiftUI）

---

## 7. 提交 App Store 前的清单

```
[基础工程]
□ Bundle ID 注册：com.swiftftp.app（或换成自有反域名）
□ Apple Developer Program 已付费
□ Distribution 证书 + MAS 描述文件
□ CFBundleVersion 单调递增
□ App Sandbox = YES，entitlements 最小集（已配置；需 Release 包复核）
□ Hardened Runtime = YES（archive 时自动）

[功能/质量]
□ 所有菜单项都有动作或被移除（已修；需运行态复核）
□ 启动后 30 秒内能看到产品价值（首次引导）
□ 大文件（>500MB）上传/下载不 OOM（SFTP 已流式；FTP 仍需真实服务器压测）
□ Cmd+Q / Cmd+W / Cmd+R 等系统快捷键正常
□ 黑暗模式视觉验证（已用系统色，理论 OK）

[安全]
□ 所有密码 / passphrase 经 Keychain（已实现）
□ SFTP host-key TOFU（已实现基础校验）
□ FTPS 默认严格 TLS（已实现；自签例外需收窄）
□ 关于面板含第三方致谢 + 隐私政策链接（About 已有，隐私政策 URL 待补）

[App Store Connect]
□ AppIcon 16–1024 全套已就绪（已完成）+ Release `.app` / Finder / Dock / ASC 上传预检显示正常
□ 5 张截图（2880×1800 推荐）
□ 副标题、关键字（≤100 字符）、宣传文案
□ 隐私问卷
□ 试玩账号（如有 IAP）：评审员能跑通解锁流程
□ 价格分层（Tier 5 ≈ $4.99 / Tier 10 ≈ $9.99）
□ 分类：实用工具 / Developer Tools 二选一

[法律]
□ EULA（Apple 标准或自定义）
□ 隐私政策 URL（公开 HTTPS）
□ 商标 / 软著（中国大陆销售强烈建议）
```

---

## 8. 我会怎么做（独立开发者建议）

1. **本周**：做 Xcode Organizer 分发签名、沙盒包手测、StoreKit Sandbox 流程、真实 FTP/FTPS/SFTP 集成测试。
2. **下周**：图标显示复核 + 截图 + ASC 物料 + 隐私政策 URL；同时**先发一个 Developer ID 直营版**（Gumroad / 爱发电 / 微店），定价 ¥38（限时 50% 早鸟），收集 30–50 个真实用户反馈。
3. **第 3–4 周**：根据直营版反馈打磨 1–2 个高频痛点（多窗口或英文化），提交 MAS。
4. **MAS 上架后**：保持每月 1 个小版本（修 bug + 加 1 个小功能），半年后视情况上调到 ¥68。

**关键判断**：这个 App 本身骨架（Swift 6 / actor / NWConnection / Citadel）是同期独立开发者作品里**质量偏上**的；卡住的不是"做不出来"，而是"上架前的合规整改 + 商业化包装"。把这两件事做完，**做成一个能稳定月入 ¥3k–¥10k 的小而美付费工具是合理预期**——前提是有持续维护。
