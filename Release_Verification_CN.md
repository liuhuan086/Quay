# SwiftFTP 发布验证

在提交 Mac App Store 构建之前运行此检查清单。
## 构建与签名
```bash
xcodebuild test \
-project SwiftFTP.xcodeproj \
-scheme SwiftFTP \
-destination 'platform=macOS' \
-derivedDataPath /private/tmp/SwiftFTPDerivedData

xcodebuild archive \
-project SwiftFTP.xcodeproj \
-scheme SwiftFTP \
-destination 'generic/platform=macOS' \
-archivePath /private/tmp/SwiftFTP.xcarchive \
-derivedDataPath /private/tmp/SwiftFTPArchiveDD

codesign -d --entitlements - /private/tmp/SwiftFTP.xcarchive/Products/Applications/SwiftFTP.app

```
归档的权限必须包括：
- `com.apple.security.app-sandbox`
- `com.apple.security.network.client`
- `com.apple.security.files.user-selected.read-write`
- `com.apple.security.files.bookmarks.app-scope`
- `keychain-access-groups`

对于 App Store 提交，请使用 Xcode Organizer 导出/上传，选择 Apple Distribution 和 Mac App Store 配置文件。

## StoreKit 测试沙盒
修改 IAP 行为前先阅读 `Docs/Monetization_Compliance_Plan.md`。

使用产品 ID：
- `com.swiftftp.app.trial7`：Tier 0 非消耗型，显示名 `7-Day Trial`，关闭 Family Sharing。
- `com.swiftftp.app.pro`：付费非消耗型，显示名 `SwiftFTP Pro`。

1. 在 App Store Connect 中创建两个 IAP，并将它们添加到与第一个引用它们的二进制文件相同的 app 版本提交中。
2. 为两个 IAP 添加 App Review 截图与审核备注。
3. 创建一个从未领取过 `com.swiftftp.app.trial7` 的干净沙盒测试者。
4. 在 scheme 中保留本地 `SwiftFTP.storekit` 配置，用于 ASC 前测试。
5. 安装归档/导出的构建，如需的话退出常规 App Store 账户，然后在 macOS 提示购买时使用沙盒测试者。
6. 验证以下路径：
   - 两个产品都能加载；App 内所有价格均来自 StoreKit `displayPrice`。
   - 开始试用前必须显示披露页，并创建 trial 交易。
   - 试用到期按原始 StoreKit 购买日期计算；重装/恢复不会重置试用。
   - 试用过期进入非变砖锁定壳：配置可查看/导出，但连接/上传/下载/同步被锁定。
   - 购买 `SwiftFTP Pro` 后立即解锁核心 FTP/FTPS/SFTP 功能。
   - 删除/重新安装应用后，恢复购买可以解锁 Pro。
   - 用户取消购买后，应用返回但不解锁 Pro。
   - Ask to Buy pending 状态显示等待批准，不解锁新能力，只有 `Transaction.updates` / `currentEntitlements` 返回 verified transaction 后才解锁。
   - 中断购买通过 `Transaction.unfinished` 恢复，并在交付权益后 finish。
   - 失败消息可理解，并提供重试/恢复路径。

## 协议烟雾测试
对于每个协议，创建一个临时测试服务器账户，使用一个临时目录并验证：
1. 连接、断开、重新连接。
2. 列出包含文件、文件夹、隐藏文件和非 ASCII 名称的目录。
3. 上传一个小文件、一个嵌套文件夹和一个大于 100 MB 的文件。
4. 下载相同的文件并比较校验和。
5. 暂停/恢复一个上传和一个下载。
6. 重命名、删除和创建文件夹。
7. 确认应用重启后密码仍然存在，并且不在导出的 JSON 中。

FTPS 特定：
1. 有效公钥证书：在关闭“允许不受信任证书”时连接成功。
2. 自签名证书：关闭“允许不受信任证书”时连接失败，开启时连接成功。
3. 过期证书：关闭“允许不受信任证书”时连接失败，开启时连接成功。
4. 主机名不匹配：即使开启“允许不受信任证书”也会连接失败。

SFTP 特定：
1. 密码认证正常工作。
2. 选择密钥后 SSH 密钥认证正常工作。
3. 重启应用后，使用相同的 SSH 密钥重新连接而无需重新选择。
4. 更改服务器主机密钥并确认 SwiftFTP 阻止连接。

沙盒文件访问：
1. 在浏览器中选择一个本地文件夹并验证重启后仍保留。
2. 将本地文件拖入远程面板并验证上传。
3. 使用选择器添加实时同步规则，重启后保存文件并验证上传。
4. 避免手动输入或拖拽路径添加同步规则；必须使用选择器以获得持久的沙盒访问权限。
