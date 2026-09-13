import SwiftUI
import NutriQuestUI
import BattleKit

/// Landing screen for battling — one card per spec mode: Ranked (RR ladder
/// + SBMM + Case rewards), Friendly (another player's stored squad, no RR),
/// Dungeon (endless floors for coins), Practice (local sparring), LAN, and
/// the Leaderboard.
struct BattleHubView: View {
    @ObservedObject var gameState: GameState

    @Environment(\.nqAccent) private var accent
    @State private var showLeaderboard = false
    @State private var showFriendlyPrompt = false
    @State private var friendlyOpponentId = ""
    @State private var friendlyBusy = false
    /// The parked friendly match, ready to push — navigation waits for the
    /// begin round-trip so the screen opens with locked specs + seed.
    @State private var friendlyReady: (match: GameState.InteractiveMatch, opponentId: String)?

    /// Pre-battle squad pick: which mode the sheet is fielding a team for.
    @State private var pickTarget: PickTarget?
    @State private var pickedSquad: [Character] = []
    /// The picked squad + mode, ready to push.
    @State private var readyFight: (mode: BattleMode, yours: [Character], theirs: [Character])?

    enum PickTarget: Identifiable {
        case ranked, practice
        var id: Self { self }
    }

    private var characters: [Character] { gameState.collection }

    private var yourBattleSquad: [Character] { gameState.battleReadySquad }

    /// Practice sparring partner: never the picked squad. Prefer other
    /// unlocked characters; fall back to the starter roster so a small
    /// collection still has a rival.
    private func practiceOpponentSquad(excluding yours: [Character]) -> [Character] {
        let yoursIDs = Set(yours.map(\.id))
        let others = characters.filter { !$0.isLocked && !yoursIDs.contains($0.id) }
        if others.count >= 3 { return Array(others.prefix(3)) }
        let fallback = SampleData.characters.filter { !$0.isLocked && !yoursIDs.contains($0.id) }
        return Array((others + fallback).prefix(3))
    }

    /// Rank row subtitle: current rank + RR, or the squad hint when the
    /// player can't field three yet.
    private var rankedSubtitle: String {
        if yourBattleSquad.count < 3 { return "Needs 3 healthy monsters" }
        if let rank = gameState.rank {
            return "\(rank.rankLabel) · \(rank.rr) RR"
        }
        return "Climb the ladder: RR and Cases on the line"
    }

