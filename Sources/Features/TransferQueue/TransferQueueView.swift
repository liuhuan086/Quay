// TransferQueueView.swift + WelcomeView.swift
import SwiftUI

// MARK: - TransferQueueView
struct TransferQueueView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("传输队列").font(.headline)
                Spacer()
                Button("清除已完成") {
                    Task { await appState.engine.clearCompleted()
                        appState.transfers.removeAll { $0.status == .completed || $0.status == .cancelled }
                    }
                }.font(.caption).disabled(appState.transfers.filter {
                    $0.status == .completed || $0.status == .cancelled
                }.isEmpty)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)

            Divider()

            if appState.transfers.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "tray").font(.largeTitle).foregroundColor(.secondary)
                    Text("暂无传输任务").foregroundColor(.secondary).font(.callout)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(appState.transfers) { task in
                    TransferRow(task: task)
                        .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                }
                .listStyle(.plain)
            }
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
                    Text(task.serverName).font(.caption2).foregroundColor(.secondary)
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
                ProgressView(value: p).progressViewStyle(.linear).tint(.blue)
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
        return min(1.0, max(0.0, Double(offset) / Double(task.fileSize)))
    }

    @ViewBuilder var statusLabel: some View {
        switch task.status {
        case .queued:              Text("等待中").font(.caption).foregroundColor(.secondary)
        case .inProgress(let p,_): Text("\(Int(p*100))%").font(.caption).foregroundColor(.blue)
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
            }.buttonStyle(.plain)
        }
        if case .paused = task.status {
            Button {
                Task {
                    await appState.engine.resume(id: task.id)
                }
            } label: { Image(systemName: "play.circle").foregroundColor(.green) }.buttonStyle(.plain)
        }
        if task.status != .completed && task.status != .cancelled {
            Button { Task { await appState.engine.cancel(id: task.id) } } label: {
                Image(systemName: "xmark.circle").foregroundColor(.secondary)
            }.buttonStyle(.plain)
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
                Text("SwiftFTP").font(.largeTitle).bold()
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
                    .disabled(!appState.hasFullAccess)
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
                    for i in appState.servers.indices {
                        var s = appState.servers[i]
                        s.password = ""
                        appState.updateServer(s)
                    }
                }.foregroundColor(.red)
            }
            .padding().tabItem { Label("安全", systemImage: "lock.shield") }

            Form {
                if appState.isPro {
                    Label("已解锁 Pro", systemImage: "checkmark.seal.fill")
                        .foregroundColor(.green)
                    Text("无限服务器、实时同步和多并发传输已启用。")
                        .foregroundColor(.secondary)
                } else if appState.isTrialActive {
                    Label("7 天试用中", systemImage: "clock.fill")
                        .foregroundColor(.blue)
                    Text("剩余约 \(appState.trialDaysRemaining) 天。试用结束后需要购买 Pro 才能继续使用。")
                        .foregroundColor(.secondary)
                    Button("购买 Pro - $4.99") {
                        Task { await appState.storeManager.purchasePro() }
                    }
                    .disabled(appState.storeManager.isLoading)
                    Button("恢复购买") {
                        Task { await appState.storeManager.restorePurchases() }
                    }
                    .disabled(appState.storeManager.isLoading)
                } else {
                    Text(appState.trialStartedAt == nil
                         ? "SwiftFTP 不提供永久免费版。开始 7 天试用可使用全部功能；试用结束后需要购买 Pro。"
                         : "7 天试用已结束。购买 Pro 后继续使用全部功能。")
                        .foregroundColor(.secondary)
                    if appState.trialStartedAt == nil {
                        Button("开始 7 天试用") {
                            appState.startTrial()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    Button("购买 Pro - $4.99") {
                        Task { await appState.storeManager.purchasePro() }
                    }
                    .disabled(appState.storeManager.isLoading)
                    Button("恢复购买") {
                        Task { await appState.storeManager.restorePurchases() }
                    }
                    .disabled(appState.storeManager.isLoading)
                }
                if appState.storeManager.isLoading {
                    ProgressView()
                        .controlSize(.small)
                }
                if let message = appState.storeManager.statusMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding().tabItem { Label("购买", systemImage: "cart") }
        }
        .frame(width: 500, height: 320)
        .padding()
    }
}
