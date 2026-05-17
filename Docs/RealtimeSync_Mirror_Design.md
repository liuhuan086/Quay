# Realtime Sync and One-Way Mirror Design

This document defines the intended product behavior and safety constraints for SwiftFTP realtime sync. Read it before changing `Sources/Features/RealtimeSync`, `FSEventWatcher`, `TransferEngine`, or any transfer behavior used by sync rules.

## Implementation Status

Most of this document is the **target** model. Track what is actually shipped here so the doc stays honest.

**Shipped (commit `ac8e0a6`, "Harden realtime sync rule creation and overwrites") — guardrails-only pass on the existing upload-only mode:**

- `SyncPathValidator` (`Sources/Core/Domain/SyncSafety.swift`): forbidden system/home roots, minimum depth (≥ 3 components), missing/symlink local root, non-absolute remote path, and overlapping-rule rejection. POSIX + Windows aware. Unit-tested.
- Same-name collision block at rule creation (stops creation, lists colliding entries).
- Conflict-safe overwrite: `SyncConflictDecision.shouldSkipUpload` — if the remote copy is newer than local (clock-skew tolerant, UTC compare), the upload is **skipped and surfaced** in the UI instead of clobbering newer remote work.
- Mandatory secret excludes (`SyncWatcher.mandatorySecretExcludes`) always layered on user patterns; default excludes expanded.
- Add-rule sheet: upload-only / no-delete / folder-behavior disclosure, required acknowledgement checkbox, second confirm echoing exact roots.
- Directory-event scan skips symlinks and app temp files, and caps a single burst at 500 files.

**Honest deviation from this doc:** mirror deletion is **not** implemented and local-delete events are hard-blocked in `RealtimeSyncView` `dispatch()`. Because remote deletion cannot occur, the rule-creation flow does **not** show a "remote files may be deleted" warning (that would be a false warning); it warns about the real risk — same-name remote overwrite. The "Rule Creation Safety" deletion-acknowledgement requirement below applies only once mirror mode actually ships.

**Not yet implemented (still target-only):** one-way mirror mode, opt-in remote deletion, initial mirror sync planner, `.swiftftp-trash` quarantine, managed-root marker (`.swiftftp-mirror.json`), canary check, delete thresholds, B-side drift detection ("B missing → ask A"), rule state machine, atomic temp-rename uploads. The Acceptance Criteria section is the gate for that future phase.

## Review Findings From Latest Sync Guardrail Pass

The `ac8e0a6` guardrail pass is directionally good, but it is not the final sync safety layer. Each item below was re-checked against the shipped code (`Sources/Core/Domain/SyncSafety.swift`, `RealtimeSyncView.swift`, `AppState.swift`) and tagged with its real status. These are gating follow-ups for the mirror / initial-sync phase tracked under Acceptance Criteria; do not treat the current guardrails as production-grade until they are resolved.

