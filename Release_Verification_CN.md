# Quay 发布验证

当前开源版的维护清单见 [Docs/Release_Verification.md](Docs/Release_Verification.md)，
包括构建与测试、签名包、FTP/隐式 FTPS/SFTP、Keychain 和沙盒文件访问检查。

执行时记录提交号、Xcode 版本、通过/失败/跳过数量及跳过原因。无签名测试通过
不能代替真实服务器、带签名 Keychain 和跨重启沙盒授权验证。

当前主线没有 StoreKit 试用或购买流程；旧付费版的发布清单仅保留在历史存档中。
