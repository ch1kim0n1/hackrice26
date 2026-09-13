import SwiftUI

/// Live gallery of every UI kit component — the backbone reference.
/// Open in Xcode previews or present `NQUIDemoView()` to audit the kit.
public struct NQUIDemoView: View {
    @State private var tab: NQTab = .home
    @State private var barValue: Double = 0.62

    public init() {}

    public var body: some View {
        NQScreen(
            tab: $tab,
            trailing: { NQStreakPill(count: 3) }
        ) {
            ScrollView {
                VStack(alignment: .leading, spacing: NQTheme.spaceL) {

                    NQBanner("Display character: **Blossom**")

                    NQSectionHeader("Character stage", trailing: "ChibiCharacterView")
                    let showcase: [(ChibiExpression, NQStatType)] = [
                        (.happy, .protein), (.neutral, .fiber), (.sleepy, .vitamin), (.sparkle, .hydration)
                    ]
                    HStack(spacing: NQTheme.spaceL) {
                        ForEach(showcase, id: \.0) { expr, stat in
                            VStack(spacing: 4) {
                                ChibiCharacterView(color: .blossom, statType: stat, expression: expr)
                                    .frame(width: 72, height: 92)
                                Text(expr.rawValue)
                                    .font(NQText.micro.font)
                                    .foregroundStyle(NQTheme.inkMuted)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, NQTheme.spaceS)

                    NQSectionHeader("Character cards", trailing: "rarity outlines")
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: NQTheme.spaceM) {
                        NQCharacterCard(name: "Fibelle", color: .mint, rarity: .common, statType: .fiber, state: .active)
                        NQCharacterCard(name: "Proteini", color: .sky, rarity: .rare, statType: .protein, state: .suggested)
                        NQCharacterCard(name: "Vitamina", color: .blossom, rarity: .epic, statType: .vitamin)
                        NQCharacterCard(name: "Hydra", color: .lilac, rarity: .legendary, statType: .hydration, state: .locked)
                    }

                    NQSectionHeader("Stat bars")
                    NQCard {
                        VStack(spacing: NQTheme.spaceM) {
                            NQStatBar(label: "Protein", value: 0.72, valueText: "72%").fill(NQCharacterColor.peach.accent)
                            NQStatBar(label: "Fiber", value: 0.45, valueText: "45%").fill(NQCharacterColor.mint.accent)
                            NQStatBar(label: "Hydration", value: 0.88, valueText: "88%").fill(NQCharacterColor.sky.accent)
                        }
                    }

                    NQSectionHeader("Buttons")
                    VStack(spacing: NQTheme.spaceS) {
                        NQButton("Scan a snack", icon: .scan) {}
                        NQButton("Secondary", style: .secondary) {}
                        NQButton("Ghost", style: .ghost, fullWidth: false) {}
                        NQButton("Delete squad", icon: .lock, style: .destructive) {}
                    }

                    NQSectionHeader("Chips")
                    NQCard {
                        VStack(alignment: .leading, spacing: NQTheme.spaceS) {
                            FlowChips()
                        }
                    }

                    NQSectionHeader("Empty state")
                    NQCard {
                        NQEmptyState(message: "Your squad is empty: let's fix that!")
                    }
                }
                .padding(NQTheme.spaceL)
                .padding(.bottom, NQTheme.spaceXL)
            }
        }
        .nqAccentContext(NQAccentContext(mode: .active, character: .blossom))
    }
}

private struct FlowChips: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                NQChip("Protein +12", icon: .gym)
                NQChip("Fiber +8", icon: .leaf)
                NQChip("Vitamin C", icon: .star)
            }
            HStack {
                NQChip("Legendary", tint: NQRarity.legendary.outline, filled: true)
                NQChip("Rare", tint: NQRarity.rare.outline, filled: true)
                NQChip("Locked", tint: NQTheme.lockedFill, filled: true)
                NQChip("Boost +18%", icon: .battle, filled: true)
            }
        }
    }
}

#Preview("UI Kit Demo") {
    NQUIDemoView()
}

#Preview("Neutral mode") {
    NQScreen(tab: .constant(.home)) {
        VStack {
            NQBanner("No characters yet: scan food to summon your first one")
            NQEmptyState(message: "Your squad is empty: let's fix that!")
        }
        .padding()
    }
    .nqAccentContext(.neutral)
}
