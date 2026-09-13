import SwiftUI
import NutriQuestUI

/// The coin shop, reached from above the Casino/Battle switch.
///
/// One case per rarity. The roll is the Loot-Boxes-Logic branch's exactly —
/// odds renormalised over whatever tiers a case stocks, no rank boost, no
/// pity — so a pricier case is better purely because it stocks rarer tiers.
/// Picking a case pushes CaseOpeningView, where the carousel spins and the
/// win pops up. Selling lives on the Squad tab, next to the monsters.
struct ShopView: View {
    @ObservedObject var gameState: GameState
    @Environment(\.nqAccent) private var accent

    @State private var cases: [ShopCaseDTO] = []
    @State private var loaded = false
    @State private var selectedCase: ShopCaseDTO?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NQTheme.spaceL) {
                header

                if !loaded {
                    NQDotsLoader(color: NQTheme.gold)
                        .frame(maxWidth: .infinity)
                } else if cases.isEmpty {
                    NQEmptyState(message: "Couldn't reach the shop.", icon: .wifiOff)
                } else {
                    ForEach(cases) { shopCase in
                        caseRow(shopCase)
                    }
                }
            }
            .padding(NQTheme.spaceL)
        }
        .nqPageBackground()
        .navigationBarTitleDisplayMode(.inline)
        // isPresented, not item: — `item:` needs iOS 17 and a Hashable
        // payload; the deployment target is 16.
        .navigationDestination(isPresented: Binding(
            get: { selectedCase != nil },
            set: { if !$0 { selectedCase = nil } }
        )) {
            if let shopCase = selectedCase {
                CaseOpeningView(shopCase: shopCase, gameState: gameState)
            }
        }
        .task {
            await gameState.loadCoinBalance()
            cases = await gameState.refreshShopCases()
            loaded = true
        }
    }

    // MARK: - Header

    /// Same overline + headline shape as Casino and Squad, with the coin
    /// balance in the top corner.
    private var header: some View {
        HStack(alignment: .top, spacing: NQTheme.spaceM) {
            VStack(alignment: .leading, spacing: NQTheme.spaceXS) {
                Text("SHOP")
                    .font(NQText.micro.font)
                    .tracking(2)
                    .foregroundStyle(NQTheme.gold)
                Text("Case Roulette")
                    .font(NQText.display.font)
                    .foregroundStyle(NQTheme.ink)
                    .shadow(color: NQTheme.inkDeep, radius: 0, y: 2)
            }
            Spacer(minLength: 0)
            NQCoinBalance(balance: gameState.coinBalance)
        }
    }

    // MARK: - Cases

    private func caseRow(_ shopCase: ShopCaseDTO) -> some View {
        let floor = Rarity(rawValue: shopCase.odds.first?.rarity ?? "") ?? .common
        let affordable = gameState.coinBalance >= shopCase.coinCost

        return Button {
            NQHaptic.selection()
            selectedCase = shopCase
        } label: {
            VStack(alignment: .leading, spacing: NQTheme.spaceS) {
                HStack(alignment: .firstTextBaseline, spacing: NQTheme.spaceS) {
                    Text(shopCase.name)
                        .font(NQText.headingL.font.weight(.heavy))
                        .foregroundStyle(NQTheme.ink)
                    Spacer(minLength: 0)
                    Text(floor.label)
                        .font(NQText.tagBold.font)
                        .foregroundStyle(floor.badgeText)
                        .nqPadding(.badge)
                        .background(floor.badgeBackground)
                        .clipShape(Capsule())
                }
                Text(oddsLine(shopCase))
                    .font(NQText.captionS.font)
                    .foregroundStyle(NQTheme.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(alignment: .firstTextBaseline, spacing: NQTheme.spaceS) {
                    Text("\(shopCase.coinCost.formatted()) coins")
                        .font(NQText.heading.font.weight(.bold))
                        .foregroundStyle(affordable ? NQTheme.gold : NQTheme.inkMuted)
                    Spacer(minLength: 0)
                    Text(affordable ? "Open →" : "Not enough coins")
                        .font(NQText.captionS.font)
                        .foregroundStyle(affordable ? accent.accent : NQTheme.inkMuted)
                }
            }
            .nqPadding(.card)
            .nqSurface(.sticker)
            .overlay {
                NQPanelShape().strokeBorder(floor.ringColor.opacity(0.6), lineWidth: NQLayout.hairlineWidth)
            }
        }
        .buttonStyle(NQPressableStyle(scale: 0.97, haptic: false))
        // Not disabled when unaffordable — the case page still shows its
        // odds table; only the Open button there is gated.
    }

    /// The case's three likeliest tiers, as the server published them — the
    /// full table lives on the case's own page.
    private func oddsLine(_ shopCase: ShopCaseDTO) -> String {
        shopCase.odds.prefix(3)
            .map { "\(percent($0.tierChance)) \($0.label)" }
            .joined(separator: " · ")
    }

    private func percent(_ chance: Double) -> String {
        chance >= 0.1
            ? String(format: "%.0f%%", chance * 100)
            : String(format: "%.2g%%", chance * 100)
    }
}
