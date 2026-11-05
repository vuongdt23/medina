import SwiftUI

/// Centralized visual language for Medina — a "warm editorial" reading room for
/// course libraries. One confident amber accent over warm paper/ink neutrals,
/// rounded display type, soft layered depth. Light and dark are both first-class.
enum Theme {
    // MARK: Accent
    /// Signature amber — warm, confident, legible on both schemes.
    static let accent = Color(red: 0.90, green: 0.52, blue: 0.18)
    static let accentSoft = Color(red: 0.96, green: 0.74, blue: 0.42)

    /// Completion green that sits beside the amber without clashing.
    static let done = Color(red: 0.36, green: 0.68, blue: 0.45)

    // MARK: Surfaces (scheme-aware)
    static func canvas(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.11, green: 0.105, blue: 0.10)
                        : Color(red: 0.98, green: 0.975, blue: 0.96)
    }
    static func card(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.16, green: 0.155, blue: 0.145)
                        : Color.white
    }
    static func cardSelected(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.22, green: 0.18, blue: 0.13)
                        : Color(red: 1.0, green: 0.96, blue: 0.90)
    }
    static func hairline(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.06)
    }

    // MARK: Type — SF Pro Rounded for display warmth.
    static func display(_ size: CGFloat, _ weight: Font.Weight = .bold) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }

    // MARK: Metrics
    static let cardRadius: CGFloat = 14
    static let cardPadding: CGFloat = 14
    static let gutter: CGFloat = 16

    // MARK: Cover palette
    /// Curated two-stop gradients for generated course covers. Warm, editorial,
    /// legible under white monogram text. Chosen deterministically per course.
    static let coverGradients: [[Color]] = [
        [Color(red: 0.90, green: 0.45, blue: 0.20), Color(red: 0.76, green: 0.24, blue: 0.22)], // ember
        [Color(red: 0.86, green: 0.58, blue: 0.19), Color(red: 0.62, green: 0.33, blue: 0.14)], // amber-oak
        [Color(red: 0.34, green: 0.46, blue: 0.56), Color(red: 0.18, green: 0.26, blue: 0.36)], // slate
        [Color(red: 0.40, green: 0.52, blue: 0.38), Color(red: 0.22, green: 0.33, blue: 0.26)], // moss
        [Color(red: 0.55, green: 0.38, blue: 0.55), Color(red: 0.33, green: 0.22, blue: 0.38)], // plum
        [Color(red: 0.80, green: 0.50, blue: 0.42), Color(red: 0.56, green: 0.30, blue: 0.34)], // clay
        [Color(red: 0.28, green: 0.47, blue: 0.50), Color(red: 0.15, green: 0.30, blue: 0.34)], // teal
        [Color(red: 0.72, green: 0.44, blue: 0.28), Color(red: 0.48, green: 0.26, blue: 0.20)], // terracotta
    ]

    /// A stable index into `coverGradients` for a course, derived from its name
    /// so a course always gets the same cover across launches.
    static func coverIndex(for seed: String) -> Int {
        var hash: UInt64 = 1469598103934665603 // FNV-1a
        for byte in seed.utf8 { hash = (hash ^ UInt64(byte)) &* 1099511628211 }
        return Int(hash % UInt64(coverGradients.count))
    }
}

/// A circular completion indicator — the signature element. Animates as the
/// fraction changes and shows a check when complete.
struct ProgressRing: View {
    var fraction: Double
    var size: CGFloat = 34
    var lineWidth: CGFloat = 3.5
    var showsLabel = true
    @Environment(\.colorScheme) private var scheme

    private var complete: Bool { fraction >= 0.999 }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Theme.hairline(scheme), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.001, fraction))
                .stroke(
                    complete ? Theme.done : Theme.accent,
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.45), value: fraction)
            if showsLabel {
                if complete {
                    Image(systemName: "checkmark")
                        .font(.system(size: size * 0.4, weight: .bold))
                        .foregroundStyle(Theme.done)
                } else if fraction > 0 {
                    Text("\(Int(fraction * 100))")
                        .font(Theme.display(size * 0.32, .bold))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(complete ? "Completed" : "\(Int(fraction * 100)) percent complete")
    }
}

/// A slim horizontal progress bar for compact rows.
struct ProgressBar: View {
    var fraction: Double
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.hairline(scheme))
                Capsule()
                    .fill(fraction >= 0.999 ? Theme.done : Theme.accent)
                    .frame(width: max(0, geo.size.width * min(1, fraction)))
                    .animation(.easeInOut(duration: 0.4), value: fraction)
            }
        }
        .frame(height: 4)
    }
}

/// A small pill used for language badges, counts, and status chips.
struct Chip: View {
    var text: String
    var systemImage: String?
    var tint: Color = Theme.accent
    @Environment(\.colorScheme) private var scheme

