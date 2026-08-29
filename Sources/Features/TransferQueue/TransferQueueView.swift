// TransferQueueView.swift + WelcomeView.swift
import SwiftUI

private func safeProgressValue(_ value: Double) -> Double {
    guard value.isFinite else { return 0 }
    return min(1.0, max(0.0, value))
}

private func progressPercentText(_ value: Double) -> String {
    "\(Int(safeProgressValue(value) * 100))%"
}

// MARK: - TransferQueueView
struct TransferQueueView: View {
    @EnvironmentObject var appState: AppState
    @State private var selectedIDs: Set<UUID> = []

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            if appState.transfers.isEmpty && appState.transferBatches.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "tray").font(.largeTitle).foregroundColor(.secondary)
                    Text("暂无传输任务").foregroundColor(.secondary).font(.callout)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                queueContent
            }
        }
        .onChange(of: visibleQueueIDs) { _, ids in
            selectedIDs.formIntersection(ids)
        }
    }

    private var header: some View {
        HStack(spacing: 9) {
            Text("传输队列").font(.headline)
            if !selectedIDs.isEmpty {
                Text("\(selectedIDs.count) 已选")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            selectedActionButton("pause.circle", "暂停选中项") {
                Task { await appState.pauseTransfers(matching: selectedIDs) }
            }
            selectedActionButton("play.circle", "继续选中项") {
                Task { await appState.resumeTransfers(matching: selectedIDs) }
            }
            selectedActionButton("arrow.clockwise.circle", "开始或重试选中项") {
                Task { await appState.startOrRetryTransfers(matching: selectedIDs) }
            }
            selectedActionButton("xmark.circle", "取消选中项") {
                Task { await appState.cancelTransfers(matching: selectedIDs) }
            }
            selectedActionButton("trash", "删除选中项", role: .destructive) {
                Task {
                    await appState.removeTransfers(matching: selectedIDs)
                    await MainActor.run { selectedIDs.removeAll() }
                }
            }
            Menu {
                Button {
                    Task { await appState.startOrRetryUnfinishedTransfers() }
                } label: {
                    Label("重试未完成项", systemImage: "arrow.clockwise")
                }
                .disabled(!hasUnfinishedTransfers)

                Divider()

                Button {
                    Task { await appState.clearCompletedTransfers() }
                } label: {
                    Label("清除已完成/已取消", systemImage: "checkmark.circle")
                }
                .disabled(!hasCompletedOrCancelledTransfers)

                Button {
                    Task { await appState.clearUnfinishedTransfers() }
                } label: {
                    Label("清除未完成", systemImage: "minus.circle")
                }
                .disabled(!hasUnfinishedTransfers)

                Button(role: .destructive) {
                    Task {
                        await appState.clearAllTransfers()
                        await MainActor.run { selectedIDs.removeAll() }
                    }
                } label: {
                    Label("全部清除", systemImage: "trash")
                }
                .disabled(appState.transfers.isEmpty && appState.transferBatches.isEmpty)
            } label: {
                Image(systemName: "ellipsis.circle")
                    .frame(width: 20, height: 20)
            }
            .menuStyle(.borderlessButton)
            .help("更多队列操作")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var standaloneTransfers: [TransferTask] {
        appState.transfers.filter { $0.batchID == nil }
    }

    private var hasUnfinishedTransfers: Bool {
        appState.transfers.contains { $0.status.isUnfinished }
    }

    private var hasCompletedOrCancelledTransfers: Bool {
        appState.transfers.contains { $0.status.isCompletedOrCancelled } ||
        appState.transferBatches.contains { batch in
            batch.isPrepared &&
            batch.expectedFileCount == 0 &&
            !appState.transfers.contains { $0.batchID == batch.id }
        }
    }

    private func tasks(for batch: TransferBatch) -> [TransferTask] {
        appState.transfers.filter { $0.batchID == batch.id }
    }

    private var visibleQueueIDs: Set<UUID> {
        Set(appState.transferBatches.map(\.id) + standaloneTransfers.map(\.id))
    }

    private var queueContent: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(appState.transferBatches) { batch in
                    let tasks = tasks(for: batch)
                    SelectableTransferRow(
                        isSelected: selectedIDs.contains(batch.id),
                        onToggle: { toggleSelection(batch.id) }
                    ) {
                        TransferBatchRow(batch: batch, tasks: tasks)
                    }
                    Divider().padding(.leading, 44)
                }
                ForEach(standaloneTransfers) { task in
                    SelectableTransferRow(
                        isSelected: selectedIDs.contains(task.id),
                        onToggle: { toggleSelection(task.id) }
                    ) {
                        TransferRow(task: task)
                    }
                    Divider().padding(.leading, 44)
                }
            }
        }
    }

    private func toggleSelection(_ id: UUID) {
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
        } else {
            selectedIDs.insert(id)
        }
    }

    private func selectedActionButton(
        _ systemImage: String,
        _ help: String,
        role: ButtonRole? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(role: role) {
            action()
        } label: {
            Image(systemName: systemImage)
                .frame(width: 18, height: 18)
        }
        .buttonStyle(.plain)
        .disabled(selectedIDs.isEmpty)
        .help(help)
    }
}

