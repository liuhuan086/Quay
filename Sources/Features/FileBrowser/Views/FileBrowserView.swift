// FileBrowserView.swift — Dual-pane file browser
import SwiftUI
import AppKit

private enum BrowserPane: Hashable {
    case local
    case remote
}

enum FilePanePresentation: Equatable {
    case regular
    case compact
}

// MARK: - FileBrowserView
struct FileBrowserView: View {
    let appState: AppState
    let server: ServerConfig
    let primaryClient: any AnyFTPClient
    @AppStorage("showHidden") private var showHidden = false

    @StateObject private var localVM  = LocalFileVM()
    @StateObject private var remoteVM: RemoteFileVM

    @State private var showNewFolderRemote = false
    @State private var showRenameLocal: LocalFileItem?
    @State private var showRenameRemote: RemoteFileItem?
    @State private var showSyncView = false
    @State private var newName = ""
    @State private var pendingOverwriteFiles: [OverwriteRequest] = []
    @State private var showOverwriteConfirm = false
    @State private var compactPane: BrowserPane = .local

    struct OverwriteRequest: Identifiable {
        let id = UUID()
        let localURL: URL
        let remotePath: String
        let direction: TransferDirection
        let fileName: String
    }

    init(appState: AppState, server: ServerConfig, primaryClient: any AnyFTPClient) {
        self.appState = appState
        self.server = server
        self.primaryClient = primaryClient
        _remoteVM = StateObject(wrappedValue: RemoteFileVM(client: primaryClient,
                                                            initialPath: server.initialPath))
    }

