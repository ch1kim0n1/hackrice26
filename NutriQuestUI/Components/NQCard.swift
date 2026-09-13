import SwiftUI

/// White card container with standard elevation and radius.
public struct NQCard<Content: View>: View {
    private let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        content
            .nqPadding(.card)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(NQTheme.background)
            .clipShape(RoundedRectangle(cornerRadius: NQTheme.radiusM))
            .nqElevation(.soft)
    }
}

// MARK: - Character card (Collection)

/// The shared Collection card: white card, rarity-colored outline, chibi
/// preview, name, stat chip, and an optional ACTIVE / SUGGESTED / LOCKED ribbon.
public struct NQCharacterCard: View {
    public enum State { case normal, active, suggested, locked }

    private let name: String
    private let color: NQCharacterColor
    private let rarity: NQRarity
    private let statType: NQStatType
    private let state: State
    private let expression: ChibiExpression

    public init(
        name: String,
        color: NQCharacterColor,
        rarity: NQRarity,
        statType: NQStatType,
        state: State = .normal,
        expression: ChibiExpression = .happy
    ) {
        self.name = name
        self.color = color
        self.rarity = rarity
        self.statType = statType
        self.state = state
        self.expression = expression
    }

    public var body: some View {
        VStack(spacing: NQTheme.spaceS) {
            ChibiCharacterView(
                color: color,
                statType: statType,
                expression: state == .locked ? .sleepy : expression
            )
            .frame(width: 96, height: 118)
            .opacity(state == .locked ? 0.45 : 1)

            Text(name)
                .font(NQText.heading.font)
                .foregroundStyle(state == .locked ? NQTheme.inkMuted : NQTheme.ink)
                .lineLimit(1)

            NQChip(rarity.displayName, tint: rarity.outline)
        }
        .nqPadding(.card)
        .frame(maxWidth: .infinity)
        .background(NQTheme.background)
        .clipShape(RoundedRectangle(cornerRadius: NQTheme.radiusM))
        .overlay {
            RoundedRectangle(cornerRadius: NQTheme.radiusM)
                .strokeBorder(outlineColor, lineWidth: state == .locked ? 1.5 : 2.5)
        }
        .overlay(alignment: .topLeading) {
            ribbon
        }
        .nqElevation(.raised)
    }

    private var outlineColor: Color {
        state == .locked ? NQTheme.lockedFill : rarity.outline
    }

    @ViewBuilder
    private var ribbon: some View {
        switch state {
        case .active:
            NQRibbon(.active, color: color.accentDark)
        case .suggested:
            NQRibbon(.suggested, color: NQTheme.gold)
        case .locked:
            NQRibbon(.locked, color: NQTheme.lockedFill)
        case .normal:
            EmptyView()
        }
    }
}

// MARK: - Empty state

/// Dashed circle + message — the "no characters yet" pattern.
public struct NQEmptyState: View {
    private let message: String
    private var icon: NQIcon

    @Environment(\.nqAccent) private var accent

    public init(message: String, icon: NQIcon = .sparkle) {
        self.message = message
        self.icon = icon
    }

    public var body: some View {
        VStack(spacing: NQTheme.spaceM) {
            Circle()
                .strokeBorder(style: StrokeStyle(lineWidth: 3, dash: [8, 6]))
                .foregroundStyle(accent.accent)
                .frame(width: 150, height: 150)
                .overlay {
                    icon.view
                        .frame(width: 36, height: 36)
                        .foregroundStyle(accent.accent)
                }
            Text(message)
                .font(NQText.bodyL.font)
                .foregroundStyle(NQTheme.inkMuted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }
}
