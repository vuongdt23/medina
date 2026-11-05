import SwiftUI
import AppKit
import QuickLookUI
import MedinaCore

/// How a selected asset should be previewed inline in the inspector.
enum PreviewKind {
    case image, pdf, markdown, code, web, unsupported
}

/// The item inspector: an editorial header plus a rich inline preview chosen by
/// file kind — zoomable image, inline PDF, rendered Markdown, highlighted code,
/// or a sandboxed web view for HTML/SVG — with Quick Look and download actions.
struct ItemDetail: View {
    let item: TreeNode
    let client: MedinaAPIClient?
    let progress: LessonProgress?
    var onPlay: (TreeNode) -> Void

    @Environment(\.colorScheme) private var scheme
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var previewData: Data?
    @State private var webMimeType: String = "text/html"
    @State private var localPreviewURL: URL?
    @State private var showingPreview = false

    private var kind: PreviewKind { Self.previewKind(for: item) }
    /// Decoded UTF-8 text for code/markdown; nil for binary kinds.
    private var previewText: String? {
        guard kind == .code || kind == .markdown, let data = previewData else { return nil }
        return String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(Theme.hairline(scheme))
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: item.id) { await loadPreviewData() }
        .sheet(isPresented: $showingPreview, onDismiss: removePreviewFile) {
            if let localPreviewURL {
                NativeQuickLookPreview(url: localPreviewURL)
                    .frame(minWidth: 700, minHeight: 500)
            }
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Chip(typeLabel, systemImage: typeIcon,
                     tint: item.type == "lesson" ? Theme.accent : .secondary)
                if let lang = CodeViewer.language(for: item.fileExtension) {
                    Chip(lang.uppercased(), tint: Theme.accent)
                }
                if progress?.isEffectivelyComplete == true {
                    Chip("Completed", systemImage: "checkmark", tint: Theme.done)
                }
                Spacer()
            }
            Text(item.title)
                .font(Theme.display(22, .bold))
                .lineLimit(3)
            HStack(spacing: 10) {
                if let name = item.originalName, name != item.title {
                    Text(name).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                }
                if let size = item.sizeBytes {
                    Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                        .font(.system(size: 11)).foregroundStyle(.tertiary)
                }
            }
            actions
        }
        .padding(20)
        .background(Theme.card(scheme))
    }

    @ViewBuilder private var actions: some View {
        HStack(spacing: 10) {
            switch item.type {
            case "lesson":
                Button { onPlay(item) } label: {
                    Label(resumeLabel, systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent).tint(Theme.accent)
            case "asset_directory":
                Button { Task { await downloadAsset() } } label: {
                    Label("Download folder as ZIP", systemImage: "archivebox")
                }.disabled(isWorking || client == nil)
            case "asset":
                if supportsQuickLook {
                    Button { Task { await loadPreview() } } label: {
                        Label("Open Fullscreen", systemImage: "arrow.up.left.and.arrow.down.right")
                    }.disabled(isWorking || client == nil)
                }
                if let text = previewText {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                    } label: { Label("Copy", systemImage: "doc.on.doc") }
                }
                Button { Task { await downloadAsset() } } label: {
                    Label("Download", systemImage: "arrow.down.to.line")
                }.disabled(isWorking || client == nil)
            default:
                EmptyView()
            }
            if isWorking { ProgressView().controlSize(.small) }
        }
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        if item.type == "lesson" {
            centered {
                VStack(spacing: 8) {
                    Image(systemName: item.mediaKind == "audio" ? "music.note" : "play.rectangle")
                        .font(.system(size: 40)).foregroundStyle(Theme.accent.opacity(0.7))
                    Text(resumeLabel).font(.callout).foregroundStyle(.secondary)
                }
            }
        } else if let errorMessage {
            centered {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red).font(.callout)
                    .multilineTextAlignment(.center)
            }
        } else if isWorking && previewData == nil {
            centered { ProgressView("Loading…").controlSize(.small) }
        } else {
            preview
        }
    }

    @ViewBuilder private var preview: some View {
        switch kind {
        case .image:
            if let data = previewData, let image = NSImage(data: data) {
                ImagePreview(image: image).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else { unsupportedState }
        case .pdf:
            if let data = previewData {
                PDFPreview(data: data).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else { unsupportedState }
        case .markdown:
            if let text = previewText {
                MarkdownPreview(text: text).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else { unsupportedState }
        case .code:
            if let text = previewText {
                CodeViewer(code: text, fileExtension: item.fileExtension)
            } else { unsupportedState }
        case .web:
            if let data = previewData {
                WebDocumentPreview(data: data, mimeType: webMimeType)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else { unsupportedState }
        case .unsupported:
            unsupportedState
        }
    }

    private var unsupportedState: some View {
        centered {
            VStack(spacing: 6) {
                Image(systemName: "doc").font(.system(size: 32)).foregroundStyle(.tertiary)
                Text("No inline preview for this file type.")
                    .font(.callout).foregroundStyle(.secondary)
                Text("Use Quick Look or download the original.")
                    .font(.caption).foregroundStyle(.tertiary)
            }
        }
    }

    private func centered<V: View>(@ViewBuilder _ content: () -> V) -> some View {
        VStack { Spacer(); content(); Spacer() }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(24)
    }

    // MARK: Derived

    private var typeLabel: String { item.type.replacingOccurrences(of: "_", with: " ").capitalized }
    private var typeIcon: String {
        switch item.type {
        case "lesson": return "play.rectangle"
        case "asset_directory": return "folder"
        default: return "doc"
        }
    }
    private var resumeLabel: String {
        if let p = progress, p.positionSeconds > 1, !p.isEffectivelyComplete,
           let at = Duration.lessonLabel(seconds: p.positionSeconds) {
            return "Play (last at \(at))"
        }
        return "Play from beginning"
    }
    /// Quick Look is only offered where fullscreen adds something the inline
    /// preview can't: images (zoom/pan at full resolution) and PDFs (full
    /// reader). Code, Markdown, and web already render fully inline, so a
    /// Quick Look button there is redundant.
    private var supportsQuickLook: Bool {
        kind == .image || kind == .pdf
    }

    /// Classifies an asset into the inline preview to render. Extension is the
    /// primary signal (the server's mime database is incomplete — `.kt`, `.webp`
    /// and others often arrive as `application/octet-stream`), with MIME as a
    /// fallback. Mirrors the server's widened `previewable` allowlist.
    static func previewKind(for item: TreeNode) -> PreviewKind {
        guard item.type == "asset" else { return .unsupported }
        let ext = (item.fileExtension ?? "").trimmingCharacters(in: CharacterSet(charactersIn: ". ")).lowercased()
        let mime = (item.mimeType ?? "").split(separator: ";", maxSplits: 1).first.map(String.init)?.lowercased() ?? ""
        if ["html", "htm", "xhtml", "svg", "svgz"].contains(ext) || mime == "text/html"
            || mime == "application/xhtml+xml" || mime == "image/svg+xml" { return .web }
        if Self.imageExtensions.contains(ext) || mime.hasPrefix("image/") { return .image }
        if ext == "pdf" || mime == "application/pdf" { return .pdf }
        if ext == "md" || ext == "markdown" { return .markdown }
        if CodeViewer.supports(extension: item.fileExtension, mimeType: item.mimeType) || mime.hasPrefix("text/") {
            return .code
        }
        return .unsupported
    }

    /// Raster/vector image extensions renderable by `NSImage`; kept in sync with
    /// the server's `imageExtensions`. SVG is routed to the web view instead.
    private static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "bmp", "avif", "tiff", "tif", "ico", "heic", "heif",
    ]

    // MARK: Loading

    @MainActor private func loadPreviewData() async {
        previewData = nil
        errorMessage = nil
        guard item.type == "asset", let client else { return }
        let kind = self.kind
        guard kind != .unsupported else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            if kind == .web {
                // HTML/SVG are 415 on /preview; fetch raw bytes from /content.
                let (data, mime) = try await client.fetchContent(id: item.id)
                previewData = data
                webMimeType = mime ?? (item.mimeType ?? "text/html")
            } else {
                previewData = try await client.previewAsset(id: item.id)
            }
        } catch let MedinaAPIError.httpStatus(status, _) where status == 415 {
            errorMessage = "The server does not allow inline preview for this file. Download the original instead."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor private func loadPreview() async {
        guard let client else { return }
        isWorking = true; errorMessage = nil
        defer { isWorking = false }
        do {
            localPreviewURL = try await AssetActions.fetchPreviewFile(item, client: client)
            showingPreview = true
        } catch let MedinaAPIError.httpStatus(status, _) where status == 415 {
            errorMessage = "The server does not allow inline preview for this file. Download the original instead."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor private func downloadAsset() async {
        guard let client else { return }
        isWorking = true; errorMessage = nil
        defer { isWorking = false }
        do {
            try await AssetActions.download(item, client: client)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private var suggestedFilename: String { AssetActions.suggestedFilename(for: item) }

    private func removePreviewFile() {
        if let localPreviewURL { try? FileManager.default.removeItem(at: localPreviewURL) }
        localPreviewURL = nil
    }
}

struct NativeQuickLookPreview: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> NSView {
        guard let view = QLPreviewView(frame: .zero, style: .normal) else {
            return NSTextField(labelWithString: "Quick Look is unavailable for this file.")
        }
        view.previewItem = url as NSURL
        return view
    }
    func updateNSView(_ view: NSView, context: Context) {
        (view as? QLPreviewView)?.previewItem = url as NSURL
    }
}
