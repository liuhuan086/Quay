# Quay — 变现与上架合规整改方案（最终版）

**文档性质**：可执行整改方案 / AI 与人共用的工作依据
**适用范围**：Mac App Store（MAS）首发版本的变现模型、IAP 合规、权益与门控
**结论定调**：MAS 免费下载 + Tier 0 `7-Day Trial` Non-Consumable + 付费 `Quay Pro` Non-Consumable（解锁首发本地 FTP/FTPS/SFTP 核心功能）；过期态为「数据可访问、核心功能锁定」，**不是全屏变砖**。
**关联文档**：`Docs/AppStore_Readiness.md`（总体上架阻断项）、`Docs/Release_Verification.md`（提交前验证清单，本方案新增项需并入）。

---

## 0. 给 AI 的执行约定（先读，硬约束）

后续任何 AI 会话在本仓库做变现/IAP/门控相关改动时，必须遵守：

- **禁止**重新引入 `UserDefaults.trialStartedAt` 作为试用授权依据。试用有效期的唯一真相是 StoreKit 交易的 `purchaseDate + 7 天`。`trialStartedAt` 持久化逻辑应被删除（见 Step 4）。
- 允许持久化**非授权用途**的 UI 状态（如 `hasSeenOnboarding`、到期前提醒已展示），但必须命名清楚、只影响 UI，不得参与 `canUseCoreFTP` / 试用期限判断。
- **禁止**把过期态做成「降级但仍可用」的免费层。过期态边界必须精确：数据可读、可导出非敏感配置、可购买/恢复；连接/上传/下载/同步/新建任务一律锁定。漂移成可用免费层 = 同时拿到 trial 与 freemium 两个模型的缺点。
- **禁止**「擅自修复」已登记的既定风险（见 §6 Accepted Risks），尤其是本地时钟回拨延长试用——这是已知并接受的取舍，不要为它加服务器校验或复杂逻辑。
- **禁止**用重复弹窗/模态骚扰催付。允许的仅限：①一个常驻、非模态的「试用剩余 X 天」可视提示；②到期前**最多一次**温和提醒；③到期锁定那一刻。除此之外不得有任何重复模态。详见 §2.1。这同时是 App Review（4.x dark pattern / 3.1.1）与评分风险。
- 能力判断一律走**统一的权益解析出口**（见 §3），不得在各 View 里散落 `isPro` / 日期比较。
- 不要把付费商品对外命名为笼统的 `Full Unlock`，否则未来 `cloud` 二档会被用户合理理解为「已经买过也应包含」。首发付费商品建议显示为 `Quay Pro` / `Quay Pro（本地功能）`，文案说明它解锁当前 FTP/FTPS/SFTP 本地客户端能力。
- 改动 IAP/门控前先读本文件与 `Docs/AppStore_Readiness.md`。

---

## 1. 结论与边界（合规 ≠ 转化）

- **Trial IAP 只解决合规**：它把 App Review 3.1.1 风险从「高」降到「低」。它**不**自动解决转化率、评分、获客、长期收入。
- **选择方案 A 的真实理由**（精确版）：不是 freemium 商业上必劣，而是 Quay 当前阶段（单人、时间有限）若走 freemium，需要维护一条脆弱的「读免费 / 写付费」功能边界（大量边界测试、文案解释、UI 分支、用户抱怨）。Trial IAP 的优势是**少维护这条边界**，且不把核心价值免费送出。
- **必须接受方案 A 的营销代价**：第 8 天锁功能即便合规，也天然制造一批低星评价，国区尤甚。非变砖过期态只能减伤，不能消除。缓冲手段写入 §5。

---

## 2. 商业 / 营销策略（定调，非代码）

