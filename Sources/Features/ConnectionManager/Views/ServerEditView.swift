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
    @State private var sshKeyBookmark: Data?
    @State private var allowLegacySSHAlgorithms: Bool
    @State private var allowSelfSignedTLS: Bool

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
        _sshKeyBookmark = State(initialValue: config?.sshKeyBookmark)
        _allowLegacySSHAlgorithms = State(initialValue: config?.allowLegacySSHAlgorithms ?? false)
        _allowSelfSignedTLS = State(initialValue: config?.allowSelfSignedTLS ?? false)
    }

    var isEditing: Bool { existingConfig != nil }
    var validatedPort: Int? {
        guard let value = Int(port), (1...65_535).contains(value) else { return nil }
        return value
    }

    var isValid: Bool {
        !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && validatedPort != nil
    }

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
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 16, height: 16)
                    Text("测试连接中…").foregroundColor(.secondary).font(.caption)
                case .ok(let ms):
                    Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                    Text("连接成功！延迟 \(ms)ms").foregroundColor(.green).font(.caption)
                case .fail(let m):
                    Image(systemName: "xmark.circle.fill").foregroundColor(.red)
                    Text(m)
                        .foregroundColor(.red)
                        .font(.caption)
                        .lineLimit(3)
                        .help(m)
                }
                Spacer()
                Button("测试连接") { testConnection() }
                    .disabled(!isValid || testState == .testing)
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
        }
        .frame(width: 500)
        .onAppear {
            showPassword = false
        }
        .onChange(of: protocol_) { oldValue, newValue in
            port = "\(newValue.defaultPort)"
            showPassword = false
        }
        .onChange(of: useSSHKey) { oldValue, newValue in
            showPassword = false
        }
    }

    // MARK: - Basic Tab
    @ViewBuilder var basicTab: some View {
        // Protocol
        protocolPickerRow
        basicCredentialsAndMetadata
    }

    private var protocolPickerRow: some View {
        ZStack {
            HStack {
                Text("协议").frame(width: 72, alignment: .trailing)
                    .foregroundColor(.secondary).font(.system(size: 12))
                Spacer()
            }
            Picker("", selection: $protocol_) {
                ForEach(ConnectionProtocol.allCases) { p in
                    Label(p.displayName, systemImage: p.sfSymbol).tag(p)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
    }

    @ViewBuilder var basicCredentialsAndMetadata: some View {
        // Host + Port
        HStack(alignment: .top, spacing: 12) {
            formRow("主机", width: 360) {
                TextField("hostname 或 IP", text: $host).textFieldStyle(.roundedBorder)
            }
            formRow("端口", width: 80) {
                TextField("端口", text: $port).textFieldStyle(.roundedBorder)
            }
        }
        if !port.isEmpty && validatedPort == nil {
            Text("端口必须是 1–65535 之间的整数")
                .font(.caption2)
                .foregroundColor(.red)
                .padding(.leading, 82)
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
        let effectivePlaceholder = isEditing ? "留空则保持已保存密码" : placeholder
        HStack(spacing: 6) {
            if showPassword {
                TextField(effectivePlaceholder, text: $password)
                    .textFieldStyle(.roundedBorder)
                    .textContentType(.password)
            } else {
                SecureField(effectivePlaceholder, text: $password)
                    .textFieldStyle(.roundedBorder)
                    .textContentType(.password)
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
        if protocol_ == .ftps {
            Text("当前支持隐式 FTPS（通常使用 990 端口），控制与数据通道均使用 TLS。")
                .font(.caption)
                .foregroundColor(.secondary)
            Toggle("允许自签名或过期证书（FTPS）", isOn: $allowSelfSignedTLS)
                .help("仅在连接自签名或内部测试服务器时开启；域名不匹配和已吊销证书仍会被拒绝。")
        }
        if protocol_ == .sftp {
            Toggle("允许旧式 SSH 算法", isOn: $allowLegacySSHAlgorithms)
                .help("仅为不支持现代算法的旧服务器开启；会允许 SHA-1 密钥交换和旧式 RSA 签名。")
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
        let normalizedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedDisplayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = normalizedDisplayName.isEmpty ? normalizedHost : normalizedDisplayName
        let cfg = ServerConfig(
            id: existingConfig?.id ?? UUID(),
            displayName: name, host: normalizedHost,
            port: validatedPort ?? protocol_.defaultPort,
            username: normalizedUsername, protocol_: protocol_,
            initialPath: initialPath.isEmpty ? "/" : initialPath,
            groupName: groupName.isEmpty ? nil : groupName,
            colorLabel: colorLabel, notes: notes,
            useSSHKey: useSSHKey,
            sshKeyPath: sshKeyPath.isEmpty ? nil : sshKeyPath,
            sshKeyBookmark: validSSHKeyBookmark(),
            allowLegacySSHAlgorithms: allowLegacySSHAlgorithms,
            allowSelfSignedTLS: allowSelfSignedTLS,
            password: password,
            createdAt: existingConfig?.createdAt ?? Date(),
            lastConnectedAt: existingConfig?.lastConnectedAt
        )
        onSave(cfg)
        dismiss()
    }

    private func testConnection() {
        testState = .testing
        guard let portInt = validatedPort else {
            testState = .fail("端口必须是 1–65535 之间的整数")
            return
        }
        let normalizedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let cfg = ServerConfig(
            displayName: normalizedHost,
            host: normalizedHost,
            port: portInt,
            username: normalizedUsername,
            protocol_: protocol_,
            initialPath: initialPath.isEmpty ? "/" : initialPath,
            groupName: groupName.isEmpty ? nil : groupName,
            colorLabel: colorLabel,
            notes: notes,
            useSSHKey: useSSHKey,
            sshKeyPath: sshKeyPath.isEmpty ? nil : sshKeyPath,
            sshKeyBookmark: validSSHKeyBookmark(),
            allowLegacySSHAlgorithms: allowLegacySSHAlgorithms,
            allowSelfSignedTLS: allowSelfSignedTLS,
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
        p.begin { response in
            guard response == .OK else { return }
            guard let url = p.url else { return }
            sshKeyPath = url.path
            do {
                sshKeyBookmark = try url.bookmarkData(
                    options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                )
            } catch {
                sshKeyBookmark = nil
                testState = .fail("私钥已选择，但保存沙盒访问授权失败：\(error.localizedDescription)")
            }
        }
    }

    private func validSSHKeyBookmark() -> Data? {
        guard useSSHKey, let sshKeyBookmark else { return nil }
        guard !sshKeyPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        do {
            var isStale = false
            let url = try URL(
                resolvingBookmarkData: sshKeyBookmark,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            guard !isStale else { return nil }
            let selectedPath = URL(fileURLWithPath: sshKeyPath).standardizedFileURL.path
            return url.standardizedFileURL.path == selectedPath ? sshKeyBookmark : nil
        } catch {
            return nil
        }
    }
}