private struct SelectableTransferRow<Content: View>: View {
    let isSelected: Bool
    let onToggle: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Button(action: onToggle) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
            .help(isSelected ? "取消选择" : "选择")

            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(isSelected ? Color.accentColor.opacity(0.10) : Color.clear)
    }
}

// MARK: - Transfer Batch Row
struct TransferBatchRow: View {
    @EnvironmentObject var appState: AppState
    let batch: TransferBatch
    let tasks: [TransferTask]

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Image(systemName: batch.direction == .upload
                      ? "folder.badge.arrow.up" : "folder.badge.arrow.down")
                    .foregroundColor(batch.direction == .upload ? .blue : .green)
                    .font(.system(size: 16))
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 1) {
                    Text(batch.name)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 1) {
                    Text(statusText)
                        .font(.caption)
                        .foregroundColor(statusColor)
                    Text(countText)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                actionButtons
            }

            ProgressView(value: progress)
                .progressViewStyle(.linear)
                .tint(statusColor)
        }
    }

    private var subtitle: String {
        batch.direction == .upload
        ? "\(batch.serverName) -> \(batch.remoteRootPath)"
        : "\(batch.serverName) -> \(batch.localRootURL.path)"
    }

    private var countText: String {
        if tasks.isEmpty {
            return batch.isPrepared ? "0/\(batch.expectedFileCount) 文件" : "准备中"
        }
        let done = tasks.filter { $0.status.isCompletedOrCancelled }.count
        let total = max(batch.expectedFileCount, tasks.count)
        return "\(done)/\(total) 文件"
    }

    private var progress: Double {
        guard !tasks.isEmpty else {
            return batch.isPrepared && batch.expectedFileCount == 0 ? 1 : 0
        }
        let totalBytes = tasks.reduce(Int64(0)) { $0 + max($1.fileSize, $1.bytesTransferred) }
        if totalBytes > 0 {
            let transferred = tasks.reduce(Int64(0)) { sum, task in
                if task.status == .completed { return sum + max(task.fileSize, task.bytesTransferred) }
                return sum + task.bytesTransferred
            }
            return safeProgressValue(Double(transferred) / Double(totalBytes))
        }
        let totalProgress = tasks.map { $0.status.progressFraction }.reduce(0, +)
        return safeProgressValue(totalProgress / Double(tasks.count))
    }

    private var statusText: String {
        if !batch.isPrepared { return "准备中" }
        if tasks.isEmpty {
            return batch.expectedFileCount == 0 ? "完成" : "等待确认"
        }
        if tasks.contains(where: { if case .inProgress = $0.status { return true }; return false }) {
            return "传输中"
        }
        if tasks.contains(where: { if case .failed = $0.status { return true }; return false }) {
            return "有失败"
        }
        let unfinished = tasks.filter { $0.status.isUnfinished }
        if !unfinished.isEmpty && unfinished.allSatisfy({ if case .paused = $0.status { return true }; return false }) {
            return "已暂停"
        }
        if unfinished.isEmpty { return "完成" }
        return "等待中"
    }

    private var statusColor: Color {
        switch statusText {
        case "传输中": return .blue
        case "有失败": return .red
        case "已暂停": return .orange
        case "完成": return .green
        default: return .secondary
        }
    }

    @ViewBuilder private var actionButtons: some View {
        HStack(spacing: 5) {
            Button {
                Task { await appState.pauseTransfers(matching: [batch.id]) }
            } label: {
                Image(systemName: "pause.circle").foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help("暂停目录批次")
            .disabled(!tasks.contains(where: { $0.status.isUnfinished }))

            Button {
                Task { await appState.startOrRetryTransfers(matching: [batch.id]) }
            } label: {
                Image(systemName: "play.circle").foregroundColor(.green)
            }
            .buttonStyle(.plain)
            .help("继续或重试目录批次")
            .disabled(!tasks.contains(where: { $0.status.isUnfinished }))

            Button {
                Task { await appState.cancelTransfers(matching: [batch.id]) }
            } label: {
                Image(systemName: "xmark.circle").foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help("取消目录批次")
            .disabled(!tasks.contains(where: { $0.status.isUnfinished }))
        }
    }
}

// MARK: - Transfer Row
struct TransferRow: View {
    @EnvironmentObject var appState: AppState
    let task: TransferTask

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                // Direction icon
                Image(systemName: task.direction == .upload
                      ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                    .foregroundColor(task.direction == .upload ? .blue : .green)
                    .font(.system(size: 16))

                VStack(alignment: .leading, spacing: 1) {
                    Text(task.fileName).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 1) {
                    statusLabel
                    if !task.displaySpeed.isEmpty {
                        Text(task.displaySpeed).font(.caption2).foregroundColor(.secondary)
                    }
                    if let eta = task.eta {
                        Text("剩余 \(eta)").font(.caption2).foregroundColor(.secondary)
                    }
                }

                // Cancel / Pause buttons
                actionButtons
            }

            // Progress bar
            switch task.status {
            case .inProgress(let p, _):
                ProgressView(value: safeProgressValue(p)).progressViewStyle(.linear).tint(.blue)
            case .completed:
                ProgressView(value: 1.0).progressViewStyle(.linear).tint(.green)
            case .paused(let offset):
                ProgressView(value: pausedProgress(offset: offset)).progressViewStyle(.linear).tint(.orange)
            default: EmptyView()
            }
        }
    }

    private func pausedProgress(offset: Int64) -> Double {
        guard task.fileSize > 0 else { return 0 }
        return safeProgressValue(Double(offset) / Double(task.fileSize))
    }

    private var subtitle: String {
        let target = task.direction == .upload
        ? task.remotePath
        : task.localURL.deletingLastPathComponent().path
        return "\(task.serverName) -> \(target)"
    }

    @ViewBuilder var statusLabel: some View {
        switch task.status {
        case .queued:              Text("等待中").font(.caption).foregroundColor(.secondary)
        case .inProgress(let p,_): Text(progressPercentText(p)).font(.caption).foregroundColor(.blue)
        case .paused:              Text("已暂停").font(.caption).foregroundColor(.orange)
        case .completed:           Text("完成").font(.caption).foregroundColor(.green)
        case .failed(let m):       Text(m).font(.caption).foregroundColor(.red).lineLimit(2)
        case .cancelled:           Text("已取消").font(.caption).foregroundColor(.secondary)
        }
    }

    @ViewBuilder var actionButtons: some View {
        if case .inProgress = task.status {
            Button { Task { await appState.engine.pause(id: task.id) } } label: {
                Image(systemName: "pause.circle").foregroundColor(.secondary)
            }.buttonStyle(.plain).help("暂停")
        }
        if case .queued = task.status {
            Button { Task { await appState.engine.pause(id: task.id) } } label: {
                Image(systemName: "pause.circle").foregroundColor(.secondary)
            }.buttonStyle(.plain).help("暂停")
        }
        if case .paused = task.status {
            Button {
                Task {
                    await appState.engine.resume(id: task.id)
                }
            } label: { Image(systemName: "play.circle").foregroundColor(.green) }.buttonStyle(.plain).help("继续")
        }
        if case .failed = task.status {
            Button {
                Task { await appState.startOrRetryTransfers(matching: [task.id]) }
            } label: { Image(systemName: "arrow.clockwise.circle").foregroundColor(.orange) }.buttonStyle(.plain).help("重试")
        }
        if case .cancelled = task.status {
            Button {
                Task { await appState.startOrRetryTransfers(matching: [task.id]) }
            } label: { Image(systemName: "arrow.clockwise.circle").foregroundColor(.orange) }.buttonStyle(.plain).help("重新开始")
        }
        if task.status != .completed && task.status != .cancelled {
            Button { Task { await appState.engine.cancel(id: task.id) } } label: {
                Image(systemName: "xmark.circle").foregroundColor(.secondary)
            }.buttonStyle(.plain).help("取消")
        }
    }
}

