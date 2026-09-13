import SwiftUI

/// Primary pill button — filled with the dynamic accent.
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
            NQHaptic.light()
            action()
        }) {
            HStack(spacing: NQTheme.spaceS) {
                if let icon {
                    icon.view
                        .frame(width: 16, height: 16)
                } else if let sfSymbol {
                    Image(systemName: sfSymbol)
                        .font(.system(size: NQText.body.size, weight: .bold))
                }
                Text(title)
                    .font(NQText.heading.font)
            }
            .nqPadding(.button)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .foregroundStyle(foreground)
            .background(background)
            .clipShape(Capsule())
            .overlay {
                if style == .secondary {
                    Capsule().strokeBorder(accent.accent, lineWidth: 2)
                }
            }
            .opacity(isEnabled ? 1 : 0.5)
            .accessibilityElement(children: .combine)
        }
        .buttonStyle(.plain)
    }

    private var foreground: Color {
        switch style {
        case .primary: return accent.accent.readableTextColor()
        case .secondary, .ghost: return accent.accentDark
        case .destructive: return NQTheme.warning.darkened(0.35)
        }
    }

    private var background: Color {
        switch style {
        case .primary: return accent.accent
        case .secondary: return .white
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(count: Int) {
        self.count = count
    }

    public var body: some View {
        HStack(spacing: NQTheme.spaceS) {
            NQIcon.flame.view
                .frame(width: 14, height: 14)
                .foregroundStyle(NQTheme.flame)
                .scaleEffect(pulsing && !reduceMotion ? 1.18 : 0.94)
                .animation(
                    reduceMotion ? nil : .easeInOut(duration: 0.8).repeatForever(autoreverses: true),
                    value: pulsing
                )
            NQCountUpText(value: count, font: NQText.body.font)
        }
        .nqPadding(.chip)
        .background(NQTheme.background)
        .clipShape(Capsule())
        .nqElevation(.card)
        .onAppear { pulsing = true }
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
                    .frame(width: 11, height: 11)
            }
            Text(text)
                .font(NQText.captionS.font)
        }
        .foregroundStyle(filled ? color.readableTextColor() : color)
        .nqPadding(.chip)
        .background(filled ? color : color.opacity(0.12))
        .clipShape(Capsule())
        .accessibilityElement(children: .combine)
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
                .frame(width: 11, height: 11)
                .foregroundStyle(.white)
        }
        .accessibilityLabel("\(statType.displayName) stat")
    }
}
