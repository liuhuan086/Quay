# Mainline alignment verification — 2026-10-23

## Scope

Local `main` was aligned to the existing open-source upstream commit
`19315b45ae0d78d12c749d9616d5467b3cce5d95` after preserving the paid edition.
Application sources, tests, dependencies, and Xcode settings remain identical
to that upstream revision. The follow-up change only restores and updates
useful development documentation.

The previous paid edition, including its three uncommitted build-setting
changes, is preserved locally on `codex/archive-paid-2026-10-23` at
`f7e0a446ee00644863ca07041761929657f747b9`. A full working-directory archive
(including Git metadata and ignored IDE state) and an all-refs Git bundle were
saved outside the repository. The archive was read back, the bundle was
verified, and a fresh checkout of the paid snapshot was successfully restored
from the bundle and checked with `git fsck --full`. No remote history was changed.

## Environment and results

- Date: 2026-10-23, Asia/Shanghai.
- macOS: 27.0.1 (26A434), Apple Silicon.
- Xcode: 27.1 (27A9275).
- Configuration: Debug, macOS arm64, `CODE_SIGNING_ALLOWED=NO`.
- Build: **succeeded**.
- Tests: **98 total, 92 passed, 6 skipped, 0 failed**.
- All six skips were `KeychainTests`: delete, existence, missing key, overwrite,
  save/retrieve, and Unicode password. Their setup detected
  `errSecMissingEntitlement` in the unsigned host.
- Repository tests using injected Keychain storage, local FTP integration,
  connection pool, transfer engine, known-host validation, and bookmark tests passed.

Commands executed from the repository root:

```bash
xcodebuild build \
  -project SwiftFTP.xcodeproj \
  -scheme SwiftFTP \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /private/tmp/quay-verification-2026-10-23/DerivedData \
  CODE_SIGNING_ALLOWED=NO

xcodebuild test \
  -project SwiftFTP.xcodeproj \
  -scheme SwiftFTP \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /private/tmp/quay-verification-2026-10-23/DerivedData \
  -resultBundlePath /private/tmp/quay-verification-2026-10-23/Tests.xcresult \
  CODE_SIGNING_ALLOWED=NO
```

Build and test logs and the `.xcresult` bundle were retained locally alongside
the paid-edition backup. Use a fresh result-bundle path when repeating the test command.

## Remaining validation and diagnostics

The build reports six existing Swift capture warnings: three in
`AppState.wireEngine` and three in `RealtimeSyncViewModel.wireSyncManager`.
They concern nested weak captures inside an outer implicitly strong capture.
The Xcode App Intents metadata step also reports that extraction was skipped
because this app has no AppIntents dependency. Neither prevented the build.
These source files were not modified during alignment.

This run does not verify signed Keychain integration, distribution signing,
real-server FTPS/SFTP scenarios, or sandbox authorization across app restarts.
Complete the applicable manual checks in
[Release_Verification.md](Release_Verification.md) before distributing a release.