// MARK: - WelcomeView
struct WelcomeView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 28) {
            Spacer()
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 104, height: 104)
                .shadow(color: .black.opacity(0.12), radius: 12, y: 6)

            VStack(spacing: 6) {
                Text("Quay").font(.largeTitle).bold()
                Text("macOS FTP / SFTP 客户端").foregroundColor(.secondary)
            }

            HStack(spacing: 14) {
                Button { appState.presentAddServer() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus.circle")
                            .font(.system(size: 14, weight: .semibold))
                        Text("新建连接")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 14)
                    .frame(height: 29)
                    .background(Capsule().fill(Color(red: 0.0, green: 0.478, blue: 1.0)))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("新建连接")

                if let first = appState.servers.first {
                    Button { Task { await appState.connect(to: first) } } label: {
                        Label("连接 \(first.displayName)", systemImage: "bolt.fill")
                    }.buttonStyle(.bordered).controlSize(.large)
                }
            }

            if !appState.servers.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    Text("最近服务器").font(.caption).foregroundColor(.secondary)
                        .padding(.horizontal, 16).padding(.bottom, 6)
                    ForEach(appState.servers.prefix(4)) { s in
                        Button { Task { await appState.connect(to: s) } } label: {
                            HStack(spacing: 12) {
                                Image(systemName: s.protocol_.sfSymbol)
                                    .foregroundColor(.blue).frame(width: 24)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(s.displayName).font(.system(size: 13, weight: .medium))
                                    Text(s.connectionSummary).font(.caption).foregroundColor(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").foregroundColor(.secondary).font(.caption)
                            }
                            .padding(.horizontal, 16).padding(.vertical, 9)
                            .background(Color(NSColor.controlBackgroundColor).opacity(0.7))
                        }
                        .buttonStyle(.plain)
                        Divider().padding(.leading, 52)
                    }
                }
                .frame(maxWidth: 420)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.2)))
            }
            Spacer()
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.windowBackgroundColor))
    }
}

