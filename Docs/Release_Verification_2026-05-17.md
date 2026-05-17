# Release Verification — 2026-05-17

This file records the Step 8 release gate result for the realtime sync / mirror
implementation pass.

## Automated Verification

All commands were run from the repository root.

### Unit Tests

```bash
xcodebuild test -project SwiftFTP.xcodeproj -scheme SwiftFTP -destination 'platform=macOS' -derivedDataPath /private/tmp/swiftftp-dd-step8 CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
```

Result:

- Passed.
- 111 tests, 0 failures.

### Debug Build

```bash
xcodebuild build -project SwiftFTP.xcodeproj -scheme SwiftFTP -destination 'platform=macOS' -derivedDataPath /private/tmp/swiftftp-dd-step8 CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
```

Result:

- Passed.
- `SwiftFTP.app` built successfully.

## Release Gate Review

Verified in code/docs:

- App Sandbox entitlements are present:
  - `com.apple.security.app-sandbox`
  - `com.apple.security.network.client`
  - `com.apple.security.files.user-selected.read-write`
  - `com.apple.security.files.bookmarks.app-scope`
- Credentials remain runtime-only in `ServerConfig` and persist through Keychain.
- Realtime sync / one-way mirror docs match the shipped behavior:
  - dry-run creation plan
  - atomic temp uploads
  - managed mirror marker
  - canary check
  - quarantine deletes under `.swiftftp-trash`
  - delete thresholds and pause behavior
  - manual remote drift detection and repair-to-remote only

Remaining items that require real release infrastructure or manual QA:

- Fill `DEVELOPMENT_TEAM` and archive with Apple Distribution / MAS provisioning.
- Register the bundle ID in App Store Connect.
- Provide a public HTTPS privacy policy URL.
- Run StoreKit sandbox purchase / restore / failure-flow tests.
- Run real FTP / FTPS / SFTP integration tests against known servers.
- Run MAS-signed sandbox manual QA for file picker, drag-drop, Finder open, realtime sync bookmarks, Keychain, known hosts, and mirror quarantine.
- Prepare App Store screenshots, copy, keywords, pricing, rating, and privacy questionnaire.
