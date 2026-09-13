import SwiftUI

// MARK: - Animation presets

/// Standard motion vocabulary. Use these instead of raw springs so the whole
/// app moves with one personality: bouncy, cute, springy.
public enum NQMotion {
    /// Small UI feedback: chips, toggles, ribbons.
    public static let snappy = Animation.spring(response: 0.3, dampingFraction: 0.7)
    /// Standard element entrance: cards, banners.
    public static let springy = Animation.spring(response: 0.45, dampingFraction: 0.72)
    /// Big celebratory: character summon, level up.
    public static let bouncy = Animation.spring(response: 0.45, dampingFraction: 0.55)
    /// Gentle ambient: idle float, breathing.
    public static let gentle = Animation.easeInOut(duration: 1.6)
    /// Quick fade: state swaps.
    public static let quick = Animation.easeOut(duration: 0.2)
    /// Stat bar fills.
    public static let fill = Animation.spring(response: 0.6, dampingFraction: 0.75)
    /// Attack wind-up and recoil — tight enough to read as force, not drift.
    public static let attackLunge = Animation.spring(response: 0.28, dampingFraction: 0.6)
    /// A fainting unit sinking out of the fight: slow, heavy, no bounce back.
    public static let faintDroop = Animation.easeOut(duration: 0.5)
    /// Crit flash — one frame of white-out, gone before it registers as a fade.
    public static let critFlash = Animation.easeOut(duration: 0.08)

    /// Spring with custom response/damping.
    public static func spring(response: Double, damping: Double) -> Animation {
        .spring(response: response, dampingFraction: damping)
    }
}

// MARK: - Haptics

public enum NQHaptic {
    #if canImport(UIKit)
    public static func light() { guard NQFeedbackSettings.hapticsEnabled else { return }; UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    public static func medium() { guard NQFeedbackSettings.hapticsEnabled else { return }; UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
    public static func success() { guard NQFeedbackSettings.hapticsEnabled else { return }; UINotificationFeedbackGenerator().notificationOccurred(.success) }
    public static func warning() { guard NQFeedbackSettings.hapticsEnabled else { return }; UINotificationFeedbackGenerator().notificationOccurred(.warning) }
    public static func error() { guard NQFeedbackSettings.hapticsEnabled else { return }; UINotificationFeedbackGenerator().notificationOccurred(.error) }
    public static func selection() { guard NQFeedbackSettings.hapticsEnabled else { return }; UISelectionFeedbackGenerator().selectionChanged() }
    #else
    public static func light() {}
    public static func medium() {}
    public static func success() {}
    public static func warning() {}
    public static func error() {}
    public static func selection() {}
    #endif
}

// MARK: - Press squish

/// Pressable squish: scales down while touched, springs back on release.
/// Attach haptics via `haptic:`. With `ledge > 0` the button gets a hard
/// bottom shadow ("3D ledge") that collapses on press — Duolingo-style
/// tactile depth.
public struct NQPressableStyle: ButtonStyle {
    private var scale: CGFloat = 0.94
    private var haptic: Bool = true
    private var ledge: CGFloat = 0
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(scale: CGFloat = 0.94, haptic: Bool = true, ledge: CGFloat = 0) {
        self.scale = scale
        self.haptic = haptic
        self.ledge = ledge
    }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? scale : 1)
            .offset(y: configuration.isPressed ? ledge * 0.6 : 0)
            .shadow(
                color: .black.opacity(configuration.isPressed || ledge == 0 ? 0 : 0.22),
                radius: 0,
                x: 0,
                y: configuration.isPressed ? 0 : ledge
            )
            .hoverEffect(.lift)
            .opacity(isEnabled ? 1 : 0.5)
            .animation(.spring(response: 0.28, dampingFraction: 0.6), value: configuration.isPressed)
            .onChange(of: configuration.isPressed) { pressed in
                if pressed && haptic { NQHaptic.light() }
            }
    }
}