    init(_ text: String, systemImage: String? = nil, tint: Color = Theme.accent) {
        self.text = text
        self.systemImage = systemImage
        self.tint = tint
    }

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage { Image(systemName: systemImage).font(.system(size: 10, weight: .semibold)) }
            Text(text).font(.system(size: 11, weight: .semibold))
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(tint.opacity(scheme == .dark ? 0.22 : 0.14), in: Capsule())
        .foregroundStyle(tint)
    }
}

extension Duration {
    /// Compact mm:ss / h:mm:ss formatting for lesson lengths.
    static func lessonLabel(seconds: Double) -> String? {
        guard seconds.isFinite, seconds > 0 else { return nil }
        let total = Int(seconds.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

/// A rotating chevron for collapse/expand affordances. Points right when
/// closed, down when open, and animates between the two.
struct DisclosureChevron: View {
    var isOpen: Bool
    var size: CGFloat = 10

    var body: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: size, weight: .bold))
            .foregroundStyle(.tertiary)
            .rotationEffect(.degrees(isOpen ? 90 : 0))
            .animation(.easeInOut(duration: 0.18), value: isOpen)
    }
}

/// A row of per-section segments, each sized by its lesson count and filled by
/// its completion. Mirrors the course's structure at a glance; segments turn
/// green when their section is fully complete.
struct SegmentedProgressBar: View {
    /// (weight, fraction, isComplete) per section, in order.
    let segments: [(weight: Int, fraction: Double, isComplete: Bool)]
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        GeometryReader { geo in
            let gap: CGFloat = 3
            let totalWeight = max(1, segments.reduce(0) { $0 + max(1, $1.weight) })
            let available = max(0, geo.size.width - gap * CGFloat(max(0, segments.count - 1)))
            HStack(spacing: gap) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, seg in
                    let width = available * CGFloat(max(1, seg.weight)) / CGFloat(totalWeight)
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.hairline(scheme))
                        Capsule()
                            .fill(seg.isComplete ? Theme.done : Theme.accent)
                            .frame(width: max(0, width * CGFloat(min(1, seg.fraction))))
                            .animation(.easeInOut(duration: 0.35), value: seg.fraction)
                    }
                    .frame(width: width)
                }
            }
        }
        .frame(height: 5)
    }
}

/// Resolves a file's extension/name to a tinted SF Symbol so resource kinds
/// read at a glance — a SwiftUI/SF-Symbols analog of jelly-courses' devicon map.
/// Code files are detected via `CodeViewer.language(for:)` so the two stay in sync.
struct FileTypeIcon: View {
    let fileExtension: String?
    let name: String?

    var body: some View {
        let (symbol, tint) = Self.resolve(fileExtension: fileExtension, name: name)
        Image(systemName: symbol)
            .font(.system(size: 12))
            .foregroundStyle(tint)
            .frame(width: 16)
    }

    static func resolve(fileExtension: String?, name: String?) -> (symbol: String, tint: Color) {
        let ext = (fileExtension ?? "")
            .trimmingCharacters(in: CharacterSet(charactersIn: ". "))
            .lowercased()
        let lowerName = (name ?? "").lowercased()

        // Image, archive, document families first — they trump "is this text".
        if ["png", "jpg", "jpeg", "gif", "svg", "svgz", "webp", "bmp", "ico", "heic", "tiff"].contains(ext) {
            return ("photo", Color(red: 0.26, green: 0.59, blue: 0.85))
        }
        if ["zip", "tar", "gz", "tgz", "rar", "7z", "bz2", "xz"].contains(ext) {
            return ("doc.zipper", Color(red: 0.90, green: 0.62, blue: 0.19))
        }
        if ext == "pdf" { return ("doc.richtext", Color(red: 0.84, green: 0.23, blue: 0.20)) }
        if ["csv", "tsv"].contains(ext) { return ("tablecells", Theme.done) }
        if ["doc", "docx", "odt", "rtf"].contains(ext) { return ("doc.text", Color(red: 0.22, green: 0.34, blue: 0.60)) }
        if ["xls", "xlsx", "ods"].contains(ext) { return ("tablecells", Color(red: 0.13, green: 0.45, blue: 0.27)) }
        if ["ppt", "pptx", "odp"].contains(ext) { return ("rectangle.on.rectangle", Color(red: 0.82, green: 0.28, blue: 0.15)) }
        if ["sh", "bash", "zsh", "bat", "cmd", "ps1", "fish"].contains(ext) {
            return ("terminal", Color(red: 0.50, green: 0.52, blue: 0.55))
        }
        // Anything the code viewer can highlight is "code".
        if CodeViewer.language(for: ext) != nil || Self.codeFileNames.contains(lowerName) {
            return ("chevron.left.forwardslash.chevron.right", Theme.accent)
        }
        if ["txt", "log", "md", "markdown", "env", "conf", "cfg", "ini", "properties"].contains(ext) {
            return ("doc.plaintext", Color(red: 0.50, green: 0.52, blue: 0.55))
        }
        return ("doc", .secondary)
    }

    private static let codeFileNames: Set<String> = [
        "dockerfile", "jenkinsfile", "vagrantfile", "makefile", "gnumakefile",
        "gemfile", "rakefile", "procfile",
    ]
}
