# Quay

Quay is a native macOS file-transfer client for FTP, implicit FTPS, and SFTP. It is built with SwiftUI, Swift 6 strict concurrency, Network.framework, and Citadel.

Quay 是一款原生 macOS 文件传输客户端，支持 FTP、隐式 FTPS 与 SFTP。

## Features

- Dual-pane local and remote file browser
- Concurrent transfer queue with pause, resume, retry, and progress tracking
- FTP with EPSV preference and PASV fallback
- Implicit FTPS on port 990 with TLS-protected control and data channels
- SFTP with password or SSH private-key authentication
- Credentials stored in macOS Keychain
- SFTP trust-on-first-use host-key verification
- Sandboxed local file access through security-scoped bookmarks
- Local-folder monitoring for automatic uploads

## Protocol scope

Quay currently supports:

| Protocol | Default port | Notes |
| --- | ---: | --- |
| FTP | 21 | Plaintext control and data channels |
| FTPS | 990 | Implicit TLS only |
| SFTP | 22 | Password or private key |

Explicit FTPS (`AUTH TLS`), FTP active mode, and proxies are not implemented. Prefer SFTP or FTPS when confidentiality matters.

## Requirements

- macOS 14 or later
- Xcode with Swift 6 support

Dependencies are resolved through Swift Package Manager when the Xcode project is opened.

## Build and test

Open `SwiftFTP.xcodeproj` in Xcode, then use **Product → Build** or **Product → Test**.

For an unsigned command-line build:

```bash
xcodebuild build \
  -project SwiftFTP.xcodeproj \
  -scheme SwiftFTP \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /private/tmp/QuayDerivedData \
  CODE_SIGNING_ALLOWED=NO
```

Run the test suite with:

```bash
xcodebuild test \
  -project SwiftFTP.xcodeproj \
  -scheme SwiftFTP \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /private/tmp/QuayDerivedData \
  CODE_SIGNING_ALLOWED=NO
```

The Xcode project, target, bundle identifier, and persistence paths retain their historical `SwiftFTP` identifiers to preserve compatibility for existing installations. The product name shown to users is Quay.

## Contributing

Bug reports and focused pull requests are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md) before submitting a change. Please report security issues according to [SECURITY.md](SECURITY.md).

## License

Quay is available under the [MIT License](LICENSE).
