import SwiftUI

/// The player's coin balance as a small corner label — a coin and a number,
/// no card around it. Sits in the top corner of the Casino tab and the Shop,
/// so a case's price never appears without the balance it's measured against.
public struct NQCoinBalance: View {
    private let balance: Int?

    public init(balance: Int?) {
        self.balance = balance
    }

    public var body: some View {
        HStack(spacing: NQTheme.spaceXS) {
            Image(systemName: "dollarsign.circle.fill")
                .font(.system(size: NQLayout.iconL, weight: .bold))
                .foregroundStyle(NQTheme.gold)
            Text(balance?.formatted() ?? "—")
                .font(NQText.headingL.font.weight(.heavy))
                .foregroundStyle(NQTheme.ink)
                .monospacedDigit()
                .contentTransition(.numericText())
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(balance.map { "\($0) coins" } ?? "Coin balance loading")
    }
}
