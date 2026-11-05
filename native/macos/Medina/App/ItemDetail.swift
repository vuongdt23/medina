import SwiftUI
import AppKit
import QuickLookUI
import MedinaCore

/// The item inspector: an editorial header plus type-appropriate content —
/// a syntax-highlighted code viewer for source, Quick Look for media/PDF,
/// play for lessons, and download/ZIP for everything else.
struct ItemDetail: View {
    let item: TreeNode
    let client: MedinaAPIClient?
    let progress: LessonProgress?
    var onPlay: (TreeNode) -> Void

    @Environment(\.colorScheme) private var scheme
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var codeText: String?
    @State private var localPreviewURL: URL?
    @State private var showingPreview = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(Theme.hairline(scheme))
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: item.id) { await loadInlineCodeIfNeeded() }
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
            case "asset", "subtitle":
                if item.type == "asset", supportsQuickLook {
                    Button { Task { await loadPreview() } } label: {
                        Label("Quick Look", systemImage: "eye")
                    }.disabled(isWorking || client == nil)
                }
                if let text = codeText {
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
        if let codeText {
            CodeViewer(code: codeText, fileExtension: item.fileExtension)
        } else if isLoadingCode {
            centered { ProgressView("Loading…").controlSize(.small) }
        } else if let errorMessage {
            centered {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red).font(.callout)
                    .multilineTextAlignment(.center)
            }
        } else if item.type == "lesson" {
            centered {
                VStack(spacing: 8) {
                    Image(systemName: item.mediaKind == "audio" ? "music.note" : "play.rectangle")
                        .font(.system(size: 40)).foregroundStyle(Theme.accent.opacity(0.7))
                    Text(resumeLabel).font(.callout).foregroundStyle(.secondary)
                }
            }
        } else if item.type == "asset", !supportsInline {
            centered {
                VStack(spacing: 6) {
                    Image(systemName: "doc").font(.system(size: 32)).foregroundStyle(.tertiary)
                    Text("No inline preview for this file type.")
                        .font(.callout).foregroundStyle(.secondary)
                    Text("Use Quick Look or download the original.")
                        .font(.caption).foregroundStyle(.tertiary)
                }
            }
        } else if let url = item.contentUrl {
            centered {
                Text(url).font(.caption.monospaced()).textSelection(.enabled).foregroundStyle(.secondary)
            }
        } else {
            Color.clear
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
        case "subtitle": return "captions.bubble"
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
    private var isLoadingCode: Bool { isWorking && item.type == "asset" && supportsInline }
    private var supportsInline: Bool { CodeViewer.supports(extension: item.fileExtension, mimeType: item.mimeType) }
    private var supportsQuickLook: Bool {
        let ext = (item.fileExtension ?? "").trimmingCharacters(in: CharacterSet(charactersIn: ". ")).lowercased()
        let mime = (item.mimeType ?? "").split(separator: ";", maxSplits: 1).first.map(String.init)?.lowercased() ?? ""
        if ["html", "htm", "xhtml", "svg", "svgz"].contains(ext) { return false }
        return mime == "application/pdf" || mime.hasPrefix("image/") || mime.hasPrefix("text/") || supportsInline
    }

    // MARK: Loading

    @MainActor private func loadInlineCodeIfNeeded() async {
        codeText = nil
        errorMessage = nil
        guard item.type == "asset", supportsInline, let client else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            let data = try await client.previewAsset(id: item.id)
            codeText = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
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
            let data = try await client.previewAsset(id: item.id)
            let rawExtension = (item.fileExtension ?? "").trimmingCharacters(in: CharacterSet(charactersIn: ". "))
            let ext = String(rawExtension.filter { $0.isLetter || $0.isNumber })
            let suffix = ext.isEmpty ? (item.mimeType == "application/pdf" ? "pdf" : "txt") : ext
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("Medina-\(UUID().uuidString)")
                .appendingPathExtension(suffix)
            try data.write(to: url, options: .atomic)
            localPreviewURL = url
            showingPreview = true
        } catch let MedinaAPIError.httpStatus(status, _) where status == 415 {
            errorMessage = "The server does not allow inline preview for this file. Download the original instead."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor private func downloadAsset() async {
        guard let client else { return }
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = suggestedFilename
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        isWorking = true; errorMessage = nil
        defer { isWorking = false }
        do {
            let url = item.type == "asset_directory"
                ? client.assetArchiveURL(id: item.id)
                : client.assetDownloadURL(id: item.id)
            try await client.download(from: url, to: destination)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private var suggestedFilename: String {
        let name = (item.originalName ?? item.title) as NSString
        let safeName = name.lastPathComponent
        if item.type == "asset_directory", !safeName.lowercased().hasSuffix(".zip") { return safeName + ".zip" }
        return safeName
    }

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