    var body: some View {
        GeometryReader { proxy in
            let compact = proxy.size.width < 720
            Group {
                if compact {
                    compactBrowser
                } else {
                    splitBrowser
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $showNewFolderRemote) {
            NameInputSheet(title: "新建文件夹", placeholder: "文件夹名称", value: $newName) {
                Task { await remoteVM.createFolder(name: newName); newName = "" }
            }
        }
        .sheet(item: $showRenameLocal) { item in
            NameInputSheet(title: "重命名", placeholder: item.name, value: $newName) {
                localVM.rename(item: item, to: newName)
                newName = ""
            }
        }
        .sheet(item: $showRenameRemote) { item in
            NameInputSheet(title: "重命名", placeholder: item.name, value: $newName) {
                Task { await remoteVM.rename(item: item, to: newName); newName = "" }
            }
        }
        .sheet(isPresented: $showSyncView) {
            RealtimeSyncView(vm: RealtimeSyncViewModel(appState: appState, server: server))
                .frame(width: 560, height: 500)
        }
        .background(
            TransferCompletionWatcher(serverID: server.id) {
                Task { await remoteVM.refresh() }
                localVM.refresh()
            }
        )
        .onAppear {
            applyShowHidden(showHidden)
            localVM.requestInitialDirectoryAccessIfNeeded()
        }
        .onChange(of: showHidden) { _, newValue in
            applyShowHidden(newValue)
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button {
                    Task { await remoteVM.refresh() }
                    localVM.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .keyboardShortcut("r", modifiers: .command)
                .help("刷新 (⌘R)")
            }
        }
        .alert("文件已存在", isPresented: $showOverwriteConfirm) {
            Button("全部覆盖") {
                for req in pendingOverwriteFiles {
                    Task {
                        await appState.enqueue(server: server, direction: req.direction,
                                               localURL: req.localURL, remotePath: req.remotePath)
                    }
                }
                pendingOverwriteFiles.removeAll()
            }
            Button("取消", role: .cancel) {
                pendingOverwriteFiles.removeAll()
            }
        } message: {
            let names = pendingOverwriteFiles.map(\.fileName).joined(separator: "\n")
            Text("以下文件已存在，是否覆盖？\n\(names)")
        }
    }

    private var splitBrowser: some View {
        HSplitView {
            localPane
                .frame(minWidth: 220, idealWidth: 560, maxWidth: .infinity)
                .layoutPriority(1)

            transferRail

            remotePane
                .frame(minWidth: 220, idealWidth: 560, maxWidth: .infinity)
                .layoutPriority(1)
        }
    }

    private var compactBrowser: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Picker("", selection: $compactPane) {
                    Label("本地", systemImage: "desktopcomputer").tag(BrowserPane.local)
                    Label("远程", systemImage: server.protocol_.sfSymbol).tag(BrowserPane.remote)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Image(systemName: "info.circle")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .help("拉宽窗口可显示本地和远程双栏")
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            Divider()

            Group {
                switch compactPane {
                case .local: localPane(presentation: .compact)
                case .remote: remotePane(presentation: .compact)
                }
            }
            .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func localPane(presentation: FilePanePresentation = .regular) -> some View {
        FilePane(
            title: "本地", icon: "desktopcomputer",
            path: localVM.currentPath, canGoUp: localVM.canGoUp,
            isLoading: false,
            presentation: presentation,
            onUp: { localVM.navigateUp() },
            onNavigate: { localVM.navigate(to: $0) },
            onRefresh: { localVM.refresh() },
            onNewFolder: nil,
            onOpenExternal: { localVM.openInFinder() },
            toolbarActions: {
                if presentation == .compact {
                    compactPaneActions(for: .local)
                }
            }
        ) {
            LocalFileList(vm: localVM,
                          onUpload: { uploadLocalItems($0) },
                          onDelete: { localVM.delete($0) },
                          onRename: { item in
                              newName = item.name
                              showRenameLocal = item
                          })
        }
    }

    private func remotePane(presentation: FilePanePresentation = .regular) -> some View {
        FilePane(
            title: server.displayName, icon: server.protocol_.sfSymbol,
            path: remoteVM.currentPath, canGoUp: remoteVM.canGoUp,
            isLoading: remoteVM.isLoading,
            presentation: presentation,
            onUp: { Task { await remoteVM.goUp() } },
            onNavigate: { path in Task { await remoteVM.navigate(to: path) } },
            onRefresh: { Task { await remoteVM.refresh() } },
            onNewFolder: { showNewFolderRemote = true },
            onOpenExternal: nil,
            toolbarActions: {
                if presentation == .compact {
                    compactPaneActions(for: .remote)
                }
            }
        ) {
            FileDropContainer(onDrop: handleUploadDrop) {
                RemoteFileList(vm: remoteVM,
                               onDownload: { downloadSelected() },
                               onDelete: { Task { await remoteVM.deleteSelected() } },
                               onRename: { item in showRenameRemote = item })
            }
        }
    }

    private var localPane: some View {
        localPane()
    }

    private var remotePane: some View {
        remotePane()
    }

    private var transferRail: some View {
        let uploadActive = !localVM.selectedIDs.isEmpty
        let downloadActive = !remoteVM.selectedIDs.isEmpty

        return VStack(spacing: 12) {
            Spacer()
            transferButton(systemImage: "arrow.right.circle.fill",
                           color: .blue,
                           isActive: uploadActive,
                           help: "上传选中文件",
                           action: uploadSelected)
                .disabled(!uploadActive)
            transferButton(systemImage: "arrow.left.circle.fill",
                           color: .green,
                           isActive: downloadActive,
                           help: "下载选中文件",
                           action: downloadSelected)
                .disabled(!downloadActive)

            Divider().frame(width: 24)

            Button { showSyncView = true } label: {
                Image(systemName: "arrow.triangle.2.circlepath.circle")
                    .font(.system(size: 20))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help("自动同步设置")

            Spacer()
        }
        .frame(width: 40)
        .background(Color(NSColor.windowBackgroundColor).opacity(0.5))
    }

    @ViewBuilder
    private func compactPaneActions(for pane: BrowserPane) -> some View {
        let uploadActive = pane == .local && !localVM.selectedIDs.isEmpty
        let downloadActive = pane == .remote && !remoteVM.selectedIDs.isEmpty

        HStack(spacing: 5) {
            Divider().frame(height: 16)
            paneActionButton(systemImage: "arrow.up.circle",
                             isActive: uploadActive,
                             help: "上传选中文件",
                             action: uploadSelected)
                .disabled(!uploadActive)
            paneActionButton(systemImage: "arrow.down.circle",
                             isActive: downloadActive,
                             help: "下载选中文件",
                             action: downloadSelected)
                .disabled(!downloadActive)
            Button { showSyncView = true } label: {
                Image(systemName: "arrow.triangle.2.circlepath.circle")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.secondary)
                    .frame(width: 22, height: 18)
            }
            .buttonStyle(.plain)
            .help("自动同步设置")
        }
    }

    private func transferButton(systemImage: String,
                                color: Color,
                                isActive: Bool = true,
                                help: String,
                                action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 22))
                .foregroundStyle(isActive ? color : Color.secondary.opacity(0.45))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func paneActionButton(systemImage: String,
                                  isActive: Bool,
                                  help: String,
                                  action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(isActive ? Color(nsColor: .systemBlue) : Color.secondary.opacity(0.55))
                .frame(width: 21, height: 18)
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func applyShowHidden(_ value: Bool) {
        localVM.showHidden = value
        remoteVM.showHidden = value
    }

    // MARK: - Upload drop handler
    private func handleUploadDrop(_ urls: [URL]) {
        uploadLocalURLs(urls)
    }

    // MARK: - Upload selected (local → remote)
    private func uploadSelected() {
        let selected = localVM.sortedItems.filter { localVM.selectedIDs.contains($0.id) }
        if selected.isEmpty {
            let panel = NSOpenPanel()
            panel.canChooseFiles = true
            panel.canChooseDirectories = true
            panel.allowsMultipleSelection = true
            panel.message = "选择要上传的文件或文件夹"
            panel.begin { response in
                guard response == .OK else { return }
                uploadLocalURLs(panel.urls)
            }
        } else {
            uploadLocalItems(selected)
        }
    }

    private func uploadLocalItems(_ items: [LocalFileItem]) {
        uploadLocalURLs(items.map(\.url))
    }

    private func uploadLocalURLs(_ urls: [URL]) {
        Task { await processUploadURLs(urls) }
    }

    @MainActor
    private func processUploadURLs(_ urls: [URL]) async {
        let existingNames = Set(remoteVM.sortedItems.map(\.name))
        var directFiles: [(URL, String, String)] = []
        var conflicts: [OverwriteRequest] = []

        for url in urls {
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            let remotePath = remotePath(appending: url.lastPathComponent, to: remoteVM.currentPath)
            if isDirectory {
                await enqueueDirectoryUpload(localURL: url, remoteDirectoryPath: remotePath)
                continue
            }
            if existingNames.contains(url.lastPathComponent) {
                conflicts.append(OverwriteRequest(localURL: url, remotePath: remotePath,
                                                   direction: .upload, fileName: url.lastPathComponent))
            } else {
                directFiles.append((url, remotePath, url.lastPathComponent))
            }
        }

        for (url, remotePath, _) in directFiles {
            await appState.enqueue(server: server, direction: .upload,
                                   localURL: url, remotePath: remotePath)
        }
        if !conflicts.isEmpty {
            pendingOverwriteFiles = conflicts
            showOverwriteConfirm = true
        }
    }

    @MainActor
    private func enqueueDirectoryUpload(localURL: URL, remoteDirectoryPath: String) async {
        await createRemoteDirectoryIfNeeded(remoteDirectoryPath)
        let entries = directoryUploadEntries(for: localURL)

        for entry in entries {
            let childRemotePath = remotePath(appending: entry.relativePath, to: remoteDirectoryPath)
            if entry.isDirectory {
                await createRemoteDirectoryIfNeeded(childRemotePath)
            } else {
                await appState.enqueue(server: server, direction: .upload,
                                       localURL: entry.url, remotePath: childRemotePath)
            }
        }
    }

    private func directoryUploadEntries(for rootURL: URL) -> [(url: URL, isDirectory: Bool, relativePath: String)] {
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: showHidden ? [] : [.skipsHiddenFiles]
        ) else { return [] }

        var entries: [(URL, Bool, String)] = []
        for case let childURL as URL in enumerator {
            let isDirectory = (try? childURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            let relativePath = childURL.path
                .replacingOccurrences(of: rootURL.path + "/", with: "")
            if isDirectory {
                entries.append((childURL, true, relativePath))
            } else {
                entries.append((childURL, false, relativePath))
            }
        }
        return entries
    }

    private func createRemoteDirectoryIfNeeded(_ path: String) async {
        do {
            try await primaryClient.createDirectory(path)
        } catch {
            // Existing directories are fine. Later file uploads will surface real path errors.
        }
    }

    private func remotePath(appending component: String, to basePath: String) -> String {
        let trimmedComponent = component.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !trimmedComponent.isEmpty else { return basePath.isEmpty ? "/" : basePath }
        if basePath.isEmpty || basePath == "/" {
            return "/" + trimmedComponent
        }
        return basePath.hasSuffix("/") ? basePath + trimmedComponent : basePath + "/" + trimmedComponent
    }

    // MARK: - Download selected
    private func downloadSelected() {
        let selected = remoteVM.sortedItems.filter { remoteVM.selectedIDs.contains($0.id) }
        let destinationDir = URL(fileURLWithPath: localVM.currentPath, isDirectory: true)

        var directFiles: [(URL, String)] = []
        var conflicts: [OverwriteRequest] = []

        for item in selected where !item.isDirectory {
            let localURL = destinationDir.appendingPathComponent(item.name)
            if FileManager.default.fileExists(atPath: localURL.path) {
                conflicts.append(OverwriteRequest(localURL: localURL, remotePath: item.path,
                                                   direction: .download, fileName: item.name))
            } else {
                directFiles.append((localURL, item.path))
            }
        }

        for (localURL, remotePath) in directFiles {
            Task {
                await appState.enqueue(server: server, direction: .download,
                                       localURL: localURL, remotePath: remotePath)
            }
        }
        if !conflicts.isEmpty {
            pendingOverwriteFiles = conflicts
            showOverwriteConfirm = true
        }
    }
}

// MARK: - Transfer Completion Watcher
private struct TransferCompletionWatcher: View {
    @EnvironmentObject var appState: AppState
    let serverID: UUID
    let onComplete: () -> Void

    var body: some View {
        Color.clear.onChange(of: appState.lastCompletedTransferServerID) { _, newVal in
            if newVal == serverID { onComplete() }
        }
    }
}

// MARK: - Generic File Pane
struct FilePane<Content: View, ToolbarActions: View>: View {
    let title: String
    let icon: String
    let path: String
    let canGoUp: Bool
    let isLoading: Bool
    let presentation: FilePanePresentation
    let onUp: () -> Void
    let onNavigate: (String) -> Void
    let onRefresh: () -> Void
    let onNewFolder: (() -> Void)?
    let onOpenExternal: (() -> Void)?
    @ViewBuilder let toolbarActions: () -> ToolbarActions
    @ViewBuilder let content: () -> Content

    init(title: String,
         icon: String,
         path: String,
         canGoUp: Bool,
         isLoading: Bool,
         presentation: FilePanePresentation = .regular,
         onUp: @escaping () -> Void,
         onNavigate: @escaping (String) -> Void,
         onRefresh: @escaping () -> Void,
         onNewFolder: (() -> Void)?,
         onOpenExternal: (() -> Void)?,
         @ViewBuilder toolbarActions: @escaping () -> ToolbarActions,
         @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.icon = icon
        self.path = path
        self.canGoUp = canGoUp
        self.isLoading = isLoading
        self.presentation = presentation
        self.onUp = onUp
        self.onNavigate = onNavigate
        self.onRefresh = onRefresh
        self.onNewFolder = onNewFolder
        self.onOpenExternal = onOpenExternal
        self.toolbarActions = toolbarActions
        self.content = content
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            if presentation == .regular {
                HStack(spacing: 6) {
                    Image(systemName: icon).foregroundColor(.secondary).font(.system(size: 12))
                    Text(title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    Spacer()
                    if isLoading {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 16, height: 16)
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Color(NSColor.controlBackgroundColor))
            }

            // Breadcrumb
            HStack(spacing: 8) {
                BreadcrumbBar(path: path, canGoUp: canGoUp, onUp: onUp, onNavigate: onNavigate)
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                if presentation == .compact && isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 16, height: 16)
                }
                toolbarActions()
            }
            .padding(.trailing, 10)
            .frame(height: 26)
            .background(Color(NSColor.windowBackgroundColor).opacity(0.6))

            Divider()
            content()

            if presentation == .regular {
                Divider()
                footerToolbar
            }
        }
    }

    private var footerToolbar: some View {
        HStack(spacing: 8) {
            Button { onRefresh() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.plain).help("刷新 (⌘R)")
            if let nf = onNewFolder {
                Button { nf() } label: { Image(systemName: "folder.badge.plus") }
                    .buttonStyle(.plain).help("新建文件夹")
            }
            if let ext = onOpenExternal {
                Button { ext() } label: { Image(systemName: "arrow.up.right.square") }
                    .buttonStyle(.plain).help("在 Finder 中打开")
            }
            Spacer()
            Text(path).font(.system(size: 10, design: .monospaced))
                .foregroundColor(.secondary).lineLimit(1).truncationMode(.head)
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Color(NSColor.controlBackgroundColor))
    }
}

extension FilePane where ToolbarActions == EmptyView {
    init(title: String,
         icon: String,
         path: String,
         canGoUp: Bool,
         isLoading: Bool,
         presentation: FilePanePresentation = .regular,
         onUp: @escaping () -> Void,
         onNavigate: @escaping (String) -> Void,
         onRefresh: @escaping () -> Void,
         onNewFolder: (() -> Void)?,
         onOpenExternal: (() -> Void)?,
         @ViewBuilder content: @escaping () -> Content) {
        self.init(title: title,
                  icon: icon,
                  path: path,
                  canGoUp: canGoUp,
                  isLoading: isLoading,
                  presentation: presentation,
                  onUp: onUp,
                  onNavigate: onNavigate,
                  onRefresh: onRefresh,
                  onNewFolder: onNewFolder,
                  onOpenExternal: onOpenExternal,
                  toolbarActions: { EmptyView() },
                  content: content)
    }
}

// MARK: - Breadcrumb
struct BreadcrumbBar: View {
    let path: String
    let canGoUp: Bool
    let onUp: () -> Void
    let onNavigate: (String) -> Void