    var body: some View {
        ScrollView {
            VStack(spacing: NQTheme.spaceM) {
                Button {
                    NQHaptic.selection()
                    pickedSquad = yourBattleSquad
                    pickTarget = .ranked
                } label: {
                    hubCard(
                        title: "Ranked",
                        subtitle: rankedSubtitle,
                        icon: .trophy,
                        tint: NQTheme.gold,
                        art: "star-badge"
                    )
                }
                .buttonStyle(NQPressableStyle(scale: 0.97, haptic: false))
                .disabled(yourBattleSquad.count < 3)
                .nqCascade(index: 0)

                Button {
                    NQHaptic.selection()
                    friendlyOpponentId = ""
                    showFriendlyPrompt = true
                } label: {
                    hubCard(
                        title: "Friendly",
                        subtitle: yourBattleSquad.count < 3
                            ? "Needs 3 healthy monsters"
                            : "Fight a friend's squad: no RR at stake",
                        icon: .person,
                        tint: NQTheme.info
                    )
                }
                .buttonStyle(NQPressableStyle(scale: 0.97, haptic: false))
                .nqCascade(index: 1)

                NavigationLink {
                    DungeonView(gameState: gameState)
                } label: {
                    hubCard(
                        title: "Dungeon",
                        subtitle: "Endless floors · coins on every clear",
                        icon: .cauldron,
                        tint: NQTheme.flame,
                        art: "dungeon-boss-door"
                    )
                }
                .buttonStyle(NQPressableStyle(scale: 0.97, haptic: false))
                .nqCascade(index: 2)

                Button {
                    NQHaptic.selection()
                    pickedSquad = yourBattleSquad
                    pickTarget = .practice
                } label: {
                    hubCard(
                        title: "Practice",
                        subtitle: "Turn-based sparring: pick every move",
                        icon: .leaf,
                        tint: NQTheme.success
                    )
                }
                .buttonStyle(NQPressableStyle(scale: 0.97, haptic: false))
                .disabled(yourBattleSquad.count < 3)
                .nqCascade(index: 3)

                NavigationLink {
                    LANLobbyView(gameState: gameState)
                } label: {
                    hubCard(
                        title: "LAN Battle",
                        subtitle: "Battle friends on the same Wi-Fi",
                        icon: .person,
                        tint: NQTheme.success
                    )
                }
                .buttonStyle(NQPressableStyle(scale: 0.97, haptic: false))
                .nqCascade(index: 4)

                Button {
                    NQJuice.tap()
                    showLeaderboard = true
                } label: {
                    hubCard(
                        title: "Leaderboard",
                        subtitle: "RR · ranked wins · win rate",
                        icon: .trophy,
                        tint: accent.accent
                    )
                }
                .buttonStyle(NQPressableStyle(scale: 0.97, haptic: false))
                .nqCascade(index: 5)
            }
            .padding(NQTheme.spaceL)
        }
        .nqSceneBackground(GameArt.scene("battle"))
        .sheet(isPresented: $showLeaderboard) {
            NavigationStack { LeaderboardView() }
        }
        .alert("Friendly battle", isPresented: $showFriendlyPrompt) {
            TextField("Friend's player ID", text: $friendlyOpponentId)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Cancel", role: .cancel) {}
            Button("Battle") { startFriendly() }
                .disabled(friendlyOpponentId.trimmingCharacters(in: .whitespaces).isEmpty)
        } message: {
            Text("They need to have fought at least once so their squad snapshot exists.")
        }
        .navigationDestination(isPresented: Binding(
            get: { friendlyReady != nil },
            set: { if !$0 { friendlyReady = nil } }
        )) {
            if let ready = friendlyReady {
                BattleView(
                    yourSquad: yourBattleSquad,
                    opponentSquad: ready.match.opponentCharacters,
                    gameState: gameState,
                    mode: .friendly(FriendlyBattleContext(match: ready.match, opponentId: ready.opponentId))
                )
            }
        }
        .sheet(item: $pickTarget) { target in
            SquadPickSheet(
                characters: characters.filter { !$0.isLocked },
                faintedIds: gameState.faintedIds,
                selection: $pickedSquad,
                title: target == .ranked ? "Ranked squad" : "Practice squad"
            ) { squad in
                pickTarget = nil
                switch target {
                case .ranked:
                    readyFight = (.ranked, squad, [])
                case .practice:
                    readyFight = (.practice, squad, practiceOpponentSquad(excluding: squad))
                }
            }
            .presentationDetents([.medium, .large])
        }
        .navigationDestination(isPresented: Binding(
            get: { readyFight != nil },
            set: { if !$0 { readyFight = nil } }
        )) {
            if let fight = readyFight {
                BattleView(
                    yourSquad: fight.yours,
                    opponentSquad: fight.theirs,
                    gameState: gameState,
                    mode: fight.mode
                )
            }
        }
        .overlay {
            if friendlyBusy {
                ZStack {
                    NQTheme.inkDeep.opacity(0.45).ignoresSafeArea()
                    VStack(spacing: NQTheme.spaceS) {
                        NQDotsLoader(color: accent.accent)
                        Text("Finding their squad…")
                            .font(NQText.caption.font.weight(.bold))
                            .foregroundStyle(NQTheme.ink)
                    }
                    .nqPadding(.card)
                    .nqSurface(.hero)
                }
            }
        }
    }

    /// Park the friendly first — the BattleView only appears once the server
    /// has locked the matchup, so the screen can play the real fight.
    private func startFriendly() {
        let opponentId = friendlyOpponentId.trimmingCharacters(in: .whitespaces)
        guard !opponentId.isEmpty, !friendlyBusy else { return }
        friendlyBusy = true
        Task {
            if let parked = await gameState.beginFriendlyBattle(opponentId: opponentId, squad: yourBattleSquad) {
                friendlyReady = (parked, opponentId)
            }
            friendlyBusy = false
        }
    }

