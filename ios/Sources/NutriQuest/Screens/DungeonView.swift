import SwiftUI
import NutriQuestUI

/// Infinite dungeon — send your top 5 down floor after floor until they wipe.
/// Depth becomes idle income: keys tick up while you're away and claim when
/// you come back. The run feed is the highlight reel.
struct DungeonView: View {
    @ObservedObject var gameState: GameState

    @Environment(\.nqAccent) private var accent
    @State private var running = false
    @State private var claiming = false

    private var partyPreview: [Character] {
        Array(gameState.collection.filter { !$0.isLocked }.prefix(5))
    }

    var body: some View {
        ScrollView {
            VStack(spacing: NQTheme.spaceM) {
                stateCard
                partyCard
                descendButton
                if let run = gameState.lastDungeonRun {
                    runFeed(run)
                }
            }
            .padding(NQTheme.spaceL)
        }
        .nqSceneBackground(GameArt.scene("dungeon"))
        .preferredColorScheme(.dark)
        .navigationTitle("Infinite Dungeon")
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
                    Text("Idle keys")
                        .font(NQText.microXS.font)
                        .foregroundStyle(NQTheme.battleInkMuted)
                    HStack(spacing: 4) {
                        NQIcon.sparkle.view.frame(width: 14, height: 14)
                        NQCountUpText(value: gameState.dungeonState?.pendingIdleKeys ?? 0, font: NQText.headingL.font, color: NQTheme.gold)
                    }
                    .foregroundStyle(NQTheme.gold)
                }
            }
            if let pending = gameState.dungeonState?.pendingIdleKeys, pending > 0 {
                Button {
                    NQJuice.tap()
                    claiming = true
                    Task {
                        _ = await gameState.claimDungeonIncome()
                        claiming = false
                        NQJuice.success()
                    }
                } label: {
                    Text(claiming ? "Claiming…" : "Claim \(pending) idle keys")
                        .font(NQText.body.font.weight(.bold))
                        .frame(maxWidth: .infinity)
                        .nqPadding(.button)
                        .background(NQTheme.gold)
                        .foregroundStyle(NQTheme.ink)
                        .clipShape(Capsule())
                }
                .buttonStyle(NQPressableStyle())
                .disabled(claiming)
            } else {
                Text("Deeper runs pay more idle keys per hour away")
                    .font(NQText.captionS.font)
                    .foregroundStyle(NQTheme.battleInkMuted)
            }
        }
        .nqPadding(.card)
        .background(NQTheme.battleSurface)
        .clipShape(RoundedRectangle(cornerRadius: NQTheme.radiusL))
    }

    // MARK: - Party

    private var partyCard: some View {
        VStack(alignment: .leading, spacing: NQTheme.spaceS) {
            Text("Your party (top 5)")
                .font(NQText.microXS.font)
                .tracking(0.6)
                .foregroundStyle(NQTheme.battleInkMuted)
            HStack(spacing: NQTheme.spaceS) {
                ForEach(partyPreview) { c in
                    CharacterArtwork(character: c, expression: .proud)
                        .frame(width: 52, height: 68)
                }
                if partyPreview.isEmpty {
                    Text("No characters yet — scan a food first")
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
            Task {
                _ = await gameState.runDungeon()
                running = false
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
        .disabled(running || partyPreview.isEmpty)
        .accessibilityLabel("Start a dungeon run with your top five characters")
    }

    // MARK: - Run feed

    private func runFeed(_ run: DungeonRunResponse) -> some View {
        VStack(alignment: .leading, spacing: NQTheme.spaceS) {
            HStack {
                Text("Floor \(run.floorsCleared) cleared")
                    .font(NQText.heading.font.weight(.heavy))
                    .foregroundStyle(NQTheme.battleInk)
                if run.keysEarned > 0 {
                    Spacer()
                    NQChip("+\(run.keysEarned) keys", icon: .sparkle, tint: NQTheme.gold, filled: true)
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
