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
                if let flame = configuration.flame {
                    RarityFlameView(flame: flame, time: time)
                        .frame(width: imageSize.width + RarityFlameView.sideBleed * 2,
                               height: imageSize.height + RarityFlameView.topBleed + RarityFlameView.bottomBleed)
                        .offset(y: RarityFlameView.bottomBleed)
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

/// Port of the cosmic-flame prototype, made stateless: each puff slot replays
/// a short life on its own clock and re-rolls spawn point and velocity every
/// cycle, so nothing is stored between frames.
private struct RarityFlameView: View {
    let flame: RarityAnimationConfiguration.Flame
    let time: Double

    /// How far the canvas reaches past the portrait, so edge puffs fade out
    /// instead of being cut off by the canvas bounds.
    static let sideBleed: CGFloat = 60
    static let topBleed: CGFloat = 96
    static let bottomBleed: CGFloat = 28

    var body: some View {
        Canvas { context, size in
            // Behind a character a centered flame is mostly hidden, so the
            // emitter spans wider than the portrait at its feet and each puff
            // leans outward to lick up around the silhouette.
            let portraitWidth = size.width - Self.sideBleed * 2
            let scale = portraitWidth / 126
            let emitter = CGPoint(x: size.width / 2, y: size.height - Self.bottomBleed - 6)
            let halfWidth = portraitWidth * 0.66
            var puffs = context
            puffs.blendMode = flame.dark ? .normal : .plusLighter
            var edgeLight = context
            edgeLight.blendMode = .plusLighter

            for index in 0..<flame.count {
                let life = 0.5 + 0.5 * unit(index, 0, 1)
                let shifted = time + unit(index, 0, 2) * life
                let cycle = Int((shifted / life).rounded(.down))
                let age = shifted / life - Double(cycle)
                let seconds = age * life

                let side = unit(index, cycle, 3) * 2 - 1
                let spawnX = side * halfWidth
                let spawnY = (unit(index, cycle, 4) - 0.5) * 16 * scale
                let vx = side * 28 * scale + (unit(index, cycle, 5) - 0.5) * 30 * scale
                let vy = (unit(index, cycle, 6) * 2.5 + 1.5) * 60 * scale
                let startRadius = (unit(index, cycle, 7) * 25 + 15) * scale
                let radius = max(0.3, startRadius - 14 * seconds * scale)
                let strength = (1 - age) * min(1, age / 0.08)

                let center = CGPoint(x: emitter.x + spawnX + vx * seconds,
                                     y: emitter.y + spawnY - vy * seconds)
                // Each puff is drawn around the origin of a space stretched
                // upward, so it reads as a tongue of flame, not a round blob.
                let circle = Path(ellipseIn: CGRect(x: -radius, y: -radius, width: radius * 2, height: radius * 2))
                let roll = unit(index, cycle, 8)

                if flame.dark && roll < 0.25 {
                    stretch(edgeLight, at: center).fill(circle, with: .radialGradient(
                        Gradient(stops: [
                            .init(color: flame.edge.opacity(strength * 0.5), location: 0),
                            .init(color: flame.edge.opacity(0), location: 1)
                        ]), center: .zero, startRadius: 0, endRadius: radius))
                    continue
                }

                let stops: [Gradient.Stop]
                if flame.dark {
                    stops = [
                        .init(color: flame.core.opacity(strength * 0.75), location: 0),
                        .init(color: flame.body.opacity(strength * 0.4), location: 0.5),
                        .init(color: flame.body.opacity(0), location: 1)
                    ]
                } else if roll < 0.12 {
                    // Bright white spark at the heart of the flame.
                    stops = [
                        .init(color: .white.opacity(strength * 0.8), location: 0),
                        .init(color: .white.opacity(strength * 0.3), location: 0.3),
                        .init(color: .white.opacity(0), location: 1)
                    ]
                } else {
                    stops = [
                        .init(color: flame.core.opacity(strength * 0.8), location: 0),
                        .init(color: flame.body.opacity(strength * 0.35), location: 0.4),
                        .init(color: flame.body.opacity(0), location: 1)
                    ]
                }
                stretch(puffs, at: center).fill(circle, with: .radialGradient(
                    Gradient(stops: stops), center: .zero, startRadius: 0, endRadius: radius))
            }
        }
    }

    private func stretch(_ context: GraphicsContext, at center: CGPoint) -> GraphicsContext {
        var local = context
        local.translateBy(x: center.x, y: center.y)
        local.scaleBy(x: 0.8, y: 1.45)
        return local
    }

    /// Deterministic 0..<1 per puff slot, life cycle and property (splitmix64).
    private func unit(_ index: Int, _ cycle: Int, _ salt: UInt64) -> Double {
        var x = UInt64(truncatingIfNeeded: index) &* 0x9E37_79B9_7F4A_7C15
        x ^= UInt64(truncatingIfNeeded: cycle) &* 0xC2B2_AE3D_27D4_EB4F
        x ^= salt &* 0x1656_67B1_9E37_79F9
        x = (x ^ (x >> 30)) &* 0xBF58_476D_1CE4_E5B9
        x = (x ^ (x >> 27)) &* 0x94D0_49BB_1331_11EB
        x ^= x >> 31
        return Double(x >> 11) / 9_007_199_254_740_992.0
    }
}
