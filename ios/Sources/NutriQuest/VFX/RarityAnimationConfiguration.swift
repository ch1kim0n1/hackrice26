import SwiftUI
import NutriQuestUI

/// All production tuning lives here; the existing rarity model and UI palette stay intact.
struct RarityAnimationConfiguration {
    enum ParticleStyle { case rising, embers, inward }

    var aura: RarityVFXAssetManifest.Sequence?
    var auraFPS: Double = 16
    var auraScale: CGFloat = 1.04
    var auraOpacity: Double = 0
    var auraTint: Color = .white
    var playsInReverse = false
    var glowColor: Color = .clear
    var glowOpacity: ClosedRange<Double> = 0...0
    var glowScale: ClosedRange<CGFloat> = 0.98...1.03
    var glowDuration: Double = 2.3
    var floatDistance: CGFloat = 0
    var horizontalDrift: CGFloat = 0
    var floatDuration: Double = 2
    var particleStyle: ParticleStyle?
    var particleCount = 0
    var particleLifetime: Double = 3
    var particleSize: CGFloat = 3
    var particleOpacity: Double = 0.55
    var accentInterval: Double = 0
    var accentDuration: Double = 1.2
    var accentStrength: Double = 0
    var secondaryAura: RarityVFXAssetManifest.Sequence?
    /// When set, a live flame replaces the frame-sequence aura for this tier.
    var flame: Flame?

    var auraEnabled: Bool { aura != nil }
    var glowEnabled: Bool { glowOpacity.upperBound > 0 }
    var floatEnabled: Bool { floatDistance > 0 }
    var particlesEnabled: Bool { particleCount > 0 && particleStyle != nil }
    var accentEnabled: Bool { accentInterval > 0 }
    var hasEffects: Bool { auraEnabled || glowEnabled || flame != nil }

    static func configuration(for rarity: Rarity) -> Self {
        switch rarity {
        case .common, .uncommon:
            return Self()
        case .rare:
            return Self(glowColor: NQRarity.rare.outline, glowOpacity: 0.30...0.50, flame: .blue)
        case .epic:
            return Self(aura: .epic, auraOpacity: 0.50,
                        glowColor: NQRarity.epic.outline, glowOpacity: 0.28...0.38,
                        floatDistance: 4.5, flame: .purple)
        case .legendary:
            return Self(aura: .gold, auraFPS: 18, auraScale: 1.20, auraOpacity: 0.72,
                        glowColor: NQRarity.legendary.outline, glowOpacity: 0.38...0.52,
                        floatDistance: 6, floatDuration: 2.1,
                        particleStyle: .rising, particleCount: 5, particleSize: 3.5,
                        accentInterval: 7.5, accentStrength: 0.12, flame: .gold)
        case .mythic:
            return Self(aura: .red, auraFPS: 20, auraScale: 1.28, auraOpacity: 0.78,
                        auraTint: Palette.redTint,
                        glowColor: Palette.red, glowOpacity: 0.44...0.60,
                        floatDistance: 7, floatDuration: 1.8,
                        particleStyle: .embers, particleCount: 7, particleLifetime: 2.7,
                        particleSize: 3.5, accentInterval: 8.5, accentDuration: 1.4,
                        accentStrength: 0.20, secondaryAura: .flame, flame: .red)
        case .secret:
            return Self(aura: .smoke, auraFPS: 15, auraScale: 1.30, auraOpacity: 0.92,
                        auraTint: Palette.void, playsInReverse: true,
                        glowColor: Palette.rim, glowOpacity: 0.25...0.35,
                        floatDistance: 8, horizontalDrift: 1, floatDuration: 1.8,
                        particleStyle: .inward, particleCount: 6, particleLifetime: 3.6,
                        particleSize: 4, particleOpacity: 0.72,
                        accentInterval: 10.5, accentDuration: 1.8, accentStrength: 0.12, flame: .black)
        }
    }

    /// Unknown wire values stay local to presentation; decoding/game data is untouched.
    static func configuration(backendValue: String) -> Self {
        configuration(for: Rarity(rawValue: backendValue) ?? .common)
    }

    /// Flame behind the monster: soft puffs rising off an emitter at its feet.
    /// One hue per tier; colored tiers blend additively so overlaps glow.
    struct Flame {
        var core: Color
        var body: Color
        var count: Int
        /// Additive light can never make black, so Secret burns as normal-blend
        /// smoke with a faint violet edge to keep it visible.
        var dark = false
        var edge: Color = .clear

        static let blue = Flame(core: Color(red: 0.45, green: 0.74, blue: 1), body: Color(red: 0.04, green: 0.52, blue: 1), count: 30)
        static let purple = Flame(core: Color(red: 0.78, green: 0.45, blue: 1), body: Color(red: 0.62, green: 0.10, blue: 1), count: 34)
        static let gold = Flame(core: Color(red: 1, green: 0.86, blue: 0.42), body: Color(red: 1, green: 0.68, blue: 0), count: 38)
        static let red = Flame(core: Color(red: 1, green: 0.45, blue: 0.32), body: Color(red: 1, green: 0.10, blue: 0.08), count: 44)
        static let black = Flame(
            core: Color(red: 0.02, green: 0.02, blue: 0.04), body: Color(red: 0.08, green: 0.06, blue: 0.12),
            count: 40, dark: true, edge: Color(red: 0.36, green: 0.20, blue: 0.56)
        )
    }

    enum Palette {
        static let red = Color(red: 0.95, green: 0.10, blue: 0.16)
        static let redTint = Color(red: 1, green: 0.22, blue: 0.30)
        static let void = Color(red: 0.025, green: 0.028, blue: 0.035)
        static let rim = Color(red: 0.65, green: 0.69, blue: 0.74)
    }

    enum Metrics {
        static let maximumFPS: Double = 24
        static let lowPowerFPS: Double = 12
        static let maximumParticleCount = 8
        static let effectOverflow: CGFloat = 8
        static let maskSolidFraction: CGFloat = 0.76
        static let glowRadiusFraction: CGFloat = 0.53
        static let rimScale: CGFloat = 1.09
        static let rimOpacity: Double = 0.72
        static let secondaryScale: CGFloat = 0.66
        static let secondaryOpacity: Double = 0.12
        static let secondaryY: CGFloat = 0.16
        static let accentScale: CGFloat = 0.08
        static let particleOuterRadius: CGFloat = 0.45
        static let particleInnerRadius: CGFloat = 0.07
        static let particleRise: CGFloat = 0.72
        static let particleSway: CGFloat = 0.035
        static let particleSideInset: CGFloat = 0.12
        static let particleBottom: CGFloat = 0.88
        static let particleOrbit: Double = .pi / 3
        static let floatReferenceHeight: CGFloat = 124
    }
}

/// Environment overrides are only set by the debug demo. Defaults are production values.
struct RarityVFXPreviewOptions {
    var speed: Double = 1
    var scale: CGFloat = 1
    var particles = true
    var floating = true
    var forceStatic = false
    var disabled = false
}

private struct RarityVFXPreviewKey: EnvironmentKey {
    static let defaultValue = RarityVFXPreviewOptions()
}

extension EnvironmentValues {
    var rarityVFXPreview: RarityVFXPreviewOptions {
        get { self[RarityVFXPreviewKey.self] }
        set { self[RarityVFXPreviewKey.self] = newValue }
    }
}