| 项 | 决定 |
|----|------|
| 分发 | MAS 免费下载 |
| 试用 | 7 天完整试用，经 Apple Tier 0 Non-Consumable IAP 发放 |
| 解锁 | 一次性买断 `Quay Pro`，无订阅；解锁首发本地 FTP/FTPS/SFTP 客户端核心功能 |
| 首发定价 | 限时低价（¥18–25 或 $2.99），3 个月后回调 $4.99 / ¥38。目标是早期评论速度与 ASC 排名飞轮，不是首月利润 |
| 文案纪律 | 商店页与截图明确「7 天完整试用 / 一次买断 / 无订阅」；避免误导性「免费」暗示 |
| 催付纪律 | 仅在功能撞墙处出现一次升级入口，无弹窗轰炸 |
| 未来杠杆 | 云存储（S3/OSS/COS）、云同步、团队能力作为**第二付费档**，不并入首发 `Quay Pro`（见 §3 二档预留） |

### 2.1 试用期内转化设计（非骚扰，结构性收益点）

试用模型的结构性缺陷：用户在 7 天内拥有完整功能，**永远不会撞墙**，直到第 8 天一次性全锁。如果到期前零提示，等于把唯一的转化机会全部押在「锁定那一刻的挫败感」上——这既转化更差，也更容易招差评。必须在试用期内做**克制的**转化铺垫：

- **常驻可视提示**：一个非模态的「试用剩余 X 天」入口（如状态栏/侧栏角标或设置内标签），任何时候不打断操作。文案中性，不诱导。
- **到期前一次温和提醒**：剩余约 24–48 小时时，出现**一次**非阻断的应用内提示，说明何时锁定哪些功能、解锁价格与入口。仅一次，关闭后不再弹；可以用 `UserDefaults` 持久化「某个 trial transaction 已提醒」这类 UI flag，但它不得参与授权判断。
- **撞墙那一刻**：进入 §4 非变砖锁定态，提供购买/恢复。
- 以上三处的「剩余天数 / 是否试用中」必须读统一 `Entitlements`（§3.2），不得各处自行 `Date()` 比较。
- 明确**禁止**：每次启动弹窗、每次传输后弹窗、倒计时恐吓文案、把剩余天数做成模态拦截、用系统通知做纯催付。违反即 §0 硬约束与 4.x dark pattern 风险。

---

## 3. 权益模型规范（代码架构）

### 3.1 状态机（权益五态 + 购买待批准态）

| 状态 | 触发条件 | App 行为 |
|------|----------|----------|
| `neverStarted` | 无 trial 交易、无 pro | 进入 Onboarding，主操作＝开始 7 天试用，备选＝购买/恢复 |
| `trialActive` | trial 交易存在 且 `purchaseDate + 7d > now` 且未撤销 | 完整功能 |
| `trialExpired` | trial 交易存在 但 `purchaseDate + 7d <= now` | **非变砖锁定态**（见 §4） |
| `pro` | pro 交易存在 且 `revocationDate == nil` | 完整功能（永久） |
| `entitlementUnknown` | 权益解析无法得到 verified StoreKit 结果（例如 StoreKit/验证异常、超时、只有 unverified transaction），且无法判断用户是否有权 | 不得变砖：允许进入、显示「无法校验购买」提示、提供「重试 / 恢复购买」。若本会话已有 verified 解析结果，沿用该内存结果；冷启动无结果时进入锁定壳但不得空白付费墙 |
| `purchasePending` | trial 或 pro 购买返回 `.pending`，尚无 verified transaction | **购买流程 UI 状态，不是权益**。不得解锁新能力；显示「等待批准」。若用户已有 trial/pro 权益，原权益继续生效；若无权益，落 §4 非变砖锁定壳并等待 `Transaction.updates` / 下次 `currentEntitlements` |

**状态解析必须分两层（防分叉 bug）**：

1. 先判断是否拿到了一个可信的 verified entitlement snapshot。成功拿到（哪怕结果为空）才进入业务状态解析；拿不到则是 `entitlementUnknown`，不得伪装成 `neverStarted`。
2. 在 verified snapshot 内部按确定优先级解析：`pro` ＞ `trialActive` ＞ `trialExpired` ＞ `neverStarted`。即「持有 pro 且同时有已过期 trial 交易」必须解析为 `pro`；「有 trial 交易但已过期且无 pro」才是 `trialExpired`；「verified snapshot 为空」才是 `neverStarted`。

能力门控只看 `canUseCoreFTP`；状态枚举仅用于 UI/Onboarding 路由，二者不得各自判断。`purchasePending` 应作为 UI overlay / pending flag 叠在权益状态上，不得覆盖已有有效权益。

