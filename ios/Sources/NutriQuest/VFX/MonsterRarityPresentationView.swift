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
        LoadKey(visible: visible, aura: configuration.aura, secondary: configuration.secondaryAura,
                particle: configuration.particlesEnabled
                    ? (configuration.particleStyle == .rising ? .spark : .mote) : nil)
    }

    private var visible: Bool { appeared && inViewport }
    private var active: Bool { visible && scenePhase == .active }
    private var isStatic: Bool { reduceMotion || preview.forceStatic }
    private var animating: Bool { active && !isStatic }
    private var fps: Double {
        min(lowPower ? RarityAnimationConfiguration.Metrics.lowPowerFPS : RarityAnimationConfiguration.Metrics.maximumFPS,
            configuration.auraFPS * preview.speed)
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
            if let sequence = configuration.aura {
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
            if let secondary = configuration.secondaryAura {
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
