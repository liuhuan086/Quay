// MainViews.swift — Root layout + Sidebar
import SwiftUI
import AppKit
import Combine
import UserNotifications

// MARK: - App Entry
@main
struct SwiftFTPApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            RootView(appState: appState)
                .environmentObject(appState)
                .environmentObject(appState.transferBadgeState)
                .frame(minWidth: 760, minHeight: 560)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            AppMenuCommands(
                appState: appState,
                onNewConnection: { appState.presentAddServer() },
                onShowTransferQueue: { appState.transferBadgeState.requestPresentation() },
                onShowAbout: { appState.presentAbout() }
            )
        }

        Settings { SettingsRootView().environmentObject(appState) }
    }
}

// MARK: - AppDelegate
class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ n: Notification) {
        UNUserNotificationCenter.current().delegate = self
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func userNotificationCenter(_ c: UNUserNotificationCenter,
                                willPresent n: UNNotification,
                                withCompletionHandler h: @escaping (UNNotificationPresentationOptions) -> Void) {
        h([.banner, .sound])
    }
}

// MARK: - RootView
struct RootView: View {
    @ObservedObject var appState: AppState
    @State private var colVisibility = NavigationSplitViewVisibility.all

    var body: some View {
        ZStack {
            NavigationSplitView(columnVisibility: $colVisibility) {
                SidebarView()
                    .navigationSplitViewColumnWidth(min: 240, ideal: 260, max: 360)
            } detail: {
                DetailView()
            }

            if appState.shouldShowOnboarding {
                OnboardingView(onFinish: { appState.completeOnboarding() })
                    .transition(.opacity)
                    .zIndex(10)
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                TransferBadgeButton(appState: appState)
            }
        }
        .sheet(isPresented: Binding(
            get: { appState.isAddServerPresented },
            set: { appState.isAddServerPresented = $0 }
        )) {
            ServerEditView(config: nil, servers: appState.servers) { cfg in
                Task {
                    if await appState.saveServer(cfg) {
                        await appState.connect(to: cfg)
                    }
                }
            }
        }
        .sheet(isPresented: Binding(
            get: { appState.isAboutPresented },
            set: { appState.isAboutPresented = $0 }
        )) {
            AboutView()
        }
        .safeAreaInset(edge: .bottom) { BottomStatusBar() }
        .background(GlobalAlertHost())
    }

}

private struct GlobalAlertHost: View {
    @EnvironmentObject var appState: AppState
    var body: some View {
        Color.clear.alert(item: $appState.alertItem) { item in
            Alert(title: Text(item.title), message: Text(item.message))
        }
    }
}

// MARK: - DetailView (shows file browser or welcome)
struct DetailView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        if let sid = appState.selectedServerID,
           let server = appState.servers.first(where: { $0.id == sid }),
           case .connected(let client) = appState.connectionStates[sid] {
            FileBrowserView(appState: appState, server: server, primaryClient: client)
                .id(sid)  // force re-init on server change
        } else {
            WelcomeView()
        }
    }
}

// MARK: - SidebarView
struct SidebarView: View {
    @EnvironmentObject var appState: AppState
    @State private var search = ""
    @State private var editTarget: ServerConfig?
    @State private var deleteTarget: ServerConfig?

