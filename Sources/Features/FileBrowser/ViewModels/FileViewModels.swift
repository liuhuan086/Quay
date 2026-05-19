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
    @Published var errorMessage: String?

    private var history: [String] = []
    private let directoryBookmarkKey = "swiftftp.v2.localDirectoryBookmark"
    private var activeScopedURL: URL?
    private var isAccessingScopedURL = false
    private var isPresentingAccessPanel = false
    private var shouldOfferInitialAccess = false
    private var pendingAccessPath: String?

    var canGoUp: Bool {
        let parent = (currentPath as NSString).deletingLastPathComponent
        return !parent.isEmpty && parent != currentPath
    }

    var sortedItems: [LocalFileItem] {
        let filtered = showHidden ? items : items.filter { !$0.name.hasPrefix(".") }
        return filtered.filter { $0.isDirectory } + filtered.filter { !$0.isDirectory }
    }

    init() {
        if !restoreBookmarkedDirectory() {
            _ = load(currentPath)
            pendingAccessPath = preferredUserDirectoryPath
            shouldOfferInitialAccess = true
        }
    }

    func enter(_ item: LocalFileItem) {
        guard item.isDirectory else { return }
        navigate(to: item.url.path)
    }

    func navigateUp() {
        guard canGoUp else { return }
        navigate(to: (currentPath as NSString).deletingLastPathComponent)
    }

    func navigate(to path: String) {
        let normalizedPath = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path
        guard normalizedPath != currentPath else { return }
        let previousPath = currentPath
        if load(normalizedPath) {
            history.append(previousPath)
        } else {
            requestDirectoryAccess(
                suggestedPath: normalizedPath,
                message: "Quay 需要你授权访问此目录或它的上级目录。"
            )
        }
    }

    func refresh() { _ = load(currentPath) }

    func delete(_ itemsToDelete: [LocalFileItem]) {
        guard !itemsToDelete.isEmpty else { return }
        let fm = FileManager.default
        var failureMessage: String?
        for item in itemsToDelete {
            do {
                try fm.removeItem(at: item.url)
            } catch {
                failureMessage = "删除失败：\(item.name)。\(error.localizedDescription)"
                break
            }
        }
        selectedIDs.removeAll()
        refresh()
        if let failureMessage {
            errorMessage = failureMessage
        }
    }

    func rename(item: LocalFileItem, to newName: String) {
        let trimmedName = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, trimmedName != item.name else { return }
        let targetURL = item.url
            .deletingLastPathComponent()
            .appendingPathComponent(trimmedName, isDirectory: item.isDirectory)
        do {
            try FileManager.default.moveItem(at: item.url, to: targetURL)
            refresh()
        } catch {
            errorMessage = "重命名失败：\(item.name)。\(error.localizedDescription)"
        }
    }

    func requestInitialDirectoryAccessIfNeeded() {
        guard shouldOfferInitialAccess else { return }
        shouldOfferInitialAccess = false
        requestDirectoryAccess(
            suggestedPath: pendingAccessPath ?? preferredUserDirectoryPath,
            message: "请选择一个本地目录，授权 Quay 浏览、上传和下载文件。"
        )
    }

    func requestDirectoryAccess() {
        requestDirectoryAccess(
            suggestedPath: pendingAccessPath ?? currentPath,
            message: "请选择要授权 Quay 访问的本地目录。"
        )
    }

    func openInFinder() {
        NSWorkspace.shared.open(URL(fileURLWithPath: currentPath))
    }

    @discardableResult
    private func load(_ path: String) -> Bool {
        let fm = FileManager.default
        let directoryURL = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        do {
            let urls = try fm.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
                options: []
            )

            items = urls.map { url in
                let res = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
                return LocalFileItem(
                    url: url, name: url.lastPathComponent,
                    isDirectory: res?.isDirectory ?? false,
                    size: Int64(res?.fileSize ?? 0),
                    modifiedDate: res?.contentModificationDate
                )
            }
            currentPath = directoryURL.path
            selectedIDs.removeAll()
            errorMessage = nil
            pendingAccessPath = nil
            return true
        } catch {
            errorMessage = Self.localAccessErrorMessage(error, path: directoryURL.path)
            pendingAccessPath = directoryURL.path
            return false
        }
    }

    private func restoreBookmarkedDirectory() -> Bool {
        guard let data = UserDefaults.standard.data(forKey: directoryBookmarkKey) else { return false }
        do {
            var isStale = false
            let url = try URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            activateSecurityScope(for: url)
            if isStale {
                persistBookmark(for: url)
            }
            return load(url.path)
        } catch {
            UserDefaults.standard.removeObject(forKey: directoryBookmarkKey)
            errorMessage = "本地目录授权已失效，请重新选择目录。"
            return false
        }
    }

    private func requestDirectoryAccess(suggestedPath: String, message: String) {
        guard !isPresentingAccessPanel else { return }
        isPresentingAccessPanel = true

        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "授权访问"
        panel.message = message
        panel.directoryURL = URL(fileURLWithPath: suggestedPath, isDirectory: true)

        panel.begin { [weak self] response in
            Task { @MainActor in
                guard let self else { return }
                self.isPresentingAccessPanel = false
                guard response == .OK, let url = panel.url else {
                    self.errorMessage = "未授予本地目录访问权限。请选择一个目录后才能稳定浏览、上传和下载。"
                    return
                }
                self.activateSecurityScope(for: url)
                self.persistBookmark(for: url)
                _ = self.load(url.path)
            }
        }
    }

    private func activateSecurityScope(for url: URL) {
        if isAccessingScopedURL {
            activeScopedURL?.stopAccessingSecurityScopedResource()
        }
        activeScopedURL = url
        isAccessingScopedURL = url.startAccessingSecurityScopedResource()
    }

    private func persistBookmark(for url: URL) {
        do {
            let data = try url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            UserDefaults.standard.set(data, forKey: directoryBookmarkKey)
        } catch {
            errorMessage = "目录已授权，但保存授权记录失败：\(error.localizedDescription)"
        }
    }

    private var preferredUserDirectoryPath: String {
        let userName = NSUserName()
        return userName.isEmpty ? NSHomeDirectory() : "/Users/\(userName)"
    }

    private static func localAccessErrorMessage(_ error: Error, path: String) -> String {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain {
            switch nsError.code {
            case NSFileReadNoPermissionError, NSFileWriteNoPermissionError:
                return "没有权限访问：\(path)。请点击“选择授权目录”授予访问权限。"
            case NSFileReadNoSuchFileError:
                return "目录不存在：\(path)"
            default:
                break
            }
        }
        if nsError.domain == NSPOSIXErrorDomain {
            switch nsError.code {
            case Int(EACCES), Int(EPERM):
                return "没有权限访问：\(path)。请点击“选择授权目录”授予访问权限。"
            case Int(ENOENT):
                return "目录不存在：\(path)"
            default:
                break
            }
        }
        return "无法打开目录：\(path)。\(error.localizedDescription)"
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
    var canGoUp: Bool { currentPath != "/" }

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
        let previousPath = currentPath
        if await load(item.path) {
            history.append(previousPath)
        }
    }

    func goUp() async {
        guard canGoUp else { return }
        await navigate(to: parentPath(for: currentPath))
    }

    func navigate(to path: String) async {
        let normalized = normalizedRemotePath(path)
        guard normalized != currentPath else { return }
        let previousPath = currentPath
        if await load(normalized) {
            history.append(previousPath)
        }
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

    @discardableResult
    private func load(_ path: String) async -> Bool {
        isLoading = true; errorMessage = nil
        do {
            items = try await client.listDirectory(path)
            currentPath = path
            selectedIDs.removeAll()
            isLoading = false
            return true
        } catch {
            errorMessage = friendlyMessage(error)
            isLoading = false
            return false
        }
    }

    private func friendlyMessage(_ error: Error) -> String {
        FTPError.friendly(error).errorDescription ?? error.localizedDescription
    }

    private func parentPath(for path: String) -> String {
        let trimmed = normalizedRemotePath(path).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !trimmed.isEmpty else { return "/" }
        let parts = trimmed.split(separator: "/").dropLast()
        return parts.isEmpty ? "/" : "/" + parts.joined(separator: "/")
    }

    private func normalizedRemotePath(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "/" }
        let absolute = trimmed.hasPrefix("/") ? trimmed : "/" + trimmed
        let collapsed = absolute.split(separator: "/").joined(separator: "/")
        return collapsed.isEmpty ? "/" : "/" + collapsed
    }
}
