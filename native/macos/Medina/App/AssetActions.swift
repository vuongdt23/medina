import SwiftUI
import AppKit
import MedinaCore

/// Shared asset operations used by both the item inspector and the sidebar
/// resource rows: save-to-disk download, folder-as-ZIP, and fetching a file's
/// bytes into a temporary file for Quick Look. Keeping these in one place avoids
/// duplicating the NSSavePanel / temp-file dance across views.
enum AssetActions {
    /// Prompts for a destination and streams the asset (or a folder's ZIP) there.
    /// Throws on network/write failure; callers surface the message.
    @MainActor
    static func download(_ item: TreeNode, client: MedinaAPIClient) async throws {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = suggestedFilename(for: item)
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        let url = item.type == "asset_directory"
            ? client.assetArchiveURL(id: item.id)
            : client.assetDownloadURL(id: item.id)
        try await client.download(from: url, to: destination)
    }

    /// Fetches a previewable asset into a uniquely named temp file whose
    /// extension matches the source, so Quick Look picks the right renderer.
    /// The caller owns the returned URL and must remove it when done.
    @MainActor
    static func fetchPreviewFile(_ item: TreeNode, client: MedinaAPIClient) async throws -> URL {
        let data = try await client.previewAsset(id: item.id)
        let rawExtension = (item.fileExtension ?? "").trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        let ext = String(rawExtension.filter { $0.isLetter || $0.isNumber })
        let suffix = ext.isEmpty ? (item.mimeType == "application/pdf" ? "pdf" : "txt") : ext
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Medina-\(UUID().uuidString)")
            .appendingPathExtension(suffix)
        try data.write(to: url, options: .atomic)
        return url
    }

    /// The default filename offered when saving — the original name, with a
    /// `.zip` suffix for folder archives.
    static func suggestedFilename(for item: TreeNode) -> String {
        let name = (item.originalName ?? item.title) as NSString
        let safeName = name.lastPathComponent
        if item.type == "asset_directory", !safeName.lowercased().hasSuffix(".zip") {
            return safeName + ".zip"
        }
        return safeName
    }
}
