import SwiftUI
import NutriQuestUI

/// Pushed from the shop when a Cookbook is picked. A cookbook buys a rarity
/// Case (spec §3): the server resolves the rarity and the mint together
/// before anything animates; the reel only dramatises what it sent back, and
/// the win lands as a popup once the strip settles — the Case's rarity is
/// part of that reveal.
struct CaseOpeningView: View {
    let cookbook: CookbookDTO
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
    /// Cookbook Boost (spec §6): earned every fifth streak day, spends one
    /// per open to multiply Rare+ odds by ×1.15. Default on when held.
    @State private var useBoost = true

    private var affordable: Bool { gameState.coinBalance >= cookbook.price }
    private var boostsHeld: Int { gameState.streak?.boosts ?? 0 }
    /// A book with no Rare+ mass can't benefit from a boost — the server
    /// wouldn't spend one anyway, so don't offer the toggle.
    private var boostable: Bool {
        cookbook.odds.contains { $0.tierChance > 0 && $0.rarity != "common" && $0.rarity != "uncommon" }
    }
    private var boostActive: Bool { useBoost && boostsHeld > 0 && boostable }
    private var busy: Bool {
        if case .idle = phase { return false }
        return true
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NQTheme.spaceL) {
                header

                oddsCard

                if boostsHeld > 0 && boostable { boostRow }

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
        default: return "Open · \(cookbook.price.formatted()) coins"
        }
    }

    // MARK: - Sections

    private var header: some View {
        HStack(alignment: .top, spacing: NQTheme.spaceM) {
            VStack(alignment: .leading, spacing: NQTheme.spaceXS) {
                Text("COOKBOOK")
                    .font(NQText.micro.font)
                    .tracking(2)
                    .foregroundStyle(NQTheme.gold)
                Text(cookbook.name)
                    .font(NQText.display.font)
                    .foregroundStyle(NQTheme.ink)
                    .shadow(color: NQTheme.inkDeep, radius: 0, y: 2)
            }
            Spacer(minLength: 0)
            NQCoinBalance(balance: gameState.coinBalance)
        }
    }

    /// Every tier the book's Case roll can land, with its real chance — the
    /// whole published odds table, not just the likeliest three.
    private var oddsCard: some View {
        VStack(alignment: .leading, spacing: NQTheme.spaceS) {
            Text(cookbook.description)
                .font(NQText.body.font)
                .foregroundStyle(NQTheme.inkMuted)
            ForEach(cookbook.odds, id: \.rarity) { odds in
                NQBandRow(color: Color(hex: odds.colorHex), label: odds.label, range: percent(odds.tierChance))
            }
        }
        .nqPadding(.card)
        .nqSurface(.sticker, fill: cookbook.shopTint.mix(with: NQTheme.background, amount: 0.55))
        .overlay {
            NQPanelShape().strokeBorder(cookbook.shopTint, lineWidth: 3)
        }
    }

    /// The Cookbook Boost toggle: one stored boost moves Rare+ odds ×1.15
    /// (renormalized — Common/Uncommon exempt). The server only consumes it
    /// when the open actually lands.
    private var boostRow: some View {
        HStack(spacing: NQTheme.spaceS) {
            NQIconView(icon: .sparkle, tint: NQTheme.gold)
                .frame(width: NQLayout.iconL, height: NQLayout.iconL)
            VStack(alignment: .leading, spacing: 2) {
                Text("Cookbook Boost")
                    .font(NQText.caption.font.weight(.bold))
                    .foregroundStyle(NQTheme.ink)
                Text("Rare+ odds ×1.15 · \(boostsHeld) held")
                    .font(NQText.micro.font)
                    .foregroundStyle(NQTheme.inkMuted)
            }
            Spacer(minLength: 0)
            Toggle("", isOn: $useBoost)
                .labelsHidden()
                .tint(NQTheme.gold)
        }
        .nqPadding(.card)
        .nqSurface(.sticker)
        .overlay {
            NQPanelShape().strokeBorder(NQTheme.gold.opacity(0.6), lineWidth: NQLayout.hairlineWidth)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Cookbook Boost, \(boostsHeld) held")
        .accessibilityHint("Rare and better odds are multiplied by 1.15 on this open")
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
            if let drop = await gameState.openCookbook(cookbookID: cookbook.id, useBoost: boostActive) {
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

    /// The win, once the strip lands: the Case's rarity first, then artwork,
    /// name, worth. Tap outside or "Done" dismisses back to the shop.
    private func winPopup(_ drop: CrateOpenResponse) -> some View {
        let rarity = Rarity(rawValue: drop.character.rarity) ?? .common
        let caseRarity = drop.caseRarity.flatMap { Rarity(rawValue: $0) } ?? rarity
        return ZStack {
            Color.black.opacity(0.55)
                .ignoresSafeArea()
                .onTapGesture { dismiss() }

            VStack(spacing: NQTheme.spaceM) {
                Text("YOU GOT A \(caseRarity.label.uppercased()) CASE")
                    .font(NQText.micro.font)
                    .tracking(2)
                    .foregroundStyle(caseRarity.ringColor)
                CharacterArtwork(
                    character: Character(
                        id: drop.character.id,
                        name: drop.character.name,
                        colorHex: drop.character.colorHex,
                        rarity: rarity
                    )
                )
                .frame(width: 120, height: 156)
                Text(drop.character.name)
                    .font(NQText.headingL.font.weight(.heavy))
                    .foregroundStyle(NQTheme.ink)
                NQChip(rarity.label, tint: rarity.ringColor, filled: true)
                if drop.boostApplied == true {
                    NQChip("Boosted ×1.15", icon: .sparkle, tint: NQTheme.gold, filled: true)
                }
                Text("Worth \(drop.value.formatted()) coins")
                    .font(NQText.captionS.font)
                    .foregroundStyle(NQTheme.inkMuted)
                if drop.overflowed == true {
                    Text("Inventory full: sent to your mailbox")
                        .font(NQText.micro.font)
                        .foregroundStyle(NQTheme.warning)
                }
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