### 3.2 能力解析（统一出口，预留二档）

- 不要用 flat `enum`（`pro` 与未来 `cloud` 会**重畳**，flat enum 二档时必再改结构）。用「原始权益事实 + 解析后的 capability set」：

```swift
enum AppCapability: Hashable, Sendable {
    case coreFTP          // 连接、上传、下载、同步、队列等首发核心能力
    case cloudIntegrations // 未来 S3/OSS/COS/云同步二档
}

struct Entitlements: Sendable {
    var hasTrialTransaction: Bool // 区分 neverStarted 与 trialExpired
    var trialExpiresAt: Date?     // nil = 没有 trial 交易；过期 trial 仍保留过期日期
    var hasPro: Bool              // 首发 Quay Pro
    var hasCloud: Bool            // 预留二档，首发恒 false

    func capabilities(now: Date) -> Set<AppCapability> {
        var result = Set<AppCapability>()
        if hasPro || (trialExpiresAt.map { $0 > now } ?? false) {
            result.insert(.coreFTP)
        }
        if hasCloud {
            result.insert(.cloudIntegrations)
        }
        return result
    }

    func canUseCoreFTP(now: Date) -> Bool {
        capabilities(now: now).contains(.coreFTP)
    }
}
```

- 解析来源：遍历 `Transaction.currentEntitlements`。
  - `productID == proProductID` 且 `revocationDate == nil` → `hasPro = true`
  - `productID == trialProductID` 且 `revocationDate == nil` → `hasTrialTransaction = true` 且 `trialExpiresAt = transaction.purchaseDate + 7d`（**注意**：Non-Consumable 的交易在 `currentEntitlements` 中永久存在，到期后**仍在**，所以绝不能「看到 trial entitlement 就放行」，必须算日期）
  - 未来 `cloudProductID` → 只插入 `.cloudIntegrations`，不得反向暗示它包含首发 `coreFTP` 之外的一切。
- 门控全仓只认统一的 `Entitlements.capabilities(now:)` / `canUseCoreFTP(now:)`，替换现有散落的 `isPro` / `hasFullAccess` 直读。UI 可以读取状态标签（试用中/已购/过期），但功能门控不得各自比较日期。
- `now` 必须可注入（测试 clock），不要在深层 View 里直接 `Date()`。

### 3.3 离线 / StoreKit 失败策略（AI 漏点，必须实现）

- 删除 `trialStartedAt` 持久化后，授权改为：每次启动优先 `refreshEntitlements()`；解析结果存**内存**（本会话），不落盘自制试用日期。
- 不要把 `Product.products(for:)` 失败等同于无权益。商品加载失败只影响购买按钮/价格显示；权益解析仍应先走 `Transaction.currentEntitlements` / `Transaction.updates`。
- 必须区分「verified entitlement snapshot 为空」与「无法获得 verified snapshot」：前者是 `neverStarted`，后者才是 `entitlementUnknown`。
- StoreKit/验证异常导致无法解析 verified entitlement 时，进入 `entitlementUnknown`，**不得锁死**。沿用本会话已解析结果；冷启动且无任何结果时默认锁定但**必须**给「重试 / 恢复购买」动线，不得让可能已付费用户无出路。
- 如果 StoreKit 返回本机缓存的 verified non-consumable transaction，即使网络不可达，也按官方交易结果授权；不要额外要求联网。
- **未完成交易必须在启动时兜住**：除 `currentEntitlements` 外，启动时还要遍历 `Transaction.unfinished`（上次会话中断的 trial/pro 购买）；只对 verified 且 productID 已知的 transaction 交付权益、刷新 UI 后 `finish()`。unverified transaction 不得授权；未知 productID 不得静默授权或静默 finish，必须显式记录并按迁移策略处理。交易监听器要在尽早时机（`StoreManager.init`）挂上，避免错过启动瞬间到达的交易。
- **pending（Ask to Buy / 家长批准）不得当作拒绝**：trial 或 pro 购买返回 `.pending` 时，没有 transaction、没有 `purchaseDate`、没有新权益；可记录非授权 `pendingPurchaseKind` UI flag（可持久化，但只影响文案），按 `purchasePending` 显示「等待批准」文案。若用户已有有效 trial/pro，继续按既有权益使用；若无权益，按 §4 非变砖锁定壳处理。由 `Transaction.updates` 或下次 `currentEntitlements` 出现 verified transaction 后自动转 `trialActive` / `pro`，并清除 pending flag；期间不得反复弹窗。若用户稍后重试购买，必须允许手动重试/恢复，不能把 pending flag 当作永久阻断。

