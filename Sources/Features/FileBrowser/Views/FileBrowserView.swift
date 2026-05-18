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
    @StateObject private var syncVM: RealtimeSyncViewModel

    @State private var showNewFolderRemote = false
    @State private var showRenameLocal: LocalFileItem?
    @State private var showRenameRemote: RemoteFileItem?
    @State private var showSyncView = false
    @State private var newName = ""
    @State private var pendingTransferPlan: TransferPlan?
    @State private var showOverwriteConfirm = false
    @State private var compactPane: BrowserPane = .local

    struct TransferRequest: Identifiable {
        let id = UUID()
        let localURL: URL
        let remotePath: String
        let direction: TransferDirection
        let fileName: String
        let fileSize: Int64?
        let batchID: UUID?
        let securityScopedURL: URL?
    }

    struct DirectoryPreparation {
        let localURL: URL?
        let remotePath: String?
        let batchID: UUID?
    }

    struct TransferPlan {
        var ready: [TransferRequest] = []
        var conflicts: [TransferRequest] = []
        var directories: [DirectoryPreparation] = []
        var blockedMessages: [String] = []

        var allBatchIDs: Set<UUID> {
            Set(
                ready.compactMap(\.batchID) +
                conflicts.compactMap(\.batchID) +
                directories.compactMap(\.batchID)
            )
        }

        var conflictBatchIDs: Set<UUID> {
            Set(conflicts.compactMap(\.batchID))
        }

        var hasWork: Bool {
            !ready.isEmpty || !conflicts.isEmpty || !directories.isEmpty
        }

        mutating func merge(_ other: TransferPlan) {
            ready.append(contentsOf: other.ready)
            conflicts.append(contentsOf: other.conflicts)
            directories.append(contentsOf: other.directories)
            blockedMessages.append(contentsOf: other.blockedMessages)
        }
    }

    init(appState: AppState, server: ServerConfig, primaryClient: any AnyFTPClient) {
        self.appState = appState
        self.server = server
        self.primaryClient = primaryClient
        _remoteVM = StateObject(wrappedValue: RemoteFileVM(client: primaryClient,
                                                            initialPath: server.initialPath))
        _syncVM = StateObject(wrappedValue: RealtimeSyncViewModel(appState: appState, server: server))
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
            RealtimeSyncView(vm: syncVM)
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
                        .resizable()
                        .scaledToFit()
                        .frame(width: 13, height: 13)
                        .frame(width: 18, height: 18)
                }
                .controlSize(.small)
                .keyboardShortcut("r", modifiers: .command)
                .help("刷新 (⌘R)")
            }
        }
        .alert("文件已存在", isPresented: $showOverwriteConfirm) {
            Button("全部覆盖") {
                guard let plan = pendingTransferPlan else { return }
                Task { @MainActor in
                    await commitTransferPlan(plan, includingConflicts: true)
                    pendingTransferPlan = nil
                }
            }
            Button("跳过同名") {
                guard let plan = pendingTransferPlan else { return }
                Task { @MainActor in
                    await commitTransferPlan(plan, includingConflicts: false)
                    pendingTransferPlan = nil
                }
            }
            Button("停止", role: .cancel) {
                if let plan = pendingTransferPlan {
                    discardPendingTransferPlan(plan)
                }
                pendingTransferPlan = nil
            }
        } message: {
            Text(overwriteMessage)
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

            compactDestinationBar(for: compactPane)

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
                               onDownload: { downloadRemoteItems($0) },
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
            if pane == .local {
                Button { localVM.openInFinder() } label: {
                    Image(systemName: "arrow.up.right.circle")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.secondary)
                        .frame(width: 22, height: 18)
                }
                .buttonStyle(.plain)
                .help("在 Finder 中打开")
            }
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

    private func compactDestinationBar(for pane: BrowserPane) -> some View {
        HStack(spacing: 6) {
            Image(systemName: pane == .local ? "arrow.up.right" : "arrow.down.left")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 14)
            Text(pane == .local ? "上传到" : "下载到")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(pane == .local ? remoteVM.currentPath : localVM.currentPath)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            if pane == .local {
                Button {
                    compactPane = .remote
                } label: {
                    Image(systemName: "folder")
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
                .help("切换到远程目录")
            } else {
                Button {
                    localVM.requestDirectoryAccess()
                } label: {
                    Image(systemName: "folder.badge.gearshape")
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
                .help("选择本地下载目录")
                Button {
                    compactPane = .local
                } label: {
                    Image(systemName: "desktopcomputer")
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
                .help("切换到本地目录")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 24)
        .background(Color(NSColor.windowBackgroundColor).opacity(0.72))
    }

    private func applyShowHidden(_ value: Bool) {
        localVM.showHidden = value
        remoteVM.showHidden = value
    }

    // MARK: - Unified transfer planning
    private func handleUploadDrop(_ urls: [URL]) {
        uploadLocalURLs(urls)
    }

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
        Task { await prepareUploadURLs(urls) }
    }

    @MainActor
    private func prepareUploadURLs(_ urls: [URL]) async {
        guard !urls.isEmpty else { return }
        let cache = RemoteDirectoryCache(client: primaryClient)
        var plan = TransferPlan()

        for url in urls {
            let didStartAccessing = url.startAccessingSecurityScopedResource()
            let itemPlan = await uploadPlan(
                for: url,
                destinationDirectory: remoteVM.currentPath,
                cache: cache,
                securityScopedURL: url
            )
            if didStartAccessing {
                url.stopAccessingSecurityScopedResource()
            }
            plan.merge(itemPlan)
        }

        await presentOrCommitTransferPlan(plan)
    }

    @MainActor
    private func uploadPlan(
        for localURL: URL,
        destinationDirectory: String,
        cache: RemoteDirectoryCache,
        securityScopedURL: URL?
    ) async -> TransferPlan {
        var plan = TransferPlan()
        let isDirectory = localURLIsDirectory(localURL)
        let destinationPath = remotePath(appending: localURL.lastPathComponent, to: destinationDirectory)

        do {
            let existing = try await cache.item(named: localURL.lastPathComponent, in: destinationDirectory)
            if isDirectory {
                if let existing, !existing.isDirectory {
                    plan.blockedMessages.append("远端已存在同名文件，无法上传文件夹：\(destinationPath)")
                    return plan
                }

                let batchID = appState.beginTransferBatch(
                    server: server,
                    direction: .upload,
                    name: localURL.lastPathComponent,
                    localRootURL: localURL,
                    remoteRootPath: destinationPath
                )
                let result = await uploadDirectoryPlan(
                    localURL: localURL,
                    remoteDirectoryPath: destinationPath,
                    remoteDirectoryExists: existing?.isDirectory == true,
                    batchID: batchID,
                    cache: cache,
                    securityScopedURL: securityScopedURL
                )
                appState.finishTransferBatch(id: batchID, expectedFileCount: result.fileCount)
                plan.merge(result.plan)
            } else {
                let request = TransferRequest(
                    localURL: localURL,
                    remotePath: destinationPath,
                    direction: .upload,
                    fileName: localURL.lastPathComponent,
                    fileSize: localFileSize(localURL),
                    batchID: nil,
                    securityScopedURL: securityScopedURL
                )
                if let existing {
                    if existing.isDirectory {
                        plan.blockedMessages.append("远端已存在同名文件夹，无法覆盖为文件：\(destinationPath)")
                    } else {
                        plan.conflicts.append(request)
                    }
                } else {
                    plan.ready.append(request)
                }
            }
        } catch {
            plan.blockedMessages.append("无法检查远端目录：\(destinationDirectory)。\(friendlyMessage(error))")
        }
        return plan
    }

    private struct DirectoryPlanResult {
        var plan = TransferPlan()
        var fileCount = 0
    }

    @MainActor
    private func uploadDirectoryPlan(
        localURL: URL,
        remoteDirectoryPath: String,
        remoteDirectoryExists: Bool,
        batchID: UUID,
        cache: RemoteDirectoryCache,
        securityScopedURL: URL?
    ) async -> DirectoryPlanResult {
        var result = DirectoryPlanResult()
        result.plan.directories.append(
            DirectoryPreparation(localURL: nil, remotePath: remoteDirectoryPath, batchID: batchID)
        )

        let children: [URL]
        do {
            children = try FileManager.default.contentsOfDirectory(
                at: localURL,
                includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
                options: showHidden ? [] : [.skipsHiddenFiles]
            )
        } catch {
            result.plan.blockedMessages.append("无法读取本地文件夹：\(localURL.path)。\(error.localizedDescription)")
            return result
        }

        var existingItems: [String: RemoteFileItem] = [:]
        if remoteDirectoryExists {
            do {
                existingItems = try await cache.itemsByName(in: remoteDirectoryPath)
            } catch {
                result.plan.blockedMessages.append("无法检查远端文件夹：\(remoteDirectoryPath)。\(friendlyMessage(error))")
                return result
            }
        }

        for childURL in children {
            let name = childURL.lastPathComponent
            let childRemotePath = remotePath(appending: name, to: remoteDirectoryPath)
            let childIsDirectory = localURLIsDirectory(childURL)
            let existing = existingItems[name]

            if childIsDirectory {
                if let existing, !existing.isDirectory {
                    result.plan.blockedMessages.append("远端已存在同名文件，无法上传文件夹：\(childRemotePath)")
                    continue
                }
                let childResult = await uploadDirectoryPlan(
                    localURL: childURL,
                    remoteDirectoryPath: childRemotePath,
                    remoteDirectoryExists: existing?.isDirectory == true,
                    batchID: batchID,
                    cache: cache,
                    securityScopedURL: securityScopedURL
                )
                result.fileCount += childResult.fileCount
                result.plan.merge(childResult.plan)
            } else {
                result.fileCount += 1
                let request = TransferRequest(
                    localURL: childURL,
                    remotePath: childRemotePath,
                    direction: .upload,
                    fileName: name,
                    fileSize: localFileSize(childURL),
                    batchID: batchID,
                    securityScopedURL: securityScopedURL
                )
                if let existing {
                    if existing.isDirectory {
                        result.plan.blockedMessages.append("远端已存在同名文件夹，无法覆盖为文件：\(childRemotePath)")
                    } else {
                        result.plan.conflicts.append(request)
                    }
                } else {
                    result.plan.ready.append(request)
                }
            }
        }
        return result
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

    private func downloadSelected() {
        let selected = remoteVM.sortedItems.filter { remoteVM.selectedIDs.contains($0.id) }
        downloadRemoteItems(selected)
    }

    private func downloadRemoteItems(_ selected: [RemoteFileItem]) {
        Task { await prepareDownloadItems(selected) }
    }

    @MainActor
    private func prepareDownloadItems(_ selected: [RemoteFileItem]) async {
        guard !selected.isEmpty else { return }
        let destinationDir = URL(fileURLWithPath: localVM.currentPath, isDirectory: true)
        var plan = TransferPlan()

        for item in selected {
            let itemPlan = await downloadPlan(for: item, destinationParentURL: destinationDir)
            plan.merge(itemPlan)
        }

        await presentOrCommitTransferPlan(plan)
    }

    @MainActor
    private func downloadPlan(
        for item: RemoteFileItem,
        destinationParentURL: URL
    ) async -> TransferPlan {
        var plan = TransferPlan()
        let localURL = destinationParentURL.appendingPathComponent(item.name, isDirectory: item.isDirectory)

        if item.isDirectory {
            switch localDestinationState(for: localURL) {
            case .file:
                plan.blockedMessages.append("本地已存在同名文件，无法下载文件夹：\(localURL.path)")
                return plan
            case .directory, .missing:
                let batchID = appState.beginTransferBatch(
                    server: server,
                    direction: .download,
                    name: item.name,
                    localRootURL: localURL,
                    remoteRootPath: item.path
                )
                let result = await downloadDirectoryPlan(
                    remoteItem: item,
                    destinationParentURL: destinationParentURL,
                    batchID: batchID
                )
                appState.finishTransferBatch(id: batchID, expectedFileCount: result.fileCount)
                plan.merge(result.plan)
            }
        } else {
            let request = TransferRequest(
                localURL: localURL,
                remotePath: item.path,
                direction: .download,
                fileName: item.name,
                fileSize: item.size,
                batchID: nil,
                securityScopedURL: nil
            )
            switch localDestinationState(for: localURL) {
            case .directory:
                plan.blockedMessages.append("本地已存在同名文件夹，无法覆盖为文件：\(localURL.path)")
            case .file:
                plan.conflicts.append(request)
            case .missing:
                plan.ready.append(request)
            }
        }
        return plan
    }

    @MainActor
    private func downloadDirectoryPlan(
        remoteItem: RemoteFileItem,
        destinationParentURL: URL,
        batchID: UUID
    ) async -> DirectoryPlanResult {
        let localDirectoryURL = destinationParentURL.appendingPathComponent(remoteItem.name, isDirectory: true)
        var result = DirectoryPlanResult()
        result.plan.directories.append(
            DirectoryPreparation(localURL: localDirectoryURL, remotePath: nil, batchID: batchID)
        )

        do {
            let children = try await primaryClient.listDirectory(remoteItem.path)
            for child in children {
                let childLocalURL = localDirectoryURL.appendingPathComponent(child.name, isDirectory: child.isDirectory)
                if child.isDirectory {
                    if case .file = localDestinationState(for: childLocalURL) {
                        result.plan.blockedMessages.append("本地已存在同名文件，无法下载文件夹：\(childLocalURL.path)")
                        continue
                    }
                    let childResult = await downloadDirectoryPlan(
                        remoteItem: child,
                        destinationParentURL: localDirectoryURL,
                        batchID: batchID
                    )
                    result.fileCount += childResult.fileCount
                    result.plan.merge(childResult.plan)
                } else {
                    result.fileCount += 1
                    let request = TransferRequest(
                        localURL: childLocalURL,
                        remotePath: child.path,
                        direction: .download,
                        fileName: child.name,
                        fileSize: child.size,
                        batchID: batchID,
                        securityScopedURL: nil
                    )
                    switch localDestinationState(for: childLocalURL) {
                    case .directory:
                        result.plan.blockedMessages.append("本地已存在同名文件夹，无法覆盖为文件：\(childLocalURL.path)")
                    case .file:
                        result.plan.conflicts.append(request)
                    case .missing:
                        result.plan.ready.append(request)
                    }
                }
            }
        } catch {
            result.plan.blockedMessages.append("无法读取远端文件夹：\(remoteItem.path)。\(friendlyMessage(error))")
        }
        return result
    }

    @MainActor
    private func presentOrCommitTransferPlan(_ plan: TransferPlan) async {
        guard plan.hasWork else {
            showTransferPlanWarnings(plan.blockedMessages)
            return
        }

        if plan.conflicts.isEmpty {
            await commitTransferPlan(plan, includingConflicts: true)
        } else {
            pendingTransferPlan = plan
            showOverwriteConfirm = true
        }
    }

    @MainActor
    private func commitTransferPlan(_ plan: TransferPlan, includingConflicts: Bool) async {
        await prepareDirectories(plan.directories)

        let acceptedRequests = plan.ready + (includingConflicts ? plan.conflicts : [])
        updateBatchExpectedCounts(for: plan, acceptedRequests: acceptedRequests)
        for request in acceptedRequests {
            await appState.enqueue(
                server: server,
                direction: request.direction,
                localURL: request.localURL,
                remotePath: request.remotePath,
                fileSize: request.fileSize,
                batchID: request.batchID,
                securityScopedURL: request.securityScopedURL
            )
        }

        if !includingConflicts {
            appState.discardEmptyTransferBatches(ids: plan.conflictBatchIDs)
        }
        showTransferPlanWarnings(plan.blockedMessages)
    }

    private func updateBatchExpectedCounts(
        for plan: TransferPlan,
        acceptedRequests: [TransferRequest]
    ) {
        var acceptedCountsByBatchID: [UUID: Int] = [:]
        for request in acceptedRequests {
            guard let batchID = request.batchID else { continue }
            acceptedCountsByBatchID[batchID, default: 0] += 1
        }
        for batchID in plan.allBatchIDs {
            appState.finishTransferBatch(
                id: batchID,
                expectedFileCount: acceptedCountsByBatchID[batchID, default: 0]
            )
        }
    }

    @MainActor
    private func prepareDirectories(_ directories: [DirectoryPreparation]) async {
        var remotePaths = Set<String>()
        var localURLs = Set<URL>()

        for directory in directories {
            if let localURL = directory.localURL, localURLs.insert(localURL).inserted {
                do {
                    try FileManager.default.createDirectory(
                        at: localURL,
                        withIntermediateDirectories: true
                    )
                } catch {
                    appState.alertItem = AlertItem(
                        title: "创建本地文件夹失败",
                        message: "\(localURL.path)：\(error.localizedDescription)"
                    )
                }
            }
            if let remotePath = directory.remotePath, remotePaths.insert(remotePath).inserted {
                await createRemoteDirectoryIfNeeded(remotePath)
            }
        }
    }

    private var overwriteMessage: String {
        guard let plan = pendingTransferPlan else { return "" }
        let names = plan.conflicts.prefix(12).map { request in
            request.direction == .upload ? request.remotePath : request.localURL.path
        }.joined(separator: "\n")
        let moreCount = max(0, plan.conflicts.count - 12)
        var lines = ["以下项目已存在，是否覆盖？", names]
        if moreCount > 0 {
            lines.append("另有 \(moreCount) 项未显示")
        }
        if !plan.ready.isEmpty {
            lines.append("未同名的 \(plan.ready.count) 项会在确认后一起加入队列。")
        }
        if !plan.blockedMessages.isEmpty {
            lines.append("另有 \(plan.blockedMessages.count) 项无法自动处理。")
        }
        return lines.joined(separator: "\n")
    }

    private func discardPendingTransferPlan(_ plan: TransferPlan) {
        appState.discardEmptyTransferBatches(ids: plan.allBatchIDs)
    }

    private func showTransferPlanWarnings(_ messages: [String]) {
        guard !messages.isEmpty else { return }
        let visible = messages.prefix(8).joined(separator: "\n")
        let more = messages.count > 8 ? "\n另有 \(messages.count - 8) 项未显示。" : ""
        appState.alertItem = AlertItem(title: "部分项目无法传输", message: visible + more)
    }

    private enum LocalDestinationState {
        case missing
        case file
        case directory
    }

    private func localDestinationState(for url: URL) -> LocalDestinationState {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return .missing
        }
        return isDirectory.boolValue ? .directory : .file
    }

    private func localURLIsDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
    }

    private func localFileSize(_ url: URL) -> Int64? {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return values?.fileSize.map(Int64.init)
    }

    private func friendlyMessage(_ error: Error) -> String {
        FTPError.friendly(error).errorDescription ?? error.localizedDescription
    }
}

@MainActor
private final class RemoteDirectoryCache {
    private let client: any AnyFTPClient
    private var cachedItems: [String: [String: RemoteFileItem]] = [:]

    init(client: any AnyFTPClient) {
        self.client = client
    }

    func item(named name: String, in path: String) async throws -> RemoteFileItem? {
        try await itemsByName(in: path)[name]
    }

    func itemsByName(in path: String) async throws -> [String: RemoteFileItem] {
        if let items = cachedItems[path] {
            return items
        }
        let items = try await client.listDirectory(path)
        var mapped: [String: RemoteFileItem] = [:]
        for item in items {
            mapped[item.name] = item
        }
        cachedItems[path] = mapped
        return mapped
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
                        .help(title)
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
                        .help("路径分隔")
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
    let onDownload: ([RemoteFileItem]) -> Void
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
                    let items = selectedItems(for: ids)
                    if !items.isEmpty {
                        Button("下载") { onDownload(items) }
                        if items.count == 1, let item = items.first {
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

    private func selectedItems(for ids: Set<UUID>) -> [RemoteFileItem] {
        vm.sortedItems.filter { ids.contains($0.id) }
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
