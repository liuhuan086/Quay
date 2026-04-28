// ServerEditView.swift — Add / Edit server connection
import SwiftUI

struct ServerEditView: View {
    @Environment(\.dismiss) var dismiss

    // Form state
    @State private var displayName: String
    @State private var host: String
    @State private var port: String
    @State private var username: String
    @State private var password: String
    @State private var protocol_: ConnectionProtocol
    @State private var initialPath: String
    @State private var groupName: String
    @State private var colorLabel: ServerColorLabel?
    @State private var notes: String
    @State private var useSSHKey: Bool
    @State private var sshKeyPath: String

    @State private var activeTab = 0
    @State private var testState: TestState = .idle
    @State private var showPassword = false
    @State private var duplicateError: String?

    enum TestState: Equatable { case idle, testing, ok(ms: Int), fail(String) }

    let existingConfig: ServerConfig?
    let existingServers: [ServerConfig]
    let onSave: (ServerConfig) -> Void

    init(config: ServerConfig?, servers: [ServerConfig] = [], onSave: @escaping (ServerConfig) -> Void) {
        self.existingConfig = config
        self.existingServers = servers
        self.onSave = onSave
        _displayName = State(initialValue: config?.displayName ?? "")
        _host        = State(initialValue: config?.host ?? "")
        _port        = State(initialValue: config.map { "\($0.port)" } ?? "22")
        _username    = State(initialValue: config?.username ?? "")
        _password    = State(initialValue: config?.password ?? "")
        _protocol_   = State(initialValue: config?.protocol_ ?? .sftp)
        _initialPath = State(initialValue: config?.initialPath ?? "/")
        _groupName   = State(initialValue: config?.groupName ?? "")
        _colorLabel  = State(initialValue: config?.colorLabel)
        _notes       = State(initialValue: config?.notes ?? "")
        _useSSHKey   = State(initialValue: config?.useSSHKey ?? false)
        _sshKeyPath  = State(initialValue: config?.sshKeyPath ?? "")
    }

    var isEditing: Bool { existingConfig != nil }
    var isValid: Bool { !host.trimmingCharacters(in: .whitespaces).isEmpty && !username.isEmpty }

    /// Check for duplicate displayName or host within the same group
    var duplicateMessage: String? {
        let name = displayName.isEmpty ? host : displayName
        let group = groupName.isEmpty ? nil : groupName
        let siblings = existingServers.filter {
            $0.id != existingConfig?.id && $0.groupName == group
        }
        if siblings.contains(where: { $0.displayName == name }) {
            return "同一分组内已存在名为「\(name)」的服务器"
        }
        if siblings.contains(where: { $0.host == host && !host.isEmpty }) {
            return "同一分组内已存在地址为「\(host)」的服务器"
        }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            // ── Header ──
            HStack {
                Text(isEditing ? "编辑服务器" : "新建连接").font(.title3).bold()
                Spacer()
                Button("取消") { dismiss() }
                Button(isEditing ? "保存" : "连接") { save() }
                    .buttonStyle(.borderedProminent).disabled(!isValid || duplicateMessage != nil)
            }
            .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 12)

            Divider()

