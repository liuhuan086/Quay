# Quay (SwiftFTP)

Quay 是使用 SwiftUI、Swift 6 严格并发和 Network.framework/Citadel 构建的 macOS 文件传输客户端。Xcode 工程和 scheme 名称仍为 `SwiftFTP`。

## 协议支持

- FTP（默认端口 21，EPSV 优先、PASV 回退）
- **隐式 FTPS**（默认端口 990，控制与数据通道均使用 TLS）
- SFTP（默认端口 22，密码或 SSH 私钥）

当前不支持显式 FTPS（`AUTH TLS`）和 FTP Active 模式。不要在产品文案中宣称支持这两项。

## 构建与测试

日常开发优先使用 Xcode：

- 构建：`⌘B`
- 测试：`⌘U`
- 静态分析：Product → Analyze

无签名命令行验证：

```bash
xcodebuild build \
  -project SwiftFTP.xcodeproj \
  -scheme SwiftFTP \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /private/tmp/SwiftFTPDerivedData \
  CODE_SIGNING_ALLOWED=NO

xcodebuild test \
  -project SwiftFTP.xcodeproj \
  -scheme SwiftFTP \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /private/tmp/SwiftFTPDerivedData \
  CODE_SIGNING_ALLOWED=NO
```

2026-07-18 基线：103 tests，97 passed，6 skipped，0 failed。跳过项是必须由带 Keychain entitlement 的签名测试宿主执行的 Keychain 集成测试；仓储与其他业务测试在无签名环境仍完整执行。

Release 和 Mac App Store 包必须使用正确的 Apple Distribution/MAS provisioning profile。无签名构建不能验证 Keychain、最终 entitlements 或可提交性。

## 发布文档

- `Docs/AppStore_Readiness.md`：当前代码能力、已关闭风险与剩余外部门禁
- `Docs/Release_Verification.md`：签名、StoreKit、协议和沙盒发布检查
- `Docs/Monetization_Compliance_Plan.md`：权益和 IAP 约束
- `Docs/AppStore_Submission_Materials.md`：App Store Connect 交接材料
- `Docs/prompts.md`：历史整改任务与后续增强提示