    var grouped: [(String, [ServerConfig])] {
        let servers = search.isEmpty ? appState.servers
            : appState.servers.filter {
                $0.displayName.localizedCaseInsensitiveContains(search) ||
                $0.host.localizedCaseInsensitiveContains(search)
            }
        let dict = Dictionary(grouping: servers) { $0.groupName ?? "未分组" }
        return dict.sorted { $0.key < $1.key }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Search
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                    .font(.caption)
                    .frame(width: 14)
                    .help("搜索服务器")
                TextField("搜索服务器", text: $search)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .frame(minWidth: 0)
                if !search.isEmpty {
                    Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundColor(.secondary)
                        .help("清除搜索")
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            List {
                ForEach(grouped, id: \.0) { group, servers in
                    Section {
                        ForEach(servers) { s in
                            ServerRow(server: s,
                                      state: appState.connectionStates[s.id],
                                      isSelected: appState.selectedServerID == s.id)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    appState.selectedServerID = s.id
                                }
                                .simultaneousGesture(TapGesture(count: 2).onEnded {
                                    connectOrDisconnect(s)
                                })
                                .tag(s.id)
                                .listRowInsets(EdgeInsets(top: 1, leading: 6, bottom: 1, trailing: 6))
                                .listRowBackground(Color.clear)
                                .contextMenu { rowMenu(for: s) }
                        }
                    } header: {
                        Text(group)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .textCase(.uppercase)
                    }
                }
            }
            .listStyle(.sidebar)

            Divider()
            SidebarToolbar(onAdd: { appState.presentAddServer() })
        }
        .frame(minWidth: 240)
        .layoutPriority(2)
        .background(InitialFirstResponderClearer())
        .sheet(item: $editTarget) { server in
            ServerEditView(config: server, servers: appState.servers) { cfg in
                Task { await appState.updateServer(cfg) }
            }
        }
        .confirmationDialog("删除服务器", isPresented: Binding(
            get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } }
        ), presenting: deleteTarget) { s in
            Button("删除 \(s.displayName)", role: .destructive) {
                Task { await appState.deleteServer(s) }
            }
        } message: { _ in Text("此操作不可撤销") }
    }

    private func connectOrDisconnect(_ server: ServerConfig) {
        let connected = appState.connectionStates[server.id]?.isConnected ?? false
        Task { connected ? await appState.disconnect(from: server) : await appState.connect(to: server) }
    }

    @ViewBuilder
    func rowMenu(for s: ServerConfig) -> some View {
        let connected = appState.connectionStates[s.id]?.isConnected ?? false
        Button(connected ? "断开" : "连接") {
            Task { connected ? await appState.disconnect(from: s) : await appState.connect(to: s) }
        }
        Divider()
        Button("编辑") {
            editTarget = s
        }
        Button("复制地址") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(s.connectionSummary, forType: .string)
        }
        Divider()
        Button("删除", role: .destructive) { deleteTarget = s }
    }
}

private struct InitialFirstResponderClearer: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            view.window?.makeFirstResponder(nil)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            view.window?.makeFirstResponder(nil)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

// MARK: - Server Row
struct ServerRow: View {
    let server: ServerConfig
    let state: ConnectionState?
    let isSelected: Bool

    private var connected: Bool {
        if case .connected = state { return true }
        return false
    }

    private var titleColor: Color { connected ? .white : .primary }
    private var subtitleColor: Color { connected ? .white.opacity(0.8) : .secondary }

    var body: some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text(server.displayName)
                    .font(.system(size: 11, weight: .regular))
                    .foregroundColor(titleColor)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(server.host)
                    .font(.system(size: 11))
                    .foregroundColor(subtitleColor)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)
            Spacer()
            stateIndicator
                .frame(width: 18, alignment: .trailing)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowBackground)
        .help(server.connectionSummary)
    }

    @ViewBuilder private var rowBackground: some View {
        if connected {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.accentColor)
        } else if isSelected {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color(nsColor: .unemphasizedSelectedContentBackgroundColor))
        } else {
            Color.clear
        }
    }

    @ViewBuilder var stateIndicator: some View {
        switch state {
        case .connecting:
            ProgressView()
                .controlSize(.small)
                .frame(width: 16, height: 16)
        case .connected:  Circle().fill(Color.green).frame(width: 7, height: 7)
        case .failed:     Image(systemName: "exclamationmark.circle.fill").foregroundColor(.red).font(.caption)
        default:          EmptyView()
        }
    }
}

