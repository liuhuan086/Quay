# Quay Release Verification

Use this checklist for the open-source edition. The current mainline has no
StoreKit purchase, trial, or entitlement prerequisites.

## Build and automated tests

Run an unsigned build and regression suite from the repository root:

```bash
xcodebuild build \
  -project SwiftFTP.xcodeproj \
  -scheme SwiftFTP \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /private/tmp/QuayDerivedData \
  CODE_SIGNING_ALLOWED=NO

xcodebuild test \
  -project SwiftFTP.xcodeproj \
  -scheme SwiftFTP \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /private/tmp/QuayDerivedData \
  CODE_SIGNING_ALLOWED=NO
```

Use the appropriate architecture for the test Mac. Record the commit, Xcode
version, result counts, and skip reasons; do not reuse the paid edition's test
counts. See [Verification_2026-10-23.md](Verification_2026-10-23.md) for the
mainline alignment verification.

## Signed build and file access

Repeat tests with an Apple Development signed host and the appropriate team.
The direct Keychain integration tests must execute, not skip. Unsigned tests
alone cannot establish signed Keychain or App Sandbox behavior.

Archive a distribution candidate using the signing configuration appropriate
for its distribution channel. Inspect the resulting app's entitlements:

```bash
codesign -d --entitlements - /path/to/SwiftFTP.app
```

Verify App Sandbox, network client, user-selected read/write, app-scope
bookmarks, and the correctly expanded Keychain access group. Test the actual
signed artifact on a clean user account before release.

## Protocol Smoke Tests

For each protocol, create a temporary test server account with a disposable directory and verify:

1. Connect, disconnect, reconnect.
2. List a directory containing files, folders, hidden files, and non-ASCII names.
3. Upload a small file, a nested folder, and a file larger than 100 MB.
4. Download the same files and compare checksums on both sides; confirm a failed download leaves any pre-existing local destination unchanged.
5. Pause/resume one upload and one download.
6. Rename, delete, and create folder.
7. Confirm the password is still present after app restart and absent from exported JSON.

FTPS-specific:

Quay supports **implicit FTPS on port 990 only**. Do not test or advertise explicit
`AUTH TLS` as supported. Confirm the server requires private data channels (`PROT P`).

1. Valid public certificate: connects with `允许自签名或过期证书` off.
2. Self-signed certificate: fails with the toggle off, connects with the toggle on.
3. Expired certificate: fails with the toggle off, connects with the toggle on.
4. Hostname mismatch: fails even with the toggle on.
5. Revoked certificate: fails even with the toggle on.
6. Capture the server logs or packet metadata and confirm both control and data channels use TLS.

SFTP-specific:

1. Password auth works.
2. SSH key auth works after selecting the key with the picker.
3. Restart the app and reconnect with the same SSH key without reselecting it.
4. Change the server host key and confirm Quay blocks the connection.
5. Confirm a default connection does not negotiate SHA-1 algorithms; enable the legacy-algorithm toggle only for a disposable legacy server and verify the warning path.

Sandbox file access:

1. Choose a local folder in the browser and verify restart persistence.
2. Drag a local file into the remote pane and verify upload.
3. Add a realtime sync rule using the picker, restart, then save a file and verify upload.
4. Avoid adding sync rules by manually typing or dragging paths; picker selection is required for durable sandbox access.