    private func hubCard(title: String, subtitle: String, icon: NQIcon, tint: Color, trailing: String? = nil, art: String? = nil) -> some View {
        HStack(spacing: NQTheme.spaceM) {
            ZStack {
                Circle()
                    .fill(tint.opacity(0.18))
                    .frame(width: 52, height: 52)
                if let art, NQAsset.uiImage(art) != nil {
                    NQAssetImage(art)
                        .frame(width: 44, height: 44)
                } else {
                    icon.view
                        .frame(width: 24, height: 24)
                        .foregroundStyle(tint)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(NQText.headingL.font.weight(.bold))
                    .foregroundStyle(NQTheme.ink)
                Text(subtitle)
                    .font(NQText.captionS.font)
                    .foregroundStyle(NQTheme.inkMuted)
            }
            Spacer()
            if let trailing {
                Text(trailing)
                    .font(NQText.captionS.font.weight(.bold))
                    .foregroundStyle(NQTheme.inkMuted)
            }
            NQChevron()
        }
        .nqPadding(.card)
        .frame(maxWidth: .infinity)
        .nqSurface(.sticker)
        .accessibilityElement(children: .combine)
    }
}

/// Pick three monsters, in order — slot 1 leads. Fainted monsters are shown
/// but can't be fielded. Used by ranked and practice.
private struct SquadPickSheet: View {
    let characters: [Character]
    let faintedIds: Set<String>
    @Binding var selection: [Character]
    let title: String
    let confirm: ([Character]) -> Void

    @Environment(\.nqAccent) private var accent

    private func pickOrder(of character: Character) -> Int? {
        selection.firstIndex(of: character).map { $0 + 1 }
    }

    private func toggle(_ character: Character) {
        guard !faintedIds.contains(character.id) else { return }
        if let i = selection.firstIndex(of: character) {
            selection.remove(at: i)
        } else if selection.count < 3 {
            selection.append(character)
        }
        NQHaptic.selection()
    }

    var body: some View {
        VStack(spacing: NQTheme.spaceM) {
            Text(title)
                .font(NQText.headingL.font.weight(.bold))
                .foregroundStyle(NQTheme.ink)
            Text("Pick 3: the first leads the fight")
                .font(NQText.captionS.font)
                .foregroundStyle(NQTheme.inkMuted)

            ScrollView {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: NQTheme.spaceS) {
                    ForEach(characters) { c in
                        let fainted = faintedIds.contains(c.id)
                        let order = pickOrder(of: c)
                        Button { toggle(c) } label: {
                            VStack(spacing: 4) {
                                ZStack(alignment: .topTrailing) {
                                    CharacterArtwork(character: c, expression: fainted ? .sleepy : .happy, hurt: fainted)
                                        .frame(height: 72)
                                    if let order {
                                        Text("\(order)")
                                            .font(NQText.micro.font.weight(.heavy))
                                            .foregroundStyle(accent.accent.readableTextColor())
                                            .frame(width: 20, height: 20)
                                            .background(Circle().fill(accent.accent))
                                    }
                                }
                                Text(c.name)
                                    .font(NQText.micro.font.weight(.bold))
                                    .foregroundStyle(NQTheme.ink)
                                    .lineLimit(1)
                                if fainted {
                                    Text("Fainted")
                                        .font(NQText.microXS.font.weight(.heavy))
                                        .foregroundStyle(NQTheme.warning)
                                }
                            }
                            .nqPadding(.badge)
                            .frame(maxWidth: .infinity)
                            .background(RoundedRectangle(cornerRadius: NQTheme.radiusM)
                                .fill(order != nil ? accent.accent.opacity(0.14) : Color.clear))
                            .overlay {
                                RoundedRectangle(cornerRadius: NQTheme.radiusM)
                                    .strokeBorder(order != nil ? accent.accent : NQTheme.hairline, lineWidth: order != nil ? 2 : 1)
                            }
                            .opacity(fainted ? 0.4 : 1)
                        }
                        .buttonStyle(.nqPressable(scale: 0.96, haptic: false))
                        .disabled(fainted)
                    }
                }
            }

            NQButton("Fight (\(selection.count)/3)", style: .primary) { confirm(selection) }
                .disabled(selection.count != 3)
        }
        .padding(NQTheme.spaceL)
        .nqPageBackground()
    }
}
