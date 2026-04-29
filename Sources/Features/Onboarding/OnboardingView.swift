// OnboardingView.swift — First-run product tour
import SwiftUI

struct OnboardingView: View {
    let onFinish: () -> Void

    @State private var stepIndex = 0

    private let steps: [OnboardingStep] = [
        OnboardingStep(
            symbol: "arrow.up.arrow.down.circle.fill",
            title: "欢迎使用 SwiftFTP",
            subtitle: "极简、安全、Swift 原生的 SFTP 客户端",
            accent: .blue
        ),
        OnboardingStep(
            symbol: "plus.rectangle.on.folder",
            title: "快速新建连接",
            subtitle: "从侧边栏的加号进入表单，保存后即可连接常用服务器。",
            accent: .indigo
        ),
        OnboardingStep(
            symbol: "arrow.triangle.2.circlepath.circle.fill",
            title: "拖拽上传与实时同步",
            subtitle: "把文件拖到远端面板上传，也可以为常用目录开启自动同步。",
            accent: .cyan
        )
    ]

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

                Spacer(minLength: 32)

                HStack(spacing: 8) {
                    ForEach(steps.indices, id: \.self) { index in
                        Capsule()
                            .fill(index == stepIndex ? Color.accentColor : Color.secondary.opacity(0.25))
                            .frame(width: index == stepIndex ? 22 : 8, height: 8)
                            .animation(.easeInOut(duration: 0.18), value: stepIndex)
                    }
                }
                .padding(.bottom, 22)

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
                        if stepIndex == steps.count - 1 {
                            onFinish()
                        } else {
                            withAnimation(.easeInOut(duration: 0.18)) {
                                stepIndex += 1
                            }
                        }
                    } label: {
                        Label(stepIndex == steps.count - 1 ? "开始使用" : "下一步",
                              systemImage: stepIndex == steps.count - 1 ? "checkmark" : "chevron.right")
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                }
                .padding(.bottom, 34)
            }
            .frame(maxWidth: 760, maxHeight: 620)
        }
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
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(.thinMaterial)
                    .shadow(color: .black.opacity(0.10), radius: 28, y: 16)
                    .overlay(
                        RoundedRectangle(cornerRadius: 28, style: .continuous)
                            .stroke(Color.white.opacity(0.55), lineWidth: 1)
                    )

                Image(systemName: step.symbol)
                    .font(.system(size: 96, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(step.accent)
            }
            .frame(width: 260, height: 190)

            VStack(spacing: 10) {
                Text(step.title)
                    .font(.system(size: 30, weight: .semibold))
                    .multilineTextAlignment(.center)
                Text(step.subtitle)
                    .font(.system(size: 15))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .frame(maxWidth: 420)
            }
        }
        .padding(.horizontal, 32)
    }
}