public extension ButtonStyle where Self == NQPressableStyle {
    static var nqPressable: NQPressableStyle { NQPressableStyle() }
    static func nqPressable(scale: CGFloat, haptic: Bool = true) -> NQPressableStyle {
        NQPressableStyle(scale: scale, haptic: haptic)
    }
    /// Chunky tactile button: hard shadow ledge collapses on press.
    static var nqLedge: NQPressableStyle { NQPressableStyle(scale: 0.96, haptic: false, ledge: 4) }
}

// MARK: - Pop-in entrance

/// Scale 0 -> overshoot -> settle. For cards, characters, modals.
public struct NQPopIn: ViewModifier {
    private var delay: Double
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(delay: Double = 0) {
        self.delay = delay
    }

    public func body(content: Content) -> some View {
        content
            .scaleEffect(shown || reduceMotion ? 1 : 0.01)
            .opacity(shown ? 1 : 0)
            .onAppear {
                withAnimation(
                    reduceMotion
                        ? Animation.easeOut(duration: 0.2).delay(delay)
                        : .spring(response: 0.42, dampingFraction: 0.62).delay(delay)
                ) {
                    shown = true
                }
            }
    }
}

/// Slide up + fade, with optional stagger index.
public struct NQSlideUp: ViewModifier {
    private var delay: Double
    private var distance: CGFloat
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(delay: Double = 0, distance: CGFloat = 26) {
        self.delay = delay
        self.distance = distance
    }

    public func body(content: Content) -> some View {
        content
            .offset(y: shown || reduceMotion ? 0 : distance)
            .opacity(shown ? 1 : 0)
            .onAppear {
                withAnimation(.spring(response: 0.45, dampingFraction: 0.8).delay(delay)) {
                    shown = true
                }
            }
    }
}

/// Staggered cascade for grids/lists — apply per item with its index.
public struct NQCascade: ViewModifier {
    private let index: Int
    private var baseDelay: Double
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(index: Int, baseDelay: Double = 0.05) {
        self.index = index
        self.baseDelay = baseDelay
    }

    public func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown || reduceMotion ? 0 : 22)
            .scaleEffect(shown || reduceMotion ? 1 : 0.92)
            .onAppear {
                withAnimation(.spring(response: 0.42, dampingFraction: 0.75)
                    .delay(reduceMotion ? 0 : baseDelay * Double(index))) {
                    shown = true
                }
            }
    }
}

// MARK: - Shake (error)

public struct NQShake: ViewModifier {
    private var trigger: Int
    @State private var offset: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(trigger: Int) {
        self.trigger = trigger
    }

    public func body(content: Content) -> some View {
        content
            .offset(x: offset)
            // `.task(id:)` instead of a chain of `asyncAfter` calls: the
            // sequence is cancelled when the trigger fires again or the view
            // goes away, so a shake can neither outlive its view nor stack on
            // top of itself when re-triggered mid-flight.
            .task(id: trigger) {
                guard trigger > 0, !reduceMotion else { return }
                let beats: [(CGFloat, Animation, UInt64)] = [
                    (-10, .spring(response: 0.08, dampingFraction: 0.4), 80_000_000),
                    (10, .spring(response: 0.08, dampingFraction: 0.4), 80_000_000),
                    (-6, .spring(response: 0.08, dampingFraction: 0.4), 80_000_000),
                    (0, .spring(response: 0.2, dampingFraction: 0.5), 0)
                ]
                for (value, animation, pause) in beats {
                    withAnimation(animation) { offset = value }
                    guard pause > 0 else { break }
                    try? await Task.sleep(nanoseconds: pause)
                    if Task.isCancelled { offset = 0; return }
                }
            }
    }
}

