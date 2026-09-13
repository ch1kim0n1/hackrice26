import SwiftUI
import NutriQuestUI
import BattleKit

/// Landing screen for the Battle tab — a hub, not a straight-into-combat
/// screen. Fans out to the three things battling touches: fighting, loot,
/// and bragging rights.
struct BattleHubView: View {
    @ObservedObject var gameState: GameState

    @Environment(\.nqAccent) private var accent
    @State private var showLeaderboard = false

    private var characters: [Character] { gameState.collection }

    private var yourBattleSquad: [Character] {
        Array(characters.filter { !$0.isLocked }.prefix(3))
    }

    /// Never fight yourself. Prefer other unlocked characters; fall back to
    /// the starter roster so a 3-character collection still has a rival.
    private var opponentBattleSquad: [Character] {
        let yours = Set(yourBattleSquad.map(\.id))
        let others = characters.filter { !$0.isLocked && !yours.contains($0.id) }
        if others.count >= 3 { return Array(others.prefix(3)) }
        let fallback = SampleData.characters.filter { !$0.isLocked && !yours.contains($0.id) }
        return Array((others + fallback).prefix(3))
    }

    var body: some View {
        ScrollView {
            VStack(spacing: NQTheme.spaceM) {
                NavigationLink {
                    BattleView(
                        yourSquad: yourBattleSquad,
                        opponentSquad: opponentBattleSquad,
                        gameState: gameState
                    )
                } label: {
                    hubCard(
                        title: "Battle",
                        subtitle: "Fight a rival squad, server-ruled",
                        icon: .battle,
                        tint: NQTheme.info,
                        art: "battle-badge"
                    )
                }
                .buttonStyle(.plain)

                NavigationLink {
                    BattleView(
                        yourSquad: yourBattleSquad,
                        opponentSquad: opponentBattleSquad,
                        gameState: gameState,
                        mode: .practice
                    )
                } label: {
                    hubCard(
                        title: "Practice",
                        subtitle: "Turn-based sparring — pick every move",
                        icon: .leaf,
                        tint: NQTheme.gold
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
                        subtitle: "See how you rank globally",
                        icon: .trophy,
                        tint: accent.accent,
                        art: "star-badge"
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
