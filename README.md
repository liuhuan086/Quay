# SwiftFTP Build

本项目是 macOS App，Xcode scheme 为 `SwiftFTP`。建议把 DerivedData 和 DMG staging 放到 `/tmp`，避免 `Documents` 目录给 `.app`/`.bundle` 自动附加 FinderInfo/FileProvider 扩展属性，导致 `codesign` 报 `resource fork, Finder information, or similar detritus not allowed`。

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

## 本次构建中的非阻断警告

- `AppState.swift`: `var task` 可以改为 `let task`
- `FTPClient.swift`: `var captured` 可以改为 `let captured`
- `FSEventWatcher.swift`: `FSEventStreamScheduleWithRunLoop` 在 macOS 13.0 后 deprecated
- `SFTPClient.swift`: Citadel 相关类型触发 Swift 6 `Sendable` 警告