public extension View {
    func nqPopIn(delay: Double = 0) -> some View { modifier(NQPopIn(delay: delay)) }
    func nqSlideUp(delay: Double = 0, distance: CGFloat = 26) -> some View { modifier(NQSlideUp(delay: delay, distance: distance)) }
    func nqCascade(index: Int, baseDelay: Double = 0.05) -> some View { modifier(NQCascade(index: index, baseDelay: baseDelay)) }
    func nqShake(on trigger: Int) -> some View { modifier(NQShake(trigger: trigger)) }
}

// MARK: - Impact shake (battle hits)

/// Camera-style impact shake: translation + a fraction of a degree of
/// rotation. Pure translation reads as a glitch; the rotation component is
/// what reads as force. Fire once when `trigger` changes.
public struct NQImpactShake: ViewModifier {
    private var trigger: Int
    private var intensity: CGFloat
    @State private var offset: CGFloat = 0
    @State private var angle: Double = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(trigger: Int, intensity: CGFloat = 8) {
        self.trigger = trigger
        self.intensity = intensity
    }

    public func body(content: Content) -> some View {
        content
            .offset(x: offset)
            .rotationEffect(.degrees(angle))
            .task(id: trigger) {
                guard trigger > 0, !reduceMotion else { return }
                withAnimation(.spring(response: 0.06, dampingFraction: 0.35)) {
                    offset = -intensity
                    angle = -0.6
                }
                try? await Task.sleep(nanoseconds: 70_000_000)
                guard !Task.isCancelled else { offset = 0; angle = 0; return }
                withAnimation(.spring(response: 0.07, dampingFraction: 0.4)) {
                    offset = intensity
                    angle = 0.5
                }
                try? await Task.sleep(nanoseconds: 80_000_000)
                guard !Task.isCancelled else { offset = 0; angle = 0; return }
                withAnimation(.spring(response: 0.2, dampingFraction: 0.5)) {
                    offset = 0
                    angle = 0
                }
            }
    }
}

public extension View {
    func nqImpactShake(on trigger: Int, intensity: CGFloat = 8) -> some View {
        modifier(NQImpactShake(trigger: trigger, intensity: intensity))
    }
}

// MARK: - Floating value popup (damage numbers)

/// A single floating number/word that pops up and drifts away — battle
/// damage, XP gains, key rewards. Compose several for a barrage.
public struct NQFloatingValue: View {
    public let text: String
    public let color: Color
    /// Unique per popup so each animates independently.
    private let id: UUID

    @State private var appeared = false
    @State private var fading = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(text: String, color: Color, id: UUID = UUID()) {
        self.text = text
        self.color = color
        self.id = id
    }

    public var body: some View {
        Text(text)
            .font(NQText.headingL.font.weight(.heavy))
            .foregroundStyle(color)
            .scaleEffect(appeared || reduceMotion ? 1 : 0.4)
            .offset(y: fading ? -34 : 0)
            .opacity(fading ? 0 : (appeared || reduceMotion ? 1 : 0))
            .task {
                guard !reduceMotion else { return }
                withAnimation(.spring(response: 0.22, dampingFraction: 0.55)) { appeared = true }
                try? await Task.sleep(nanoseconds: 450_000_000)
                guard !Task.isCancelled else { return }
                withAnimation(.easeIn(duration: 0.4)) { fading = true }
            }
            .accessibilityHidden(true)
    }
}

// MARK: - Success burst

/// Expanding ring + particle burst — play once when `trigger` changes.
public struct NQSuccessBurst: ViewModifier {
    private var trigger: Int
    @State private var animate = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(trigger: Int) {
        self.trigger = trigger
    }

