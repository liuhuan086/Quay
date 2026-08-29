// RealtimeSyncView.swift — Real-time sync with FSEvents
import SwiftUI
import Combine
import AppKit

// MARK: - SyncManager (actor, owns the watcher)
actor SyncManager {
    private let watcher = FSEventWatcher()
    private var cancellables = Set<AnyCancellable>()
    private var scopedURLs: [URL] = []
    var onFileChange: (@Sendable (FileChangeEvent, SyncWatcher) -> Void)?
    var onBookmarkStale: (@Sendable (SyncWatcher) -> Void)?

    deinit {
        watcher.stopWatching()
        for url in scopedURLs {
            url.stopAccessingSecurityScopedResource()
        }
    }

    func start(watchers: [SyncWatcher]) -> Set<UUID> {
        stopAll()
        let active = watchers.filter { $0.isActive }
        guard !active.isEmpty else { return [] }

        var usableWatchers: [SyncWatcher] = []
        var paths: [String] = []
        for watcher in active {
            guard let bookmark = watcher.localPathBookmark else {
                onBookmarkStale?(watcher)
                continue
            }

            do {
                var isStale = false
                let url = try URL(
                    resolvingBookmarkData: bookmark,
                    options: [.withSecurityScope],
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                )
                guard !isStale else {
                    onBookmarkStale?(watcher)
                    continue
                }
                guard url.startAccessingSecurityScopedResource() else {
                    onBookmarkStale?(watcher)
                    continue
                }
                scopedURLs.append(url)
                usableWatchers.append(watcher)
                paths.append(url.path)
            } catch {
                onBookmarkStale?(watcher)
            }
        }
        guard !paths.isEmpty else { return [] }
        let dispatchWatchers = usableWatchers

        watcher.eventPublisher
            .receive(on: RunLoop.main)
            .sink { [weak self] event in
                Task { [weak self] in
                    await self?.dispatch(event: event, watchers: dispatchWatchers)
                }
            }
            .store(in: &cancellables)

        guard watcher.startWatching(paths: paths) else {
            stopAll()
            usableWatchers.forEach { onBookmarkStale?($0) }
            return []
        }
        return Set(usableWatchers.map(\.id))
    }

    func stopAll() {
        watcher.stopWatching()
        cancellables.removeAll()
        for url in scopedURLs {
            url.stopAccessingSecurityScopedResource()
        }
        scopedURLs.removeAll()
    }

    private func dispatch(event: FileChangeEvent, watchers: [SyncWatcher]) {
        guard event.kind != .deleted else { return }
        for w in watchers where isPath(event.path, containedIn: w.localPath) {
            let matcher = ExclusionMatcher(patterns: w.excludePatterns)
            if event.isDirectory || isDirectory(at: event.path) {
                for path in recentlyChangedFiles(in: event.path, matcher: matcher) {
                    onFileChange?(FileChangeEvent(path: path, kind: event.kind, isDirectory: false), w)
                }
            } else if shouldSyncFile(at: event.path, matcher: matcher) {
                onFileChange?(event, w)
            }
        }
    }

    private func isPath(_ path: String, containedIn rootPath: String) -> Bool {
        let root = normalizedPath(rootPath)
        let candidate = normalizedPath(path)
        guard root != "/" else { return true }
        return candidate == root || candidate.hasPrefix(root + "/")
    }

    private func normalizedPath(_ path: String) -> String {
        let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
        guard normalized != "/" else { return normalized }
        return normalized.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private func shouldSyncFile(at path: String, matcher: ExclusionMatcher) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              !isDirectory.boolValue else { return false }
        return !matcher.shouldExclude(path)
    }

    private func isDirectory(at path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    private func recentlyChangedFiles(in directoryPath: String, matcher: ExclusionMatcher) -> [String] {
        let rootURL = URL(fileURLWithPath: directoryPath, isDirectory: true)
        let cutoff = Date().addingTimeInterval(-30)
        let keys: [URLResourceKey] = [
            .isRegularFileKey,
            .contentModificationDateKey,
            .creationDateKey
        ]
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: keys,
            options: [.skipsPackageDescendants]
        ) else { return [] }

        var paths: [String] = []
        for case let fileURL as URL in enumerator {
            let path = fileURL.path
            if matcher.shouldExclude(path) { continue }
            guard let values = try? fileURL.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true else { continue }
            let modifiedRecently = values.contentModificationDate.map { $0 >= cutoff } ?? false
            let createdRecently = values.creationDate.map { $0 >= cutoff } ?? false
            if modifiedRecently || createdRecently {
                paths.append(path)
            }
        }
        return paths
    }
}

