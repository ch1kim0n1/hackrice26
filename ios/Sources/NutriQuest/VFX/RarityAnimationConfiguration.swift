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
    /// When set, a live flame (MonsterAuraView) replaces the frame-sequence aura.
    var flame: RarityTier?
    /// Soft tinted plate behind the monster — separates it from the card
    /// without boxing it in the way the old inner frame did.
    var backplateColor: Color?
    var backplateOpacity: Double = 0
    var backplateScale: CGFloat = 1
    /// Subtle size lift for higher tiers.
    var characterScale: CGFloat = 1

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
            return Self(glowColor: NQRarity.rare.outline, glowOpacity: 0.30...0.50, flame: .rare,
                        backplateColor: .blue, backplateOpacity: 0.16, backplateScale: 1.08)
        case .epic:
            return Self(aura: .epic, auraOpacity: 0.50,
                        glowColor: NQRarity.epic.outline, glowOpacity: 0.28...0.38,
                        floatDistance: 2, flame: .epic,
                        backplateColor: .purple, backplateOpacity: 0.20, backplateScale: 1.12,
                        characterScale: 1.02)
        case .legendary:
            return Self(aura: .gold, auraFPS: 18, auraScale: 1.20, auraOpacity: 0.72,
                        glowColor: NQRarity.legendary.outline, glowOpacity: 0.38...0.52,
                        floatDistance: 3, floatDuration: 2.1,
                        particleStyle: .rising, particleCount: 5, particleSize: 3.5,
                        accentInterval: 7.5, accentStrength: 0.12, flame: .legendary,
                        backplateColor: .yellow, backplateOpacity: 0.24, backplateScale: 1.17,
                        characterScale: 1.03)
        case .mythic:
            return Self(aura: .red, auraFPS: 20, auraScale: 1.28, auraOpacity: 0.78,
                        auraTint: Palette.redTint,
                        glowColor: Palette.red, glowOpacity: 0.44...0.60,
                        floatDistance: 5, floatDuration: 1.8,
                        particleStyle: .embers, particleCount: 7, particleLifetime: 2.7,
                        particleSize: 3.5, accentInterval: 8.5, accentDuration: 1.4,
                        accentStrength: 0.20, secondaryAura: .flame, flame: .mythic,
                        backplateColor: .red, backplateOpacity: 0.30, backplateScale: 1.21,
                        characterScale: 1.04)
        case .secret:
            return Self(aura: .smoke, auraFPS: 15, auraScale: 1.30, auraOpacity: 0.92,
                        auraTint: Palette.void, playsInReverse: true,
                        glowColor: Palette.rim, glowOpacity: 0.25...0.35,
                        floatDistance: 6, horizontalDrift: 1, floatDuration: 1.8,
                        particleStyle: .inward, particleCount: 6, particleLifetime: 3.6,
                        particleSize: 4, particleOpacity: 0.72,
                        accentInterval: 10.5, accentDuration: 1.8, accentStrength: 0.12, flame: .secret,
                        // Pale to match Secret's white/silver/light-blue flame
                        // (the spec's charcoal predates that palette change).
                        backplateColor: Palette.secretPlate, backplateOpacity: 0.32, backplateScale: 1.24,
                        characterScale: 1.05)
        }
    }

    /// Unknown wire values stay local to presentation; decoding/game data is untouched.
    static func configuration(backendValue: String) -> Self {
        configuration(for: Rarity(rawValue: backendValue) ?? .common)
    }

    enum Palette {
        static let red = Color(red: 0.95, green: 0.10, blue: 0.16)
        static let redTint = Color(red: 1, green: 0.22, blue: 0.30)
        static let void = Color(red: 0.025, green: 0.028, blue: 0.035)
        static let rim = Color(red: 0.65, green: 0.69, blue: 0.74)
        static let secretPlate = Color(red: 0.78, green: 0.86, blue: 0.95)
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
