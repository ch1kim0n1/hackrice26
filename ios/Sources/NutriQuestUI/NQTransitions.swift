import SwiftUI

// MARK: - Transitions

/// Named transitions matching the design language.
public enum NQTransition {
    /// Cards / characters appearing: scale + fade spring.
    public static var pop: AnyTransition {
        .asymmetric(
            insertion: .scale(scale: 0.7).combined(with: .opacity),
            removal: .scale(scale: 0.85).combined(with: .opacity)
        )
    }

    /// List rows: slide up + fade.
    public static var slideUp: AnyTransition {
        .asymmetric(
            insertion: .move(edge: .bottom).combined(with: .opacity),
            removal: .opacity
        )
    }

    /// Detail screens: slide from trailing edge with fade.
    public static var push: AnyTransition {
        .asymmetric(
            insertion: .move(edge: .trailing).combined(with: .opacity),
            removal: .move(edge: .leading).combined(with: .opacity)
        )
    }

    /// Modal / summon overlay: scale from center + fade.
    public static var summon: AnyTransition {
        .asymmetric(
            insertion: .scale(scale: 1.15).combined(with: .opacity),
            removal: .scale(scale: 0.9).combined(with: .opacity)
        )
    }

    /// Flip-style reveal (rarity reveal, card flip).
    public static var flip: AnyTransition {
        .asymmetric(
            insertion: .scale(scale: 0.6, anchor: .center).combined(with: .opacity),
            removal: .scale(scale: 1.2, anchor: .center).combined(with: .opacity)
        )
    }
}

// MARK: - Ribbon slide-in

/// ACTIVE / SUGGESTED / LOCKED ribbon that slides in from the corner.
public struct NQRibbon: View {
    public enum Kind: String {
        case active = "Active"
        case suggested = "Suggested"
        case locked = "Locked"
    }

    private let kind: Kind
    private var color: Color
    @State private var slidIn = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(_ kind: Kind, color: Color) {
        self.kind = kind
        self.color = color
    }

    public var body: some View {
        Text(kind.rawValue)
            .font(NQText.microS.font)
            .foregroundStyle(color.readableTextColor())
            .nqPadding(.badge)
            .background(color)
            .clipShape(UnevenRoundedRectangle(topLeadingRadius: NQTheme.radiusM, bottomTrailingRadius: 8))
            .offset(x: slidIn || reduceMotion ? 0 : -34)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.spring(response: 0.4, dampingFraction: 0.7).delay(0.15)) {
                    slidIn = true
                }
            }
    }
}

// MARK: - State variants

public extension NQBanner {
    /// Semantic banner presets.
    static func info(_ message: String, accent: NQAccentContext) -> NQBanner {
        NQBanner(message, dotColor: accent.accent)
    }
    static func success(_ message: String) -> NQBanner {
        NQBanner(message, dotColor: NQTheme.success)
    }
    static func warning(_ message: String) -> NQBanner {
        NQBanner(message, dotColor: NQTheme.warning)
    }
    static func error(_ message: String, onDismiss: (() -> Void)? = nil) -> NQBanner {
        NQBanner(message, dotColor: NQTheme.warning.darkened(0.2), onDismiss: onDismiss)
    }
}

/// Full content-state pattern: loading / empty / error / offline.
public struct NQContentState: View {
    public enum Kind {
        case loading(String)
        case empty(String)
        case error(String, retry: (() -> Void)?)
        case offline(retry: (() -> Void)?)
    }

    private let kind: Kind

    @Environment(\.nqAccent) private var accent

    public init(_ kind: Kind) {
        self.kind = kind
    }