    var crumbs: [(name: String, path: String)] {
        let parts = path.split(separator: "/").map(String.init)
        var current = ""
        return parts.map { part in
            current += "/" + part
            return (part, current)
        }
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                Button { onUp() } label: { Image(systemName: "chevron.left").font(.caption) }
                    .buttonStyle(.plain)
                    .disabled(!canGoUp)
                    .padding(.horizontal, 4)
                    .help("上一级")
                Button { onNavigate("/") } label: {
                    Image(systemName: "externaldrive")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("根目录")
                ForEach(Array(crumbs.enumerated()), id: \.offset) { _, crumb in
                    Image(systemName: "chevron.right").font(.caption2).foregroundColor(.secondary)
                    Button { onNavigate(crumb.path) } label: {
                        Text(crumb.name).font(.system(size: 11)).lineLimit(1)
                    }
                    .buttonStyle(.plain)
                    .help(crumb.path)
                }
            }
            .padding(.horizontal, 8)
        }
        .frame(height: 26)
    }
}

// MARK: - Local File List
struct LocalFileList: View {
    @ObservedObject var vm: LocalFileVM
    let onUpload: ([LocalFileItem]) -> Void
    let onDelete: ([LocalFileItem]) -> Void
    let onRename: (LocalFileItem) -> Void

