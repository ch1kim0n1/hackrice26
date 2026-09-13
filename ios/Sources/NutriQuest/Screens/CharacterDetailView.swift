import SwiftUI
import NutriQuestUI
import BattleKit

/// Full stat sheet for one collection card — what tapping a character
/// should have always done.
struct CharacterDetailView: View {
    let character: Character
    @ObservedObject var gameState: GameState

    @Environment(\.dismiss) private var dismiss
    @Environment(\.nqAccent) private var accent
    @State private var settingDisplay = false

    private var stats: BattleUnitSpec? {
        character.isLocked ? nil : gameState.battleStats(for: character)
    }

    private var isDisplayCharacter: Bool {
        gameState.profile?.activeCharacterId == character.id
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: NQTheme.spaceL) {
                    portrait
                    if character.isLocked {
                        lockedNote
                    } else {
                        rarityRow
                        if let bio = gameState.bio(for: character) {
                            bioCard(bio)
                        }
                        displayCharacterButton
                        if let stats {
                            statBlock(stats)
                            movesBlock(stats.moves)
                        }
                    }
                }
                .padding(NQTheme.spaceL)
            }
            .nqPageBackground()
            .navigationTitle(character.isLocked ? "???" : character.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            // Retry the catalog on open — a fetch that failed at launch
            // (offline, stale deploy) would otherwise leave this sheet on
            // the Strike-only fallback moveset forever.
            .task { await gameState.loadCharacterCatalog() }
        }
    }

    private var portrait: some View {
        ZStack {
            Circle()
                .fill(
                    LinearGradient(colors: [accent.accentSoft, NQTheme.background], startPoint: .top, endPoint: .bottom)
                )
                .frame(width: 190, height: 190)
            if character.isLocked {
                NQIcon.lock.view
                    .frame(width: 48, height: 48)
                    .foregroundStyle(NQTheme.inkFaint)
            } else {
                CharacterArtwork(character: character)
                    .frame(width: 150, height: 150)
                    .nqSquish()
                    .modifier(MascotIdleBob(enabled: true))
            }
        }
        .padding(.top, NQTheme.spaceM)
    }

    private var lockedNote: some View {
        VStack(spacing: NQTheme.spaceS) {
            Text("Not discovered yet")
                .font(NQText.headingL.font.weight(.bold))
                .foregroundStyle(NQTheme.ink)
            Text("Scan more food or open a crate to find this character.")
                .font(NQText.caption.font)
                .foregroundStyle(NQTheme.inkMuted)
                .multilineTextAlignment(.center)
        }
    }

    private var rarityRow: some View {
        HStack(spacing: NQTheme.spaceS) {
            Text(character.rarity.label.uppercased())
                .font(NQText.captionS.font.weight(.heavy))
                .foregroundStyle(character.rarity.badgeText)
                .nqPadding(.badge)
                .padding(.horizontal, 4)
                .background(RoundedRectangle(cornerRadius: NQTheme.radiusS).fill(character.rarity.badgeBackground))

            HStack(spacing: 5) {
                Image(systemName: "star.fill")
                    .font(.system(size: 12, weight: .bold))
                Text("★\(character.starLevel)")
                    .font(NQText.captionS.font.weight(.bold))
            }
            .foregroundStyle(accent.accentDark)
            .nqPadding(.badge)
            .padding(.horizontal, 4)
            .background(Capsule().fill(accent.accentSoft))

            Spacer()
        }
    }

    /// Showcase this character as the Profile pfp — the feature the backend
    /// and client model have supported since day one, but no screen ever
    /// exposed a way to change it.
    private var displayCharacterButton: some View {
        NQButton(
            isDisplayCharacter ? "Displayed on profile" : "Set as display character",
            icon: .crown,
            style: isDisplayCharacter ? .secondary : .primary,
            fullWidth: false
        ) {
            guard !isDisplayCharacter else { return }
            settingDisplay = true
            Task {
                await gameState.setDisplayCharacter(character.id)
                settingDisplay = false
            }
        }
        .disabled(isDisplayCharacter || settingDisplay)
    }

    /// The character's bio: authored catalog entry first, then whatever the
    /// drop carried, then the local starter-roster copy — resolved by
    /// `gameState.bio(for:)` so the sheet never has to know which source won.
    private func bioCard(_ bio: String) -> some View {
        Text(bio)
            .font(NQText.caption.font)
            .foregroundStyle(NQTheme.inkMuted)
            .fixedSize(horizontal: false, vertical: true)
            .nqPadding(.card)
            .frame(maxWidth: .infinity, alignment: .leading)
            .nqPlate(RoundedRectangle(cornerRadius: NQTheme.radiusL), elevation: .soft)
    }

    /// Effective (rarity × star scaled) combat figures — what the unit
    /// actually fights with, matching the server engine's scaling.
    private func statBlock(_ unit: BattleUnitSpec) -> some View {
        let maxValue = max(unit.maxHP, unit.effectiveAttack, Double(unit.startingMana), 1)

        return VStack(alignment: .leading, spacing: NQTheme.spaceM - 2) {
            Text("Battle Stats")
                .font(NQText.heading.font)
                .foregroundStyle(NQTheme.ink)
            VStack(spacing: NQTheme.spaceS + 2) {
                statRow("Health", unit.maxHP, maxValue, NQTheme.success)
                statRow("Attack", unit.effectiveAttack, maxValue, NQTheme.warning)
                if unit.baseMana != nil {
                    statRow("Mana", Double(unit.startingMana), maxValue, NQTheme.info)
                }
            }
            if unit.baseMana != nil {
                Text("Special Ability available")
                    .font(NQText.captionS.font.weight(.bold))
                    .foregroundStyle(NQTheme.info)
            }
            if unit.star > 1 {
                HStack(spacing: NQTheme.spaceS) {
                    NQAssetImage("star-badge")
                        .frame(width: 28, height: 28)
                    Text("★\(unit.star) — stats scale with stars")
                        .font(NQText.captionS.font.weight(.bold))
                        .foregroundStyle(NQTheme.gold)
                }
            }
        }
        .nqPadding(.card)
        .frame(maxWidth: .infinity, alignment: .leading)
        .nqPlate(RoundedRectangle(cornerRadius: NQTheme.radiusL), elevation: .soft)
    }

    /// The authored moveset — three standards, then the Mana Special for
    /// Epic+. Each row carries the numbers a player needs to choose a move
    /// mid-battle: power, accuracy, mana cost, status, and the description.
    private func movesBlock(_ moves: [BattleMoveSpec]) -> some View {
        VStack(alignment: .leading, spacing: NQTheme.spaceM - 2) {
            Text("Moves")
                .font(NQText.heading.font)
                .foregroundStyle(NQTheme.ink)
            ForEach(moves) { move in
                moveRow(move)
            }
        }
        .nqPadding(.card)
        .frame(maxWidth: .infinity, alignment: .leading)
        .nqPlate(RoundedRectangle(cornerRadius: NQTheme.radiusL), elevation: .soft)
    }

    private func moveRow(_ move: BattleMoveSpec) -> some View {
        VStack(alignment: .leading, spacing: NQTheme.spaceXS) {
            HStack(spacing: NQTheme.spaceS) {
                Text(move.name)
                    .font(NQText.body.font.weight(.bold))
                    .foregroundStyle(NQTheme.ink)
                if move.kind == .special {
                    NQChip("Special", icon: .sparkle, tint: NQTheme.info, filled: true)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: NQTheme.spaceS) {
                if move.power > 0 {
                    moveTag("Pow \(Int(move.power))")
                }
                moveTag("Acc \(Int(move.accuracy))%")
                if move.manaCost > 0 {
                    moveTag("\(Int(move.manaCost)) mana")
                }
                if let effect = move.statusEffect {
                    moveTag(effectLabel(effect, chance: move.statusChance))
                }
            }
            if let description = move.description, !description.isEmpty {
                Text(description)
                    .font(NQText.captionS.font)
                    .foregroundStyle(NQTheme.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, NQTheme.spaceXS)
    }

    private func moveTag(_ text: String) -> some View {
        Text(text)
            .font(NQText.micro.font.weight(.bold))
            .foregroundStyle(NQTheme.inkMuted)
            .nqPadding(.badge)
            .background(Capsule().fill(NQTheme.hairline))
    }

    private func effectLabel(_ effect: StatusEffectID, chance: Double?) -> String {
        let name = effect.rawValue.replacingOccurrences(of: "_", with: " ")
        guard let chance, chance > 0 else { return name }
        return "\(name) \(Int(chance))%"
    }

    private func statRow(_ label: String, _ value: Double, _ maxValue: Double, _ color: Color) -> some View {
        HStack(spacing: NQTheme.spaceS + 2) {
            if label == "Power" {
                NQAssetImage("nutriquest-strength-bolt-512")
                    .frame(width: 16, height: 16)
                    .colorMultiply(color)
            }
            Text(label)
                .font(NQText.caption.font)
                .foregroundStyle(NQTheme.inkSubtle)
                .frame(width: 62, alignment: .leading)
            NQStatBar(value: value / maxValue)
                .fill(color)
            Text("\(Int(value))")
                .font(NQText.captionS.font.weight(.heavy))
                .foregroundStyle(NQTheme.ink)
                .frame(width: 30, alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label), \(Int(value))")
    }
}
