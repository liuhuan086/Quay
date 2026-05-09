# SwiftFTP Build

本项目是 macOS App，Xcode scheme 为 `SwiftFTP`。建议把 DerivedData 和 DMG staging 放到 `/tmp`，避免 `Documents` 目录给 `.app`/`.bundle` 自动附加 FinderInfo/FileProvider 扩展属性，导致 `codesign` 报 `resource fork, Finder information, or similar detritus not allowed`。

## 产品化与上架文档

- `Docs/AppStore_Readiness.md`：Mac App Store 上架可行性、付费定价、阻塞问题与整改顺序。
- `Docs/prompts.md`：后续 AI/工程协作的专业提示词、验收标准和审核检查清单。

## 本次产物

- App: `/tmp/swiftftp-build/DerivedData/Build/Products/Release/SwiftFTP.app`
- DMG: `build/SwiftFTP_v2.0.0.dmg`
- ZIP: `build/SwiftFTP_v2.0.0.zip`

本次构建结果：

```text
** BUILD SUCCEEDED **
SwiftFTP.app: Mach-O universal binary with 2 architectures: x86_64, arm64
codesign: valid on disk, satisfies its Designated Requirement
hdiutil verify: checksum of "build/SwiftFTP_v2.0.0.dmg" is VALID
```

## 编译命令

```bash
mkdir -p /tmp/swiftftp-build

xcodebuild \
  -project SwiftFTP.xcodeproj \
  -scheme SwiftFTP \
  -configuration Release \
  -derivedDataPath /tmp/swiftftp-build/DerivedData \
  -clonedSourcePackagesDirPath /tmp/swiftftp-build/SourcePackages \
  CODE_SIGN_IDENTITY=- \
  CODE_SIGNING_REQUIRED=NO \
  ONLY_ACTIVE_ARCH=NO \
  build
```

## 校验 App

```bash
file /tmp/swiftftp-build/DerivedData/Build/Products/Release/SwiftFTP.app/Contents/MacOS/SwiftFTP

codesign --verify --deep --strict --verbose=2 \
  /tmp/swiftftp-build/DerivedData/Build/Products/Release/SwiftFTP.app
```

## 打包 DMG

```bash
mkdir -p /tmp/swiftftp-dmg-staging

ditto \
  /tmp/swiftftp-build/DerivedData/Build/Products/Release/SwiftFTP.app \
  /tmp/swiftftp-dmg-staging/SwiftFTP.app

ln -sfn /Applications /tmp/swiftftp-dmg-staging/Applications

hdiutil create \
  -volname SwiftFTP \
  -srcfolder /tmp/swiftftp-dmg-staging \
  -ov \
  -format UDZO \
  build/SwiftFTP_v2.0.0.dmg

hdiutil verify build/SwiftFTP_v2.0.0.dmg
```

## 打包 ZIP

```bash
ditto -c -k --keepParent \
  /tmp/swiftftp-build/DerivedData/Build/Products/Release/SwiftFTP.app \
  build/SwiftFTP_v2.0.0.zip
```

## 当前验证备注

- Debug build 已可用 `xcodebuild build ... CODE_SIGNING_ALLOWED=NO` 通过。
- 单测已可用 `xcodebuild test ... CODE_SIGNING_ALLOWED=NO` 通过，当前 47 tests。
- 若命令行环境无法写入默认 Xcode 缓存，可加：
  `-derivedDataPath /private/tmp/SwiftFTPDerivedData -clonedSourcePackagesDirPath /private/tmp/SwiftFTPSourcePackages`
- Release / App Store 包仍需要配置 `DEVELOPMENT_TEAM`、Distribution 证书和 MAS provisioning profile。
