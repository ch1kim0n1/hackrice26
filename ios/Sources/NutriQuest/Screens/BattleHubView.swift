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

    private var moves: [BattleMove] {
        [
            BattleMove(name: "Protein Punch", statType: .protein, description: "Power 45 · high crit"),
            BattleMove(name: "Fiber Whirl", statType: .fiber, description: "Power 30 · hits twice"),
            BattleMove(name: "Vitamin Beam", statType: .vitamin, description: "Power 38 · buffs squad"),
            BattleMove(name: "Hydro Splash", statType: .hydration, description: "Power 26 · heals 10%")
        ]
    }

    var body: some View {
        ScrollView {
            VStack(spacing: NQTheme.spaceM) {
                // "You were challenged" feed — async friend battles that
                // resolved while you were away.
                if !gameState.battleNotices.isEmpty {
                    noticesCard
                }

                NavigationLink {
                    BattleView(
                        yourSquad: yourBattleSquad,
                        opponentSquad: opponentBattleSquad,
                        fatigued: false,
                        moves: moves,
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

                // Squad set bonus — mono-type squads synergize; the chip makes
                // the synergy visible so players hunt for matching members.
                if let bonus = setBonus {
                    bonusChip(bonus)
                }

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
        .task {
            await gameState.refreshBattleNotices()
        }
    }

    /// Async battle feed: who attacked your stored squad, and whether it held.
    private var noticesCard: some View {
        VStack(alignment: .leading, spacing: NQTheme.spaceS) {
            NQSectionHeader("While you were away")
            ForEach(Array(gameState.battleNotices.enumerated()), id: \.offset) { _, notice in
                HStack(spacing: NQTheme.spaceS) {
                    Image(systemName: notice.defendedWin ? "shield.fill" : "bolt.fill")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(notice.defendedWin ? NQTheme.success : NQTheme.warning)
                    Text(notice.defendedWin
                         ? "\(notice.challengerName) attacked — your squad held in \(notice.rounds) rounds"
                         : "\(notice.challengerName) beat your squad in \(notice.rounds) rounds")
                        .font(NQText.caption.font.weight(.semibold))
                        .foregroundStyle(NQTheme.ink)
                    Spacer()
                }
            }
        }
        .nqPadding(.card)
        .nqPlate(RoundedRectangle(cornerRadius: NQTheme.radiusL + 2), elevation: .card)
        .accessibilityElement(children: .combine)
    }

    /// Pair/trio of same-type members: 2-of-a-kind +5%, full trio +12%.
    private var setBonus: (label: String, icon: NQIcon, tint: Color)? {
        let counts = Dictionary(grouping: yourBattleSquad, by: \.statType)
            .mapValues { $0.count }
        guard let (type, n) = counts.max(by: { $0.value < $1.value }), n >= 2 else { return nil }
        let icon: NQIcon = { switch type { case .protein: .battle; case .fiber: .leaf; case .vitamin: .star; case .hydration: .droplet } }()
        let bonus = n >= 3 ? "+12%" : "+5%"
        return ("\(type.label) ×\(n) set · \(bonus) stats", icon, accent.accent)
    }

    private func bonusChip(_ bonus: (label: String, icon: NQIcon, tint: Color)) -> some View {
        HStack(spacing: NQTheme.spaceS) {
            bonus.icon.view
                .frame(width: 14, height: 14)
                .foregroundStyle(bonus.tint)
            Text(bonus.label)
                .font(NQText.captionS.font.weight(.heavy))
                .foregroundStyle(bonus.tint)
            Spacer()
        }
        .nqPadding(.badge)
        .padding(.horizontal, NQTheme.spaceS)
        .background(bonus.tint.opacity(0.12))
        .clipShape(Capsule())
        .accessibilityLabel("Squad set bonus: \(bonus.label)")
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
