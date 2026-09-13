import SwiftUI

/// Coin disc + count. No enclosing plate — a plate on a 28pt-tall HUD
/// always reads as a capsule, which this game does not use.
public struct NQCoinBalance: View {
    private let balance: Int?
    @State private var popped = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(balance: Int?) {
        self.balance = balance
    }

    public var body: some View {
        HStack(spacing: 6) {
            ZStack {
                Circle().fill(NQTheme.gold)
                Circle().strokeBorder(NQTheme.inkDeep, lineWidth: 2.5)
                Text("$")
                    .font(NQText.caption.font.weight(.heavy))
                    .foregroundStyle(NQTheme.inkDeep)
            }
            .frame(width: 28, height: 28)
            .nqElevation(.sticker)
            .scaleEffect(popped && !reduceMotion ? 1.18 : 1)
            Text(balance?.formatted() ?? "-")
                .font(NQText.heading.font.weight(.heavy))
                .foregroundStyle(NQTheme.ink)
                .shadow(color: NQTheme.inkDeep, radius: 0, y: 2)
                .monospacedDigit()
                .contentTransition(.numericText())
        }
        .scaleEffect(popped && !reduceMotion ? 1.08 : 1)
        .onChange(of: balance) { _ in
            guard !reduceMotion else { return }
            NQHaptic.light()
            withAnimation(NQMotion.bouncy) { popped = true }
            withAnimation(NQMotion.snappy.delay(0.28)) { popped = false }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(balance.map { "\($0) coins" } ?? "Coin balance loading")
    }
}
