import SwiftUI

struct AuraFrameAnimationView: View {
    let frames: RarityFrames?
    let time: Double
    let configuration: RarityAnimationConfiguration
    var isStatic = false

    private var frame: UIImage? {
        guard let images = frames?.images, !images.isEmpty else { return nil }
        let index = isStatic ? images.count / 2 : RarityVFXAssetManifest.frameIndex(
            time: time, fps: configuration.auraFPS, count: images.count,
            reversed: configuration.playsInReverse
        ) ?? 0
        return images[index]
    }

    var body: some View {
        if let frame {
            Image(uiImage: frame)
                .resizable()
                .scaledToFit()
                .colorMultiply(configuration.auraTint)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

struct RarityGlowView: View {
    let configuration: RarityAnimationConfiguration
    let time: Double
    let size: CGSize
    let isStatic: Bool

    var body: some View {
        let breath = isStatic ? 0.5 : RarityVFXMotion.wave(time, period: configuration.glowDuration)
        let opacity = configuration.glowOpacity.lowerBound
            + (configuration.glowOpacity.upperBound - configuration.glowOpacity.lowerBound) * breath
        let scale = configuration.glowScale.lowerBound
            + (configuration.glowScale.upperBound - configuration.glowScale.lowerBound) * breath
        RadialGradient(colors: [configuration.glowColor, configuration.glowColor.opacity(0)],
                       center: .center, startRadius: 0,
                       endRadius: min(size.width, size.height) * RarityAnimationConfiguration.Metrics.glowRadiusFraction)
            .opacity(opacity)
            .scaleEffect(scale)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

enum RarityVFXMotion {
    static func wave(_ time: Double, period: Double) -> Double {
        (1 - cos(time * 2 * .pi / period)) / 2
    }

    static func accent(_ time: Double, configuration: RarityAnimationConfiguration) -> Double {
        guard configuration.accentEnabled else { return 0 }
        let phase = time.truncatingRemainder(dividingBy: configuration.accentInterval)
        // The first surge happens near the end of the interval, never on appearance.
        let start = configuration.accentInterval - configuration.accentDuration
        guard phase > start else { return 0 }
        return sin((phase - start) / configuration.accentDuration * .pi) * configuration.accentStrength
    }

    static func particlePosition(index: Int, progress: Double,
                                 style: RarityAnimationConfiguration.ParticleStyle) -> CGPoint {
        typealias M = RarityAnimationConfiguration.Metrics
        // Golden-angle distribution keeps particles staggered without random state.
        let seed = Double(index) * 0.61803398875
        let fraction = seed - floor(seed)
        let angle = fraction * 2 * .pi
        if style == .inward {
            let radius = M.particleOuterRadius * (1 - progress) + M.particleInnerRadius * progress
            let orbit = angle + progress * M.particleOrbit
            return CGPoint(x: 0.5 + cos(orbit) * radius, y: 0.5 + sin(orbit) * radius)
        }
        let sway = sin(progress * 2 * .pi + angle) * M.particleSway
        return CGPoint(x: M.particleSideInset + fraction * (1 - 2 * M.particleSideInset) + sway,
                       y: M.particleBottom - progress * M.particleRise)
    }
}

/// One character-sized Canvas with a fixed upper bound, no emitters, scenes,
/// timers, retained nodes, or particle allocations that accumulate over time.
struct RarityParticleView: View {
    let configuration: RarityAnimationConfiguration
    let texture: UIImage?
    let time: Double

    var body: some View {
        Canvas { context, size in
            guard let texture, let style = configuration.particleStyle else { return }
            let count = min(configuration.particleCount, RarityAnimationConfiguration.Metrics.maximumParticleCount)
            var sprite = context.resolve(Image(uiImage: texture).renderingMode(.template))
            sprite.shading = .color(style == .inward
                ? RarityAnimationConfiguration.Palette.void : configuration.glowColor)
            for index in 0..<count {
                let progress = (time / configuration.particleLifetime + Double(index) / Double(count))
                    .truncatingRemainder(dividingBy: 1)
                let point = RarityVFXMotion.particlePosition(index: index, progress: progress, style: style)
                let diameter = configuration.particleSize
                var particle = context
                particle.opacity = sin(progress * .pi) * configuration.particleOpacity
                particle.draw(sprite, in: CGRect(x: point.x * size.width - diameter / 2,
                                                y: point.y * size.height - diameter / 2,
                                                width: diameter, height: diameter))
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
