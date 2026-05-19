# SwiftFTP — 变现与上架合规整改方案（最终版）

**文档性质**：可执行整改方案 / AI 与人共用的工作依据
**适用范围**：Mac App Store（MAS）首发版本的变现模型、IAP 合规、权益与门控
**结论定调**：MAS 免费下载 + Tier 0 `7-Day Trial` Non-Consumable + 付费 `Full Unlock` Non-Consumable；过期态为「数据可访问、核心功能锁定」，**不是全屏变砖**。
**关联文档**：`Docs/AppStore_Readiness.md`（总体上架阻断项）、`Docs/Release_Verification.md`（提交前验证清单，本方案新增项需并入）。

---

## 0. 给 AI 的执行约定（先读，硬约束）

后续任何 AI 会话在本仓库做变现/IAP/门控相关改动时，必须遵守：

- **禁止**重新引入 `UserDefaults.trialStartedAt` 作为试用授权依据。试用有效期的唯一真相是 StoreKit 交易的 `purchaseDate + 7 天`。`trialStartedAt` 持久化逻辑应被删除（见 Step 4）。
- **禁止**把过期态做成「降级但仍可用」的免费层。过期态边界必须精确：数据可读、可导出非敏感配置、可购买/恢复；连接/上传/下载/同步/新建任务一律锁定。漂移成可用免费层 = 同时拿到 trial 与 freemium 两个模型的缺点。
- **禁止**「擅自修复」已登记的既定风险（见 §6 Accepted Risks），尤其是本地时钟回拨延长试用——这是已知并接受的取舍，不要为它加服务器校验或复杂逻辑。
- **禁止**用重复弹窗/模态骚扰催付。升级提示只在「撞墙那一刻」出现一次，文案克制。这同时是 App Review（4.x dark pattern / 3.1.1）与评分风险。
- 能力判断一律走**统一的权益解析出口**（见 §3），不得在各 View 里散落 `isPro` / 日期比较。
- 改动 IAP/门控前先读本文件与 `Docs/AppStore_Readiness.md`。

---

## 1. 结论与边界（合规 ≠ 转化）

- **Trial IAP 只解决合规**：它把 App Review 3.1.1 风险从「高」降到「低」。它**不**自动解决转化率、评分、获客、长期收入。
- **选择方案 A 的真实理由**（精确版）：不是 freemium 商业上必劣，而是 SwiftFTP 当前阶段（单人、时间有限）若走 freemium，需要维护一条脆弱的「读免费 / 写付费」功能边界（大量边界测试、文案解释、UI 分支、用户抱怨）。Trial IAP 的优势是**少维护这条边界**，且不把核心价值免费送出。
- **必须接受方案 A 的营销代价**：第 8 天锁功能即便合规，也天然制造一批低星评价，国区尤甚。非变砖过期态只能减伤，不能消除。缓冲手段写入 §5。

---

## 2. 商业 / 营销策略（定调，非代码）

| 项 | 决定 |
|----|------|
| 分发 | MAS 免费下载 |
| 试用 | 7 天完整试用，经 Apple Tier 0 Non-Consumable IAP 发放 |
| 解锁 | 一次性买断 `Full Unlock`，无订阅 |
| 首发定价 | 限时低价（¥18–25 或 $2.99），3 个月后回调 $4.99 / ¥38。目标是早期评论速度与 ASC 排名飞轮，不是首月利润 |
| 文案纪律 | 商店页与截图明确「7 天完整试用 / 一次买断 / 无订阅」；避免误导性「免费」暗示 |
| 催付纪律 | 仅在功能撞墙处出现一次升级入口，无弹窗轰炸 |
| 未来杠杆 | 云存储（S3/OSS/COS）、云同步、团队能力作为**第二付费档**，不并入首发 `Full Unlock`（见 §3 二档预留） |

---

## 3. 权益模型规范（代码架构）

### 3.1 状态机（五态，含 AI 漏掉的离线态）