            // ── Tabs ──
            Picker("", selection: $activeTab) {
                Text("基本").tag(0)
                Text("高级").tag(1)
                Text("备注").tag(2)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 20).padding(.vertical, 10)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch activeTab {
                    case 0: basicTab
                    case 1: advancedTab
                    default: notesTab
                    }
                }
                .padding(.horizontal, 20).padding(.bottom, 16)
            }

            Divider()

            // ── Test Connection footer ──
            HStack(spacing: 10) {
                switch testState {
                case .idle: EmptyView()
                case .testing:
                    ProgressView().scaleEffect(0.7)
                    Text("测试连接中…").foregroundColor(.secondary).font(.caption)
                case .ok(let ms):
                    Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                    Text("连接成功！延迟 \(ms)ms").foregroundColor(.green).font(.caption)
                case .fail(let m):
                    Image(systemName: "xmark.circle.fill").foregroundColor(.red)
                    Text(m).foregroundColor(.red).font(.caption).lineLimit(2)
                }
                Spacer()
                Button("测试连接") { testConnection() }
                    .disabled(!isValid || testState == .testing)
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
        }
        .frame(width: 500)
        .onChange(of: protocol_) { oldValue, newValue in port = "\(newValue.defaultPort)" }
    }

    // MARK: - Basic Tab
    @ViewBuilder var basicTab: some View {
        // Protocol — centered within formRow
        formRow("协议") {
            HStack {
                Spacer()
                Picker("", selection: $protocol_) {
                    ForEach(ConnectionProtocol.allCases) { p in
                        Label(p.rawValue, systemImage: p.sfSymbol).tag(p)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer()
            }
        }

        // Host + Port
        HStack(alignment: .top, spacing: 12) {
            formRow("主机", width: 360) {
                TextField("hostname 或 IP", text: $host).textFieldStyle(.roundedBorder)
            }
            formRow("端口", width: 80) {
                TextField("端口", text: $port).textFieldStyle(.roundedBorder)
            }
        }

        // Username
        formRow("用户名") { TextField("username", text: $username).textFieldStyle(.roundedBorder) }

        // Auth
        if protocol_ == .sftp {
            Toggle("使用 SSH 私钥认证", isOn: $useSSHKey)
            if useSSHKey {
                formRow("私钥路径") {
                    HStack {
                        TextField("~/.ssh/id_rsa", text: $sshKeyPath).textFieldStyle(.roundedBorder)
                        Button("选择…") { pickKey() }
                    }
                }
                formRow("密钥密码") { passwordField(placeholder: "（可留空）") }
            } else {
                formRow("密码") { passwordField(placeholder: "password") }
            }
        } else {
            formRow("密码") { passwordField(placeholder: "password") }
        }

        // Display name
        formRow("显示名称") {
            TextField("自定义名称（留空则使用主机名）", text: $displayName).textFieldStyle(.roundedBorder)
        }

        // Duplicate warning
        if let msg = duplicateMessage {
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange).font(.caption)
                Text(msg).font(.caption).foregroundColor(.orange)
            }
        }
    }

    // MARK: - Password Field with show/hide toggle
    @ViewBuilder
    func passwordField(placeholder: String) -> some View {
        HStack(spacing: 6) {
            if showPassword {
                TextField(placeholder, text: $password)
                    .textFieldStyle(.roundedBorder)
            } else {
                // Always show fixed 16 dots regardless of actual password length
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                        .background(RoundedRectangle(cornerRadius: 5).fill(Color(NSColor.textBackgroundColor)))
                        .frame(height: 22)
                    if password.isEmpty {
                        Text(placeholder)
                            .foregroundColor(.secondary.opacity(0.5))
                            .font(.system(size: 13))
                            .padding(.horizontal, 4)
                    } else {
                        Text(String(repeating: "•", count: 16))
                            .font(.system(size: 13))
                            .padding(.horizontal, 4)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { showPassword = true }
            }
            Button {
                showPassword.toggle()
            } label: {
                Image(systemName: showPassword ? "eye.fill" : "eye.slash.fill")
                    .foregroundColor(.secondary)
                    .font(.system(size: 13))
            }
            .buttonStyle(.plain)
            .help(showPassword ? "隐藏密码" : "显示密码")
        }
    }

    // MARK: - Advanced Tab
    @ViewBuilder var advancedTab: some View {
        formRow("初始路径") { TextField("/", text: $initialPath).textFieldStyle(.roundedBorder) }
        formRow("分组标签") { TextField("如：生产环境", text: $groupName).textFieldStyle(.roundedBorder) }
        formRow("颜色标签") {
            HStack {
                ForEach(ServerColorLabel.allCases) { label in colorDot(label) }
                Spacer()
                if colorLabel != nil {
                    Button("清除") { colorLabel = nil }.font(.caption)
                }
            }
        }
    }

    // MARK: - Notes Tab
    @ViewBuilder var notesTab: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("备注").font(.caption).foregroundColor(.secondary)
            TextEditor(text: $notes).frame(height: 120)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
        }
    }

    // MARK: - Helpers
    func formRow<C: View>(_ label: String, width: CGFloat? = nil, @ViewBuilder content: () -> C) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Text(label).frame(width: 72, alignment: .trailing)
                .foregroundColor(.secondary).font(.system(size: 12))
            if let w = width {
                content().frame(maxWidth: w)
            } else {
                content().frame(maxWidth: .infinity)
            }
        }
    }

    func colorDot(_ label: ServerColorLabel) -> some View {
        let colors: [ServerColorLabel: Color] = [.red:.red,.orange:.orange,.yellow:.yellow,
                                                  .green:.green,.blue:.blue,.purple:.purple]
        return Circle()
            .fill(colors[label] ?? .gray)
            .frame(width: 22, height: 22)
            .overlay(colorLabel == label
                ? Circle().stroke(Color.primary.opacity(0.5), lineWidth: 2).padding(-3)
                : nil)
            .onTapGesture { colorLabel = label }
            .help(label.displayName)
    }

    // MARK: - Actions
    private func save() {
        let name = displayName.isEmpty ? host : displayName
        let cfg = ServerConfig(
            id: existingConfig?.id ?? UUID(),
            displayName: name, host: host,
            port: Int(port) ?? protocol_.defaultPort,
            username: username, protocol_: protocol_,
            initialPath: initialPath.isEmpty ? "/" : initialPath,
            groupName: groupName.isEmpty ? nil : groupName,
            colorLabel: colorLabel, notes: notes,
            useSSHKey: useSSHKey,
            sshKeyPath: sshKeyPath.isEmpty ? nil : sshKeyPath,
            password: password,
            createdAt: existingConfig?.createdAt ?? Date(),
            lastConnectedAt: existingConfig?.lastConnectedAt
        )
        onSave(cfg)
        dismiss()
    }

    private func testConnection() {
        testState = .testing
        let portInt = Int(port) ?? protocol_.defaultPort
        let cfg = ServerConfig(
            displayName: host,
            host: host,
            port: portInt,
            username: username,
            protocol_: protocol_,
            initialPath: initialPath.isEmpty ? "/" : initialPath,
            groupName: groupName.isEmpty ? nil : groupName,
            colorLabel: colorLabel,
            notes: notes,
            useSSHKey: useSSHKey,
            sshKeyPath: sshKeyPath.isEmpty ? nil : sshKeyPath,
            password: password
        )
        Task {
            let start = Date()
            let client = ClientFactory.makeClient(for: cfg)
            do {
                try await client.connect(password: password)
                await client.disconnect()
                let ms = Int(Date().timeIntervalSince(start) * 1000)
                testState = .ok(ms: ms)
            } catch {
                let friendly = FTPError.friendly(error).errorDescription ?? error.localizedDescription
                testState = .fail(friendly)
            }
        }
    }

    private func pickKey() {
        let p = NSOpenPanel()
        p.canChooseFiles = true; p.canChooseDirectories = false
        p.directoryURL = URL(fileURLWithPath: NSHomeDirectory() + "/.ssh")
        p.message = "选择 SSH 私钥文件"
        if p.runModal() == .OK { sshKeyPath = p.url?.path ?? "" }
    }
}
