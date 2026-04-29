// FileViewModels.swift
import SwiftUI
import Combine

// MARK: - LocalFileItem
struct LocalFileItem: Identifiable {
    let id = UUID()
    let url: URL
    let name: String
    let isDirectory: Bool
    let size: Int64
    let modifiedDate: Date?

    var displaySize: String { isDirectory ? "—" : ByteCountFormatter.string(fromByteCount: size, countStyle: .file) }
    var sfSymbol: String {
        if isDirectory { return "folder.fill" }
        switch url.pathExtension.lowercased() {
        case "jpg","jpeg","png","gif","webp": return "photo"
        case "pdf": return "doc.richtext"
        case "zip","tar","gz": return "archivebox"
        case "swift","py","js","ts","html","css","go","rs": return "chevron.left.forwardslash.chevron.right"
        default: return "doc"
        }
    }
}

// MARK: - LocalFileVM
@MainActor
final class LocalFileVM: ObservableObject {
    @Published var items: [LocalFileItem] = []
    @Published var currentPath: String = NSHomeDirectory()
    @Published var showHidden = false
    @Published var selectedIDs: Set<UUID> = []

    private var history: [String] = []
    var canGoBack: Bool { !history.isEmpty }

    var sortedItems: [LocalFileItem] {
        let filtered = showHidden ? items : items.filter { !$0.name.hasPrefix(".") }
        return filtered.filter { $0.isDirectory } + filtered.filter { !$0.isDirectory }
    }

    init() { load(currentPath) }

    func enter(_ item: LocalFileItem) {
        guard item.isDirectory else { return }
        history.append(currentPath)
        load(item.url.path)
    }

    func navigateBack() {
        guard let prev = history.popLast() else { return }
        load(prev)
    }

    func refresh() { load(currentPath) }

    func openInFinder() {
        // FIXME(AppSandbox): only open folders the user selected or restored
        // through a security-scoped bookmark.
        NSWorkspace.shared.open(URL(fileURLWithPath: currentPath))
    }

    private func load(_ path: String) {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(
            at: URL(fileURLWithPath: path),
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
            options: []
        ) else { return }

        items = urls.map { url in
            let res = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
            return LocalFileItem(
                url: url, name: url.lastPathComponent,
                isDirectory: res?.isDirectory ?? false,
                size: Int64(res?.fileSize ?? 0),
                modifiedDate: res?.contentModificationDate
            )
        }
        currentPath = path
    }
}

// MARK: - RemoteFileVM
@MainActor
final class RemoteFileVM: ObservableObject {
    @Published var items: [RemoteFileItem] = []
    @Published var currentPath: String
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var selectedIDs: Set<UUID> = []
    @Published var showHidden = false

    private var history: [String] = []
    private var client: any AnyFTPClient
    var canGoBack: Bool { !history.isEmpty }

    var sortedItems: [RemoteFileItem] {
        let filtered = showHidden ? items : items.filter { !$0.name.hasPrefix(".") }
        return filtered.filter { $0.isDirectory } + filtered.filter { !$0.isDirectory }
    }

    init(client: any AnyFTPClient, initialPath: String = "/") {
        self.client = client
        self.currentPath = initialPath
        Task { await load(initialPath) }
    }

    func enter(_ item: RemoteFileItem) async {
        guard item.isDirectory else { return }
        history.append(currentPath)
        await load(item.path)
    }

    func goBack() async {
        guard let prev = history.popLast() else { return }
        await load(prev)
    }

    func refresh() async { await load(currentPath) }

    func createFolder(name: String) async {
        let path = currentPath.hasSuffix("/") ? currentPath + name : currentPath + "/" + name
        do { try await client.createDirectory(path); await refresh() }
        catch { errorMessage = friendlyMessage(error) }
    }

    func deleteSelected() async {
        let toDelete = sortedItems.filter { selectedIDs.contains($0.id) }
        for item in toDelete {
            do { try await client.delete(path: item.path, isDirectory: item.isDirectory) }
            catch { errorMessage = friendlyMessage(error) }
        }
        selectedIDs.removeAll()
        await refresh()
    }

    func rename(item: RemoteFileItem, to name: String) async {
        let dir = (item.path as NSString).deletingLastPathComponent
        let newPath = dir + "/" + name
        do { try await client.rename(from: item.path, to: newPath); await refresh() }
        catch { errorMessage = friendlyMessage(error) }
    }

    private func load(_ path: String) async {
        isLoading = true; errorMessage = nil
        do {
            items = try await client.listDirectory(path)
            currentPath = path
        } catch {
            errorMessage = friendlyMessage(error)
        }
        isLoading = false
    }

    private func friendlyMessage(_ error: Error) -> String {
        FTPError.friendly(error).errorDescription ?? error.localizedDescription
    }
}