| 状态 | 触发条件 | App 行为 |
|------|----------|----------|
| `neverStarted` | 无 trial 交易、无 pro | 进入 Onboarding，主操作＝开始 7 天试用，备选＝购买/恢复 |
| `trialActive` | trial 交易存在 且 `purchaseDate + 7d > now` 且未撤销 | 完整功能 |
| `trialExpired` | trial 交易存在 但 `purchaseDate + 7d <= now` | **非变砖锁定态**（见 §4） |
| `pro` | pro 交易存在 且 `revocationDate == nil` | 完整功能（永久） |
| `entitlementUnknown` | 启动时 StoreKit 不可达且无本会话已解析结果 | 不得变砖：允许进入、显示「无法校验购买」提示、提供「重试 / 恢复购买」，沿用本会话最后一次内存解析结果（若有）作为临时授权 |

### 3.2 能力解析（统一出口，预留二档）

- 不要用 flat `enum`（`pro` 与未来 `futureCloud` 会**重畳**，flat enum 二档时必再改结构）。用「解析后的能力集合」：

```swift
struct Entitlements: Sendable {
    var trialExpiresAt: Date?     // nil = 无有效试用
    var hasPro: Bool              // 首发 Full Unlock
    var hasCloud: Bool            // 预留二档，首发恒 false

    var fullAccess: Bool {        // 门控唯一入口
        hasPro || (trialExpiresAt.map { $0 > Date() } ?? false)
    }
}
```

- 解析来源：遍历 `Transaction.currentEntitlements`。
  - `productID == proProductID` 且 `revocationDate == nil` → `hasPro = true`
  - `productID == trialProductID` 且 `revocationDate == nil` → `trialExpiresAt = transaction.purchaseDate + 7d`（**注意**：Non-Consumable 的交易在 `currentEntitlements` 中永久存在，到期后**仍在**，所以绝不能「看到 trial entitlement 就放行」，必须算日期）
- 门控全仓只认 `Entitlements.fullAccess`，替换现有散落的 `isPro` / `hasFullAccess` 直读。

### 3.3 离线 / StoreKit 失败策略（AI 漏点，必须实现）

- 删除 `trialStartedAt` 持久化后，授权改为：每次启动 `refreshEntitlements()`；解析结果存**内存**（本会话），不落盘。
- StoreKit 不可达：进入 `entitlementUnknown`，**不得锁死**。沿用本会话已解析结果；冷启动且无任何结果时默认锁定但**必须**给「重试 / 恢复购买」动线，不得让可能已付费用户无出路。

---

## 4. 过期态边界（精确，不可漂移）

`trialExpired` / `entitlementUnknown(无授权)` 下：

**允许**：查看服务器列表与配置；导出**非敏感**配置（host/port/协议/路径，**绝不导出密码**——密码在 Keychain，导出即绕过 Keychain，违反安全卖点与审核安全维度）；删除本地数据；打开 关于/隐私/条款；购买；恢复购买；设置页。

**锁定**：建立连接；上传/下载；实时同步；新建任何传输任务；新增/编辑服务器（保持现有 `presentAddServer` / `saveServer` 门控，但文案改为 §5 合规版）。

设计意图：像一个**完整产品的锁定态**，不是空白付费墙——满足 App Review 2.1（提交版本完整、IAP 可见可测）。

---

## 5. 文案 / 披露规范（3.1.1 第一拒因）

3.1.1 要求：**试用开始前**清楚说明 ① 时长 ② 到期后失去什么 ③ 后续费用。Tier 0 的 StoreKit 购买弹窗**不会**展示这些 → 唯一合规位置是「点击开始试用之前的应用内界面」。

**开始试用前界面必须包含（交付物级别）**：

- 时长：明确「7 天完整试用」
- 到期失去：「试用结束后，连接、上传、下载、实时同步将被锁定；你的服务器配置与本地数据不会被删除，可继续查看与导出」
- 后续费用：「永久解锁需一次性购买 [价格]，无订阅」
- 主按钮「开始 7 天试用」，次按钮「直接购买」「恢复购买」

