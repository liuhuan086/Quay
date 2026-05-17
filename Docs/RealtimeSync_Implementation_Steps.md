# Realtime Sync Implementation Steps

This file is the execution plan for `Docs/RealtimeSync_Mirror_Design.md`.
Read both documents before editing realtime sync code.

The goal is to ship the mirror model in small, reviewable steps. Each step
should be independently testable and should avoid widening destructive behavior
until the previous guardrails are in place.

## Step 0: Repository Hygiene

Scope:

- Ignore local AI/editor state such as `.claude/`.

Acceptance:

- `git status` does not show local Claude state.

## Step 1: Safety Foundation

Scope:

- Add a remote path canonicalizer shared by remote validation and overlap checks.
- Resolve `.`, `..`, repeated slashes, POSIX paths, and Windows drive paths before validation.
- Reject dangerous remote roots and sensitive descendants across macOS, Linux, and Windows.
- Reject local sensitive home descendants such as `~/Library/...`, `~/.ssh/...`, `~/.aws/...`, and `~/.kube/...`.
- Make mandatory secret excludes case-folded and Unicode-normalized.
- Treat SwiftFTP temp files as both prefix and suffix patterns.
- Parse FTP MLSD `modify` timestamps as UTC.
- Surface directory scan truncation instead of silently dropping files after the burst cap.

Acceptance:

- Unit tests cover remote canonicalization, remote overlap canonicalization, local sensitive descendants, remote home known folders, Windows remote known folders, and case-insensitive secret excludes.
- Large directory events produce a visible warning when the scan is truncated.
- Existing upload-only sync behavior remains upload-only. No mirror delete behavior is introduced in this step.

## Step 2: Initial Sync Planner

Status:

- Pure planner implemented in `SyncSafety.swift`.
- Covered by `InitialSyncPlannerTests`.
- The planner only returns a dry-run plan; it does not execute transfers or deletes.

Scope:

- Build a dry-run planner that recursively compares local and remote paths.
- Support upload-only initial sync:
  - local-only path: upload or create remote directory.
  - local newer than remote: upload.
  - remote newer than local: conflict, unless the user explicitly chooses local-wins.
  - type mismatch: conflict.
- Support mirror dry-run planning without executing deletes yet:
  - remote-only paths are planned as deletes only when mirror deletion is enabled.
- Report counts, first affected paths, size warnings, and conflicts.

Acceptance:

- Planner is pure and unit-testable.
- Rule creation can present a plan before any transfer starts.
- No destructive remote delete is executed by the planner.

## Step 3: Rule Creation UX

Status:

- Realtime upload rules now generate a recursive dry-run plan before creation.
- Future-only rules stop when the remote already has same-relative-path content.
- "Upload missing and newer local files now" enqueues uploads only after plan confirmation.
- Mirror mode is visible with deletion acknowledgements, but actual rule creation remains gated until managed-root marker, trash, and delete thresholds are implemented.
- Legacy persisted watchers decode with safe defaults for new mode fields.

Scope:

- Add sync mode selection: realtime upload and one-way mirror.
- Add explicit initial sync choice for realtime upload:
  - upload missing and newer local files now.
  - only sync future changes.
- Add two deletion warnings for mirror mode.
- Stop rule creation on recursive collisions and type conflicts.
- Add advanced confirmation for system-like deploy targets such as `/var/www/...`.

Acceptance:

- The user cannot accidentally create a destructive mirror rule with one click.
- The exact local and remote roots are shown in confirmations.
- Existing upload-only rules keep their current behavior unless changed by the user.

## Step 4: Atomic Uploads

Status:

- Upload tasks write to `<filename>.__swiftftp_tmp__` and then rename into place.
- SwiftFTP temp names are skipped by realtime watchers, local snapshots, remote snapshots, and default excludes.
- Stale temp cleanup remains future work because destructive cleanup must be scoped to a managed root.

Scope:

- Upload to `<filename>.__swiftftp_tmp__`.
- Rename temp files into place after successful upload.
- Ignore SwiftFTP temp files in watchers and scan logic.
- Clean stale SwiftFTP temp files only inside the managed rule root.

Acceptance:

- Remote consumers do not observe partial files for supported protocols.
- Temp cleanup cannot escape the normalized remote rule root.

## Step 5: Managed Mirror Root

Status:

- Marker model and validation are implemented in `ManagedMirrorRoot`.
- AppState can write/read `.swiftftp-mirror.json`, validate it before destructive actions, and run a SwiftFTP-owned create/rename/delete canary.
- Mirror execution is still not enabled; these guards are infrastructure for Step 6.

Scope:

- Write `.swiftftp-mirror.json` inside destructive mirror roots.
- Store rule ID, local root display path, canonical remote root, creation date, app version, and mode.
- Before any destructive action, verify the marker matches the active rule.
- Add a canary create/rename/delete check before the first destructive operation.

Acceptance:

- Missing or mismatched marker pauses destructive sync.
- Canary failure pauses destructive sync.

## Step 6: Realtime Mirror Execution

Status:

- Mirror rules can now be activated after marker + canary verification.
- Local delete events in one-way mirror mode move matching remote paths into `.swiftftp-trash/<rule-id>/<timestamp>/...`.
- Snapshot diffing detects missed local deletes after later FSEvents, collapses directory children, and pauses when a delete burst exceeds the safety threshold.
- Initial mirror creation quarantines remote-only paths from the dry-run plan before considering the rule live.

Scope:

- Implement source-authoritative remote deletes for local delete events.
- Prefer quarantine deletes under `.swiftftp-trash/<rule-id>/<timestamp>/...`.
- Add delete thresholds and pause behavior.
- Add snapshot/index support to catch missed deletes and renames.

Acceptance:

- A deletes can delete or quarantine B only when mirror deletion is explicitly enabled.
- B deletes never delete A.
- Any delete outside the canonical remote root hard-fails.

## Step 7: Remote Drift Detection

Scope:

- Add manual drift detection first, scheduled drift detection later.
- Detect remote missing, remote extra, remote newer, type conflict, and case-folding conflict.
- Offer actions: repair remote from local, ignore once, pause rule, view differences.

Acceptance:

- If B is missing files that exist on A, SwiftFTP asks before repairing B.
- B-side drift never writes back to A.

## Step 8: Release Gate

Scope:

- Run unit tests and Xcode build.
- Review App Sandbox and Keychain requirements in `Docs/AppStore_Readiness.md`.
- Verify sync UI copy is honest for the shipped behavior.

Acceptance:

- No doc claims mirror deletion is shipped before it actually is.
- Destructive behavior has tests, confirmations, and visible failure states.
