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

    /// Spring with custom response/damping.
    public static func spring(response: Double, damping: Double) -> Animation {
        .spring(response: response, dampingFraction: damping)
    }
}

// MARK: - Haptics

public enum NQHaptic {
    #if canImport(UIKit)
    public static func light() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    public static func medium() { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
    public static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    public static func warning() { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
    public static func error() { UINotificationFeedbackGenerator().notificationOccurred(.error) }
    public static func selection() { UISelectionFeedbackGenerator().selectionChanged() }
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
/// Attach haptics via `haptic:`.
public struct NQPressableStyle: ButtonStyle {
    private var scale: CGFloat = 0.94
    private var haptic: Bool = true
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(scale: CGFloat = 0.94, haptic: Bool = true) {
        self.scale = scale
        self.haptic = haptic
    }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? scale : 1)
            .opacity(isEnabled ? 1 : 0.5)
            .animation(.spring(response: 0.28, dampingFraction: 0.6), value: configuration.isPressed)
            .onChange(of: configuration.isPressed) { _, pressed in
                if pressed && haptic { NQHaptic.light() }
            }
    }
}

public extension ButtonStyle where Self == NQPressableStyle {
    static var nqPressable: NQPressableStyle { NQPressableStyle() }
    static func nqPressable(scale: CGFloat, haptic: Bool = true) -> NQPressableStyle {
        NQPressableStyle(scale: scale, haptic: haptic)
    }
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
            .onChange(of: trigger) { _, _ in
                guard !reduceMotion else { return }
                withAnimation(.spring(response: 0.08, dampingFraction: 0.4)) { offset = -10 }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                    withAnimation(.spring(response: 0.08, dampingFraction: 0.4)) { offset = 10 }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
                    withAnimation(.spring(response: 0.08, dampingFraction: 0.4)) { offset = -6 }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.24) {
                    withAnimation(.spring(response: 0.2, dampingFraction: 0.5)) { offset = 0 }
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
            .onChange(of: trigger) { _, _ in
                animate = false
                withAnimation(.easeOut(duration: 0.7)) { animate = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) { animate = false }
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(active: Bool = true) {
        self.active = active
    }

    public func body(content: Content) -> some View {
        content
            .overlay {
                if active && !reduceMotion {
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(color: Color) {
        self.color = color
    }

    public func body(content: Content) -> some View {
        content
            .background {
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
            .onAppear { breathing = true }
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