过期态文案：移除「永久免费」字样；说明锁定项与解锁方式；不得诱导性措辞。

---

## 6. Accepted Risks（已登记并接受，勿擅自处理）

| 风险 | 处置 |
|------|------|
| 本地时钟回拨可延长试用 | **接受**。所有同类 App 同此问题。不加服务器校验、不加复杂逻辑。 |
| 第 8 天锁功能带来低星评价（国区尤甚） | **接受**，用 §2 首发低价 + 清晰披露 + 非变砖锁定态缓冲。不因评分压力改回 freemium。 |
| 试用每 Apple ID 一生一次，老用户回归直接进锁定态 | **接受**，由 §4 完整锁定态 + §7 审核备注覆盖。 |

---

## 7. 分阶段执行计划

> 依赖链：Step 1（权益+文案规范）是根，必须先于代码。Step 4 依赖 Step 1/3。Step 5 依赖 Step 4。

### Step 1 — 定义权益模型与门控文案
- **目标**：四/五态定义、能力解析出口、过期态边界、试用前披露文案全部书面定稿。
- **改动**：本文件 §3/§4/§5 即定稿；产出待实现的 `Entitlements` 接口签名与文案终稿。
- **交付物**：`Entitlements` 结构与解析规则（§3.2）；试用前披露文案终稿（§5）；过期态允许/锁定清单（§4）。
- **测试**：无（设计阶段）。评审口径：是否覆盖五态、是否无「可用免费层」漏洞。
- **下一步**：Step 2 与 Step 3 可并行。

### Step 2 — 实现过期态 UI（非变砖）
- **目标**：用 §4 边界替换 `MainViews.swift:67` 的全屏 `TrialPaywallView` 阻断。
- **改动**：`Sources/Features/MainViews.swift`（`TrialPaywallView` 由全屏遮罩改为「锁定态壳」，保留导航/列表/导出/关于/购买/恢复）；`Sources/App/AppState.swift`（`presentAddServer`/`saveServer` 文案改 §5 合规版，逻辑门控保留）。
- **交付物**：锁定态界面（可查看配置、导出非敏感配置、购买/恢复入口）。
- **测试**：UI 手测——过期态下可浏览/导出/打开关于/发起购买；不可连接/传输/同步/新建任务；导出文件不含密码。
- **下一步**：Step 5。

### Step 3 — ASC 与本地 StoreKit 配置
- **目标**：可在 ASC 提交、可在本地测试。
- **改动**：ASC 建两个 IAP：`com.swiftftp.app.trial7`（Tier 0 Non-Consumable，Display Name 形如 `7-Day Trial`，**Family Sharing 关闭**）；`com.swiftftp.app.pro`（付费 Non-Consumable，`Full Unlock`，Family Sharing 可开启）。两个 IAP 必须随首个引用它们的版本一同送审。新增仓库内 `.storekit` 配置文件用于本地无 ASC 测试。
- **交付物**：ASC 两个 IAP 配置；仓库内 `SwiftFTP.storekit`（含 trial7 与 pro，trial 周期便于压缩测试）。
- **测试**：Xcode StoreKit 配置可加载、两商品可见、$0 trial 购买不计费。
- **下一步**：Step 4。

### Step 4 — 重写 StoreManager（双商品 + 日期判定 + 删除 UserDefaults）
- **目标**：授权来源切到 StoreKit 交易，删除自制计时。
- **改动**：`Sources/Core/Billing/StoreManager.swift`（新增 `trialProductID`；`refreshEntitlements()` 同时识别 trial/pro，trial 用 `purchaseDate + 7d` 算 `trialExpiresAt`，pro 看 `revocationDate`；产出 §3.2 `Entitlements`）；`Sources/App/AppState.swift`（删除 `trialStartedAt` 及其 `didSet`/`trialStartedAtKey`/`wireTrialTimer` 中对持久化的依赖；`hasFullAccess` 改为读统一 `Entitlements.fullAccess`；实现 §3.3 离线策略——内存缓存、不落盘、`entitlementUnknown` 不变砖）。
- **交付物**：双商品 StoreManager；统一能力出口；离线/失败兜底逻辑。
- **测试**（含 §8 矩阵）：单测覆盖能力解析（trial 未过期/已过期/已撤销/pro/二者皆无/StoreKit 失败兜底）；确认全仓无 `trialStartedAt` 持久读写。
- **下一步**：Step 5。

