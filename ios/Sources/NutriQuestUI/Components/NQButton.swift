import SwiftUI

/// Beveled command button with a dark edge and a golden primary action.
public struct NQButton: View {
    public enum Style { case primary, secondary, ghost, destructive }

    private let title: String
    private let icon: NQIcon?
    private let sfSymbol: String?
    private let style: Style
    private let fullWidth: Bool
    private let action: () -> Void

    @Environment(\.nqAccent) private var accent
    @Environment(\.isEnabled) private var isEnabled

    public init(
        _ title: String,
        icon: NQIcon? = nil,
        sfSymbol: String? = nil,
        style: Style = .primary,
        fullWidth: Bool = true,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.icon = icon
        self.sfSymbol = sfSymbol
        self.style = style
        self.fullWidth = fullWidth
        self.action = action
    }

    public var body: some View {
        Button(action: {
            NQSound.play(tapSound)
            NQHaptic.light()
            action()
        }) {
            HStack(spacing: NQTheme.spaceS) {
                if let icon {
                    NQIconView(icon: icon, tint: foreground)
                        .frame(width: NQLayout.iconM, height: NQLayout.iconM)
                } else if let sfSymbol {
                    Image(systemName: sfSymbol)
                        .font(.system(size: NQLayout.iconM, weight: .bold))
                }
                Text(title)
                    .font(NQText.heading.font)
                    .tracking(0.3)
            }
            .nqPadding(.button)
            .frame(minHeight: NQLayout.controlMinHeight)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .foregroundStyle(foreground)
            .background {
                if style != .ghost {
                    NQPanelShape()
                        .fill(background)
                        .overlay {
                            NQPanelShape().fill(LinearGradient(
                                colors: [.white.opacity(0.3), .clear],
                                startPoint: .top, endPoint: .bottom
                            ))
                        }
                }
            }
            .overlay {
                if style != .ghost {
                    NQPanelShape().strokeBorder(NQTheme.inkDeep, lineWidth: 3)
                    NQPanelShape().inset(by: 4)
                        .strokeBorder(style == .primary ? Color.white.opacity(0.5) : accent.accent.opacity(0.5), lineWidth: 1)
                }
            }
            .opacity(isEnabled ? 1 : 0.5)
            .accessibilityElement(children: .combine)
        }
        .buttonStyle(NQPressableStyle(
            scale: 0.96,
            haptic: false,
            ledge: style == .ghost ? 0 : (style == .primary ? 5 : 3)
        ))
        .onHover { hovering in
            if hovering { NQSound.play(.hover) }
        }
    }

    private var foreground: Color {
        switch style {
        case .primary: return accent.accent.readableTextColor()
        case .secondary, .ghost: return accent.accentDark
        case .destructive: return NQTheme.warning
        }
    }

    // tap vs tapAlt: primary/destructive are the main action, the rest are quieter.
    private var tapSound: NQSound.Effect {
        switch style {
        case .primary, .destructive: return .tap
        case .secondary, .ghost: return .tapAlt
        }
    }

    private var background: Color {
        switch style {
        case .primary: return accent.accent
        case .secondary: return NQTheme.surface
        case .ghost: return .clear
        case .destructive: return NQTheme.warning.opacity(0.12)
        }
    }
}

// MARK: - Streak pill (flame counter)

/// Flame + count pill shown in the top bar. Pulse-animated.
public struct NQStreakPill: View {
    private let count: Int
    @State private var pulsing = false
    @State private var running = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(count: Int) {
        self.count = count
    }

    public var body: some View {
        HStack(spacing: NQTheme.spaceS) {
            NQIcon.flame.view
                .frame(width: NQLayout.iconS, height: NQLayout.iconS)
                .foregroundStyle(NQTheme.flame)
                .scaleEffect(pulsing && running && !reduceMotion ? 1.08 : 1)
                .animation(
                    reduceMotion ? nil : .easeInOut(duration: 1.6).repeatForever(autoreverses: true),
                    value: pulsing
                )
            NQCountUpText(value: count, font: NQText.body.font)
        }
        .nqPadding(.chip)
        .nqPlate(NQTicketShape(), elevation: .sticker, inkStroke: true, lineWidth: NQLayout.hairlineWidth)
        .onAppear { running = true; pulsing = true }
        .onDisappear { running = false }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(count) day streak")
    }
}

// MARK: - Chips

/// Small rounded label chip. Defaults to the dynamic accent; override with `tint`.
public struct NQChip: View {
    private let text: String
    private let icon: NQIcon?
    private var tint: Color?
    private var filled: Bool

    @Environment(\.nqAccent) private var accent

    public init(_ text: String, icon: NQIcon? = nil, tint: Color? = nil, filled: Bool = false) {
        self.text = text
        self.icon = icon
        self.tint = tint
        self.filled = filled
    }

    public var body: some View {
        let color = tint ?? accent.accentDark
        HStack(spacing: NQTheme.spaceXS) {
            if let icon {
                icon.view
                    .frame(width: NQLayout.iconXS - 1, height: NQLayout.iconXS - 1)
            }
            Text(text)
                .font(NQText.captionS.font)
        }
        .foregroundStyle(filled ? color.readableTextColor() : color)
        .padding(.horizontal, NQTheme.spaceS)
        .padding(.vertical, 6)
        .background(NQTicketShape().fill(filled ? color : NQTheme.chrome))
        .overlay {
            NQTicketShape().strokeBorder(NQTheme.inkDeep, lineWidth: 2)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Pulsing "Live" chip for a round that's still in play.
public struct NQLiveBadge: View {
    private var tint: Color
    @State private var pulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(tint: Color = NQTheme.warning) {
        self.tint = tint
    }

    public var body: some View {
        HStack(spacing: NQTheme.spaceXS) {
            Circle()
                .fill(tint)
                .frame(width: 7, height: 7)
                .scaleEffect(pulse && !reduceMotion ? 1.25 : 0.9)
            Text("Live")
                .font(NQText.microS.font)
        }
        .foregroundStyle(tint)
        .nqPadding(.badge)
        .background(NQPanelShape(cut: NQTheme.radiusXS).fill(tint.opacity(0.16)))
        .overlay {
            NQPanelShape(cut: NQTheme.radiusXS).strokeBorder(tint.opacity(0.45), lineWidth: 1)
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
        .accessibilityLabel("Live round")
    }
}

/// Trailing chevron used on rows and doorways — one glyph, one size.
public struct NQChevron: View {
    public init() {}

    public var body: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: NQLayout.iconS, weight: .bold))
            .foregroundStyle(NQTheme.inkFaint)
            .accessibilityHidden(true)
    }
}

// MARK: - Stat badge (character chest badge)

/// The small badge a chibi character wears on its chest, showing its stat type.
public struct NQStatBadge: View {
    private let statType: NQStatType
    private var tint: Color?

    public init(statType: NQStatType, tint: Color? = nil) {
        self.statType = statType
        self.tint = tint
    }

    public var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: NQTheme.radiusXS)
                .fill((tint ?? statType.tint).darkened(0.25))
            statType.icon.view
                .frame(width: NQLayout.iconXS - 1, height: NQLayout.iconXS - 1)
                .foregroundStyle(.white)
        }
        .accessibilityLabel("\(statType.displayName) stat")
    }
}
