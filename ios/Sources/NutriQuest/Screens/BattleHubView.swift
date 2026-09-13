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
    /// The resolved friendly, ready to push — navigation waits for the
    /// server result so the replay arrives with its opponent squad.
    @State private var friendlyReady: (replay: BattleReplay, opponentSquad: [Character], opponentId: String)?

    private var characters: [Character] { gameState.collection }

    private var yourBattleSquad: [Character] { gameState.battleReadySquad }

    /// Practice sparring partner: never your own lead three. Prefer other
    /// unlocked characters; fall back to the starter roster so a small
    /// collection still has a rival.
    private var practiceOpponentSquad: [Character] {
        let yours = Set(yourBattleSquad.map(\.id))
        let others = characters.filter { !$0.isLocked && !yours.contains($0.id) }
        if others.count >= 3 { return Array(others.prefix(3)) }
        let fallback = SampleData.characters.filter { !$0.isLocked && !yours.contains($0.id) }
        return Array((others + fallback).prefix(3))
    }

    /// Rank row subtitle: current rank + RR, or the squad hint when the
    /// player can't field three yet.
    private var rankedSubtitle: String {
        if yourBattleSquad.count < 3 { return "Needs 3 healthy monsters" }
        if let rank = gameState.rank {
            return "\(rank.rankLabel) · \(rank.rr) RR"
        }
        return "Climb the ladder — RR and Cases on the line"
    }

    var body: some View {
        ScrollView {
            VStack(spacing: NQTheme.spaceM) {
                NavigationLink {
                    BattleView(
                        yourSquad: yourBattleSquad,
                        opponentSquad: [],
                        gameState: gameState,
                        mode: .ranked
                    )
                } label: {
                    hubCard(
                        title: "Ranked",
                        subtitle: rankedSubtitle,
                        icon: .trophy,
                        tint: NQTheme.gold,
                        art: "star-badge"
                    )
                }
                .buttonStyle(.plain)

                Button {
                    NQHaptic.selection()
                    friendlyOpponentId = ""
                    showFriendlyPrompt = true
                } label: {
                    hubCard(
                        title: "Friendly",
                        subtitle: yourBattleSquad.count < 3
                            ? "Needs 3 healthy monsters"
                            : "Fight a friend's squad — no RR at stake",
                        icon: .person,
                        tint: NQTheme.info
                    )
                }
                .buttonStyle(.plain)

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
                .buttonStyle(.plain)

                NavigationLink {
                    BattleView(
                        yourSquad: yourBattleSquad,
                        opponentSquad: practiceOpponentSquad,
                        gameState: gameState,
                        mode: .practice
                    )
                } label: {
                    hubCard(
                        title: "Practice",
                        subtitle: "Turn-based sparring — pick every move",
                        icon: .leaf,
                        tint: NQTheme.success
                    )
                }
                .buttonStyle(.plain)

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
                .buttonStyle(.plain)

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
                .buttonStyle(.plain)
            }
            .padding(NQTheme.spaceL)
        }
        .nqPageBackground()
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
                    opponentSquad: ready.opponentSquad,
                    gameState: gameState,
                    mode: .friendly(FriendlyBattleContext(replay: ready.replay, opponentId: ready.opponentId))
                )
            }
        }
        .overlay {
            if friendlyBusy {
                ProgressView()
                    .tint(accent.accent)
                    .scaleEffect(1.4)
            }
        }
    }

    /// Resolve the friendly first — the BattleView only appears once the
    /// server has answered, so the screen can animate the real replay.
    private func startFriendly() {
        let opponentId = friendlyOpponentId.trimmingCharacters(in: .whitespaces)
        guard !opponentId.isEmpty, !friendlyBusy else { return }
        friendlyBusy = true
        Task {
            if let result = await gameState.challengeFriend(opponentId: opponentId) {
                friendlyReady = (result.replay, result.opponentSquad, opponentId)
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
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(NQTheme.inkFaint)
        }
        .nqPadding(.card)
        .frame(maxWidth: .infinity)
        .nqPlate(RoundedRectangle(cornerRadius: NQTheme.radiusL + 2), elevation: .card)
        .accessibilityElement(children: .combine)
    }
}
