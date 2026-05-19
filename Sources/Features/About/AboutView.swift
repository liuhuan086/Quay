// AboutView.swift — App information and third-party acknowledgements
import SwiftUI

struct AboutView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var showingAcknowledgements = false

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "2.0.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }

    var body: some View {
        VStack(spacing: 22) {
            HStack(alignment: .top) {
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("关闭")
            }

            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
                .shadow(color: .black.opacity(0.12), radius: 12, y: 6)

            VStack(spacing: 6) {
                Text("SwiftFTP")
                    .font(.system(size: 30, weight: .semibold))
                Text("版本 \(appVersion)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Text("SwiftFTP 是一个面向 macOS 的轻量 FTP / FTPS / SFTP 客户端，专注于安全保存凭据、快速文件传输和常用目录同步。")
                .font(.callout)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .frame(maxWidth: 420)

            HStack(spacing: 18) {
                Link("官网", destination: AppLinks.homepage)
                Link("隐私政策", destination: AppLinks.privacyPolicy)
                Link("用户协议", destination: AppLinks.termsOfUse)
            }
            .font(.callout)

            Button("第三方致谢") {
                showingAcknowledgements = true
            }
            .buttonStyle(.bordered)

            Spacer(minLength: 0)
        }
        .padding(28)
        .frame(width: 520, height: 480)
        .sheet(isPresented: $showingAcknowledgements) {
            AcknowledgementsView()
        }
    }
}

private struct AcknowledgementsView: View {
    @Environment(\.dismiss) private var dismiss
    private let acknowledgements = Acknowledgement.load()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("第三方致谢")
                    .font(.headline)
                Spacer()
                Button("完成") { dismiss() }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            Divider()

            List(acknowledgements) { item in
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(item.name)
                            .font(.system(size: 13, weight: .semibold))
                        Spacer()
                        Text(item.license)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Text(item.copyright)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    if let url = URL(string: item.url) {
                        Link(item.url, destination: url)
                            .font(.caption)
                    }
                }
                .padding(.vertical, 5)
            }
            .listStyle(.plain)
        }
        .frame(width: 560, height: 460)
    }
}

private struct Acknowledgement: Decodable, Identifiable {
    let name: String
    let license: String
    let copyright: String
    let url: String

    var id: String { name }

    static func load() -> [Acknowledgement] {
        guard let url = Bundle.main.url(forResource: "Acknowledgements", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([Acknowledgement].self, from: data) else {
            return fallback
        }
        return decoded
    }

    private static let fallback: [Acknowledgement] = [
        Acknowledgement(
            name: "Citadel",
            license: "BSD-2-Clause",
            copyright: "Copyright (c) Joannis Orlandos",
            url: "https://github.com/orlandos-nl/Citadel"
        ),
        Acknowledgement(
            name: "SwiftNIO",
            license: "Apache License 2.0",
            copyright: "Copyright (c) Apple Inc. and the SwiftNIO project authors",
            url: "https://github.com/apple/swift-nio"
        )
    ]
}
