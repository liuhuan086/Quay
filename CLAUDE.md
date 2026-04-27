# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

SwiftFTP v2 is a macOS FTP/FTPS/SFTP client built with SwiftUI + Swift 6 strict concurrency. It targets macOS and uses `Network.framework` for FTP/FTPS and NMSSH (optional, via SPM) for SFTP.

## Build & Test

This is an Xcode project — there is no `Package.swift`. Build and test via Xcode:

- **Build:** `⌘B` in Xcode, or `Product → Build`
- **Run tests:** `⌘U` in Xcode, or `Product → Test`
- **Run a single test:** Click the diamond icon next to any `func test_...` in the test file, or right-click a test method and choose "Run"
- **Static analysis:** `Product → Analyze`
- **Enable Swift 6 strict concurrency:** Build Settings → Swift Compiler → Swift Language Version = Swift 6 (or Swift Strict Concurrency = Complete)
- **Runtime race detection:** Instruments → Thread Sanitizer

SFTP support via NMSSH requires adding the package dependency manually in Xcode and uncommenting the `/* ── NMSSH ──` blocks in `SFTPClient.swift`.

## Architecture

### Layer structure

```
Sources/
├── App/AppState.swift          — @MainActor singleton: owns all published state, wires services
├── Core/
│   ├── Domain/
│   │   ├── Entities/Entities.swift     — All value types (Sendable structs/enums)
│   │   └── Repositories/AnyFTPClient.swift  — Protocol all clients conform to
│   ├── Data/ServerRepository.swift     — UserDefaults persistence + NotificationService
│   └── Infrastructure/
│       ├── Network/
│       │   ├── FTPClient.swift         — FTP/FTPS (class + DispatchQueue, not actor)
│       │   ├── SFTPClient.swift        — SFTP (NMSSH wrapper, commented out until added)
│       │   ├── ClientFactory.swift     — Creates correct client for a ServerConfig
│       │   ├── ConnectionPool.swift    — actor: per-server pool (max 5), borrow/return pattern
│       │   └── TransferEngine.swift    — actor: transfer queue, concurrency, pause/resume/retry
│       ├── FileSystem/FSEventWatcher.swift  — FSEvents + debounce for realtime sync
│       └── Security/KeychainManager.swift  — macOS Keychain, Sendable singleton
└── Features/
    ├── MainViews.swift                — @main App + RootView + Sidebar + StatusBar
    ├── FileBrowser/                   — Dual-pane browser with drag-drop; Local + Remote VMs
    ├── TransferQueue/                 — Transfer list UI (pause/resume/cancel)
    ├── RealtimeSync/                  — Sync watcher management UI
    └── ConnectionManager/             — Server add/edit form
```

### Key design decisions

**`AnyFTPClient` protocol** (`Repositories/AnyFTPClient.swift`): All `async throws` methods, marked `Sendable`. Clients use an internal `DispatchQueue` (not `actor`) for state isolation — this avoids the Swift 6 "conformance crosses into actor-isolated code" error that occurs when an `actor` conforms to a protocol.

**`ContinuationBox`** (used in `FTPClient.swift`): A `@unchecked Sendable` wrapper around `CheckedContinuation` with `NSLock` to guarantee single-resume. Needed because Swift 6 forbids capturing `var` in concurrent closures (the `var resumed = false` pattern).

**`ConnectionPool` / `ConnectionPoolRegistry`**: Both are `actor`s. The registry (singleton) holds one pool per server UUID. Pools support borrow/return with waiter queues; stale/idle connections are evicted. FTP is single-channel, so concurrent transfers require separate connections.

**`TransferEngine`** (`actor`): Central queue for all transfer tasks. Supports pause (saves `resumeOffset`), resume (restarts from offset), and retry (up to `TransferTask.maxRetries = 3`). Progress callbacks cross the actor boundary via `@Sendable` closures that dispatch back to `@MainActor`.

**`AppState`** (`@MainActor`): Single source of truth for UI. Bridges the actor world (TransferEngine callbacks) to SwiftUI by receiving `@Sendable` callbacks and updating `@Published` properties via `Task { @MainActor in ... }`.

### Swift 6 concurrency patterns used

| Pattern | Where |
|---------|-------|
| `class` + `DispatchQueue` instead of `actor` for protocol conformance | `FTPClient`, `SFTPClient` |
| `ContinuationBox` + `NSLock` for one-shot callbacks | `FTPClient` connect/transfer |
| `@Sendable` closures for cross-actor callbacks | `TransferEngine` → `AppState` |
| `actor` for shared mutable state | `ConnectionPool`, `ConnectionPoolRegistry`, `TransferEngine` |
| All domain types `Sendable` | `Entities.swift` (all structs) |
