import UIKit
import ImageIO
import os

/// Immutable predecoded images may be shared by all visible presentations.
final class RarityFrames: @unchecked Sendable {
    let images: [UIImage]
    let decodedBytes: Int

    init(images: [UIImage]) {
        self.images = images
        decodedBytes = images.reduce(0) { $0 + (($1.cgImage?.bytesPerRow ?? 0) * ($1.cgImage?.height ?? 0)) }
    }
}

/// Actor serialization coalesces concurrent requests. ImageIO decoding never runs on
/// the main actor; SwiftUI bodies only index immutable arrays. No image enumeration.
actor RarityFrameCache {
    static let shared = RarityFrameCache()
    private let cache = NSCache<NSString, RarityFrames>()
    private let logger = Logger(subsystem: "com.nutriquest.app", category: "RarityVFX")
    private var memoryObserver: NSObjectProtocol?
    private(set) var decodeCount = 0

    init() {
        cache.totalCostLimit = 32 * 1024 * 1024
        cache.countLimit = 7
    }

    func frames(for sequence: RarityVFXAssetManifest.Sequence) -> RarityFrames {
        if memoryObserver == nil {
            memoryObserver = NotificationCenter.default.addObserver(
                forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: nil
            ) { [weak self] _ in
                Task { await self?.removeAll() }
            }
        }
        // v1 includes the preprocessed resolution/crop variant. Runtime tinting
        // doesn't change decoded pixels, so all colors reuse these exact images.
        let key = "\(sequence.rawValue)-rgba-v1" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let images = sequence.orderedNames.compactMap { name -> UIImage? in
            guard let url = RarityVFXAssetManifest.url(for: name, sequence: sequence),
                  let image = Self.decode(url: url) else {
                #if DEBUG
                logger.error("Missing or invalid VFX frame: \(name, privacy: .public)")
                #endif
                return nil
            }
            return image
        }
        let frames = RarityFrames(images: images)
        decodeCount += 1
        cache.setObject(frames, forKey: key, cost: frames.decodedBytes)
        #if DEBUG
        logger.debug("Decoded \(sequence.rawValue, privacy: .public): \(images.count) frames, \(frames.decodedBytes) bytes")
        #endif
        return frames
    }

    nonisolated static func decode(url: URL) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, [
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceShouldCache: true
              ] as CFDictionary) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    func removeAll() { cache.removeAllObjects() }

    deinit {
        if let memoryObserver { NotificationCenter.default.removeObserver(memoryObserver) }
    }
}