// MARK: - Sidebar Toolbar
struct SidebarToolbar: View {
    @EnvironmentObject var appState: AppState
    let onAdd: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onAdd) { Image(systemName: "plus") }
                .buttonStyle(.plain).help("新建连接")
            Spacer()
            if let sid = appState.selectedServerID,
               let server = appState.servers.first(where: { $0.id == sid }) {
                let connected = appState.connectionStates[sid]?.isConnected ?? false
                Button {
                    Task { connected ? await appState.disconnect(from: server) : await appState.connect(to: server) }
                } label: {
                    Image(systemName: connected ? "eject.fill" : "bolt.fill")
                        .foregroundColor(connected ? .orange : .green)
                }
                .buttonStyle(.plain).help(connected ? "断开" : "连接")
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8).padding(.bottom, 4)
    }
}

// MARK: - Bottom Status Bar
struct BottomStatusBar: View {
    @EnvironmentObject var appState: AppState

    var activeTransfers: [TransferTask] {
        appState.transfers.filter {
            if case .inProgress = $0.status { return true }; return false
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            if !activeTransfers.isEmpty {
                let avg = activeTransfers.map { $0.status.progressFraction }.reduce(0, +) / Double(activeTransfers.count)
                let totalBps: Int64 = activeTransfers.reduce(0) { sum, t in
                    if case .inProgress(_, let bps) = t.status { return sum + bps }
                    return sum
                }
                let speed = totalBps > 0
                    ? ByteCountFormatter.string(fromByteCount: totalBps, countStyle: .file) + "/s"
                    : "—"
                ProgressView(value: avg).progressViewStyle(.linear).frame(width: 80).tint(.blue)
                Text("\(activeTransfers.count) 传输中")
                    .font(.caption).foregroundColor(.secondary)
                    .frame(minWidth: 64, alignment: .leading)
                Text(speed)
                    .font(.caption).foregroundColor(.secondary)
                    .monospacedDigit()
                    .frame(minWidth: 84, alignment: .leading)
            }
            Spacer()
            if let sid = appState.selectedServerID,
               let state = appState.connectionStates[sid] {
                HStack(spacing: 4) {
                    Circle().fill(state.isConnected ? Color.green : Color.secondary).frame(width: 6, height: 6)
                    Text(state.label).font(.caption).foregroundColor(.secondary)
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 4)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) { Divider() }
    }
}

// MARK: - Transfer Badge Button
struct TransferBadgeButton: View {
    let appState: AppState
    @EnvironmentObject var badgeState: TransferBadgeState

    var body: some View {
        TransferBadgePopoverAnchor(appState: appState, badgeState: badgeState)
            .frame(width: 28, height: 22)
            .help("传输队列")
    }
}

private struct TransferBadgePopoverAnchor: NSViewRepresentable {
    let appState: AppState
    let badgeState: TransferBadgeState

    func makeCoordinator() -> Coordinator { Coordinator(appState: appState, badgeState: badgeState) }

    func makeNSView(context: Context) -> NSView {
        let coord = context.coordinator
        let host = ClickableHostingView(rootView: TransferBadgeContent(active: badgeState.activeCount))
        host.onClick = { [weak coord] in coord?.toggle() }
        host.toolTip = badgeState.activeCount > 0
            ? "传输队列（\(badgeState.activeCount) 进行中）" : "传输队列"
        coord.host = host
        coord.bindPresentationRequestIfNeeded()
        return host
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.scheduleRefreshIcon()
    }

    @MainActor
    final class Coordinator: NSObject, NSPopoverDelegate {
        let appState: AppState
        let badgeState: TransferBadgeState
        weak var host: ClickableHostingView<TransferBadgeContent>?
        let popover: NSPopover
        private var cancellable: AnyCancellable?
        private var presentationCancellable: AnyCancellable?
        private var refreshScheduled = false
        private var renderedActiveCount: Int?

        init(appState: AppState, badgeState: TransferBadgeState) {
            self.appState = appState
            self.badgeState = badgeState
            self.popover = NSPopover()
            super.init()
            popover.behavior = .transient
            popover.delegate = self
            cancellable = badgeState.objectWillChange.sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.scheduleRefreshIcon()
                }
            }
        }

