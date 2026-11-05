import SwiftUI
import WebKit

/// Renders a source/text asset with syntax highlighting in a sandboxed WKWebView
/// backed by a locally bundled highlight.js — no network, matching Medina's
/// offline, self-hosted ethos. Falls back to plain monospaced text for types
/// highlight.js does not recognize.
struct CodeViewer: NSViewRepresentable {
    let code: String
    let fileExtension: String?
    @Environment(\.colorScheme) private var scheme

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        let web = WKWebView(frame: .zero, configuration: config)
        web.setValue(false, forKey: "drawsBackground") // let CSS paint the canvas
        load(into: web)
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) {
        if context.coordinator.lastCode != code || context.coordinator.lastExt != fileExtension {
            load(into: web)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var lastCode = "\u{0}"; var lastExt: String? = "\u{0}" }

    private func load(into web: WKWebView) {
        guard let dir = Bundle.main.resourceURL?.appendingPathComponent("highlight", isDirectory: true) else {
            web.loadHTMLString("<pre>\(Self.escape(code))</pre>", baseURL: nil)
            return
        }
        web.loadHTMLString(Self.html(code: code, language: Self.language(for: fileExtension)),
                           baseURL: dir)
    }

    /// highlight.js is handed the raw source through a JSON string literal so no
    /// HTML escaping of the source is required; only the document chrome is ours.
    static func html(code: String, language: String?) -> String {
        let json = (try? String(data: JSONEncoder().encode(code), encoding: .utf8)) ?? "\"\""
        let langAttr = language.map { "class=\"language-\($0)\"" } ?? ""
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <link rel="stylesheet" href="medina-theme.css">
        <script src="highlight.min.js"></script>
        </head><body>
        <div class="wrap"><div class="gutter" id="gutter"></div><pre><code id="code" \(langAttr)></code></pre></div>
        <script>
          const src = \(json);
          const codeEl = document.getElementById('code');
          codeEl.textContent = src;
          try { hljs.highlightElement(codeEl); } catch (e) { codeEl.classList.add('plain'); }
          const lines = src.split('\\n');
          if (lines.length && lines[lines.length-1] === '') lines.pop();
          document.getElementById('gutter').textContent =
            lines.map((_, i) => i + 1).join('\\n');
        </script>
        </body></html>
        """
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
    }

    /// Maps a file extension to a highlight.js language id. Returning nil lets
    /// highlight.js auto-detect.
    static func language(for ext: String?) -> String? {
        guard let raw = ext?.trimmingCharacters(in: CharacterSet(charactersIn: ". ")).lowercased(), !raw.isEmpty else { return nil }
        let map: [String: String] = [
            "kt": "kotlin", "kts": "kotlin", "swift": "swift",
            "go": "go", "rs": "rust", "py": "python", "rb": "ruby",
            "js": "javascript", "jsx": "javascript", "mjs": "javascript", "cjs": "javascript",
            "ts": "typescript", "tsx": "typescript",
            "java": "java", "scala": "scala", "c": "c", "h": "c",
            "cpp": "cpp", "cc": "cpp", "cxx": "cpp", "hpp": "cpp",
            "cs": "csharp", "php": "php", "sh": "bash", "bash": "bash", "zsh": "bash",
            "json": "json", "yaml": "yaml", "yml": "yaml", "toml": "ini", "ini": "ini",
            "xml": "xml", "html": "xml", "css": "css", "scss": "scss",
            "sql": "sql", "md": "markdown", "markdown": "markdown",
            "dockerfile": "dockerfile", "makefile": "makefile", "gradle": "gradle",
        ]
        return map[raw]
    }

    /// Whether this asset should open in the code viewer rather than Quick Look.
    static func supports(extension ext: String?, mimeType mime: String?) -> Bool {
        let cleanedMime = (mime ?? "").split(separator: ";", maxSplits: 1).first.map(String.init)?.lowercased() ?? ""
        if cleanedMime == "application/pdf" || cleanedMime.hasPrefix("image/") { return false }
        if language(for: ext) != nil { return true }
        let textish = ["txt", "log", "env", "conf", "cfg", "properties", "gitignore", "editorconfig"]
        let raw = (ext ?? "").trimmingCharacters(in: CharacterSet(charactersIn: ". ")).lowercased()
        return textish.contains(raw) || cleanedMime.hasPrefix("text/")
    }
}
