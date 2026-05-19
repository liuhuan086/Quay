# Quay Release Verification

Run this checklist before submitting a Mac App Store build.

## Build And Signing

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

The archived entitlements must include:

- `com.apple.security.app-sandbox`
- `com.apple.security.network.client`
- `com.apple.security.files.user-selected.read-write`
- `com.apple.security.files.bookmarks.app-scope`
- `keychain-access-groups`

For App Store submission, export/upload from Xcode Organizer using Apple Distribution and the Mac App Store provisioning profile.

## StoreKit Sandbox

Read `Docs/Monetization_Compliance_Plan.md` before changing IAP behavior. Use `Docs/AppStore_Submission_Materials.md` when preparing App Store Connect IAP metadata, review notes, screenshots, and privacy answers.

Use product IDs:

- `com.swiftftp.app.trial7` — Tier 0 Non-Consumable, display name `7-Day Trial`, Family Sharing off.
- `com.swiftftp.app.pro` — paid Non-Consumable, display name `Quay Pro`.

1. In App Store Connect, create both IAPs and add them to the same app version submission as the first binary that references them.
2. Add App Review screenshots and notes for both IAPs.
3. Create a clean Sandbox tester that has not consumed `com.swiftftp.app.trial7`.
4. Keep a local `SwiftFTP.storekit` configuration in the scheme for pre-ASC testing.
5. Install the archived/exported build, sign out of the regular App Store account if needed, then use the Sandbox tester when macOS prompts during purchase.
6. Verify these paths:
   - Both products load; all prices shown in-app come from StoreKit `displayPrice`.
   - Starting the trial requires the pre-trial disclosure screen and creates the trial transaction.
   - Trial expiry uses the original StoreKit purchase date; reinstall/restore does not reset it.
   - Expired trial enters the non-bricking locked shell: configuration is viewable/exportable, but connect/upload/download/sync are locked.
   - `Quay Pro` purchase unlocks core FTP/FTPS/SFTP features immediately.
   - Restore purchases unlocks Pro after deleting/reinstalling the app.
   - User-cancelled purchase returns to the app without unlocking Pro.
   - Pending Ask to Buy purchase shows a waiting state, does not unlock new capabilities, and unlocks only after `Transaction.updates` / `currentEntitlements` delivers a verified transaction.
   - Interrupted purchases are recovered through `Transaction.unfinished` and finished after entitlement delivery.
   - Failure messages are understandable and provide retry/restore paths.
   - The 24–48 hour trial reminder appears at most once for a given trial expiry and is non-modal.
   - Closing Onboarding without starting trial or buying Pro lands in the same non-bricking locked shell.
   - A user with Pro plus an expired trial resolves to `pro`, not `trialExpired`.
   - Code and screenshots do not hardcode a concrete Pro price; in-app price text comes from StoreKit `displayPrice`.
   - Verified empty entitlement snapshot resolves to `neverStarted`; verification failure or only unverified known transactions resolves to `entitlementUnknown`.
   - Trial start is disabled while either trial product or Pro price is unavailable.
   - Editing/importing/new server creation remains locked after expiry; exporting non-sensitive JSON remains available.
   - `Transaction.unfinished` with an unverified or unknown product ID does not unlock capability and is not silently finished.

## Protocol Smoke Tests

For each protocol, create a temporary test server account with a disposable directory and verify:

1. Connect, disconnect, reconnect.
2. List a directory containing files, folders, hidden files, and non-ASCII names.
3. Upload a small file, a nested folder, and a file larger than 100 MB.
4. Download the same files and compare checksums.
5. Pause/resume one upload and one download.
6. Rename, delete, and create folder.
7. Confirm the password is still present after app restart and absent from exported JSON.

FTPS-specific:

1. Valid public certificate: connects with `允许不受信任证书` off.
2. Self-signed certificate: fails with the toggle off, connects with the toggle on.
3. Expired certificate: fails with the toggle off, connects with the toggle on.
4. Hostname mismatch: fails even with the toggle on.

SFTP-specific:

1. Password auth works.
2. SSH key auth works after selecting the key with the picker.
3. Restart the app and reconnect with the same SSH key without reselecting it.
4. Change the server host key and confirm Quay blocks the connection.

Sandbox file access:

1. Choose a local folder in the browser and verify restart persistence.
2. Drag a local file into the remote pane and verify upload.
3. Add a realtime sync rule using the picker, restart, then save a file and verify upload.
4. Avoid adding sync rules by manually typing or dragging paths; picker selection is required for durable sandbox access.
