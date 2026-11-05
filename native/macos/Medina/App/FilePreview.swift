import SwiftUI
import AppKit
import PDFKit
import WebKit
import MedinaCore

// MARK: - Image preview

/// An inline image viewer with scroll/pinch zoom, drag pan, and a double-click
/// toggle between fit-to-pane and 100%. A small HUD offers −/fit/+.
struct ImagePreview: View {
    let image: NSImage
    @State private var scale: CGFloat = 1
    @State private var fitScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var dragAnchor: CGSize = .zero

    private let minScale: CGFloat = 0.25
    private let maxScale: CGFloat = 8

    var body: some View {
        GeometryReader { geo in
            let fit = fitScaleFor(geo.size)
            ZStack {
                Color.black.opacity(0.02)
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: image.size.width, height: image.size.height)
                    .scaleEffect(scale)
                    .offset(offset)
                    .gesture(
                        DragGesture()
                            .onChanged { v in offset = CGSize(width: dragAnchor.width + v.translation.width,
                                                              height: dragAnchor.height + v.translation.height) }
                            .onEnded { _ in dragAnchor = offset }
                    )
                    .gesture(
                        MagnificationGesture()
                            .onChanged { m in scale = clamp(fit * m) }
                            .onEnded { _ in snapIfNearFit(fit) }
                    )
                    .onTapGesture(count: 2) { toggleZoom(fit) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .onAppear { if scale == 1 && offset == .zero { scale = fit; fitScale = fit } }
            .onChange(of: geo.size) { _, newSize in
                let newFit = fitScaleFor(newSize)
                // Keep fit behavior responsive to pane resizes while fitted.
                if abs(scale - fitScale) < 0.001 { scale = newFit }
                fitScale = newFit
            }
            .overlay(alignment: .bottom) { hud(fit: fit) }
        }
    }

    private func hud(fit: CGFloat) -> some View {
        HStack(spacing: 14) {
            Button { scale = clamp(scale / 1.4); dragAnchor = offset } label: { Image(systemName: "minus.magnifyingglass") }
            Button { scale = fit; offset = .zero; dragAnchor = .zero } label: {
                Text("\(Int((scale / max(fit, 0.0001)) * 100))%").monospacedDigit().font(.system(size: 11, weight: .semibold))
            }
            Button { scale = clamp(scale * 1.4); dragAnchor = offset } label: { Image(systemName: "plus.magnifyingglass") }
        }
        .buttonStyle(.plain)
        .font(.system(size: 13))
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .padding(.bottom, 14)
    }

    private func fitScaleFor(_ size: CGSize) -> CGFloat {
        guard image.size.width > 0, image.size.height > 0, size.width > 0, size.height > 0 else { return 1 }
        return min(size.width / image.size.width, size.height / image.size.height, 1)
    }
    private func clamp(_ s: CGFloat) -> CGFloat { min(maxScale, max(minScale, s)) }
    private func snapIfNearFit(_ fit: CGFloat) { if abs(scale - fit) < 0.05 { scale = fit; offset = .zero; dragAnchor = .zero } }
    private func toggleZoom(_ fit: CGFloat) {
        withAnimation(.easeInOut(duration: 0.2)) {
            if abs(scale - fit) < 0.01 { scale = clamp(1) } else { scale = fit; offset = .zero; dragAnchor = .zero }
        }
    }
}

// MARK: - PDF preview

/// Inline PDF rendering via PDFKit — native scroll, zoom, and page breaks.
struct PDFPreview: NSViewRepresentable {
    let data: Data

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displaysPageBreaks = true
        view.document = PDFDocument(data: data)
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        if view.document?.dataRepresentation() != data {
            view.document = PDFDocument(data: data)
        }
    }
}

// MARK: - Markdown preview

/// Renders Markdown as formatted rich text with a Rendered/Source toggle. The
/// source side reuses the syntax-highlighting CodeViewer.
struct MarkdownPreview: View {
    let text: String
    @State private var showSource = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("", selection: $showSource) {
                    Text("Rendered").tag(false)
                    Text("Source").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer()
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(Theme.card(scheme))
            Divider().overlay(Theme.hairline(scheme))
            if showSource {
                CodeViewer(code: text, fileExtension: "md")
            } else {
                ScrollView {
                    Text(rendered)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(22)
                }
                .background(Theme.canvas(scheme))
            }
        }
    }

    /// Full-document Markdown parse so headings, lists, and paragraph breaks
    /// survive (the default inline-only parse collapses newlines).
    private var rendered: AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .full, failurePolicy: .returnPartiallyParsedIfPossible)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}

// MARK: - Web document preview (HTML / SVG)

/// Renders an HTML or SVG document in a locked-down WKWebView: JavaScript
/// disabled and content loaded from in-memory bytes with no network base URL,
/// so nothing in the document can script the app or phone home.
struct WebDocumentPreview: NSViewRepresentable {
    let data: Data
    let mimeType: String

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        let web = WKWebView(frame: .zero, configuration: config)
        web.setValue(false, forKey: "drawsBackground")
        load(into: web)
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) { load(into: web) }

    private func load(into web: WKWebView) {
        let mime = mimeType.isEmpty ? "text/html" : mimeType
        web.load(data, mimeType: mime, characterEncodingName: "utf-8", baseURL: URL(string: "about:blank")!)
    }
}