// MARK: - RealtimeSyncViewModel
@MainActor
final class RealtimeSyncViewModel: ObservableObject {
    @Published var watchers: [SyncWatcher] = []
    @Published var showAddSheet = false
    @Published var recentEvents: [(String, Date)] = []   // (filename, time)
    @Published private var runningWatcherIDs: Set<UUID> = []

    private let appState: AppState
    private let server: ServerConfig
    private let syncManager = SyncManager()
    private var stateCancellables = Set<AnyCancellable>()

    var activeCount: Int { runningWatcherIDs.count }

    init(appState: AppState, server: ServerConfig) {
        self.appState = appState
        self.server = server
        self.watchers = appState.syncWatchers.values.filter { $0.serverID == server.id }
        wireSyncManager()
        appState.$syncWatchers
            .dropFirst()
            .sink { [weak self] stored in
                guard let self else { return }
                self.watchers = stored.values
                    .filter { $0.serverID == self.server.id }
                    .sorted { $0.localPath < $1.localPath }
            }
            .store(in: &stateCancellables)

    }

    // MARK: - Add watcher
    func addWatcher(localPath: String, localPathBookmark: Data, remotePath: String, excludePatterns: [String]) {
        let w = SyncWatcher(
            id: UUID(), serverID: server.id, serverName: server.displayName,
            localPath: localPath, localPathBookmark: localPathBookmark, remotePath: remotePath,
            excludePatterns: excludePatterns, isActive: true,
            lastSyncAt: nil, totalSynced: 0
        )
        watchers.append(w)
        appState.upsertSyncWatcher(w)
        refreshWatcher()
    }

    // MARK: - Toggle active
    func toggle(_ watcher: SyncWatcher) {
        guard let idx = watchers.firstIndex(where: { $0.id == watcher.id }) else { return }
        watchers[idx].isActive.toggle()
        appState.upsertSyncWatcher(watchers[idx])
        refreshWatcher()
    }

    // MARK: - Remove watcher
    func remove(_ watcher: SyncWatcher) {
        watchers.removeAll { $0.id == watcher.id }
        appState.removeSyncWatcher(watcher)
        refreshWatcher()
    }

    // MARK: - Wire sync events
    private func wireSyncManager() {
        let initialWatchers = watchers
        Task {
            await syncManager.setCallback { [weak self] event, watcher in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let fileName = URL(fileURLWithPath: event.path).lastPathComponent
                    let relative = String(event.path.dropFirst(watcher.localPath.count))
                    let remotePath = watcher.remotePath.hasSuffix("/")
                        ? watcher.remotePath + relative.trimmingCharacters(in: .init(charactersIn: "/"))
                        : watcher.remotePath + relative

                    await self.appState.enqueue(
                        server: self.server, direction: .upload,
                        localURL: URL(fileURLWithPath: event.path),
                        remotePath: remotePath, isAutoSync: true
                    )

                    self.recentEvents.insert((fileName, Date()), at: 0)
                    if self.recentEvents.count > 20 { self.recentEvents.removeLast() }

                }
            }
            await syncManager.setBookmarkStaleCallback { [weak self] watcher in
                Task { @MainActor [weak self] in
                    self?.appState.alertItem = AlertItem(
                        title: "同步目录需要重新选择",
                        message: "\(watcher.localPath) 的访问权限已失效，请重新添加同步规则。"
                    )
                }
            }
            let runningIDs = await syncManager.start(watchers: initialWatchers)
            Task { @MainActor [weak self] in
                self?.runningWatcherIDs = runningIDs
            }
        }
    }

    private func refreshWatcher() {
        let currentWatchers = watchers
        Task { [weak self] in
            guard let self else { return }
            let runningIDs = await syncManager.start(watchers: currentWatchers)
            await MainActor.run {
                self.runningWatcherIDs = runningIDs
            }
        }
    }

}

extension SyncManager {
    func setCallback(_ callback: @Sendable @escaping (FileChangeEvent, SyncWatcher) -> Void) {
        onFileChange = callback
    }

    func setBookmarkStaleCallback(_ callback: @Sendable @escaping (SyncWatcher) -> Void) {
        onBookmarkStale = callback
    }
}

// MARK: - RealtimeSyncView
struct RealtimeSyncView: View {
    @ObservedObject var vm: RealtimeSyncViewModel
    @Environment(\.dismiss) private var dismiss

    // Add-sheet state
    @State private var localPath = ""
    @State private var localPathBookmark: Data?
    @State private var remotePath = ""
    @State private var excludeText = SyncWatcher.defaultExcludePatterns.joined(separator: "\n")

