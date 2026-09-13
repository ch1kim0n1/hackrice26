import Foundation

enum RarityVFXAssetManifest {
    enum Sequence: String, CaseIterable, Sendable {
        case epic, gold, red, flame, smoke, mote, spark

        var frameCount: Int {
            switch self {
            case .epic, .gold, .red: return 20
            case .flame: return 16
            case .smoke: return 30
            case .mote, .spark: return 1
            }
        }

        var orderedNames: [String] {
            (0..<frameCount).map { String(format: "%@_%03d", rawValue, $0) }
        }

        var representativeFrame: Int { frameCount / 2 }
    }

    static var bundle: Bundle {
        #if SWIFT_PACKAGE
        return .module
        #else
        return .main
        #endif
    }

    static func url(for name: String, sequence: Sequence, in bundle: Bundle = bundle) -> URL? {
        bundle.url(forResource: name, withExtension: "png", subdirectory: "RarityVFX/\(sequence.rawValue)")
    }

    static func frameIndex(time: Double, fps: Double, count: Int, reversed: Bool) -> Int? {
        guard count > 0, time.isFinite, fps.isFinite, fps > 0 else { return nil }
        let phase = (max(0, time) * fps).truncatingRemainder(dividingBy: Double(count))
        guard phase.isFinite else { return 0 }
        let index = min(count - 1, Int(phase))
        return reversed ? count - 1 - index : index
    }
}