    public var body: some View {
        VStack(spacing: NQTheme.spaceM) {
            switch kind {
            case .loading(let message):
                NQDotsLoader(color: accent.accent)
                Text(message)
                    .font(NQText.body.font)
                    .foregroundStyle(NQTheme.inkMuted)
            case .empty(let message):
                NQEmptyState(message: message)
            case .error(let message, let retry):
                stateBlock(
                    icon: .alert,
                    tint: NQTheme.warning,
                    message: message,
                    actionTitle: retry == nil ? nil : "Try Again",
                    action: retry
                )
            case .offline(let retry):
                stateBlock(
                    icon: .wifiOff,
                    tint: NQTheme.inkMuted,
                    message: "No connection. Check your internet.",
                    actionTitle: retry == nil ? nil : "Retry",
                    action: retry
                )
            }
        }
        .frame(maxWidth: .infinity)
        .padding(NQLayout.heroAir)
        .transition(NQTransition.pop)
    }

    private func stateBlock(icon: NQIcon, tint: Color, message: String, actionTitle: String?, action: (() -> Void)?) -> some View {
        VStack(spacing: NQTheme.spaceM) {
            icon.view
                .frame(width: 40, height: 40)
                .foregroundStyle(tint)
            Text(message)
                .font(NQText.bodyL.font)
                .foregroundStyle(NQTheme.inkMuted)
                .multilineTextAlignment(.center)
            if let actionTitle, let action {
                NQButton(actionTitle, style: .secondary, fullWidth: false, action: action)
            }
        }
    }
}

// MARK: - Selected glow (card selection)

/// Glowing ring for the currently selected card.
public struct NQSelectedGlow: ViewModifier {
    private var selected: Bool
    private var color: Color

    public init(selected: Bool, color: Color) {
        self.selected = selected
        self.color = color
    }

    public func body(content: Content) -> some View {
        content
            .overlay {
                if selected {
                    // A ring, not a pulse. Selection is a state the user just
                    // set deliberately; it does not need to keep announcing
                    // itself, and a looping glow on a selected card is exactly
                    // the kind of idle motion that makes a screen feel noisy.
                    RoundedRectangle(cornerRadius: NQTheme.radiusM, style: .continuous)
                        .stroke(color, lineWidth: 3)
                        .allowsHitTesting(false)
                }
            }
            .animation(NQMotion.snappy, value: selected)
    }
}

public extension View {
    func nqSelectedGlow(_ selected: Bool, color: Color) -> some View {
        modifier(NQSelectedGlow(selected: selected, color: color))
    }
}

// MARK: - Long-press wobble (edit mode)

/// Jiggling wobble for edit/rearrange mode.
public struct NQWobble: ViewModifier {
    private var active: Bool
    @State private var angle: Double = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(active: Bool) {
        self.active = active
    }

    public func body(content: Content) -> some View {
        content
            .rotationEffect(.degrees(active && !reduceMotion ? angle : 0))
            .onAppear {
                guard active, !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.18).repeatForever(autoreverses: true)) {
                    angle = 2.2
                }
            }
            .onChange(of: active) { isActive in
                guard !reduceMotion else { return }
                if isActive {
                    withAnimation(.easeInOut(duration: 0.18).repeatForever(autoreverses: true)) {
                        angle = 2.2
                    }
                } else {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { angle = 0 }
                }
            }
    }
}

public extension View {
    func nqWobble(_ active: Bool) -> some View { modifier(NQWobble(active: active)) }
}

// MARK: - Locked shimmer

/// Subtle shimmer over locked cards.
public struct NQLockedShimmer: ViewModifier {
    @State private var phase: CGFloat = -1
    @State private var running = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init() {}

    public func body(content: Content) -> some View {
        content
            .overlay {
                if running && !reduceMotion {
                    GeometryReader { geo in
                        LinearGradient(
                            colors: [.clear, .white.opacity(0.35), .clear],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        )
                        .frame(width: geo.size.width * 0.5)
                        .offset(x: phase * geo.size.width * 1.8)
                        .allowsHitTesting(false)
                    }
                    .clipped()
                    .onAppear {
                        withAnimation(.easeInOut(duration: 2.6).repeatForever(autoreverses: false).delay(1.0)) {
                            phase = 1
                        }
                    }
                }
            }
            .onAppear { running = true }
            .onDisappear { running = false }
    }
}

public extension View {
    func nqLockedShimmer() -> some View { modifier(NQLockedShimmer()) }
}
