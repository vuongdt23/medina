import SwiftUI
import AppKit
import MedinaCore

/// Profile-scoped, bounded in-memory thumbnail cache layered over URLSession's
/// HTTP cache. The full origin is part of every key so server profiles cannot
/// leak images into one another.
@MainActor
private final class ThumbnailStore {
    static let shared = ThumbnailStore()

    private let images: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 200
        cache.totalCostLimit = 64 * 1024 * 1024
        return cache
    }()

    func image(path: String, client: MedinaAPIClient) async -> NSImage? {
        let key = "\(client.profile.origin.absoluteString)|\(path)" as NSString
        if let cached = images.object(forKey: key) { return cached }
        do {
            let data = try await client.thumbnailData(at: path)
            try Task.checkCancellation()
            guard let image = NSImage(data: data) else { return nil }
            let pixels = max(1, Int(image.size.width * image.size.height * 4))
            images.setObject(image, forKey: key, cost: pixels)
            return image
        } catch {
            return nil
        }
    }
}

/// Displays an advertised server thumbnail. Missing and failed images remain
/// transparent so the caller's generated artwork or file icon stays visible.
struct ServerThumbnail: View {
    let path: String?
    let client: MedinaAPIClient?
    var contentMode: ContentMode = .fill

    @State private var image: NSImage?

    private var requestKey: String {
        guard let path, let client else { return "none" }
        return "\(client.profile.origin.absoluteString)|\(path)"
    }

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
                    .transition(.opacity)
            } else {
                Color.clear
            }
        }
        .task(id: requestKey) {
            image = nil
            guard let path, let client else { return }
            image = await ThumbnailStore.shared.image(path: path, client: client)
        }
        .accessibilityHidden(true)
    }
}
