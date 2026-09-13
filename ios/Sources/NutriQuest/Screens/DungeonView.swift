import SwiftUI
import NutriQuestUI

/// Endless dungeon — send your top 3 down floor after floor until they wipe.
/// Every cleared floor pays coins (bosses pay triple) and earnings survive
/// the wipe. The run feed is the highlight reel.
struct DungeonView: View {
    @ObservedObject var gameState: GameState

    @Environment(\.nqAccent) private var accent
    @State private var running = false
    /// Floors descended so far this run — drives the descent track.
    @State private var descentFloor = 0

    /// Spec §5: a dungeon run fields exactly three monsters — the player's
    /// top three unlocked, non-fainted cards, same rule as ranked.
    private var partyPreview: [Character] {
        gameState.battleReadySquad
    }

    var body: some View {
        ScrollView {
            VStack(spacing: NQTheme.spaceM) {
                stateCard
                partyCard
                descendButton
                if running { descentTrack }
                if let run = gameState.lastDungeonRun {
                    runFeed(run)
                }
            }
            .padding(NQTheme.spaceL)
        }
        .nqSceneBackground(GameArt.scene("dungeon"))
        .preferredColorScheme(.dark)
        .navigationTitle("Endless Dungeon")
        .navigationBarTitleDisplayMode(.inline)
        .task { await gameState.refreshDungeon() }
    }

    // MARK: - State