    var body: some View {
        syncContent
    }

    private var syncContent: some View {
        VStack(spacing: 0) {
            // ── Header ──
            HStack {
                Label {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("实时同步").font(.headline)
                        Text(vm.activeCount > 0
                             ? "\(vm.activeCount) 条规则监控中"
                             : "监控已停止")
                            .font(.caption).foregroundColor(vm.activeCount > 0 ? .green : .secondary)
                    }
                } icon: {
                    Image(systemName: vm.activeCount > 0
                          ? "arrow.triangle.2.circlepath.circle.fill"
                          : "arrow.triangle.2.circlepath.circle")
                        .foregroundColor(vm.activeCount > 0 ? .green : .secondary)
                        .font(.title2)
                }
                Spacer()
                HStack(spacing: 8) {
                    Button { vm.showAddSheet = true } label: {
                        Label("添加规则", systemImage: "plus")
                    }
                    .buttonStyle(RealtimeSyncHeaderGhostButtonStyle())

                    Button { dismiss() } label: {
                        Label("关闭", systemImage: "xmark")
                    }
                    .buttonStyle(RealtimeSyncHeaderGhostButtonStyle())
                    .help("关闭")
                }
            }
            .padding()

            Divider()

            // ── Watcher list ──
            if vm.watchers.isEmpty {
                emptyState
            } else {
                List(vm.watchers) { w in
                    WatcherRow(watcher: w,
                               onToggle: { vm.toggle(w) },
                               onDelete: { vm.remove(w) })
                }
                .listStyle(.inset)
            }

            // ── Recent events log ──
            if !vm.recentEvents.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    Text("最近同步").font(.caption).foregroundColor(.secondary).padding(.horizontal, 12)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(vm.recentEvents.prefix(8), id: \.1) { name, date in
                                HStack {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(.green).font(.caption2)
                                    Text(name).font(.caption).lineLimit(1)
                                    Spacer()
                                    Text(date.formatted(date: .omitted, time: .shortened))
                                        .font(.caption2).foregroundColor(.secondary)
                                }
                                .padding(.horizontal, 12)
                            }
                        }
                    }
                    .frame(maxHeight: 120)
                }
                .padding(.vertical, 6)
                .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
            }
        }
        .sheet(isPresented: $vm.showAddSheet) { addSheet }
    }

    // MARK: - Empty state
    var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "eye.slash").font(.system(size: 40)).foregroundColor(.secondary)
            Text("尚未配置同步规则").font(.callout)
            Text("添加规则后，本地文件保存时会自动上传到远程服务器")
                .font(.caption).foregroundColor(.secondary).multilineTextAlignment(.center)
            Button("添加第一条规则") { vm.showAddSheet = true }
                .buttonStyle(.borderedProminent)
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Add sheet
    var addSheet: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("添加同步规则").font(.title3).bold()

            // Local path
            VStack(alignment: .leading, spacing: 4) {
                Text("本地监控文件夹").font(.caption).foregroundColor(.secondary)
                HStack {
                    FileDropContainer { urls in
                        guard let url = urls.first else { return }
                        localPath = url.path
                        localPathBookmark = nil
                    } content: {
                        TextField("拖入文件夹或点击选择", text: $localPath)
                            .textFieldStyle(.roundedBorder)
                    }
                    Button("选择…") {
                        let p = NSOpenPanel()
                        p.canChooseFiles = false; p.canChooseDirectories = true
                        p.canCreateDirectories = true
                        p.begin { response in
                            guard response == .OK else { return }
                            guard let url = p.url else { return }
                            localPath = url.path
                            localPathBookmark = try? url.bookmarkData(
                                options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                                includingResourceValuesForKeys: nil,
                                relativeTo: nil
                            )
                        }
                    }
                }
                if !localPath.isEmpty && localPathBookmark == nil {
                    Text("请点击“选择…”授予沙盒访问权限；拖入或手动输入的路径不能在重启后稳定监控。")
                        .font(.caption2)
                        .foregroundColor(.orange)
                }
            }

            // Remote path
            VStack(alignment: .leading, spacing: 4) {
                Text("远程目标路径").font(.caption).foregroundColor(.secondary)
                TextField("/var/www/html", text: $remotePath).textFieldStyle(.roundedBorder)
            }

            // Exclude patterns
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("排除规则（每行一条，支持 * 通配符）")
                        .font(.caption).foregroundColor(.secondary)
                    Spacer()
                    Button("重置默认") {
                        excludeText = SyncWatcher.defaultExcludePatterns.joined(separator: "\n")
                    }.font(.caption)
                }
                TextEditor(text: $excludeText)
                    .font(.system(.caption, design: .monospaced))
                    .frame(height: 90)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
            }

            Spacer()

            HStack {
                Button("取消") { vm.showAddSheet = false }
                Spacer()
                Button("添加") {
                    let patterns = excludeText.split(separator: "\n")
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                    guard let localPathBookmark else { return }
                    vm.addWatcher(
                        localPath: localPath,
                        localPathBookmark: localPathBookmark,
                        remotePath: remotePath,
                        excludePatterns: patterns
                    )
                    vm.showAddSheet = false
                }
                .buttonStyle(.borderedProminent)
                .disabled(localPath.isEmpty || localPathBookmark == nil || remotePath.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 500, height: 420)
    }
}