    var body: some View {
        Group {
            if let errorMessage = vm.errorMessage {
                VStack(spacing: 10) {
                    Image(systemName: "folder.badge.questionmark")
                        .font(.title)
                        .foregroundColor(.secondary)
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(4)
                        .frame(maxWidth: 360)
                    HStack(spacing: 10) {
                        Button("选择授权目录") { vm.requestDirectoryAccess() }
                            .buttonStyle(.borderedProminent)
                        Button("重试") { vm.refresh() }
                            .buttonStyle(.bordered)
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                localTable
            }
        }
    }

    private var localTable: some View {
        Table(vm.sortedItems, selection: $vm.selectedIDs) {
            TableColumn("名称") { item in
                Label(item.name, systemImage: item.sfSymbol)
                    .font(.system(size: 12))
                    .help(item.name)
            }
            TableColumn("大小") { Text($0.displaySize).font(.system(size: 11)).foregroundColor(.secondary) }
                .width(80)
            TableColumn("修改日期") { item in
                Text(item.modifiedDate?.formatted(date: .abbreviated, time: .shortened) ?? "—")
                    .font(.system(size: 11)).foregroundColor(.secondary)
            }.width(130)
        }
        .contextMenu(forSelectionType: UUID.self) { ids in
            let items = selectedItems(for: ids)
            if let item = items.first {
                Button("上传") { onUpload(items) }
                if items.count == 1 {
                    if item.isDirectory {
                        Button("打开文件夹") { vm.enter(item) }
                    } else {
                        Button("打开文件") {
                            NSWorkspace.shared.open(item.url)
                        }
                    }
                    Button("重命名") { onRename(item) }
                }
                Divider()
                Button("删除", role: .destructive) { onDelete(items) }
            }
        } primaryAction: { ids in
            guard let item = vm.sortedItems.first(where: { ids.contains($0.id) }) else { return }
            if item.isDirectory { vm.enter(item) }
            else {
                NSWorkspace.shared.open(item.url)
            }
        }
    }

    private func selectedItems(for ids: Set<UUID>) -> [LocalFileItem] {
        vm.sortedItems.filter { ids.contains($0.id) }
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
        // FIXME(AppSandbox): call startAccessingSecurityScopedResource()
        // for dropped file URLs before reading them.
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

// MARK: - Remote File List
struct RemoteFileList: View {
    @ObservedObject var vm: RemoteFileVM
    let onDownload: () -> Void
    let onDelete: () -> Void
    let onRename: (RemoteFileItem) -> Void

    var body: some View {
        Group {
            if let err = vm.errorMessage {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle").font(.title).foregroundColor(.red)
                    Text(err).font(.caption).foregroundColor(.secondary).multilineTextAlignment(.center)
                    Button("重试") { Task { await vm.refresh() } }
                }
                .padding()
            } else {
                Table(vm.sortedItems, selection: $vm.selectedIDs) {
                    TableColumn("名称") { item in
                        Label(item.name, systemImage: item.sfSymbol)
                            .font(.system(size: 12)).help(item.name)
                    }
                    TableColumn("大小") { Text($0.displaySize).font(.system(size: 11)).foregroundColor(.secondary) }
                        .width(80)
                    TableColumn("权限") { Text($0.permissions).font(.system(size: 11, design: .monospaced)).foregroundColor(.secondary) }
                        .width(90)
                    TableColumn("修改日期") { item in
                        Text(item.modifiedDate?.formatted(date: .abbreviated, time: .shortened) ?? "—")
                            .font(.system(size: 11)).foregroundColor(.secondary)
                    }.width(130)
                }
                .contextMenu(forSelectionType: UUID.self) { ids in
                    if !ids.isEmpty {
                        Button("下载") { onDownload() }
                        if ids.count == 1, let item = vm.sortedItems.first(where: { ids.contains($0.id) }) {
                            if item.isDirectory {
                                Button("打开文件夹") { Task { await vm.enter(item) } }
                            }
                            Button("重命名") { onRename(item) }
                        }
                        Divider()
                        Button("删除", role: .destructive) { onDelete() }
                    }
                } primaryAction: { ids in
                    guard let item = vm.sortedItems.first(where: { ids.contains($0.id) }),
                          item.isDirectory else { return }
                    Task { await vm.enter(item) }
                }
            }
        }
    }
}

// MARK: - Name Input Sheet
struct NameInputSheet: View {
    let title: String
    let placeholder: String
    @Binding var value: String
    let onConfirm: () -> Void
    @Environment(\.dismiss) var dismiss

    var body: some View {
        VStack(spacing: 16) {
            Text(title).font(.headline)
            TextField(placeholder, text: $value).textFieldStyle(.roundedBorder).onSubmit { confirm() }
            HStack {
                Button("取消") { dismiss() }
                Spacer()
                Button("确定") { confirm() }.buttonStyle(.borderedProminent).disabled(value.isEmpty)
            }
        }
        .padding(24).frame(width: 300)
    }

    private func confirm() { onConfirm(); dismiss() }
}