---

## 4. 过期态边界（精确，不可漂移）

`trialExpired` / `entitlementUnknown(无授权)` 下：

**允许**：查看服务器列表与配置；导出**非敏感**配置（host/port/协议/路径等由用户主动导出的连接元数据，**绝不导出密码、passphrase、Keychain 内容、security-scoped bookmark、SSH 私钥内容**）；删除本地数据；打开 关于/隐私/条款；购买；恢复购买；设置页。

**锁定**：建立连接；上传/下载；实时同步；新建任何传输任务；新增/编辑服务器（保持现有 `presentAddServer` / `saveServer` 门控，但文案改为 §5 合规版）。

**Onboarding 未操作落点**：首启 Onboarding 若被关闭而用户既未开始试用也未购买，落点必须是本节同一个非变砖锁定壳（含「开始试用 / 购买 / 恢复」入口），**绝不可**是空白页、纯付费墙或可空手进入的空 App。即 `neverStarted` 在「已看过 Onboarding 但未行动」时与 `trialExpired` 共用同一锁定壳 UI（仅文案不同：前者强调「开始 7 天试用」）。

设计意图：像一个**完整产品的锁定态**，不是空白付费墙——满足 App Review 2.1（提交版本完整、IAP 可见可测）。

---

## 5. 文案 / 披露规范（3.1.1 第一拒因）

3.1.1 要求：**试用开始前**清楚说明 ① 时长 ② 到期后失去什么 ③ 后续费用。Tier 0 的 StoreKit 购买弹窗**不会**展示这些 → 唯一合规位置是「点击开始试用之前的应用内界面」。

**开始试用前界面必须包含（交付物级别）**：

- 时长：明确「7 天完整试用」
- 到期失去：「试用结束后，连接、上传、下载、实时同步将被锁定；你的服务器配置与本地数据不会被删除，可继续查看与导出」
- 后续费用：「永久解锁需一次性购买 [价格]，无订阅」
- 主按钮「开始 7 天试用」，次按钮「直接购买」「恢复购买」
- IAP Display Name：trial 商品在所有本地化中必须保留 `7-Day Trial` 语义（例如 `7-Day Trial` 或 `7-Day Trial（7 天试用）`，注意 ASC display name 长度限制）；Pro 商品避免 `Full Unlock`，用 `Quay Pro` / `Quay Pro（本地功能）`。
- IAP Description 与 App Store 截图文案不得暗示永久免费，也不得暗示未来 cloud 二档包含在首发 Pro 中。
- **价格只有一个真实源**：所有「后续费用」展示一律取 StoreKit `proProduct.displayPrice`（已本地化、含币种），**禁止**在代码、文案、商店截图里写死数字。截图若必须出现价格，用「限时首发价」类不绑定具体金额的措辞，避免调价后与 ASC 不一致触发审核/退款/信任问题。
- **开始试用前必须已加载 trial 与 pro 两个 Product**：trial 用于发起 Tier 0 购买，pro 用于展示 `displayPrice`。若 `proProduct.displayPrice` 不可用，不能让用户开始试用；应显示「正在加载价格 / 重试」并禁用开始试用按钮。否则 3.1.1 的「试用前告知后续费用」会失效。

过期态文案：移除「永久免费」字样；说明锁定项与解锁方式；不得诱导性措辞。

---

## 6. Accepted Risks（已登记并接受，勿擅自处理）

