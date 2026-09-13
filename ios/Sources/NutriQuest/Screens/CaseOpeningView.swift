import SwiftUI
import NutriQuestUI

/// Pushed from the shop when a case is picked. The server resolves the drop
/// before anything animates; the reel only dramatises what it sent back, and
/// the win lands as a popup once the strip settles.
struct CaseOpeningView: View {
    let shopCase: ShopCaseDTO
    @ObservedObject var gameState: GameState

    @Environment(\.dismiss) private var dismiss

    /// What the page is doing right now. The server call and the reel never
    /// overlap: `.opening` waits on the network, `.spinning` plays the
    /// resolved reel, `.revealed` is the win popup.
    /// fileprivate, not private — the file-level extension below adds
    /// `isRevealed` for the reveal animation binding.
    fileprivate enum Phase {
        case idle
        case opening
        case spinning(CrateOpenResponse)
        case revealed(CrateOpenResponse)
    }
    @State private var phase: Phase = .idle

    private var floor: Rarity {
        Rarity(rawValue: shopCase.odds.first?.rarity ?? "") ?? .common
    }
    private var affordable: Bool { gameState.coinBalance >= shopCase.coinCost }
    private var busy: Bool {
        if case .idle = phase { return false }
        return true
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NQTheme.spaceL) {
                header

                oddsCard

                if case .spinning(let drop) = phase, let reel = drop.reel, let winnerIndex = drop.reelWinnerIndex {
                    CaseRouletteStrip(reel: reel, winnerIndex: winnerIndex) {
                        withAnimation(NQMotion.springy) { phase = .revealed(drop) }
                        NQJuice.success()
                    }
                    .transition(.opacity)
                }

                NQButton(
                    phaseLabel,
                    icon: .crown
                ) {
                    open()
                }
                .disabled(busy || !affordable)
            }
            .padding(NQTheme.spaceL)
        }
        .nqPageBackground()
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if case .revealed(let drop) = phase {
                winPopup(drop)
            }
        }
        .animation(NQMotion.springy, value: phase.isRevealed)
        .task { await gameState.loadCoinBalance() }
    }

    private var phaseLabel: String {
        switch phase {
        case .opening: return "Opening…"
        case .spinning: return "Spinning…"
        default: return "Open · \(shopCase.coinCost.formatted()) coins"
        }
    }

    // MARK: - Sections

    private var header: some View {
        HStack(alignment: .top, spacing: NQTheme.spaceM) {
            VStack(alignment: .leading, spacing: NQTheme.spaceXS) {
                Text("CASE")
                    .font(NQText.micro.font)
                    .tracking(2)
                    .foregroundStyle(NQTheme.gold)
                Text(shopCase.name)
                    .font(NQText.display.font)
                    .foregroundStyle(NQTheme.ink)
                    .shadow(color: NQTheme.inkDeep, radius: 0, y: 2)
            }
            Spacer(minLength: 0)
            NQCoinBalance(balance: gameState.coinBalance)
        }
    }

    /// Every tier the case stocks with its real chance — the whole odds
    /// table, not just the likeliest three.
    private var oddsCard: some View {
        VStack(alignment: .leading, spacing: NQTheme.spaceS) {
            Text(shopCase.description)
                .font(NQText.body.font)
                .foregroundStyle(NQTheme.inkMuted)
            ForEach(shopCase.odds, id: \.rarity) { odds in
                NQBandRow(color: Color(hex: odds.colorHex), label: odds.label, range: percent(odds.tierChance))
            }
        }
        .nqPadding(.card)
        .nqSurface(.sticker)
        .overlay {
            NQPanelShape().strokeBorder(floor.ringColor.opacity(0.6), lineWidth: NQLayout.hairlineWidth)
        }
    }

    private func percent(_ chance: Double) -> String {
        chance >= 0.1
            ? String(format: "%.0f%%", chance * 100)
            : String(format: "%.2g%%", chance * 100)
    }

    // MARK: - Open + reveal

    private func open() {
        phase = .opening
        Task {
            // The server has already decided the outcome by the time this
            // returns — the reel only animates what it resolved.
            if let drop = await gameState.openShopCase(caseID: shopCase.id) {
                gameState.addCrateCharacter(drop: drop)
                if drop.reel != nil, drop.reelWinnerIndex != nil {
                    phase = .spinning(drop)
                } else {
                    phase = .revealed(drop)
                    NQJuice.success()
                }
            } else {
                phase = .idle
            }
        }
    }

    /// The win, once the strip lands: artwork, name, rarity, worth. Tap
    /// outside or "Done" dismisses back to the shop.
    private func winPopup(_ drop: CrateOpenResponse) -> some View {
        let rarity = Rarity(rawValue: drop.character.rarity) ?? .common
        return ZStack {
            Color.black.opacity(0.55)
                .ignoresSafeArea()
                .onTapGesture { dismiss() }

            VStack(spacing: NQTheme.spaceM) {
                Text("YOU GOT")
                    .font(NQText.micro.font)
                    .tracking(2)
                    .foregroundStyle(rarity.ringColor)
                CharacterArtwork(
                    character: Character(
                        id: drop.character.id,
                        name: drop.character.name,
                        colorHex: drop.character.colorHex,
                        rarity: rarity,
                        statType: StatType(rawValue: drop.character.statType) ?? .fiber,
                        isShiny: drop.shiny
                    )
                )
                .frame(width: 120, height: 156)
                Text(drop.character.name)
                    .font(NQText.headingL.font.weight(.heavy))
                    .foregroundStyle(NQTheme.ink)
                HStack(spacing: NQTheme.spaceS) {
                    NQChip(rarity.label, tint: rarity.ringColor, filled: true)
                    if drop.shiny { NQChip("SHINY", tint: NQTheme.gold, filled: true) }
                }
                Text("Worth \(drop.value.formatted()) coins")
                    .font(NQText.captionS.font)
                    .foregroundStyle(NQTheme.inkMuted)
                NQButton("Done", icon: .checkCircle) { dismiss() }
            }
            .nqPadding(.card)
            .nqSurface(.sticker)
            .padding(NQTheme.spaceXL)
            .transition(NQTransition.pop)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Summoned \(drop.character.name), \(rarity.label)")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { dismiss() }
    }
}

fileprivate extension CaseOpeningView.Phase {
    var isRevealed: Bool {
        if case .revealed = self { return true }
        return false
    }
}
