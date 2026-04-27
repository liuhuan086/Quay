// MainViews.swift — Root layout + Sidebar
import SwiftUI
import UserNotifications

// MARK: - App Entry
@main
struct SwiftFTPApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appState)
                .frame(minWidth: 960, minHeight: 640)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands { AppMenuCommands() }

        Settings { SettingsRootView().environmentObject(appState) }
    }
}

// MARK: - AppDelegate
class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ n: Notification) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
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
    @EnvironmentObject var appState: AppState
    @State private var colVisibility = NavigationSplitViewVisibility.all

    var body: some View {
        NavigationSplitView(columnVisibility: $colVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 300)
        } detail: {
            DetailView()
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                TransferBadgeButton()
            }
        }
        .safeAreaInset(edge: .bottom) { BottomStatusBar() }
        .alert(item: $appState.alertItem) { item in
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
            FileBrowserView(server: server, primaryClient: client)
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
    @State private var showAdd = false
    @State private var editTarget: ServerConfig?
    @State private var deleteTarget: ServerConfig?
    @State private var lastSelectedID: UUID?
    @State private var lastSelectedTime: Date = .distantPast

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
                Image(systemName: "magnifyingglass").foregroundColor(.secondary).font(.caption)
                TextField("搜索服务器", text: $search).textFieldStyle(.plain).font(.system(size: 12))
                if !search.isEmpty {
                    Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            List(selection: Binding(
                get: { appState.selectedServerID },
                set: { newID in
                    let now = Date()
                    if newID == lastSelectedID,
                       now.timeIntervalSince(lastSelectedTime) < 0.4,
                       let server = appState.servers.first(where: { $0.id == newID }) {
                        // Double-click: connect or disconnect
                        let connected = appState.connectionStates[server.id]?.isConnected ?? false
                        Task { connected ? await appState.disconnect(from: server) : await appState.connect(to: server) }
                    }
                    lastSelectedID = newID
                    lastSelectedTime = now
                    appState.selectedServerID = newID
                }
            )) {
                ForEach(grouped, id: \.0) { group, servers in
                    Section {
                        ForEach(servers) { s in
                            ServerRow(server: s, state: appState.connectionStates[s.id])
                                .tag(s.id)
                                .contextMenu { rowMenu(for: s) }
                        }
                    } header: {
                        Text(group).font(.caption2).foregroundColor(.secondary).textCase(.uppercase)
                    }
                }
            }
            .listStyle(.sidebar)

            Divider()
            SidebarToolbar(onAdd: { showAdd = true })
        }
        .sheet(isPresented: $showAdd) {
            ServerEditView(config: nil, servers: appState.servers) { cfg in
                appState.saveServer(cfg)
                Task { await appState.connect(to: cfg) }
            }
        }
        .sheet(item: $editTarget) { server in
            ServerEditView(config: server, servers: appState.servers) { cfg in
                appState.updateServer(cfg)
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

    @ViewBuilder
    func rowMenu(for s: ServerConfig) -> some View {
        let connected = appState.connectionStates[s.id]?.isConnected ?? false
        Button(connected ? "断开" : "连接") {
            Task { connected ? await appState.disconnect(from: s) : await appState.connect(to: s) }
        }
        Divider()
        Button("编辑") { editTarget = s }
        Button("复制地址") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(s.connectionSummary, forType: .string)
        }
        Divider()
        Button("删除", role: .destructive) { deleteTarget = s }
    }
}

// MARK: - Server Row
struct ServerRow: View {
    let server: ServerConfig
    let state: ConnectionState?

    var body: some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text(server.displayName).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Text(server.host).font(.system(size: 11)).foregroundColor(.secondary).lineLimit(1)
            }
            Spacer()
            stateIndicator
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder var stateIndicator: some View {
        switch state {
        case .connecting: ProgressView().scaleEffect(0.5).frame(width: 14)
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
                ProgressView(value: avg).progressViewStyle(.linear).frame(width: 80).tint(.blue)
                Text("\(activeTransfers.count) 传输中").font(.caption).foregroundColor(.secondary)
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
    @EnvironmentObject var appState: AppState
    @State private var showQueue = false

    var active: Int { appState.transfers.filter {
        if case .inProgress = $0.status { return true }; return false
    }.count }

    var body: some View {
        Button { showQueue.toggle() } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: active > 0 ? "arrow.up.arrow.down.circle.fill" : "arrow.up.arrow.down.circle")
                    .foregroundColor(active > 0 ? .blue : .secondary)
                if active > 0 {
                    Text("\(active)").font(.system(size: 8, weight: .bold))
                        .foregroundColor(.white).padding(2)
                        .background(Color.red).clipShape(Circle())
                        .offset(x: 5, y: -5)
                }
            }
        }
        .help("传输队列")
        .popover(isPresented: $showQueue, arrowEdge: .bottom) {
            TransferQueueView().frame(width: 420, height: 380)
        }
    }
}

// MARK: - App Menu Commands
struct AppMenuCommands: Commands {
    var body: some Commands {
        CommandMenu("连接") {
            Button("新建连接…") {}.keyboardShortcut("n", modifiers: [.command, .shift])
        }
        CommandMenu("传输") {
            Button("显示传输队列") {}.keyboardShortcut("t", modifiers: [.command, .shift])
        }
    }
}