| 风险 | 处置 |
|------|------|
| 本地时钟回拨可延长试用 | **接受**。所有同类 App 同此问题。不加服务器校验、不加复杂逻辑。 |
| 第 8 天锁功能带来低星评价（国区尤甚） | **接受**，用 §2 首发低价 + 清晰披露 + 非变砖锁定态缓冲。不因评分压力改回 freemium。 |
| 试用每 Apple ID 一生一次，老用户回归直接进锁定态 | **接受**，由 §4 完整锁定态 + §7 审核备注覆盖。 |
| Apple 撤销（revoke）Tier 0 试用券后用户可能再次领取一次试用 | **接受**。$0 商品被撤销极罕见，重新发放一次免费试用风险极低，不为此加额外防滥用逻辑。 |

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
- **改动**：ASC 建两个 IAP：`com.swiftftp.app.trial7`（Tier 0 Non-Consumable，Display Name 形如 `7-Day Trial`，**Family Sharing 保持关闭且不要误点开启**）；`com.swiftftp.app.pro`（付费 Non-Consumable，Display Name `Quay Pro`，Family Sharing 可开启但**一旦开启不可关闭**，需在提交前明确接受）。两个 IAP 必须随首个引用它们的版本一同送审。新增仓库内 `.storekit` 配置文件用于本地无 ASC 测试，并在 Xcode scheme 中选择该 StoreKit Configuration。
- **交付物**：ASC 两个 IAP 配置；每个 IAP 的 App Review Screenshot 与 Review Notes；仓库内 `SwiftFTP.storekit`（含 trial7 与 pro，trial 周期便于压缩测试）。
- **测试**：Xcode StoreKit 配置可加载、两商品可见、本地 trial 购买不计费、scheme 确认使用该 `.storekit` 文件。
- **下一步**：Step 4。

### Step 4 — 重写 StoreManager（双商品 + 日期判定 + 删除 UserDefaults）
- **目标**：授权来源切到 StoreKit 交易，删除自制计时。
- **改动**：`Sources/Core/Billing/StoreManager.swift`（新增 `trialProductID`；`refreshEntitlements()` 同时识别 trial/pro，trial 用 `purchaseDate + 7d` 算 `trialExpiresAt`，pro 看 `revocationDate`；产出 §3.2 `Entitlements`；`Transaction.updates` 同时处理 trial/pro/未来 cloud；启动遍历 `Transaction.unfinished` 兜住中断购买；处理 `.pending` 为非授权 `purchasePending` UI 状态；购买成功交付权益后 `finish()`）；`Sources/App/AppState.swift`（删除 `trialStartedAt` 及其 `didSet`/`trialStartedAtKey`/`wireTrialTimer` 中对持久化的依赖；`hasFullAccess` 改为读统一 capability；实现 §3.3 离线策略——内存缓存、不落盘自制日期、`entitlementUnknown` 不变砖）。
- **交付物**：双商品 StoreManager；统一 capability 出口；离线/失败兜底逻辑；可测试 clock。
- **测试**（含 §8 矩阵）：单测覆盖能力解析（trial 未过期/已过期/已撤销/pro/二者皆无/StoreKit 失败兜底）；**状态优先级**（pro+已过期 trial 必解析为 pro，矩阵 #19）；verified 空 snapshot 与解析失败的分流（#21）；覆盖 `Transaction.updates` 后状态刷新；确认全仓无 `trialStartedAt` 持久读写。
- **下一步**：Step 5。

