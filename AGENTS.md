# Development guidance

## Project scope

Quay (historically SwiftFTP) is an open-source macOS 14+ FTP, implicit-FTPS,
and SFTP client using SwiftUI and Swift 6 strict concurrency. The current
mainline has no StoreKit purchases, trials, or feature entitlement gates.
Keep the existing SwiftFTP project, scheme, bundle identifiers, and persistence
keys compatible with existing installations.

FTPS means implicit TLS on port 990. Explicit `AUTH TLS`, FTP active mode, and
proxies are not implemented.

## Build and validation

This is an Xcode project, not a root Swift package. Use `SwiftFTP.xcodeproj`
and scheme `SwiftFTP`; Xcode resolves Citadel through SwiftPM. `project.yml`
is the XcodeGen specification: keep it consistent with the checked-in project
when changing build settings or dependencies.

- Build: Xcode Product → Build, or the command in README.md.
- Test: Xcode Product → Test, or the command in README.md.
- Analyze: Xcode Product → Analyze; use the scheme diagnostics for Thread Sanitizer.
- Read Docs/Release_Verification.md before preparing a release.
- Report skipped tests and environment limitations explicitly. An unsigned test
  pass does not verify signed Keychain access or distribution readiness.

## Architecture

- `Sources/App/AppState.swift`: `@MainActor` UI state and service wiring.
- `Sources/Core/Domain/Entities/Entities.swift`: Sendable domain values.
- `Sources/Core/Domain/Repositories/AnyFTPClient.swift`: Sendable client protocol
  and shared download staging helpers.
- `Sources/Core/Data/ServerRepository.swift`: server metadata persistence and
  Keychain-backed credential handling; exports must omit passwords and bookmarks.
- `Sources/Core/Infrastructure/Network/FTPClient.swift`: Network.framework
  FTP/FTPS implementation with serial-queue state isolation.
- `Sources/Core/Infrastructure/Network/SFTPClient.swift`: Citadel SFTP client
  and persistent TOFU host-key validation.
- `ConnectionPool` and `ConnectionPoolRegistry`: actors owning per-server pools.
  AppState configures 9 slots for up to 8 transfers plus interactive access.
- `TransferEngine`: actor owning queue, concurrency, pause/resume, and retries.
- `Sources/Core/Infrastructure/FileSystem/FSEventWatcher.swift`: file events and debounce.
- `Sources/Features`: browser, connection form, transfer queue, onboarding, and sync UI.

## Implementation constraints

Preserve Swift 6 strict concurrency. Follow existing queue/actor ownership,
Sendable callbacks, and MainActor UI delivery; `@unchecked Sendable` requires
actual synchronization. See Docs/Swift6_Migration_Guide.md for implementation notes.

Keep these boundaries intact:

- Credentials in Keychain; exported server JSON contains no credentials or bookmarks.
- App Sandbox with picker-granted security-scoped file access.
- Strict TLS by default; narrow certificate exceptions must stay explicit.
- SFTP host-key mismatch rejection and failure on first-use persistence errors.
- Validation of command arguments, remote names, and local download paths.
- Download to staging files, then replace the destination only after success.
- Cancellation must finish underlying I/O before releasing a transfer slot.

Follow CONTRIBUTING.md for focused changes and SECURITY.md for vulnerability reporting.
