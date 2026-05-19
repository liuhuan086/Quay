# SwiftFTP App Store Submission Materials

Use this handoff when creating the first Mac App Store version that references SwiftFTP's trial and Pro in-app purchases.

## Product Setup

Create both in-app purchases in App Store Connect and add them to the same app version submission as the binary that first references them.

| Product | Value |
| --- | --- |
| Trial product ID | `com.swiftftp.app.trial7` |
| Trial type | Non-Consumable |
| Trial price | Price Tier 0 |
| Trial display name | `7-Day Trial` / `7-Day Trial（7 天试用）` |
| Trial description | `Unlocks full SwiftFTP core FTP/FTPS/SFTP features for 7 days. After the trial ends, connections, transfers, and realtime sync require SwiftFTP Pro.` |
| Trial Family Sharing | Off |
| Pro product ID | `com.swiftftp.app.pro` |
| Pro type | Non-Consumable |
| Pro display name | `SwiftFTP Pro` / `SwiftFTP Pro（本地功能）` |
| Pro description | `One-time unlock for SwiftFTP's core local FTP/FTPS/SFTP client features, including connections, uploads, downloads, transfer queue controls, and realtime sync.` |
| Pro Family Sharing | Decide before submission; once enabled for a non-consumable purchase it cannot be turned off. |

Do not name Pro `Full Unlock`, because future cloud integrations may become a separate paid tier. Do not put concrete Pro prices into screenshots or static copy; the app shows the localized StoreKit `displayPrice`.

## Review Notes

Paste and adapt this note in App Review Information:

> SwiftFTP uses the App Review Guideline 3.1.1 Tier 0 Non-Consumable trial path. `com.swiftftp.app.trial7` is a Price Tier 0 free trial product for 7 days (Display Name: `7-Day Trial`). `com.swiftftp.app.pro` is a one-time `SwiftFTP Pro` unlock for the app's initial local FTP/FTPS/SFTP client features. Before the user can start the trial, SwiftFTP discloses the trial duration, the features locked after expiry, and the later one-time Pro price using StoreKit's localized price. After expiry the app is not blank or bricked: users can still view and export non-sensitive server configuration, delete local data, open About/Privacy/Terms, buy Pro, or restore purchases. If the review account has already consumed the Tier 0 trial product, the app will enter this same locked shell, which is expected for a non-consumable trial. Use a clean Sandbox tester to review the first-trial path.

## Screenshot Plan

Capture five Mac screenshots from a signed build using production-like sample data. Avoid showing any password, private key, passphrase, token, or concrete Pro price.

1. Dual-pane browser connected to an SFTP server with local and remote file lists.
2. Server editor showing protocol, host, port, username, TLS/SFTP security options, and Keychain-safe password copy.
3. Transfer queue with active, paused, retryable, and completed rows.
4. Realtime sync rule list with a user-selected local folder and remote target.
5. Trial disclosure or locked shell showing the 7-day trial, one-time Pro unlock, restore path, and non-bricking data access.

## Privacy Answers

Current implementation can be submitted as no data collected, provided no analytics SDK is added before release.

| App Store Connect question | Answer |
| --- | --- |
| Data used to track the user | None |
| Data linked to the user | None |
| Data not linked to the user | None |
| Third-party advertising | No |
| Third-party analytics | No |

Notes for the privacy policy:

- Server credentials are stored locally in macOS Keychain.
- Server configuration metadata is stored locally on the user's Mac.
- FTP/FTPS/SFTP traffic goes directly between the user's Mac and their configured servers.
- SwiftFTP does not operate a backend service for account, telemetry, analytics, or tracking data.

## Manual Validation Before Upload

- Verify `SwiftFTP.storekit` remains selected in the Xcode scheme for local StoreKit testing.
- Test trial purchase, trial expiry, Pro purchase, restore, cancel, pending Ask to Buy, and interrupted purchases.
- Export a non-sensitive server configuration JSON from the locked shell and confirm it contains no password, passphrase, security-scoped bookmark, private key content, or Keychain material.
- Archive with Apple Distribution and the Mac App Store provisioning profile through Xcode Organizer.
- Install the exported build and repeat sandbox checks for file picker access, drag/drop upload, realtime sync folder bookmarks, Keychain persistence, and StoreKit Sandbox purchases.