    public func body(content: Content) -> some View {
        content
            .overlay {
                if animate && !reduceMotion {
                    ZStack {
                        Circle()
                            .stroke(NQTheme.success.opacity(0.6), lineWidth: 3)
                            .frame(width: 60, height: 60)
                            .scaleEffect(animate ? 2.2 : 0.4)
                            .opacity(animate ? 0 : 1)
                        ForEach(0..<8, id: \.self) { i in
                            Circle()
                                .fill(NQTheme.success)
                                .frame(width: 6, height: 6)
                                .offset(
                                    x: animate ? cos(CGFloat(i) / 8 * 2 * .pi) * 46 : 0,
                                    y: animate ? sin(CGFloat(i) / 8 * 2 * .pi) * 46 : 0
                                )
                                .opacity(animate ? 0 : 1)
                        }
                    }
                    .allowsHitTesting(false)
                }
            }
            .task(id: trigger) {
                guard trigger > 0 else { return }
                animate = false
                withAnimation(.easeOut(duration: 0.7)) { animate = true }
                try? await Task.sleep(nanoseconds: 750_000_000)
                animate = false
            }
    }
}

public extension View {
    func nqSuccessBurst(on trigger: Int) -> some View { modifier(NQSuccessBurst(trigger: trigger)) }
}

// MARK: - Shine sweep (legendary)

/// Diagonal light band sweeping across — attach to legendary cards / rewards.
public struct NQShineSweep: ViewModifier {
    private var active: Bool
    @State private var phase: CGFloat = -1.4
    @State private var running = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(active: Bool = true) {
        self.active = active
    }

    public func body(content: Content) -> some View {
        content
            .overlay {
                // `running` gates the overlay so the repeating sweep stops
                // when the view leaves the screen rather than animating on
                // forever behind whatever replaced it.
                if active && running && !reduceMotion {
                    GeometryReader { geo in
                        LinearGradient(
                            colors: [.clear, .white.opacity(0.55), .clear],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                        .frame(width: geo.size.width * 0.6)
                        .offset(x: phase * geo.size.width * 1.6)
                        .blendMode(.plusLighter)
                        .allowsHitTesting(false)
                    }
                    .clipped()
                    .onAppear {
                        withAnimation(.easeInOut(duration: 2.2).repeatForever(autoreverses: false).delay(0.6)) {
                            phase = 1.4
                        }
                    }
                }
            }
            .onAppear { running = true }
            .onDisappear { running = false }
    }
}

public extension View {
    func nqShineSweep(active: Bool = true) -> some View { modifier(NQShineSweep(active: active)) }
}

// MARK: - Breathing glow (active character)

/// Soft pulsing halo — attach behind the displayed character.
public struct NQBreathingGlow: ViewModifier {
    private var color: Color
    @State private var breathing = false
    @State private var running = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(color: Color) {
        self.color = color
    }

    public func body(content: Content) -> some View {
        content
            .background {
                if running {
                Circle()
                    .fill(color.opacity(0.35))
                    .frame(width: 190, height: 190)
                    .blur(radius: 30)
                    .scaleEffect(breathing && !reduceMotion ? 1.12 : 0.94)
                    .animation(
                        reduceMotion ? nil : .easeInOut(duration: 2.0).repeatForever(autoreverses: true),
                        value: breathing
                    )
                    .allowsHitTesting(false)
                }
            }
            .onAppear { running = true; breathing = true }
            .onDisappear { running = false }
    }
}

public extension View {
    func nqBreathingGlow(color: Color) -> some View { modifier(NQBreathingGlow(color: color)) }
}

// MARK: - Floating particles (ambient sparkles)

/// Gentle drifting sparkles — attach to any screen for ambient life.
public struct NQFloatingSparkles: View {
    private var count: Int = 7
    private var color: Color

    @State private var animate = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(count: Int = 7, color: Color = NQTheme.gold) {
        self.count = count
        self.color = color
    }