- **Remote `.`/`..` canonicalization — Confirmed gap (remote only).** `remoteRootError` collapses `//` and maps `\`→`/`, but never resolves `.`/`..`. `/home/user/project/../../etc` has six components, matches no forbidden entry, and is accepted. (The local side already resolves `..` via `normalize()` / `standardizedFileURL`, so the gap is remote-side only.) Canonicalization must also run before any future remote write/delete, not just at rule creation.
- **Remote macOS home broad-folders — Confirmed gap.** `forbiddenHomeChildren` is applied only in `localRootStaticError`; `remoteRootError` has no home-folder concept. `/Users/<user>/Downloads`, `/Documents`, `/Desktop` are accepted as remote roots. They must be rejected as roots while `/Users/<user>/Downloads/project-a` may be allowed.
- **Remote Linux home + sensitive descendants — Partially handled.** `/etc/...` *is* already blocked (subtree entry in `forbiddenRemoteSubtrees`) — it should not be cited as a gap. Still open: `/home/<user>` is rejected only incidentally by the depth rule (reported as "too shallow", not as a home root), and `/root/...`, `/usr/...`, `/opt/...`, `/var/lib/...`, `/var/log/...` deeper than three components pass because those roots are `forbiddenRemoteExact` only, with no subtree entry. Add intent-based home-root rejection and subtree coverage for these sensitive trees.
- **`/var/www/site`-style deploy targets — Design gate, not a bug.** Currently accepted with only the generic acknowledgement checkbox. Upload-only "advanced deploy" destinations are a deliberate product choice: they need an explicit advanced confirmation and must remain disallowed for destructive mirror mode unless the user has deliberately created a managed remote root.
- **Missing remote target classification — Confirmed gap (FTP).** `AppState.remoteDirectoryNames` only maps `FTPError.fileNotFound` to "empty / no collision". FTP commonly surfaces a missing directory as a generic `550` / bad response, so on FTP `validateAndAddWatcher` would wrongly block creation of a valid brand-new dedicated target. Classify protocol-aware: missing directory with an accessible parent → allow; permission/connection failure → keep blocking.
- **Remote mtime trust — Open (design-level).** `SyncConflictDecision.shouldSkipUpload` already fails open on unknown timestamps, but the *quality* of `RemoteFileItem.modifiedDate` is not graded by protocol. SFTP attrs are usually reliable; FTP `MLSD modify` should be parsed as UTC; FTP `LIST` time is not reliable enough to drive a skip. When timestamp quality is unknown, mark the comparison uncertain rather than silently skipping an upload.
- **Burst-cap visibility — Confirmed gap.** `recentlyChangedFiles` breaks silently at 500 files with no rule state or UI signal. A truncated scan must show "scan truncated" and offer a rescan / manual initial sync instead of dropping the remaining files.
- **Collision depth — Accurate; future requirement.** `validateAndAddWatcher` does a top-level, name-only, non-recursive check. That is acceptable as a conservative first pass, but the initial-sync / mirror planner must report exact relative-path collisions and type conflicts (file-vs-directory) recursively.
- **App temp matching — Confirmed gap.** Only `hasPrefix(".__swiftftp_tmp__")` is checked (in `shouldSyncFile` and `recentlyChangedFiles`); the default-exclude literal `.__swiftftp_tmp__` is an exact-component match. The suffix form (e.g. `report.txt.__swiftftp_tmp__`) is not skipped. Cover both `.__swiftftp_tmp__*` and `*.__swiftftp_tmp__`, consistent with the Atomic Uploads plan below.

## Product Goal

SwiftFTP should support a code-test workflow where computer A is the source of truth and computer B is a remote test machine:

- A user can create a rule from a local project folder to a remote target folder.
- If the rule is created after local work already exists, SwiftFTP can first perform an initial sync.
- After the initial sync, SwiftFTP keeps B updated from A in realtime.
- In mirror mode, deletes on A are also reflected on B.

This is a one-way sync model. B is not an editing source, and SwiftFTP should not attempt two-way merge or conflict resolution.

Mirror mode is source-authoritative:

- Local A is the only source of truth.
- Remote B is a reconstructable target.
- A delete may delete the corresponding B path when mirror deletion is enabled and confirmed.
- B delete must never delete A.
- B create or modify must never write back to A.
- B-side drift may only produce a repair prompt or warning.

## Safety Philosophy

Sync is convenient because it hides repetitive work, but destructive sync is dangerous because it can multiply a single mistake across machines. SwiftFTP should bias toward explicit, recoverable, and observable behavior:

- The app should reject obviously dangerous roots before asking the user to decide.
- The app should preview large or destructive plans before executing them.
- The app should prefer quarantining remote deletes over immediate permanent deletion where practical.
- The app should stop on ambiguity rather than guessing.
- The app should make rule state and failures visible.

Common mistakes to design against:

- Selecting `~/Downloads`, `~/Desktop`, `/home/user`, or `/Users/user` instead of a project subfolder.
- Pointing a mirror rule at a non-empty remote directory that contains unrelated files.
- Creating overlapping rules, for example syncing both `~/project` and `~/project/src` to the same server.
- Expecting "realtime upload" to delete remote files.
- Expecting "mirror" to preserve edits made on the remote test machine.
- Expecting B-side deletes to remove A-side files. SwiftFTP must never do this.
- Forgetting that `.env`, SSH keys, cloud credentials, and local IDE files may live under project folders.
- Moving or renaming the local root after creating a security-scoped bookmark.
- Using a symlinked folder where the resolved path escapes the intended project root.
- Creating case-only filename differences on macOS and syncing to Linux, for example `Readme.md` and `README.md`.
- Assuming modification times are perfectly comparable across FTP/SFTP servers with different clocks or timestamp precision.

## Modes

SwiftFTP should expose two distinct sync modes.

### Realtime Upload

Safe default mode.

- Upload local created, modified, and renamed files.
- Create missing remote parent directories.
- Overwrite remote files when the local file changes.
- Do not delete remote files.
- Do not perform an initial full sync unless explicitly requested.

### One-Way Mirror

Power-user mode for code deployment and remote testing.

- Local folder is the source of truth.
- On rule creation, run an initial scan and sync before entering realtime monitoring.
- Local created or modified files upload to remote.
- Local deleted files delete the corresponding remote files.
- Local directory creation creates remote directories.
- Local directory deletion deletes the corresponding remote directory.
- Rename may be implemented as delete old path plus upload/create new path unless a robust rename pairing exists.

## Rule Creation Safety

Mirror mode can delete remote data, so rule creation must be guarded.

1. Show a deletion-risk warning when the user selects mirror mode.
2. Show a second confirmation before creating the rule. The confirmation must show the exact local and remote roots and state that remote files not present locally may be deleted.
3. Require an explicit acknowledgement, such as a checkbox: "I understand remote files may be deleted."
4. If the remote target contains same-relative-path files or directories that collide with local files or directories, stop rule creation and show a conflict message. Do not auto-overwrite during rule creation.
5. Prefer an empty or dedicated remote target directory for mirror rules. If future UX allows non-empty targets, it must provide a dry-run preview first.
6. Reject overlapping rules for the same server when either local roots or remote roots are identical, parent/child, or otherwise normalize to the same path.

For realtime upload mode, rule creation may offer an initial sync choice:

- "Upload missing and newer local files now": compare local and remote paths before monitoring. If A has a file and B does not, upload it. If A and B both have a file and A has a newer modification time, upload A over B. Then start realtime monitoring.
- "Only sync future changes": do not upload existing files during rule creation. Only files created, modified, renamed, or deleted after the rule starts are processed according to the selected mode.

The initial sync choice must be explicit. Do not silently upload a large existing tree when the user only expected future realtime changes.

If both local and remote contain the same relative file and the remote file is newer than the local file during rule creation, treat it as a conflict and stop unless the user explicitly chooses a local-wins mirror workflow. This prevents accidentally overwriting work done directly on B.

## Initial Mirror Sync

Before creating or activating a mirror rule, build a plan. If the user chose initial sync for realtime upload mode, use the same planning model but omit remote-only deletes.

- Local-only path: upload file or create directory remotely.
- Local and remote path both exist and differ by type: stop and ask the user to fix the conflict.
- Local and remote file both exist but size or modified time differs: upload local file over remote.
- Remote-only path: delete remote path only when mirror deletion is enabled and the user confirmed it.
- If local and remote files are identical by size and modification time tolerance, skip them.

The plan should be visible enough for user trust:

- Number of uploads.
- Number of overwrites.
- Number of remote deletes.
- Number of skipped files.
- First several affected paths, especially deletes and overwrites.

For large plans, use a confirmation threshold:

- More than 100 uploads or overwrites: show a summary and require confirmation.
- More than 10 deletes, or deletes covering more than 20% of remote paths: stop and require a second confirmation.
- Any single file larger than 500 MB: show a size warning before initial sync.
- More than 10,000 scanned files: require confirmation before continuing, and show that initial sync may take a long time.
- Any delete outside the expected remote root after normalization: hard fail.
- Any type conflict, case-folding conflict, or symlink escape: hard fail.

Modification-time comparisons need tolerance:

- Use a timestamp tolerance window, for example 2 seconds, because filesystem and FTP timestamp precision can differ.
- If remote modification time is missing or unreliable, compare size first and treat same-size files as "unknown" rather than automatically overwriting.
- Optional future enhancement: hash files on demand for small files or when the user requests a precise comparison.

## Realtime Mirror Sync

After initial sync succeeds:

- Use FSEvents for local changes.
- Coalesce events with debounce.
- Treat directory events as a signal to rescan recent files under that directory.
- Use a snapshot or local path index to catch missed deletes and renames.
- Apply exclude patterns before enqueueing any transfer or delete.

Source-authoritative behavior:

- A creates a file: create/upload it on B.
- A modifies a file: upload A over B.
- A deletes a file: delete or quarantine the corresponding B file only when mirror deletion is enabled.
- B creates a file: do not copy it to A. Mark as remote-extra during drift detection.
- B modifies a file: do not copy it to A. Mark as remote-modified or remote-drifted; future A changes may overwrite it.
- B deletes a file: do not delete A. Mark as remote-missing and prompt the user to repair B from A.

Remote drift handling:

- Drift detection can run manually or on a schedule, but it must be separate from local FSEvents.
- If B is missing files that exist on A, show "Remote is missing files. Repair from local?".
- If B has extra files that do not exist on A, show "Remote has extra files" and only delete them when mirror deletion is enabled and confirmed.
- If B has newer files than A, show a conflict/drift warning. Do not pull those changes into A.
- Available actions should be "Repair remote from local", "Ignore once", "Pause rule", and "View differences".

Deletion sync must be conservative:

- Never delete remote paths outside the normalized remote rule root.
- Ignore app-generated temp files.
- Prefer moving remote deletes to `.swiftftp-trash/<rule-id>/<timestamp>/...` when the protocol and permissions allow it.
- If permanent delete is the only available behavior, the user must have enabled mirror deletion explicitly.
- If remote delete fails, pause or mark the rule as failed instead of continuing silently.

Add a managed-root marker for destructive mirror rules:

- On successful rule creation, write a small marker file such as `.swiftftp-mirror.json` inside the remote root.
- Include the rule ID, remote root, local root display path, creation date, app version, and mode.
- Before any destructive operation, verify the marker exists and matches the rule.
- If the marker is missing or mismatched, pause the rule and ask the user to repair or recreate it.

The marker protects against a user accidentally changing a rule from `/home/liuhuan/project-a` to `/home/liuhuan` or pointing two rules at the same remote root.

Before the first destructive operation for a rule, perform a canary check:

- Create, rename, and delete a tiny SwiftFTP-owned temp file inside the remote root.
- If any step fails, do not run destructive mirror operations.
- Never use a user file as the canary.

## Atomic Uploads

For code/test workflows, remote consumers must not observe half-written files.

Upload files using a temporary remote name and then rename into place:

1. Upload to `<filename>.__swiftftp_tmp__`.
2. Verify upload completion.
3. Rename temp file to the final remote path.
4. Clean stale SwiftFTP temp files only inside the rule root.

FTP and SFTP implementations may need protocol-specific handling, but the sync layer should treat atomic upload as the target behavior.

Before upload, wait until a changed file is stable:

- Check that size and modification time remain unchanged for a short debounce window.
- Do not upload sockets, devices, FIFOs, or other non-regular files.
- Skip files currently matching app temp patterns.
- If a file disappears during upload planning, treat it as a delete or ignore based on the selected mode.

## Forbidden Sync Roots

These restrictions apply to local source roots and remote target roots. They are intended to prevent accidental system-wide sync or destructive deletes. Normalize paths before validation, resolve `~`, trim trailing slashes, and reject paths that escape the selected root through symlinks.

Path validation should be implemented as layered gates:

1. Normalize and canonicalize the candidate path.
2. If the path is inside the current user's home, represent it as a logical home-relative path for validation. For example `/Users/huan/Downloads/docs` becomes `~/Downloads/docs`.
3. Enforce minimum specificity:
   - Home-relative paths must have at least two components after `~`. `~/Downloads` is rejected; `~/Downloads/docs` is allowed.
   - Absolute paths must have at least three components after `/`. `/home/liuhuan` is rejected; `/home/liuhuan/project-a` is allowed.
4. Apply the system/broad-root blacklist below.
5. Reject symlinks or resolved paths that escape the validated root.

This minimum-depth gate is a safety baseline, not a replacement for the blacklist. For example `/usr/local/bin` has enough depth but is still rejected because it is under `/usr`.

### macOS

Always forbid these broad system roots:

- `/`
- `/System`
- `/Library`
- `/Applications`
- `/bin`
- `/sbin`
- `/usr`
- `/opt`
- `/etc`
- `/var`
- `/private`
- `/Volumes`
- `/Users`
- `/Network`
- `/cores`

For user homes, forbid using the home root or common broad folders as the sync rule root:

- `~`
- `~/Desktop`
- `~/Documents`
- `~/Downloads`
- `~/Library`
- `~/Movies`
- `~/Music`
- `~/Pictures`
- `~/Public`
- `~/Applications`
- `~/Sites`

Dedicated project subdirectories may be allowed, for example `~/Downloads/docs` or `~/Documents/project-a`, as long as the path is explicit and not one of the broad roots above.

Also reject these macOS-sensitive locations as roots or descendants for mirror mode:

- `/Library/LaunchAgents`
- `/Library/LaunchDaemons`
- `/Library/PrivilegedHelperTools`
- `/Library/Extensions`
- `/Library/Application Support`
- `/System/Library`
- `/private/etc`
- `/private/var/db`
- `/private/var/root`
- `~/Library`
- `~/Library/LaunchAgents`
- `~/Library/Application Support`
- `~/Library/Keychains`
- `~/.ssh`

Apple documents System Integrity Protection protections around `/System`, `/usr`, `/bin`, `/sbin`, and `/var`; SwiftFTP should be stricter than the OS because remote targets may not have the same protections.

### Linux and Unix-like Servers

Always forbid these broad system roots:

- `/`
- `/bin`
- `/boot`
- `/dev`
- `/etc`
- `/lib`
- `/lib64`
- `/opt`
- `/proc`
- `/root`
- `/run`
- `/sbin`
- `/sys`
- `/usr`
- `/var`
- `/home`
- `/mnt`
- `/media`
- `/snap`

Dedicated project subdirectories under a user home may be allowed, for example `/home/liuhuan/project-a`, but broad home roots such as `/home`, `/home/liuhuan`, or `~` must be rejected for mirror rules.

Also reject these Linux-sensitive locations as roots or descendants for mirror mode:

- `/etc/systemd`
- `/etc/init.d`
- `/etc/ssh`
- `/etc/sudoers.d`
- `/usr/bin`
- `/usr/sbin`
- `/usr/lib`
- `/usr/libexec`
- `/lib/modules`
- `/var/lib`
- `/var/db`
- `/var/run`
- `/var/spool`
- `/var/log`
- `/var/cache`
- `/var/www`
- `/root/.ssh`
- `~/.ssh`
- `~/.gnupg`
- `~/.aws`
- `~/.kube`

Many Linux systems follow the Filesystem Hierarchy Standard, where `/etc` contains host-specific configuration, `/usr` contains shared system/application content, `/var` contains variable state, and `/opt` contains add-on packages. Mirror sync should not treat those as safe project roots.

### Windows-style Remote Paths

SwiftFTP is a macOS app, but FTP/SFTP servers may expose Windows paths. If a remote path looks Windows-style, apply similar protections.

Always reject these broad or sensitive roots:

- Drive roots such as `C:\` or `D:\`
- `%SystemDrive%\`
- `%windir%`
- `C:\Windows`
- `C:\Windows\System32`
- `C:\Windows\SysWOW64`
- `C:\Program Files`
- `C:\Program Files (x86)`
- `C:\ProgramData`
- `C:\Users`
- `C:\Users\<user>`
- `C:\Users\<user>\Desktop`
- `C:\Users\<user>\Documents`
- `C:\Users\<user>\Downloads`
- `C:\Users\<user>\AppData`
- `C:\Users\<user>\AppData\Roaming\Microsoft\Windows\Start Menu`
- `C:\Users\<user>\AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup`

Dedicated project subdirectories may be allowed, for example `C:\Users\liuhuan\Downloads\project-a`, but not the broad profile or known-folder roots themselves.

### Generated or Sensitive Roots

Do not allow these as sync roots:

- `.git`
- `.svn`
- `.hg`
- `node_modules`
- `dist`
- `build`
- `.next`
- `DerivedData`
- `.venv`
- `venv`

These may still be covered by default exclude rules when they appear under an allowed project root.

## Default Excludes

Default excludes should protect performance, secrets, and generated output:

- `.git`
- `.DS_Store`
- `node_modules`
- `dist`
- `build`
- `.next`
- `__pycache__`
- `.venv`
- `venv`
- `*.log`
- `*.swp`
- `.env`
- `.env.*`
- `.ssh`
- `.gnupg`
- `.aws`
- `.kube`
- `.npmrc`
- `.pypirc`
- `.netrc`
- `*.pem`
- `*.key`
- `id_rsa`
- `id_ed25519`
- `DerivedData`
- `*.xcuserstate`
- `.idea`
- `.vscode`
- `.__swiftftp_tmp__`

Users may edit excludes, but mirror mode should warn before removing secret-related excludes such as `.env`.

Symlink policy:

- Do not follow symlinks by default.
- If symlink support is added later, sync the link itself only when both protocols and platforms can represent it safely.
- Never allow a symlink under the local root to cause reads outside the local root.
- Never allow a remote symlink to cause writes or deletes outside the remote root.

Case and path compatibility:

- Detect case-folding conflicts before initial sync, for example `README.md` and `readme.md`.
- Reject or sanitize names invalid on the target platform.
- Normalize Unicode consistently enough to avoid duplicate-looking paths.
- Keep path containment checks byte/path based after canonicalization, not string-prefix-only.

## Failure Visibility

Sync rules should never fail silently.

Each rule needs clear states:

- Preparing
- Scanning
- Initial sync running
- Realtime monitoring
- Paused
- Failed

Failure messages should distinguish:

- Local security-scoped bookmark failure.
- FSEvents watcher failed to start.
- Remote permission denied.
- Remote target path rejected by safety policy.
- Remote collision during rule creation.
- Transfer failed.
- Delete quarantined but final cleanup failed.
- Managed-root marker missing or mismatched.
- Plan blocked by delete threshold.
- Plan blocked by forbidden path.
- Plan blocked by symlink escape.

## Recovery and Undo

Users need a way out when a sync rule behaves unexpectedly.

- Provide "Pause rule" and "Stop all sync" actions near sync status.
- For mirror deletes, show where quarantined files were moved.
- Keep a recent operation log per rule, including upload, overwrite, delete, skip, and failure.
- Allow retrying failed operations after permissions or connectivity are fixed.
- Do not automatically resume a failed destructive rule without user action.

## Implementation Acceptance Criteria

Before shipping mirror mode:

- Unit-test forbidden path validation on macOS and Linux-style paths.
- Unit-test Windows-style forbidden path validation.
- Unit-test remote path containment before delete.
- Unit-test managed-root marker validation before delete.
- Unit-test initial sync planning for upload, overwrite, delete, and type conflict.
- Unit-test initial sync conflict when remote file is newer than local.
- Unit-test excludes before upload/delete.
- Unit-test symlink escape rejection.
- Unit-test case-folding conflict detection.
- Unit-test delete threshold blocking.
- Manually test a local project folder to a remote Mac user folder.
- Manually test local delete reflects on remote only in mirror mode.
- Manually test an existing conflicting remote file blocks rule creation.
- Manually test App Sandbox security-scoped bookmark restore after app restart.

## References

- [Apple: About System Integrity Protection on your Mac](https://support.apple.com/en-us/102149) documents protected locations such as `/System`, `/usr`, `/bin`, `/sbin`, and `/var`.
- [Apple: File System Protections](https://developer.apple.com/library/archive/documentation/Security/Conceptual/System_Integrity_Protection_Guide/FileSystemProtections/FileSystemProtections.html) notes that all directories in `/usr` except `/usr/local` are restricted to the system.
- [Filesystem Hierarchy Standard](https://specifications.freedesktop.org/fhs/latest-single/) defines system roles for directories such as `/etc`, `/usr`, `/var`, and `/opt`.
- [Microsoft: Known Folder IDs](https://learn.microsoft.com/en-us/windows/win32/shell/knownfolderid) and [Shell Special Folders](https://learn.microsoft.com/en-us/windows/win32/api/shldisp/ne-shldisp-shellspecialfolderconstants) document Windows locations such as Program Files, Windows, System32, AppData, Start Menu, and Startup.
