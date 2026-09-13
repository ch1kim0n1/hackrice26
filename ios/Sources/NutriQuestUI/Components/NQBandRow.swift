import SwiftUI

/// A colored dot + label + range row, for rarity brackets and price bands.
public struct NQBandRow: View {
    private let color: Color
    private let label: String
    private let range: String

    public init(color: Color, label: String, range: String) {
        self.color = color
        self.label = label
        self.range = range
    }

    public var body: some View {
        HStack {
            Circle()
                .fill(color)
                .frame(width: 10, height: 10)
            Text(label)
                .font(NQText.heading.font)
                .foregroundStyle(NQTheme.ink)
            Spacer()
            Text(range)
                .font(NQText.caption.font.weight(.bold))
                .foregroundStyle(NQTheme.inkMuted)
        }
        .accessibilityElement(children: .combine)
    }
}

/// "EPIC VALUE REACHED" — the toast a wager game shows when a climbing pot
/// crosses into the next rarity bracket.
///
/// Lived twice, verbatim, in Cauldron Crash and Kitchen Mines. Both games
/// climb a multiplier through the same `rarityBands` ladder, so the toast is
/// one component, not one per game.
public struct NQBracketBanner: View {
    private let label: String

    public init(_ label: String) {
        self.label = label
    }

    public var body: some View {
        Text("\(label.uppercased()) VALUE REACHED")
            .font(NQText.microS.font.weight(.heavy))
            .tracking(0.8)
            .foregroundStyle(NQTheme.background)
            .nqPadding(.banner)
            .background(NQTheme.gold)
            .clipShape(Capsule())
            .nqElevation(.card)
            .accessibilityAddTraits(.isStaticText)
    }
}
