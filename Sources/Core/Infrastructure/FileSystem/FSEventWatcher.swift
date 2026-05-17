// FSEventWatcher.swift — Swift 6–safe file system event watcher
import Foundation
import CoreServices
import Combine

// MARK: - Event
public struct FileChangeEvent: Sendable {
    public let path: String
    public let kind: Kind
    public let isDirectory: Bool

    public enum Kind: Sendable { case created, modified, deleted, renamed }
}

// MARK: - FSEventWatcher
/// Non-actor class. Uses a dedicated serial queue for debouncing.
/// Publishes events via a PassthroughSubject on the main runloop.
public final class FSEventWatcher: @unchecked Sendable {
    // `@unchecked Sendable` is safe because:
    //  • streamRef is only touched on `debounceQueue`
    //  • debounceWork is protected by a lock
    //  • eventPublisher itself is thread-safe (PassthroughSubject is Sendable)

    public let eventPublisher = PassthroughSubject<FileChangeEvent, Never>()

    private var streamRef: FSEventStreamRef?
    private let debounceQueue = DispatchQueue(label: "com.swiftftp.fsevents", qos: .utility)
    private let fixedDebounceDelay: TimeInterval?
    private let lock = NSLock()
    private struct PendingDebounce {
        let id: UUID
        let work: DispatchWorkItem
    }
    private var pendingWork: [String: PendingDebounce] = [:]

    public init(debounceDelay: TimeInterval? = nil) {
        self.fixedDebounceDelay = debounceDelay
    }

    // MARK: - Start
    @discardableResult
    public func startWatching(paths: [String]) -> Bool {
        // FIXME(AppSandbox): each watched path must come from a security-scoped
        // bookmark before this is used in the Mac App Store sandbox.
        stopWatching()
        guard !paths.isEmpty else { return false }

        // We pass `self` as UnsafeMutableRawPointer; the callback is a C function,
        // so we use `@unchecked Sendable` + manual retain/release to bridge safely.
        var ctx = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: { ptr -> UnsafeRawPointer? in
                _ = Unmanaged<FSEventWatcher>.fromOpaque(ptr!).retain()
                return ptr
            },
            release: { ptr in
                Unmanaged<FSEventWatcher>.fromOpaque(ptr!).release()
            },
            copyDescription: nil
        )

        let flags = UInt32(
            kFSEventStreamCreateFlagUseCFTypes  |
            kFSEventStreamCreateFlagFileEvents  |
            kFSEventStreamCreateFlagNoDefer
        )

        let callback: FSEventStreamCallback = { _, info, numEvents, eventPaths, eventFlags, _ in
            guard let info else { return }
            let watcher = Unmanaged<FSEventWatcher>.fromOpaque(info).takeUnretainedValue()
            let paths   = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as! [String]
            for i in 0..<numEvents {
                watcher.handleRaw(path: paths[i], flags: eventFlags[i])
            }
        }

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &ctx,
            paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.2, flags
        ) else {
            return false
        }

        streamRef = stream
        FSEventStreamSetDispatchQueue(stream, debounceQueue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            streamRef = nil
            return false
        }
        return true
    }

    // MARK: - Stop
    public func stopWatching() {
        if let stream = streamRef {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            streamRef = nil
        }
        lock.lock()
        pendingWork.values.forEach { $0.work.cancel() }
        pendingWork.removeAll()
        lock.unlock()
    }

    // MARK: - Raw event handler
    private func handleRaw(path: String, flags: FSEventStreamEventFlags) {
        // Debounce per path
        lock.lock()
        pendingWork[path]?.work.cancel()
        let id = UUID()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let isDir  = flags & UInt32(kFSEventStreamEventFlagItemIsDir) != 0
            var kind: FileChangeEvent.Kind = .modified
            if flags & UInt32(kFSEventStreamEventFlagItemCreated) != 0 { kind = .created }
            else if flags & UInt32(kFSEventStreamEventFlagItemRemoved) != 0 { kind = .deleted }
            else if flags & UInt32(kFSEventStreamEventFlagItemRenamed) != 0 { kind = .renamed }
            let event = FileChangeEvent(path: path, kind: kind, isDirectory: isDir)
            self.eventPublisher.send(event)
            self.lock.lock()
            if self.pendingWork[path]?.id == id {
                self.pendingWork.removeValue(forKey: path)
            }
            self.lock.unlock()
        }
        pendingWork[path] = PendingDebounce(id: id, work: work)
        lock.unlock()
        debounceQueue.asyncAfter(deadline: .now() + effectiveDebounceDelay, execute: work)
    }

    deinit { stopWatching() }

    private var effectiveDebounceDelay: TimeInterval {
        if let fixedDebounceDelay {
            return min(max(fixedDebounceDelay, 0.1), 2.0)
        }
        let saved = UserDefaults.standard.double(forKey: "debounce")
        return saved > 0 ? min(max(saved, 0.1), 2.0) : 0.5
    }
}

// MARK: - Exclusion Matcher
public struct ExclusionMatcher: Sendable {
    public let patterns: [String]

    public func shouldExclude(_ path: String) -> Bool {
        let fileName = (path as NSString).lastPathComponent
        for p in patterns {
            if p.contains("*") {
                if matchGlob(fileName, pattern: p) { return true }
            } else if pathComponents(path).contains(p) {
                return true
            }
        }
        return false
    }

    private func pathComponents(_ path: String) -> [String] {
        path.split(separator: "/").map(String.init)
    }

    private func matchGlob(_ string: String, pattern: String) -> Bool {
        if pattern.hasPrefix("*") && pattern.hasSuffix("*") {
            return string.contains(String(pattern.dropFirst().dropLast()))
        } else if pattern.hasPrefix("*") { return string.hasSuffix(String(pattern.dropFirst())) }
        else if pattern.hasSuffix("*")   { return string.hasPrefix(String(pattern.dropLast())) }
        return string == pattern
    }
}