// MARK: - Settings Root
struct SettingsRootView: View {
    @EnvironmentObject var appState: AppState
    @AppStorage("maxConcurrent") var maxConcurrent = 3
    @AppStorage("showHidden") var showHidden = false
    @AppStorage("debounce") var debounce = 0.5

    var body: some View {
        TabView {
            Form {
                Toggle("显示隐藏文件（.开头）", isOn: $showHidden)
                Stepper("最大并发传输：\(maxConcurrent)", value: $maxConcurrent, in: 1...8)
                    .onChange(of: maxConcurrent) { _, newValue in
                        appState.updateTransferConcurrencyPreference(newValue)
                    }
                Toggle(
                    "登录时启动 Quay",
                    isOn: Binding(
                        get: { appState.launchAtLoginState.isToggleOn },
                        set: { appState.setLaunchAtLoginEnabled($0) }
                    )
                )
                .disabled(appState.launchAtLoginState == .unavailable)
                Text(appState.launchAtLoginState.message)
                    .font(.caption)
                    .foregroundColor(.secondary)
                if appState.launchAtLoginState.needsApproval {
                    Button("打开系统登录项设置") {
                        appState.openLoginItemsSettings()
                    }
                }
                HStack {
                    Text("同步防抖延迟")
                    Slider(value: $debounce, in: 0.1...2.0, step: 0.1)
                    Text("\(debounce, specifier: "%.1f")s").frame(width: 36)
                }
                Button("重新观看引导") {
                    appState.resetOnboarding()
                }
            }
            .padding().tabItem { Label("通用", systemImage: "gear") }

            Form {
                Text("密码安全保存在 macOS 钥匙串中。")
                    .foregroundColor(.secondary)
                Button("清除所有保存的密码") {
                    Task { await appState.clearSavedPasswords() }
                }.foregroundColor(.red)
            }
            .padding().tabItem { Label("安全", systemImage: "lock.shield") }

        }
        .frame(width: 500, height: 360)
        .padding()
        .onAppear {
            appState.refreshLaunchAtLoginStatus()
        }
    }

}
