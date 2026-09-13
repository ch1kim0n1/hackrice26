import SwiftUI
import UIKit

/// Wrap the already-sized artwork node. Backgrounds/offsets do not participate in
/// layout, so the original content retains its sizing, alignment and accessibility.
struct MonsterRarityPresentationView<CharacterImage: View>: View {
    let rarity: Rarity
    var enabled = true
    @ViewBuilder let characterImage: CharacterImage
    @Environment(\.rarityVFXPreview) private var preview

    private var isEnabled: Bool {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-rarityVFXDisabled") { return false }
        #endif
        return enabled && !preview.disabled
    }

    var body: some View {
        let configuration = RarityAnimationConfiguration.configuration(for: rarity)
        if isEnabled && configuration.hasEffects {
            RarityAnimatedArtwork(configuration: configuration, characterImage: characterImage)
        } else {
            characterImage
        }
    }
}

private struct RarityAnimatedArtwork<CharacterImage: View>: View {
    let configuration: RarityAnimationConfiguration
    let characterImage: CharacterImage
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.rarityVFXPreview) private var preview
    @State private var appeared = false
    @State private var inViewport = false
    @State private var imageSize = CGSize.zero
    @State private var origin = Date()
    @State private var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    @State private var frames: [RarityVFXAssetManifest.Sequence: RarityFrames] = [:]

    private struct LoadKey: Equatable {
        let visible: Bool
        let aura: RarityVFXAssetManifest.Sequence?
        let secondary: RarityVFXAssetManifest.Sequence?
        let particle: RarityVFXAssetManifest.Sequence?
    }

    private var loadKey: LoadKey {
        // A flame tier never draws its frame-sequence aura, so don't decode it.
        let flames = configuration.flame != nil
        return LoadKey(visible: visible,
                aura: flames ? nil : configuration.aura,
                secondary: flames ? nil : configuration.secondaryAura,
                particle: configuration.particlesEnabled
                    ? (configuration.particleStyle == .rising ? .spark : .mote) : nil)
    }

    private var visible: Bool { appeared && inViewport }
    private var active: Bool { visible && scenePhase == .active }
    private var isStatic: Bool { reduceMotion || preview.forceStatic }
    private var animating: Bool { active && !isStatic }
    private var fps: Double {
        // Fire reads as choppy at a slow aura's frame rate; flame tiers run at the cap.
        let requested = configuration.flame != nil ? RarityAnimationConfiguration.Metrics.maximumFPS : configuration.auraFPS
        return min(lowPower ? RarityAnimationConfiguration.Metrics.lowPowerFPS : RarityAnimationConfiguration.Metrics.maximumFPS,
            requested * preview.speed)
    }

    var body: some View {
        Group {
            if animating {
                TimelineView(.animation(minimumInterval: 1 / fps)) { context in
                    composition(time: context.date.timeIntervalSince(origin) * preview.speed)
                }
            } else {
                composition(time: 0)
            }
        }
        .background {
            // A single non-layout GeometryReader tracks scroll visibility. LazyVGrid
            // prefetch may call onAppear before a card actually enters the viewport.
            GeometryReader { geometry in
                let rect = geometry.frame(in: .global)
                Color.clear
                    .onAppear { updateGeometry(rect: rect, size: geometry.size) }
                    .onChange(of: rect) { updateGeometry(rect: $0, size: geometry.size) }
            }
        }
        .onAppear { appeared = true }
        .onDisappear {
            appeared = false
            frames = [:]
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)) { _ in
            lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        }
        .task(id: loadKey) {
            guard visible else { frames = [:]; return }
            let required = [loadKey.aura, loadKey.secondary, loadKey.particle].compactMap { $0 }
            frames = frames.filter { required.contains($0.key) }
            for sequence in required {
                guard !Task.isCancelled else { return }
                let decoded = await RarityFrameCache.shared.frames(for: sequence)
                guard !Task.isCancelled else { return }
                frames[sequence] = decoded
            }
        }
    }

    private func updateGeometry(rect: CGRect, size: CGSize) {
        if imageSize != size { imageSize = size }
        let intersects = !rect.isEmpty && rect.intersects(UIScreen.main.bounds)
        if inViewport != intersects { inViewport = intersects }
    }

    private func composition(time: Double) -> some View {
        let motion = animating && preview.floating && configuration.floatEnabled
        let floatScale = min(1, imageSize.height / RarityAnimationConfiguration.Metrics.floatReferenceHeight)
        let vertical = motion ? -configuration.floatDistance * floatScale
            * RarityVFXMotion.wave(time, period: configuration.floatDuration) : 0
        let horizontal = motion ? configuration.horizontalDrift
            * sin(time * 2 * .pi / configuration.floatDuration) : 0
        return characterImage
            .offset(x: horizontal, y: vertical)
            .background(alignment: .bottom) {
                // Above the glow, and outside the effect stack's mask so the
                // flames can rise past the top of the portrait.
                if let tier = configuration.flame {
                    // Canvas bottom sits `inset` below the portrait, so the
                    // 150×200 particle space's floor lands at the monster's feet.
                    MonsterAuraView(tier: tier, isDetailedView: false, isActive: animating)
                        .frame(width: imageSize.width * MonsterAuraView.widthRatio + MonsterAuraView.inset * 2,
                               height: imageSize.height * MonsterAuraView.heightRatio + MonsterAuraView.inset * 2)
                        .offset(y: MonsterAuraView.inset)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .background {
                effectStack(time: time)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
    }

    private func effectStack(time: Double) -> some View {
        typealias M = RarityAnimationConfiguration.Metrics
        let size = CGSize(width: imageSize.width + M.effectOverflow * 2,
                          height: imageSize.height + M.effectOverflow * 2)
        let surge = animating && !lowPower ? RarityVFXMotion.accent(time, configuration: configuration) : 0
        let scale = configuration.auraScale * preview.scale
        return ZStack {
            RarityGlowView(configuration: configuration, time: time, size: size, isStatic: !animating)
            if let sequence = configuration.aura, configuration.flame == nil {
                if configuration.playsInReverse {
                    // Thin neutral edge under a much darker core: visible against both
                    // light and dark backgrounds without turning Secret purple/cyan.
                    AuraFrameAnimationView(frames: frames[sequence], time: time,
                                           configuration: rimConfiguration, isStatic: !animating)
                        .scaleEffect(scale * M.rimScale)
                        .opacity(M.rimOpacity)
                }
                AuraFrameAnimationView(frames: frames[sequence], time: time,
                                       configuration: configuration, isStatic: !animating)
                    .scaleEffect(scale * (1 + surge * M.accentScale))
                    .opacity(min(1, configuration.auraOpacity + surge))
            }
            if let secondary = configuration.secondaryAura, configuration.flame == nil {
                AuraFrameAnimationView(frames: frames[secondary], time: time,
                                       configuration: configuration, isStatic: !animating)
                    .scaleEffect(M.secondaryScale * preview.scale)
                    .offset(y: imageSize.height * M.secondaryY)
                    .opacity(M.secondaryOpacity + surge)
            }
            if animating && preview.particles && !lowPower && configuration.particlesEnabled {
                RarityParticleView(configuration: configuration,
                                   texture: frames[configuration.particleStyle == .rising ? .spark : .mote]?.images.first,
                                   time: time)
            }
        }
        .frame(width: size.width, height: size.height)
        .mask {
            // Softly finish inside the local effect rectangle; never clip a hard
            // aura edge against a card and never change the parent's clipping.
            Ellipse().fill(RadialGradient(stops: [
                .init(color: .white, location: M.maskSolidFraction),
                .init(color: .clear, location: 1)
            ], center: .center, startRadius: 0, endRadius: size.width / 2))
        }
        .clipped()
    }

    private var rimConfiguration: RarityAnimationConfiguration {
        var value = configuration
        value.auraTint = RarityAnimationConfiguration.Palette.rim
        return value
    }
}

// MARK: - Monster aura flame

/// Tiers that burn; Common and Uncommon get no flame.
enum RarityTier {
    case rare, epic, legendary, mythic, secret

    /// Particle colors. A tier with several gives each particle one of them at
    /// spawn, so the colors overlap and mix.
    var colors: [Color] {
        switch self {
        case .rare: return [.blue]
        case .epic: return [.purple]
        case .legendary: return [.yellow] // Gold
        case .mythic: return [.red]
        case .secret:
            // White, silver and light blue overlapping.
            return [.white, Color(red: 0.75, green: 0.78, blue: 0.83), Color(red: 0.55, green: 0.80, blue: 1)]
        }
    }
}

struct AuraParticle: Identifiable {
    let id = UUID()
    var x: CGFloat
    var y: CGFloat
    var vx: CGFloat
    var vy: CGFloat
    var radius: CGFloat
    var initialRadius: CGFloat
    var maxLife: Double
    var life: Double
    var isSpark: Bool
    /// Index into the tier's colors, fixed for the particle's life.
    var colorIndex: Int
}

/// Flame behind a monster. Particles live in a 150×200 space (the Squad
/// portrait at ~1.6×), step once per frame, and the canvas scales to fit.
struct MonsterAuraView: View {
    let tier: RarityTier
    let isDetailedView: Bool
    /// Off-screen or Reduce Motion: freeze instead of stepping.
    var isActive = true

    static let space = CGSize(width: 150, height: 200)
    /// Particle space relative to the 96×124 Squad portrait it was tuned on.
    static let widthRatio: CGFloat = 150.0 / 96.0
    static let heightRatio: CGFloat = 200.0 / 124.0
    /// Margin so blurred puffs at the edges aren't cut off.
    static let inset: CGFloat = 30

    @State private var particles: [AuraParticle] = []

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !isActive)) { timeline in
            Canvas { context, size in
                // Blend on the shared canvas (not a layer per particle) so
                // overlapping puffs actually add up and glow.
                var canvas = context
                canvas.blendMode = .plusLighter
                canvas.translateBy(x: Self.inset, y: Self.inset)
                canvas.scaleBy(x: (size.width - Self.inset * 2) / Self.space.width,
                               y: (size.height - Self.inset * 2) / Self.space.height)

                for particle in particles {
                    let progress = particle.life / particle.maxLife
                    guard progress > 0 else { continue }

                    var color = tier.colors[particle.colorIndex % tier.colors.count]
                    var opacity = progress * 0.45
                    if particle.isSpark {
                        color = .white
                        opacity = progress * 0.60
                    }

                    let rect = CGRect(
                        x: particle.x - particle.radius,
                        y: particle.y - particle.radius,
                        width: particle.radius * 2,
                        height: particle.radius * 2
                    )
                    canvas.fill(Path(ellipseIn: rect), with: .radialGradient(
                        Gradient(colors: [color.opacity(opacity), color.opacity(0)]),
                        center: CGPoint(x: rect.midX, y: rect.midY),
                        startRadius: 0,
                        endRadius: particle.radius
                    ))
                }
            }
            .blur(radius: 5)
            .drawingGroup()
            .onChange(of: timeline.date) { _ in
                updateParticles()
            }
        }
        .onAppear {
            // Pre-warm so a card scrolling into view shows a full flame
            // instead of growing one from nothing.
            guard isActive, particles.isEmpty else { return }
            for _ in 0..<60 { updateParticles() }
        }
    }

    private func updateParticles() {
        particles = particles.compactMap { particle -> AuraParticle? in
            var updated = particle
            updated.life -= 1
            guard updated.life > 0 else { return nil }

            updated.x += updated.vx
            updated.y += updated.vy
            updated.radius = updated.initialRadius * CGFloat(updated.life / updated.maxLife)
            return updated
        }

        // Particles live ~60% longer than the prototype's, so the cap rises with
        // them to keep the same density.
        let maxAllowedParticles = isDetailedView ? 220 : 72
        let spawnCount = isDetailedView ? 6 : 3
        guard particles.count < maxAllowedParticles else { return }

        for _ in 0..<spawnCount {
            let isSpark = Double.random(in: 0...1) < 0.15
            let initialRadius = isSpark ? CGFloat.random(in: 12...20) : CGFloat.random(in: 26...38)
            // One roll for both, so a particle never starts above full life.
            // Slower than the prototype: ~40% less speed, longer life, same height.
            let life = Double.random(in: 40...60)
            particles.append(AuraParticle(
                x: CGFloat.random(in: 25...125),
                y: CGFloat.random(in: 170...195),
                vx: CGFloat.random(in: -0.3...0.3),
                vy: CGFloat.random(in: -4.0 ... -2.2),
                radius: initialRadius,
                initialRadius: initialRadius,
                maxLife: life,
                life: life,
                isSpark: isSpark,
                colorIndex: Int.random(in: 0..<tier.colors.count)
            ))
        }
    }
}
