import AppKit
import AVFoundation
import Foundation
import Observation

@MainActor
@Observable
public final class SeekPreviewController {
    public typealias Thumbnail = @Sendable (Double) async throws -> Data
    public typealias Factory = (URL) throws -> Thumbnail

    public private(set) var imageData: Data?
    public private(set) var imageTime: Int?
    public private(set) var lastError: String?
    public private(set) var sourceRevision = 0
    public var onDiagnostic: ((Bool, String) -> Void)?

    private let cacheLimit: Int
    private let factory: Factory
    private var sourceURL: URL?
    private var decoder: Thumbnail?
    private var cache: [Int: Data] = [:]
    private var recency: [Int] = []
    private var desiredTime: Int?
    private var activeTask: Task<Void, Never>?
    private var activeToken: UUID?

    public convenience init(cacheLimit: Int = 60) {
        self.init(cacheLimit: cacheLimit, thumbnailFactory: Self.defaultFactory)
    }

    public init(cacheLimit: Int = 60, thumbnailFactory: @escaping Factory) {
        self.cacheLimit = max(1, cacheLimit)
        self.factory = thumbnailFactory
    }

    public func load(url: URL) {
        sourceRevision += 1
        sourceURL = url
        desiredTime = nil
        imageData = nil
        imageTime = nil
        lastError = nil
        cache.removeAll(keepingCapacity: true)
        recency.removeAll(keepingCapacity: true)
        activeTask?.cancel()
        do { decoder = try factory(url) }
        catch {
            decoder = nil
            lastError = error.localizedDescription
            onDiagnostic?(false, "Seek preview initialization failed: \(error.localizedDescription)")
        }
    }

    public func request(at time: Double) {
        guard time.isFinite, time >= 0, time < Double(Int.max), sourceURL != nil else { return }
        let bucket = Int(time.rounded(.down))
        desiredTime = bucket
        guard decoder != nil else { return }
        lastError = nil
        if let data = cache[bucket] {
            touch(bucket)
            imageData = data
            imageTime = bucket
            return
        }
        imageData = nil
        imageTime = nil
        guard activeTask == nil else { return }
        start(bucket)
    }

    public func dismiss() {
        desiredTime = nil
        imageData = nil
        imageTime = nil
        lastError = nil
        activeTask?.cancel()
    }

    public func unload() {
        dismiss()
        sourceRevision += 1
        sourceURL = nil
        decoder = nil
        cache.removeAll()
        recency.removeAll()
    }

    private func start(_ bucket: Int) {
        guard activeTask == nil, let decoder else { return }
        let token = UUID()
        let revision = sourceRevision
        activeToken = token
        activeTask = Task { [weak self] in
            do {
                let data = try await decoder(Double(bucket))
                self?.finish(token: token, revision: revision, bucket: bucket, data: data, error: nil)
            } catch {
                self?.finish(token: token, revision: revision, bucket: bucket, data: nil, error: error)
            }
        }
    }

    private func finish(token: UUID, revision: Int, bucket: Int, data: Data?, error: Error?) {
        guard activeToken == token else { return }
        activeToken = nil
        activeTask = nil
        if revision == sourceRevision, let data {
            insert(data, at: bucket)
            if desiredTime == bucket {
                imageData = data
                imageTime = bucket
                lastError = nil
            }
        } else if revision == sourceRevision, let error {
            onDiagnostic?(false, "Seek preview failed at \(bucket)s: \(error.localizedDescription)")
            if desiredTime == bucket { lastError = error.localizedDescription }
        }
        if let pending = desiredTime, cache[pending] == nil {
            start(pending)
        }
    }

    private func insert(_ data: Data, at bucket: Int) {
        cache[bucket] = data
        touch(bucket)
        while recency.count > cacheLimit {
            cache.removeValue(forKey: recency.removeFirst())
        }
    }

    private func touch(_ bucket: Int) {
        recency.removeAll { $0 == bucket }
        recency.append(bucket)
    }

    private static let defaultFactory: Factory = { url in
        let asset = AVURLAsset(url: url)
        let generator = AssetImageGenerator(generator: AVAssetImageGenerator(asset: asset))
        generator.generator.appliesPreferredTrackTransform = true
        generator.generator.maximumSize = CGSize(width: 440, height: 248)
        return { seconds in
            let (image, _) = try await generator.generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600))
            let bitmap = NSBitmapImageRep(cgImage: image)
            guard let data = bitmap.representation(using: .png, properties: [:]) else {
                throw CocoaError(.fileWriteUnknown)
            }
            return data
        }
    }
}

private final class AssetImageGenerator: @unchecked Sendable {
    let generator: AVAssetImageGenerator
    init(generator: AVAssetImageGenerator) { self.generator = generator }
}