### Step 5 — 重做首启 Onboarding
- **目标**：合规披露 + 既购用户不被要求开试用。
- **改动**：`Sources/Features/Onboarding/OnboardingView.swift` 与 `Sources/Features/MainViews.swift`（启动先 `refreshEntitlements()`：已 pro/试用中 → 直接进入；过期 → 锁定态；`neverStarted` → Onboarding，最后一屏即 §5 披露 + 主按钮「开始 7 天试用」+ 次「购买/恢复」）。
- **交付物**：含合规披露的首启流程；既购用户绕过试用 CTA。
- **测试**：二台设备/已购账号启动不显示试用 CTA；从未试用账号看到完整披露后方可开始。
- **下一步**：Step 6。

### Step 6 — Release 验证清单增量
- **目标**：把本方案特有的回归项并入提交前清单。
- **改动**：`Docs/Release_Verification.md` 增补 §8 测试矩阵关键项。
- **交付物**：更新后的 Release 清单。
- **测试**：清单可被人/AI 逐条执行。
- **下一步**：进入 `Docs/AppStore_Readiness.md` 既有的 ASC 物料 / 签名 / 沙盒手测主线。

---

## 8. 测试矩阵（Step 4/5/6 据此验证）

| # | 场景 | 期望 |
|---|------|------|
| 1 | 从未试用启动 | Onboarding 显示试用 CTA + 完整披露 |
| 2 | 开始试用 | 完整功能；存在 trial 交易，`purchaseDate` 有值 |
| 3 | 试用中重启 App（无 UserDefaults） | 仍为 `trialActive`，来源是 StoreKit |
| 4 | 模拟第 8 天（.storekit 压缩周期） | `trialExpired`：可浏览/导出/购买，传输类全锁 |
| 5 | 试用期内删除并重装 | 试用按**原 purchaseDate** 续算，**不重置** |
| 6 | 第 30 天恢复购买（仅试用过） | 显示**已过期**，不发放新的 7 天 |
| 7 | 审核账号已消耗过 trial | 落锁定态，但 App 完整、文案可理解、可购买/恢复 |
| 8 | 购买 Full Unlock（从过期态） | 永久解锁 |
| 9 | Pro 退款/撤销（`revocationDate`） | 访问权按规则收回 |
| 10 | 离线/StoreKit 不可达启动（曾解析为有权） | 不变砖，沿用本会话结果，提供重试/恢复 |
| 11 | 冷启动 + 离线 + 无任何缓存 | 锁定但提供「重试/恢复购买」出路 |
| 12 | 任意导出配置 | 文件不含任何密码/passphrase |
| 13 | 既购用户二台设备启动 | 自动识别 pro，不显示试用 CTA |

---

## 9. 审核提交备注（Review Notes 模板）

> SwiftFTP 采用 App Review Guideline 3.1.1 指定的 Tier 0 Non-Consumable 试用路径。`com.swiftftp.app.trial7` 为 Price Tier 0 免费试用券（7 天），`com.swiftftp.app.pro` 为一次性永久解锁。试用前界面已明确披露试用时长、到期锁定的功能、后续一次性费用。试用到期后 App 不变砖：用户仍可查看与导出（非敏感）服务器配置、删除数据、购买与恢复。若审核账号此前已领取过该 Tier 0 试用券，将直接进入锁定态——这是 Non-Consumable「每 Apple ID 一次」的预期行为，可用提供的未消耗 Sandbox 账号体验首次试用态。