        func toggle() {
            if popover.isShown {
                popover.performClose(nil)
                return
            }
            show()
        }

        func show() {
            guard !popover.isShown else { return }
            guard let host else { return }
            let content = NSHostingController(
                rootView: TransferQueueView()
                    .environmentObject(appState)
                    .frame(width: 420, height: 380)
            )
            popover.contentViewController = content
            popover.contentSize = NSSize(width: 420, height: 380)
            let bottomEdge: NSRectEdge = host.isFlipped ? .maxY : .minY
            popover.show(relativeTo: host.bounds, of: host, preferredEdge: bottomEdge)
        }

        func bindPresentationRequestIfNeeded() {
            guard presentationCancellable == nil else { return }
            presentationCancellable = badgeState.$presentationRequestID
                .compactMap { $0 }
                .sink { [weak self] _ in
                    Task { @MainActor [weak self] in self?.show() }
                }
        }

        func scheduleRefreshIcon() {
            guard !refreshScheduled else { return }
            refreshScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.refreshScheduled = false
                self.refreshIcon()
            }
        }

        func refreshIcon() {
            guard let host else { return }
            let active = badgeState.activeCount
            host.toolTip = active > 0 ? "传输队列（\(active) 进行中）" : "传输队列"
            guard renderedActiveCount != active else { return }
            renderedActiveCount = active
            host.rootView = TransferBadgeContent(active: active)
        }
    }
}

private final class ClickableHostingView<Root: View>: NSHostingView<Root> {
    var onClick: () -> Void = {}
    override func mouseDown(with event: NSEvent) { onClick() }
    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

private struct TransferBadgeContent: View {
    let active: Int
    var body: some View {
        ZStack(alignment: .topTrailing) {
            Image(systemName: active > 0 ? "arrow.up.arrow.down.circle.fill" : "arrow.up.arrow.down.circle")
                .foregroundColor(active > 0 ? .blue : .secondary)
                .font(.system(size: 16))
            if active > 0 {
                Text("\(active)").font(.system(size: 8, weight: .bold))
                    .foregroundColor(.white).padding(2)
                    .background(Color.red).clipShape(Circle())
                    .offset(x: 5, y: -5)
            }
        }
        .frame(width: 28, height: 22)
    }
}


// MARK: - App Menu Commands
struct AppMenuCommands: Commands {
    @ObservedObject var appState: AppState
    @AppStorage("showHidden") private var showHidden = false
    let onNewConnection: () -> Void
    let onShowTransferQueue: () -> Void
    let onShowAbout: () -> Void

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("关于 Quay", action: onShowAbout)
        }
        CommandGroup(after: .newItem) {
            Button("导入服务器配置…") {
                importServers()
            }
            Button("导出服务器配置…") { exportServers() }
                .disabled(appState.servers.isEmpty)
            Divider()
        }
        CommandGroup(after: .toolbar) {
            Toggle("显示隐藏文件", isOn: $showHidden)
                .keyboardShortcut("l", modifiers: [.command, .shift])
            Divider()
        }
        CommandMenu("连接") {
            Button("新建连接…", action: onNewConnection)
                .keyboardShortcut("n", modifiers: [.command, .shift])
        }
        CommandMenu("传输") {
            Button("显示传输队列", action: onShowTransferQueue)
                .keyboardShortcut("t", modifiers: [.command, .shift])
        }
    }

    private func exportServers() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "Quay-Servers.json"
        panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                let data = try appState.repository.exportJSON()
                try data.write(to: url, options: .atomic)
            } catch {
                appState.showError(error)
            }
        }
    }

    private func importServers() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                do {
                    let data = try await Task.detached(priority: .userInitiated) {
                        try Data(contentsOf: url)
                    }.value
                    try await appState.repository.importJSON(data)
                    appState.loadServers()
                } catch {
                    appState.showError(error)
                }
            }
        }
    }
}