    private var stateCard: some View {
        VStack(spacing: NQTheme.spaceS) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Deepest floor")
                        .font(NQText.microXS.font)
                        .foregroundStyle(NQTheme.battleInkMuted)
                    NQCountUpText(value: gameState.dungeonState?.bestFloor ?? 0, font: NQFont.display.font(40), color: NQTheme.gold)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("Last run")
                        .font(NQText.microXS.font)
                        .foregroundStyle(NQTheme.battleInkMuted)
                    Text(gameState.dungeonState?.lastRunAt?.prefix(10).description ?? "—")
                        .font(NQText.headingL.font)
                        .foregroundStyle(NQTheme.gold)
                }
            }
            Text("Every cleared floor pays coins — bosses pay triple. You keep what you earn, even on a wipe.")
                .font(NQText.captionS.font)
                .foregroundStyle(NQTheme.battleInkMuted)
        }
        .nqPadding(.card)
        .background(NQTheme.battleSurface)
        .clipShape(RoundedRectangle(cornerRadius: NQTheme.radiusL))
    }

    // MARK: - Party

    private var partyCard: some View {
        VStack(alignment: .leading, spacing: NQTheme.spaceS) {
            Text("Your party (top 3)")
                .font(NQText.microXS.font)
                .tracking(0.6)
                .foregroundStyle(NQTheme.battleInkMuted)
            HStack(spacing: NQTheme.spaceS) {
                ForEach(partyPreview) { c in
                    CharacterArtwork(character: c, expression: .proud)
                        .frame(width: 64, height: 84)
                }
                if partyPreview.count < 3 {
                    Text(partyPreview.isEmpty
                         ? "No monsters yet — scan a food first"
                         : "You need 3 monsters to descend — scan more food")
                        .font(NQText.caption.font)
                        .foregroundStyle(NQTheme.battleInkMuted)
                }
            }
        }
        .nqPadding(.card)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(NQTheme.battleSurface)
        .clipShape(RoundedRectangle(cornerRadius: NQTheme.radiusL))
    }

    private var descendButton: some View {
        Button {
            NQJuice.tap()
            running = true
            descentFloor = 0
            Task {
                _ = await gameState.runDungeon()
                withAnimation(NQMotion.snappy) { running = false }
                if let run = gameState.lastDungeonRun, run.floorsCleared > 0 {
                    NQJuice.success()
                }
            }
        } label: {
            HStack {
                if running { ProgressView().tint(.white) }
                Text(running ? "Descending…" : "Descend")
                    .font(NQText.heading.font.weight(.heavy))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
            .background(LinearGradient(colors: [accent.accent, accent.accentDark], startPoint: .top, endPoint: .bottom))
            .clipShape(RoundedRectangle(cornerRadius: NQTheme.radiusL))
            .foregroundStyle(accent.accent.readableTextColor())
        }
        .buttonStyle(NQPressableStyle(scale: 0.97, ledge: 5))
        .disabled(running || partyPreview.count < 3)
        .accessibilityLabel("Start a dungeon run with your top three monsters")
    }

    // MARK: - Descent animation

    /// While the server resolves the run, the party visibly walks the path:
    /// a scrolling strip of floor nodes with the party marching down it
    /// (#22 — the screen was a dead button before). The node count advances
    /// on a timer so the descent reads as endless until the result lands.
    private var descentTrack: some View {
        VStack(spacing: 2) {
            ForEach(0..<6, id: \.self) { row in
                let floor = descentFloor + row + 1
                HStack(spacing: NQTheme.spaceS) {
                    NQAssetImage(floor % 10 == 0 ? "dungeon-boss-door" : "dungeon-floor-node-cleared")
                        .frame(width: 24, height: 24)
                        .opacity(row == 0 ? 1 : 0.55)
                    Text(floor % 10 == 0 ? "BOSS F\(floor)" : "F\(floor)")
                        .font(NQText.microXS.font.weight(.heavy))
                        .foregroundStyle(floor % 10 == 0 ? NQTheme.gold : NQTheme.battleInkMuted)
                    Spacer()
                    if row == 0 {
                        HStack(spacing: -NQTheme.spaceS) {
                            ForEach(partyPreview.prefix(3)) { c in
                                CharacterArtwork(character: c, expression: .happy)
                                    .frame(width: 30, height: 38)
                            }
                        }
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                .padding(.vertical, 3)
            }
        }
        .nqPadding(.card)
        .background(NQTheme.battleSurface)
        .clipShape(RoundedRectangle(cornerRadius: NQTheme.radiusL))
        .task {
            while running {
                try? await Task.sleep(nanoseconds: 420_000_000)
                withAnimation(NQMotion.quick) { descentFloor += 1 }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Descending the dungeon")
    }

    // MARK: - Run feed

    private func runFeed(_ run: DungeonRunResponse) -> some View {
        VStack(alignment: .leading, spacing: NQTheme.spaceS) {
            HStack {
                Text(run.floorsCleared > 0 ? "Floor \(run.floorsCleared) cleared" : "Wiped on floor 1")
                    .font(NQText.heading.font.weight(.heavy))
                    .foregroundStyle(NQTheme.battleInk)
                if run.coinsEarned > 0 {
                    Spacer()
                    NQChip("+\(run.coinsEarned) coins", icon: .sparkle, tint: NQTheme.gold, filled: true)
                }
            }
            ForEach(Array(run.feed.enumerated()), id: \.offset) { _, floor in
                HStack(spacing: NQTheme.spaceS) {
                    NQAssetImage(floor.boss ? "dungeon-boss-door" : "dungeon-floor-node-cleared")
                        .frame(width: 28, height: 28)
                    Text(floor.boss ? "BOSS" : "F\(floor.floor)")
                        .font(NQText.microXS.font.weight(.heavy))
                        .foregroundStyle(floor.boss ? NQTheme.gold : NQTheme.battleInkMuted)
                        .frame(width: 40, alignment: .leading)
                    Text(floor.enemies.joined(separator: ", "))
                        .font(NQText.captionS.font)
                        .foregroundStyle(NQTheme.battleInkMuted)
                        .lineLimit(1)
                    Spacer()
                    if floor.won, floor.reward > 0 {
                        Text("+\(floor.reward)")
                            .font(NQText.captionS.font.weight(.bold))
                            .foregroundStyle(NQTheme.gold)
                    }
                    Image(systemName: floor.won ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(floor.won ? NQTheme.success : NQTheme.warning)
                }
            }
        }
        .nqPadding(.card)
        .background(NQTheme.battleSurface)
        .clipShape(RoundedRectangle(cornerRadius: NQTheme.radiusL))
        .accessibilityElement(children: .combine)
    }
}
