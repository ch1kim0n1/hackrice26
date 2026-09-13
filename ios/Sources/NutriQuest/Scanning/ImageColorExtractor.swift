import Foundation
import CoreGraphics
import ImageIO

/// A dominant color found in a product photo, mapped to the closest human name.
public struct ColorSwatch: Identifiable {
    public let id = UUID()
    let red: Int
    let green: Int
    let blue: Int
    let name: String
    let proportion: Double
}

/// Extracts the dominant color palette from an image entirely on-device:
/// downsamples the photo, buckets pixels, merges similar buckets, and names
/// each cluster by nearest reference color.
public enum ImageColorExtractor {

    public static func dominantColors(from data: Data, maxColors: Int = 5) -> [ColorSwatch] {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return [] }

        let size = 64
        guard let ctx = CGContext(
            data: nil,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: size * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return [] }

        ctx.interpolationQuality = .low
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
        guard let buffer = ctx.data else { return [] }
        let pixels = buffer.bindMemory(to: UInt8.self, capacity: size * size * 4)

        // Bucket pixels into 4-bit-per-channel cells, averaging true colors.
        var buckets: [Int: (count: Int, r: Int, g: Int, b: Int)] = [:]
        var opaquePixels = 0

        for i in 0..<(size * size) {
            let o = i * 4
            let a = Int(pixels[o + 3])
            guard a > 32 else { continue }
            let r = Int(pixels[o]), g = Int(pixels[o + 1]), b = Int(pixels[o + 2])
            let key = (r >> 4) << 8 | (g >> 4) << 4 | (b >> 4)
            var bucket = buckets[key] ?? (0, 0, 0, 0)
            bucket.count += 1
            bucket.r += r
            bucket.g += g
            bucket.b += b
            buckets[key] = bucket
            opaquePixels += 1
        }
        guard opaquePixels > 0 else { return [] }

        let sorted = buckets.values.sorted { $0.count > $1.count }

        // Greedily keep the largest buckets that are visually distinct.
        var kept: [(r: Int, g: Int, b: Int, count: Int)] = []
        for bucket in sorted {
            guard kept.count < maxColors else { break }
            let avg = (bucket.r / bucket.count, bucket.g / bucket.count, bucket.b / bucket.count)
            let tooSimilar = kept.contains { colorDistance(avg, ($0.r, $0.g, $0.b)) < 60 }
            if !tooSimilar {
                kept.append((avg.0, avg.1, avg.2, bucket.count))
            }
        }

        return kept.map { cluster in
            let rgb = (cluster.r, cluster.g, cluster.b)
            return ColorSwatch(
                red: cluster.r,
                green: cluster.g,
                blue: cluster.b,
                name: nearestName(rgb),
                proportion: Double(cluster.count) / Double(opaquePixels)
            )
        }
    }

    private static func colorDistance(_ a: (Int, Int, Int), _ b: (Int, Int, Int)) -> Double {
        let dr = Double(a.0 - b.0), dg = Double(a.1 - b.1), db = Double(a.2 - b.2)
        return (dr * dr + dg * dg + db * db).squareRoot()
    }

    private static let namedColors: [(name: String, rgb: (Int, Int, Int))] = [
        ("White", (245, 245, 245)),
        ("Off-white", (235, 230, 215)),
        ("Cream", (245, 235, 195)),
        ("Beige", (225, 200, 160)),
        ("Tan", (205, 170, 125)),
        ("Gold", (210, 170, 60)),
        ("Yellow", (240, 220, 60)),
        ("Orange", (235, 140, 35)),
        ("Red", (215, 45, 45)),
        ("Dark red", (140, 30, 35)),
        ("Maroon", (105, 35, 45)),
        ("Pink", (235, 150, 175)),
        ("Light pink", (245, 200, 210)),
        ("Purple", (125, 60, 165)),
        ("Lavender", (180, 160, 220)),
        ("Blue", (55, 95, 200)),
        ("Dark blue", (30, 45, 115)),
        ("Light blue", (135, 190, 230)),
        ("Teal", (45, 140, 140)),
        ("Green", (65, 160, 65)),
        ("Dark green", (30, 100, 45)),
        ("Light green", (155, 210, 125)),
        ("Olive", (130, 130, 60)),
        ("Brown", (120, 75, 35)),
        ("Dark brown", (80, 48, 22)),
        ("Light brown", (170, 125, 80)),
        ("Gray", (128, 128, 128)),
        ("Light gray", (200, 200, 200)),
        ("Dark gray", (75, 75, 75)),
        ("Black", (25, 25, 25))
    ]

    private static func nearestName(_ rgb: (Int, Int, Int)) -> String {
        namedColors.min {
            colorDistance(rgb, $0.rgb) < colorDistance(rgb, $1.rgb)
        }?.name ?? "Unknown"
    }
}
