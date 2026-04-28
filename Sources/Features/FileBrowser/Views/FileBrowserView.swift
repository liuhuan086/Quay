// FileBrowserView.swift — Dual-pane file browser
import SwiftUI
import AppKit

// MARK: - FileBrowserView
struct FileBrowserView: View {
    let appState: AppState
    let server: ServerConfig
    let primaryClient: any AnyFTPClient

    @StateObject private var localVM  = LocalFileVM()
    @StateObject private var remoteVM: RemoteFileVM

    @State private var showNewFolderRemote = false
    @State private var showRenameRemote: RemoteFileItem?
    @State private var showSyncView = false
    @State private var newName = ""
    @State private var pendingOverwriteFiles: [OverwriteRequest] = []
    @State private var showOverwriteConfirm = false

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
        HSplitView {
            // ── Local pane ──
            FilePane(
                title: "本地", icon: "desktopcomputer",
                path: localVM.currentPath, canGoBack: localVM.canGoBack,
                isLoading: false,
                onBack: { localVM.navigateBack() },
                onRefresh: { localVM.refresh() },
                onNewFolder: nil,
                onOpenExternal: { localVM.openInFinder() }
            ) {
                LocalFileList(vm: localVM)
            }
            .frame(minWidth: 280, idealWidth: 600, maxWidth: .infinity)
            .layoutPriority(1)

            // ── Transfer buttons (center column) ──
            VStack(spacing: 12) {
                Spacer()
                Button { uploadSelected() } label: {
                    Image(systemName: "arrow.right.circle.fill")
                        .font(.system(size: 24))
                        .foregroundColor(.blue)
                }
                .buttonStyle(.plain)
                .help("上传选中文件")

                Button { downloadSelected() } label: {
                    Image(systemName: "arrow.left.circle.fill")
                        .font(.system(size: 24))
                        .foregroundColor(.green)
                }
                .buttonStyle(.plain)
                .help("下载选中文件")
                .disabled(remoteVM.selectedIDs.isEmpty)

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
            .frame(width: 44)
            .background(Color(NSColor.windowBackgroundColor).opacity(0.5))

            // ── Remote pane ──
            FilePane(
                title: server.displayName, icon: server.protocol_.sfSymbol,
                path: remoteVM.currentPath, canGoBack: remoteVM.canGoBack,
                isLoading: remoteVM.isLoading,
                onBack: { Task { await remoteVM.goBack() } },
                onRefresh: { Task { await remoteVM.refresh() } },
                onNewFolder: { showNewFolderRemote = true },
                onOpenExternal: nil
            ) {
                FileDropContainer(onDrop: handleUploadDrop) {
                    RemoteFileList(vm: remoteVM,
                                   onDownload: { downloadSelected() },
                                   onDelete: { Task { await remoteVM.deleteSelected() } },
                                   onRename: { item in showRenameRemote = item })
                }
            }
            .frame(minWidth: 280, idealWidth: 600, maxWidth: .infinity)
            .layoutPriority(1)
        }
        .sheet(isPresented: $showNewFolderRemote) {
            NameInputSheet(title: "新建文件夹", placeholder: "文件夹名称", value: $newName) {
                Task { await remoteVM.createFolder(name: newName); newName = "" }
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

    // MARK: - Upload drop handler
    private func handleUploadDrop(_ urls: [URL]) {
        let remoteBasePath = remoteVM.currentPath
        for url in urls {
            Task { @MainActor in
                let remotePath = remoteBasePath.hasSuffix("/")
                    ? remoteBasePath + url.lastPathComponent
                    : remoteBasePath + "/" + url.lastPathComponent
                await appState.enqueue(server: server, direction: .upload,
                                       localURL: url, remotePath: remotePath)
            }
        }
    }

    // MARK: - Upload selected (local → remote)
    private func uploadSelected() {
        let selected = localVM.sortedItems.filter { localVM.selectedIDs.contains($0.id) && !$0.isDirectory }
        if selected.isEmpty {
            let panel = NSOpenPanel()
            panel.canChooseFiles = true
            panel.canChooseDirectories = false
            panel.allowsMultipleSelection = true
            panel.message = "选择要上传的文件"
            panel.begin { response in
                guard response == .OK else { return }
                processUploadURLs(panel.urls)
            }
        } else {
            processUploadURLs(selected.map(\.url))
        }
    }

    private func processUploadURLs(_ urls: [URL]) {
        let existingNames = Set(remoteVM.sortedItems.map(\.name))
        var directFiles: [(URL, String)] = []
        var conflicts: [OverwriteRequest] = []

        for url in urls {
            let remotePath = remoteVM.currentPath.hasSuffix("/")
                ? remoteVM.currentPath + url.lastPathComponent
                : remoteVM.currentPath + "/" + url.lastPathComponent
            if existingNames.contains(url.lastPathComponent) {
                conflicts.append(OverwriteRequest(localURL: url, remotePath: remotePath,
                                                   direction: .upload, fileName: url.lastPathComponent))
            } else {
                directFiles.append((url, remotePath))
            }
        }

        for (url, remotePath) in directFiles {
            Task {
                await appState.enqueue(server: server, direction: .upload,
                                       localURL: url, remotePath: remotePath)
            }
        }
        if !conflicts.isEmpty {
            pendingOverwriteFiles = conflicts
            showOverwriteConfirm = true
        }
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
struct FilePane<Content: View>: View {
    let title: String
    let icon: String
    let path: String
    let canGoBack: Bool
    let isLoading: Bool
    let onBack: () -> Void
    let onRefresh: () -> Void
    let onNewFolder: (() -> Void)?
    let onOpenExternal: (() -> Void)?
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            // Header
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

            // Breadcrumb
            BreadcrumbBar(path: path, canGoBack: canGoBack, onBack: onBack)

            Divider()
            content()
            Divider()

            // Footer toolbar
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
}

// MARK: - Breadcrumb
struct BreadcrumbBar: View {
    let path: String
    let canGoBack: Bool
    let onBack: () -> Void

    var crumbs: [String] { path.split(separator: "/").map(String.init) }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                Button { onBack() } label: { Image(systemName: "chevron.left").font(.caption) }
                    .buttonStyle(.plain).disabled(!canGoBack).padding(.horizontal, 4)
                Image(systemName: "externaldrive").font(.caption2).foregroundColor(.secondary)
                ForEach(Array(crumbs.enumerated()), id: \.offset) { _, c in
                    Image(systemName: "chevron.right").font(.caption2).foregroundColor(.secondary)
                    Text(c).font(.system(size: 11)).lineLimit(1)
                }
            }
            .padding(.horizontal, 8)
        }
        .frame(height: 26)
        .background(Color(NSColor.windowBackgroundColor).opacity(0.6))
    }
}

// MARK: - Local File List
struct LocalFileList: View {
    @ObservedObject var vm: LocalFileVM

    var body: some View {
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
            if let item = vm.sortedItems.first(where: { ids.contains($0.id) }) {
                if item.isDirectory {
                    Button("打开文件夹") { vm.enter(item) }
                } else {
                    Button("打开文件") { NSWorkspace.shared.open(item.url) }
                }
            }
        } primaryAction: { ids in
            guard let item = vm.sortedItems.first(where: { ids.contains($0.id) }) else { return }
            if item.isDirectory { vm.enter(item) }
            else { NSWorkspace.shared.open(item.url) }
        }
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
