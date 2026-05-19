// OnboardingView.swift — First-run product tour
import SwiftUI

struct OnboardingView: View {
    @ObservedObject var appState: AppState
    let onFinish: () -> Void

    @State private var stepIndex = 0

    private var steps: [OnboardingStep] {
        [
            OnboardingStep(
                symbol: "arrow.up.arrow.down.circle.fill",
                title: "欢迎使用 Quay",
                subtitle: "极简、安全、Swift 原生的 FTP/FTPS/SFTP 文件传输客户端。",
                accent: .blue
            ),
            OnboardingStep(
                symbol: "plus.rectangle.on.folder",
                title: "快速新建连接",
                subtitle: "保存常用服务器，双栏浏览本地与远端文件。",
                accent: .indigo
            ),
            OnboardingStep(
                symbol: "arrow.triangle.2.circlepath.circle.fill",
                title: "拖拽上传与实时同步",
                subtitle: "把文件拖到远端面板上传，也可以为常用目录开启自动同步。",
                accent: .cyan
            ),
            OnboardingStep(
                symbol: "checkmark.seal.fill",
                title: "7 天完整试用",
                subtitle: trialDisclosure,
                accent: .green
            )
        ]
    }

    var body: some View {
        ZStack {
            Color(NSColor.windowBackgroundColor).ignoresSafeArea()

            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    Button("跳过") { onFinish() }
                        .buttonStyle(.borderless)
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 32)
                .padding(.top, 28)

                Spacer(minLength: 28)

                OnboardingStepView(step: steps[stepIndex])
                    .id(stepIndex)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))

                Spacer(minLength: 24)

                HStack(spacing: 8) {
                    ForEach(steps.indices, id: \.self) { index in
                        Capsule()
                            .fill(index == stepIndex ? Color.accentColor : Color.secondary.opacity(0.25))
                            .frame(width: index == stepIndex ? 22 : 8, height: 8)
                            .animation(.easeInOut(duration: 0.18), value: stepIndex)
                    }
                }
                .padding(.bottom, 20)

                if stepIndex == steps.count - 1 {
                    purchaseControls
                        .padding(.bottom, 28)
                } else {
                    navigationControls
                        .padding(.bottom, 34)
                }
            }
            .frame(maxWidth: 780, maxHeight: 660)
        }
        .task {
            await appState.storeManager.loadProducts()
        }
    }

    private var navigationControls: some View {
        HStack(spacing: 12) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    stepIndex = max(0, stepIndex - 1)
                }
            } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(stepIndex == 0)
            .help("上一步")

            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    stepIndex += 1
                }
            } label: {
                Label("下一步", systemImage: "chevron.right")
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
    }

    private var purchaseControls: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Button("开始 7 天试用") {
                    Task {
                        if await appState.startTrial() {
                            onFinish()
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!appState.storeManager.canStartTrial || appState.storeManager.isLoading)
                .help(appState.storeManager.canStartTrial ? "开始完整试用" : "正在加载试用与价格信息")

                Button(proButtonTitle) {
                    Task {
                        if await appState.purchasePro() {
                            onFinish()
                        }
                    }
                }
                .buttonStyle(.bordered)
                .disabled(appState.storeManager.isLoading)

                Button("恢复购买") {
                    Task {
                        if await appState.restorePurchases() {
                            onFinish()
                        }
                    }
                }
                .buttonStyle(.bordered)
                .disabled(appState.storeManager.isLoading)
            }

            HStack(spacing: 10) {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        stepIndex = max(0, stepIndex - 1)
                    }
                } label: {
                    Image(systemName: "chevron.left")
                }
                .help("上一步")

                Button("稍后再说") { onFinish() }
                    .buttonStyle(.borderless)
            }

            if appState.storeManager.isLoading || appState.storeManager.isRefreshingEntitlements {
                ProgressView()
                    .controlSize(.small)
            }
            if let pending = appState.storeManager.pendingPurchaseKind {
                Text("\(pending.displayName) 正在等待批准。")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            if let message = appState.storeManager.statusMessage {
                Text(message)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
            }
        }
    }

    private var trialDisclosure: String {
        let price = appState.storeManager.proDisplayPrice ?? "正在加载价格"
        return "试用期间可使用全部本地 FTP/FTPS/SFTP 功能。试用结束后，连接、上传、下载、实时同步将被锁定；服务器配置与本地数据不会被删除，可继续查看与导出。永久解锁需一次性购买 \(price)，无订阅。"
    }

    private var proButtonTitle: String {
        if let price = appState.storeManager.proDisplayPrice {
            return "直接购买 - \(price)"
        }
        return "直接购买"
    }
}

private struct OnboardingStep: Identifiable {
    let id = UUID()
    let symbol: String
    let title: String
    let subtitle: String
    let accent: Color
}

private struct OnboardingStepView: View {
    let step: OnboardingStep

    var body: some View {
        VStack(spacing: 24) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.thinMaterial)
                    .shadow(color: .black.opacity(0.10), radius: 28, y: 16)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color.white.opacity(0.55), lineWidth: 1)
                    )

                Image(systemName: step.symbol)
                    .font(.system(size: 92, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(step.accent)
            }
            .frame(width: 260, height: 180)

            VStack(spacing: 10) {
                Text(step.title)
                    .font(.system(size: 30, weight: .semibold))
                    .multilineTextAlignment(.center)
                Text(step.subtitle)
                    .font(.system(size: 15))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .frame(maxWidth: 520)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 32)
    }
}