private struct FileDropContainer<Content: View>: NSViewRepresentable {
    let onDrop: ([URL]) -> Void
    let content: Content

    init(onDrop: @escaping ([URL]) -> Void, @ViewBuilder content: () -> Content) {
        self.onDrop = onDrop
        self.content = content()
    }

    func makeNSView(context: Context) -> FileDropHostingView<Content> {
        FileDropHostingView(rootView: content, onDrop: onDrop)
    }

    func updateNSView(_ nsView: FileDropHostingView<Content>, context: Context) {
        nsView.rootView = content
        nsView.onDrop = onDrop
    }
}

private final class FileDropHostingView<Root: View>: NSHostingView<Root> {
    var onDrop: ([URL]) -> Void

    init(rootView: Root, onDrop: @escaping ([URL]) -> Void) {
        self.onDrop = onDrop
        super.init(rootView: rootView)
        registerForDraggedTypes([.fileURL])
    }

    @MainActor @preconcurrency required dynamic init(rootView: Root) {
        self.onDrop = { _ in }
        super.init(rootView: rootView)
        registerForDraggedTypes([.fileURL])
    }

    @MainActor @preconcurrency required dynamic init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        Self.fileURLs(from: sender).isEmpty ? [] : .copy
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let urls = Self.fileURLs(from: sender)
        guard !urls.isEmpty else { return false }
        // FIXME(AppSandbox): dropped folders are not durable permissions.
        // Persist a security-scoped bookmark from NSOpenPanel before watching.
        onDrop(urls)
        return true
    }

    private static func fileURLs(from sender: any NSDraggingInfo) -> [URL] {
        sender.draggingPasteboard.pasteboardItems?.compactMap { item in
            item.string(forType: .fileURL)
                .flatMap { URL(string: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        } ?? []
    }
}

private struct RealtimeSyncHeaderGhostButtonStyle: ButtonStyle {
    var foreground: Color = .primary

    func makeBody(configuration: Configuration) -> some View {
        RealtimeSyncHeaderGhostButton(
            configuration: configuration,
            foreground: foreground
        )
    }
}

private struct RealtimeSyncHeaderGhostButton: View {
    let configuration: ButtonStyle.Configuration
    let foreground: Color
    @State private var isHovering = false

    var body: some View {
        configuration.label
            .font(.subheadline)
            .foregroundColor(foreground)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(backgroundColor)
            )
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .onHover { isHovering = $0 }
    }

    private var backgroundColor: Color {
        if configuration.isPressed {
            Color.primary.opacity(0.12)
        } else if isHovering {
            Color.primary.opacity(0.07)
        } else {
            Color.clear
        }
    }
}

// MARK: - Watcher Row
struct WatcherRow: View {
    let watcher: SyncWatcher
    let onToggle: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Toggle("", isOn: .init(get: { watcher.isActive }, set: { _ in onToggle() }))
                .toggleStyle(.switch).labelsHidden()

            VStack(alignment: .leading, spacing: 3) {
                Text(watcher.localPath)
                    .font(.system(size: 12, weight: .medium)).lineLimit(1)
                    .truncationMode(.head)
                HStack(spacing: 4) {
                    Image(systemName: "arrow.right").font(.caption2).foregroundColor(.secondary)
                    Text(watcher.remotePath).font(.caption).foregroundColor(.secondary).lineLimit(1)
                }
                if let last = watcher.lastSyncAt {
                    Text("最后同步：\(last.formatted(date: .omitted, time: .shortened))  ·  共 \(watcher.totalSynced) 次")
                        .font(.caption2).foregroundColor(.secondary)
                }
            }

            Spacer()

            if watcher.isActive {
                HStack(spacing: 3) {
                    Circle().fill(Color.green).frame(width: 6, height: 6)
                    Text("监控中").font(.caption2).foregroundColor(.green)
                }
            }

            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash").foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
    }
}