### Step 5 — 重做首启 Onboarding
- **目标**：合规披露 + 既购用户不被要求开试用。
- **改动**：`Sources/Features/Onboarding/OnboardingView.swift` 与 `Sources/Features/MainViews.swift`（启动先 `refreshEntitlements()`，按 §3.1 优先级解析：已 pro/试用中 → 直接进入；过期 → 锁定态；`neverStarted` → Onboarding，最后一屏即 §5 披露 + 主按钮「开始 7 天试用」+ 次「购买/恢复」；**Onboarding 被关闭而未行动 → 进 §4 同一非变砖锁定壳，绝不空白页/纯付费墙**）。同时实现 §2.1 试用期内非骚扰转化（常驻剩余天数 + 到期前一次提醒，均读统一 `Entitlements`）。
- **交付物**：含合规披露的首启流程；既购用户绕过试用 CTA；未行动落点为非变砖锁定壳；§2.1 转化提示。
- **测试**：二台设备/已购账号启动不显示试用 CTA；从未试用账号看到完整披露后方可开始；关闭 Onboarding 未行动落非变砖锁定壳（矩阵 #18）；剩余 24–48h 仅一次提醒（#17）。
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
| 8 | 从过期态购买 `Quay Pro` | 永久解锁首发本地核心功能 |
| 9 | Pro 退款/撤销（`revocationDate`） | 访问权按规则收回 |
| 10 | 离线/StoreKit 不可达启动（曾解析为有权） | 不变砖，沿用本会话结果，提供重试/恢复 |
| 11 | 冷启动 + 离线 + 无任何缓存 | 锁定但提供「重试/恢复购买」出路 |
| 12 | 任意导出配置 | 文件不含任何密码/passphrase |
| 13 | 既购用户二台设备启动 | 自动识别 pro，不显示试用 CTA |
| 14 | `Product.products(for:)` 失败但 `currentEntitlements` 有 pro | 仍解锁核心功能，只禁用/降级购买按钮显示 |
| 15 | `Transaction.updates` 收到 pro/trial 交易 | 状态即时刷新并 finish transaction |
| 16 | ASC/IAP 元数据检查 | trial 名称含 `7-Day Trial`；Pro 不叫 `Full Unlock`；两个 IAP 均有审核截图与备注 |
| 17 | 试用剩余约 24–48h | 出现且仅出现一次温和提醒；关闭后不再弹；启动不弹窗 |
| 18 | Onboarding 关闭但未开始试用/未购买 | 落非变砖锁定壳（含开始试用/购买/恢复），无空白页、无纯付费墙 |
| 19 | 同时持有 pro 与已过期 trial 交易 | 解析为 `pro`，完整功能，不显示过期态 |
| 20 | 价格展示 | 全部来自 StoreKit `displayPrice`；代码/截图无写死金额 |
| 21 | verified entitlement snapshot 为空 vs 获取失败 | 空 snapshot → `neverStarted`；获取/验证失败 → `entitlementUnknown` |
| 22 | Pro 价格未加载时尝试开始试用 | 开始试用按钮禁用，提示加载/重试；不得在价格未知时发起 trial 购买 |
| 23 | 到期前提醒已展示 flag | 可持久化 UI flag；删除/篡改 flag 不影响 `canUseCoreFTP` |
| 24 | 上次会话中断的 trial/pro 购买 | 启动时经 `Transaction.unfinished` 兜住并 `finish()`，状态正确 |
| 25 | trial 购买返回 `.pending`（Ask to Buy） | 无新权益；非变砖锁定壳 +「等待批准」；批准后经 `Transaction.updates` / `currentEntitlements` 自动转 `trialActive` 并清除 pending flag |
| 26 | Pro 购买返回 `.pending`（试用中或过期态） | 试用中继续使用 trial 权益；过期/无权益则锁定壳 +「等待批准」；批准后自动转 `pro` |
| 27 | `Transaction.unfinished` 含 unverified 或未知 productID | 不授权；不静默 finish；记录并走显式迁移/错误处理 |

---

## 9. 审核提交备注（Review Notes 模板）

> Quay 采用 App Review Guideline 3.1.1 指定的 Tier 0 Non-Consumable 试用路径。`com.swiftftp.app.trial7` 为 Price Tier 0 免费试用券（7 天，Display Name: `7-Day Trial`），`com.swiftftp.app.pro` 为一次性 `Quay Pro` 解锁，覆盖首发本地 FTP/FTPS/SFTP 客户端核心功能。试用前界面已明确披露试用时长、到期锁定的功能、后续一次性费用。试用到期后 App 不变砖：用户仍可查看与导出（非敏感）服务器配置、删除数据、购买与恢复。若审核账号此前已领取过该 Tier 0 试用券，将直接进入锁定态——这是 Non-Consumable「每 Apple ID 一次」的预期行为；锁定态本身可完整审核购买/恢复路径。如需体验首次试用态，可使用未消耗过 trial 的干净 Sandbox 账号。