    public var body: some View {
        GeometryReader { geo in
            ForEach(0..<count, id: \.self) { i in
                let seed = CGFloat(i)
                let x = geo.size.width * ((seed * 0.618).truncatingRemainder(dividingBy: 1))
                let baseY = geo.size.height * ((seed * 0.382).truncatingRemainder(dividingBy: 1))
                NQIcon.sparkle.view
                    .font(.system(size: 9 + (seed.truncatingRemainder(dividingBy: 3)) * 3))
                    .foregroundStyle(color.opacity(animate && !reduceMotion ? 0.15 : 0.6))
                    .position(
                        x: x + (animate && !reduceMotion ? 8 : -8),
                        y: baseY + (animate && !reduceMotion ? -14 : 6)
                    )
                    .animation(
                        reduceMotion
                            ? nil
                            : .easeInOut(duration: 2.4 + Double(i % 4) * 0.7)
                                .repeatForever(autoreverses: true),
                        value: animate
                    )
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear { animate = true }
    }
}

// MARK: - Card tilt (TCG feel)

/// Drag-driven 3D tilt — the physical "pick up the card" feel from TCG apps.
/// The card rotates toward the finger and a light band tracks the tilt;
/// release springs it flat. Off under Reduce Motion.
public struct NQCardTilt: ViewModifier {
    @State private var tiltX: Double = 0
    @State private var tiltY: Double = 0
    @State private var shine: CGFloat = -0.4
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let maxTilt: Double = 14

    public init() {}

    public func body(content: Content) -> some View {
        content
            .rotation3DEffect(.degrees(tiltY), axis: (x: 1, y: 0, z: 0), perspective: 0.6)
            .rotation3DEffect(.degrees(tiltX), axis: (x: 0, y: 1, z: 0), perspective: 0.6)
            .overlay {
                if !reduceMotion, tiltX != 0 || tiltY != 0 {
                    LinearGradient(
                        colors: [.clear, .white.opacity(0.25), .clear],
                        startPoint: UnitPoint(x: 0, y: shine),
                        endPoint: UnitPoint(x: 1, y: shine + 0.4)
                    )
                    .blendMode(.plusLighter)
                    .allowsHitTesting(false)
                }
            }
            .gesture(
                // Threshold keeps taps flowing to the button underneath.
                DragGesture(minimumDistance: 8)
                    .onChanged { v in
                        guard !reduceMotion else { return }
                        let size = CGSize(width: 90, height: 120)
                        tiltY = -Double(v.location.y / size.height - 0.5) * maxTilt * 2
                        tiltX = Double(v.location.x / size.width - 0.5) * maxTilt * 2
                        shine = v.location.y / 240
                    }
                    .onEnded { _ in
                        withAnimation(NQMotion.springy) {
                            tiltX = 0
                            tiltY = 0
                            shine = -0.4
                        }
                    }
            )
    }
}

public extension View {
    /// TCG-style 3D tilt on drag. Attach to cards.
    func nqCardTilt() -> some View { modifier(NQCardTilt()) }
}

// MARK: - Squish (mascot squash-and-stretch)

/// Tap squash: dips flat then overshoots tall and settles — the classic
/// cartoon bounce that makes a mascot feel squishable.
public struct NQSquish: ViewModifier {
    @State private var squishY: CGFloat = 1
    @State private var squishX: CGFloat = 1
    @State private var taps = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init() {}

    public func body(content: Content) -> some View {
        content
            .scaleEffect(x: squishX, y: squishY, anchor: .bottom)
            .gesture(
                SpatialTapGesture()
                    .onEnded { _ in
                        guard !reduceMotion else { return }
                        NQHaptic.light()
                        taps += 1
                    }
            )
            // The rebound rides a cancellable task so a mascot tapped as the
            // screen is dismissed cannot leave its scale mid-squash.
            .task(id: taps) {
                guard taps > 0, !reduceMotion else { return }
                withAnimation(.easeOut(duration: 0.08)) {
                    squishY = 0.82; squishX = 1.14
                }
                try? await Task.sleep(nanoseconds: 90_000_000)
                withAnimation(.spring(response: 0.3, dampingFraction: 0.4)) {
                    squishY = 1; squishX = 1
                }
            }
    }
}

public extension View {
    /// Squash-and-stretch on tap. Attach to mascots and stickers.
    func nqSquish() -> some View { modifier(NQSquish()) }
}
