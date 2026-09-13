import SwiftUI
import NutriQuestUI

/// The coin shop, reached from above the Casino/Battle switch.
///
/// Four Cookbooks (spec §3): each is bought with coins, rolls a rarity Case
/// on its own published odds table, then mints a ★1 monster of that rarity.
/// A pricier book is better purely because its odds favour rarer tiers.
/// Picking a book pushes CaseOpeningView, where the carousel spins and the
/// win pops up. Selling lives on the Squad tab, next to the monsters.
struct ShopView: View {
    @ObservedObject var gameState: GameState
    @Environment(\.nqAccent) private var accent

    @State private var cookbooks: [CookbookDTO] = []
    @State private var loaded = false
    @State private var selectedBook: CookbookDTO?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NQTheme.spaceL) {
                header

                if !loaded {
                    NQDotsLoader(color: NQTheme.gold)
                        .frame(maxWidth: .infinity)
                } else if cookbooks.isEmpty {
                    NQEmptyState(message: "Couldn't reach the shop.", icon: .wifiOff)
                } else {
                    ForEach(cookbooks) { book in
                        bookRow(book)
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
            get: { selectedBook != nil },
            set: { if !$0 { selectedBook = nil } }
        )) {
            if let book = selectedBook {
                CaseOpeningView(cookbook: book, gameState: gameState)
            }
        }
        .task {
            await gameState.loadCoinBalance()
            cookbooks = await gameState.refreshCookbooks()
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
                Text("Cookbooks")
                    .font(NQText.display.font)
                    .foregroundStyle(NQTheme.ink)
                    .shadow(color: NQTheme.inkDeep, radius: 0, y: 2)
            }
            Spacer(minLength: 0)
            NQCoinBalance(balance: gameState.coinBalance)
        }
    }

    // MARK: - Cookbooks

    private func bookRow(_ book: CookbookDTO) -> some View {
        // Odds arrive sorted likeliest-first — `first` is the book's modal
        // tier, which is what distinguishes the four books at a glance.
        let floor = Rarity(rawValue: book.odds.first?.rarity ?? "") ?? .common
        let affordable = gameState.coinBalance >= book.price

        return Button {
            NQHaptic.selection()
            selectedBook = book
        } label: {
            VStack(alignment: .leading, spacing: NQTheme.spaceS) {
                HStack(alignment: .firstTextBaseline, spacing: NQTheme.spaceS) {
                    Text(book.name)
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
                Text(oddsLine(book))
                    .font(NQText.captionS.font)
                    .foregroundStyle(NQTheme.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(alignment: .firstTextBaseline, spacing: NQTheme.spaceS) {
                    Text("\(book.price.formatted()) coins")
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
        // Not disabled when unaffordable — the book's page still shows its
        // odds table; only the Open button there is gated.
    }

    /// The book's three likeliest tiers, as the server published them — the
    /// full table lives on the book's own page.
    private func oddsLine(_ book: CookbookDTO) -> String {
        book.odds.sorted { $0.tierChance > $1.tierChance }.prefix(3)
            .map { "\(percent($0.tierChance)) \($0.label)" }
            .joined(separator: " · ")
    }

    private func percent(_ chance: Double) -> String {
        chance >= 0.1
            ? String(format: "%.0f%%", chance * 100)
            : String(format: "%.2g%%", chance * 100)
    }
}
