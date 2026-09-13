import SwiftUI
import NutriQuestUI

/// Kitchen Mines.
///
/// Twenty-five covered dishes, some of them burnt. Lift safe ones to climb the
/// multiplier and stop before you find a burnt one. The whole game is the one
/// decision the board keeps asking: take what you have, or risk it for the
/// next dish.
///
/// The client knows nothing. Where the mines are is decided when the board is
/// laid and stays on the server until the round is over — every tap is a
/// question, and the answer comes back from the server.
struct KitchenMinesView: View {
    @ObservedObject var gameState: GameState

    @Environment(\.nqAccent) private var accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Selected monster id, before the board is laid.
    @State private var selection: String?
    /// Which step of the pre-round flow we are on. The spec keeps these apart
    /// deliberately: the inventory screen chooses a monster, the kitchen
    /// screen chooses the danger, and mixing them hides the mine selector
    /// behind a selection the player has not made yet.
    @State private var stage: Stage = .choosingWager
    @State private var mines: Int = 5
    @State private var confirming = false
    @State private var sheet: MinesSheet?
    /// Tiles the player has lifted this round, with what was under them, so the
    /// board can animate without re-asking the server.
    @State private var uncovered: [Int: Bool] = [:]
    /// The dish that ended it, for the burn animation.
    @State private var burntTile: Int?
    @State private var announcedRarity: String?
    @State private var rarityToast: String?

    private enum Stage {
        /// Pick one monster.
        case choosingWager
        /// Pick the mine count, look at the empty board, commit.
        case settingUpBoard
    }

    private enum MinesSheet: Identifiable {
        case result(MinesRoundDTO)
        case houseRules

        var id: String {
            switch self {
            case .result(let round): return round.roundId
            case .houseRules: return "house-rules"
            }
        }
    }

    private var round: MinesRoundDTO? { gameState.minesRound }
    private var wagerable: [CasinoMonsterDTO] { gameState.minesWagerable }
    private var config: MinesConfigResponse? { gameState.minesConfig }

    private var minMines: Int { config?.minMines ?? 1 }
    private var maxMines: Int { config?.maxMines ?? 24 }
    private var tileCount: Int { config?.tileCount ?? 25 }
    private var columns: Int { config?.columns ?? 5 }

    private var selectedMonster: CasinoMonsterDTO? {
        wagerable.first { $0.id == selection }
    }

    var body: some View {
        ZStack {
            NQAdventureBackdrop().ignoresSafeArea()

            if let round {
                board(round)
            } else if stage == .settingUpBoard, let monster = selectedMonster {
                kitchen(monster)
            } else {
                wagerPicker
            }
        }
        .navigationTitle("Kitchen Mines")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    NQJuice.tap()
                    sheet = .houseRules
                } label: {
                    Image(systemName: "questionmark.circle")
                        .font(.system(size: 17, weight: .bold))
                }
                .accessibilityLabel("How Kitchen Mines works")
            }
        }
        .overlay(alignment: .top) {
            if let rarityToast {
                rarityBanner(rarityToast)
                    .padding(.top, NQTheme.spaceS)
                    .transition(NQTransition.slideUp)
            }
        }
        .animation(NQMotion.snappy, value: rarityToast)
        .sheet(item: $sheet) { presented in
            switch presented {
            case .result(let finished):
                MinesResultView(round: finished) { sheet = nil }
            case .houseRules:
                NavigationStack { MinesRulesView(gameState: gameState, mines: mines) }
            }
        }
        .confirmationDialog(
            "Cook with \(selectedMonster?.character.name ?? "this monster")?",
            isPresented: $confirming,
            titleVisibility: .visible
        ) {
            Button("Start cooking · \(mines) burnt", role: .destructive) {
                Task { await start() }
            }
            Button("Keep it", role: .cancel) {}
        } message: {
            Text("Once the board is laid this monster is committed. Hit a burnt dish and it is gone for good.")
        }
        .task {
            await gameState.loadMinesConfig()
            await gameState.refreshMines()
            syncBoard()
            applyLaunchStage()
        }
    }

    // MARK: - Step one: pick a monster

    private var wagerPicker: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NQTheme.spaceM) {
                if let last = gameState.minesLastRound {
                    lastRoundCard(last)
                }

                NQSectionHeader("Choose your wager", trailing: selection == nil ? "0/1" : "1/1")

                if wagerable.isEmpty {
                    NQEmptyState(
                        message: "No monsters to cook with yet. Open a crate and come back.",
                        icon: .cauldron,
                        actionLabel: "Open a crate",
                        action: { gameState.showCrates = true }
                    )
                    .padding(.vertical, NQTheme.spaceXL)
                } else {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 150), spacing: NQTheme.spaceM)],
                        spacing: NQTheme.spaceM
                    ) {
                        ForEach(wagerable) { monster in
                            monsterTile(monster)
                        }
                    }
                }

            }
            .padding(NQTheme.spaceL)
            .padding(.bottom, 140)
        }
        .safeAreaInset(edge: .bottom) { continueBar }
    }

    private func monsterTile(_ monster: CasinoMonsterDTO) -> some View {
        let isSelected = selection == monster.id
        let rarity = Rarity(rawValue: monster.character.rarity) ?? .common

        return Button {
            NQJuice.tap()
            withAnimation(NQMotion.snappy) {
                selection = isSelected ? nil : monster.id
            }
        } label: {
            VStack(spacing: NQTheme.spaceS) {
                CharacterArtwork(
                    character: Character(
                        id: monster.character.id,
                        name: monster.character.name,
                        colorHex: monster.character.colorHex,
                        rarity: rarity
                    )
                )
                .frame(width: 64, height: 64)

                Text(monster.character.name)
                    .font(NQText.heading.font)
                    .foregroundStyle(NQTheme.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                HStack(spacing: NQTheme.spaceXS) {
                    Text(rarity.label)
                        .font(NQText.microS.font.weight(.heavy))
                        .foregroundStyle(rarity.badgeText)
                        .nqPadding(.badge)
                        .background(rarity.badgeBackground)
                        .clipShape(Capsule())
                    Text(String(repeating: "★", count: max(1, monster.stars)))
                        .font(NQText.microS.font)
                        .foregroundStyle(NQTheme.gold)
                }

                Text("\(monster.netWorth.formatted()) NW")
                    .font(NQText.caption.font.weight(.bold))
                    .foregroundStyle(NQTheme.inkMuted)
            }
            .nqPadding(.card)
            .frame(maxWidth: .infinity)
            .background(NQTheme.background)
            .clipShape(RoundedRectangle(cornerRadius: NQTheme.radiusL))
            .overlay {
                RoundedRectangle(cornerRadius: NQTheme.radiusL)
                    .strokeBorder(
                        isSelected ? accent.accentDark : rarity.ringColor.opacity(0.5),
                        lineWidth: isSelected ? 3 : rarity.ringWidth
                    )
            }
            .nqElevation(.card)
            .scaleEffect(isSelected && !reduceMotion ? 1.03 : 1)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(monster.character.name), \(rarity.label), \(monster.stars) star, \(monster.netWorth) net worth")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// How many dishes to burn. More mines, more danger, bigger ladder.
    private var mineSelector: some View {
        VStack(alignment: .leading, spacing: NQTheme.spaceS) {
            NQSectionHeader("Burnt dishes", trailing: "\(tileCount - mines) safe")

            HStack(spacing: NQTheme.spaceM) {
                stepperButton("minus", enabled: mines > minMines) {
                    mines = max(minMines, mines - 1)
                }
                Text("\(mines)")
                    .font(.system(size: 40, weight: .heavy, design: .rounded))
                    .foregroundStyle(NQTheme.ink)
                    .monospacedDigit()
                    .frame(minWidth: 64)
                    .contentTransition(.numericText())
                stepperButton("plus", enabled: mines < maxMines) {
                    mines = min(maxMines, mines + 1)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 0) {
                    Text("FIRST DISH PAYS")
                        .font(NQText.microXS.font)
                        .tracking(0.6)
                        .foregroundStyle(NQTheme.inkMuted)
                    Text(String(format: "%.2fx", firstDishMultiplier))
                        .font(NQText.headingL.font.weight(.heavy))
                        .foregroundStyle(accent.accentDark)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }
            }
            .animation(NQMotion.snappy, value: mines)

            // Shortcuts only — every value in range stays reachable with ±.
            HStack(spacing: NQTheme.spaceXS) {
                ForEach(config?.minePresets ?? [1, 3, 5, 10, 15, 20, 24], id: \.self) { preset in
                    Button {
                        NQHaptic.selection()
                        withAnimation(NQMotion.snappy) { mines = preset }
                    } label: {
                        Text("\(preset)")
                            .font(NQText.captionS.font.weight(.heavy))
                            .foregroundStyle(mines == preset ? accent.accent.readableTextColor() : NQTheme.inkMuted)
                            .frame(maxWidth: .infinity)
                            .nqPadding(.chip)
                            .background(mines == preset ? accent.accent : NQTheme.surface)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(preset) burnt dishes")
                }
            }
        }
        .nqPadding(.card)
        .frame(maxWidth: .infinity)
        .background(NQTheme.background)
        .clipShape(RoundedRectangle(cornerRadius: NQTheme.radiusL + 2))
        .nqElevation(.card)
    }

    private func stepperButton(_ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button {
            NQHaptic.selection()
            action()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .black))
                .foregroundStyle(enabled ? accent.accentDark : NQTheme.inkFaint)
                .frame(width: 44, height: 44)
                .background(NQTheme.surface)
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(symbol == "minus" ? "One fewer burnt dish" : "One more burnt dish")
    }

    /// The published payout for surviving one dish on the selected board.
    private var firstDishMultiplier: Double {
        let safe = Double(tileCount - mines)
        guard safe > 0 else { return 1 }
        let edge = config?.houseEdge ?? 0.05
        let raw = (1 - edge) / (safe / Double(tileCount))
        return max(1, (raw * 100).rounded(.down) / 100)
    }

    private var continueBar: some View {
        VStack(spacing: NQTheme.spaceS) {
            if let monster = selectedMonster {
                selectedSummary(monster)
            }

            NQButton(selection == nil ? "Pick a monster" : "Continue", icon: .flame) {
                withAnimation(NQMotion.springy) { stage = .settingUpBoard }
            }
            .disabled(selection == nil)
        }
        .padding(NQTheme.spaceL)
        .background(NQTheme.background.ignoresSafeArea(edges: .bottom))
        .nqElevation(.nav)
    }

    private func selectedSummary(_ monster: CasinoMonsterDTO) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 0) {
                Text("Cooking with")
                    .font(NQText.microXS.font)
                    .tracking(0.6)
                    .foregroundStyle(NQTheme.inkMuted)
                Text(monster.character.name)
                    .font(NQText.headingL.font.weight(.heavy))
                    .foregroundStyle(NQTheme.ink)
            }
            Spacer()
            Text("\(monster.netWorth.formatted()) NW")
                .font(NQText.headingL.font.weight(.heavy))
                .foregroundStyle(NQTheme.ink)
        }
    }

    // MARK: - Step two: the kitchen — choose the danger, then commit

    private func kitchen(_ monster: CasinoMonsterDTO) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NQTheme.spaceM) {
                selectedSummary(monster)
                    .nqPadding(.card)
                    .background(NQTheme.background)
                    .clipShape(RoundedRectangle(cornerRadius: NQTheme.radiusL))
                    .nqElevation(.card)
                    .overlay(alignment: .topTrailing) {
                        Button("Change") {
                            NQJuice.tap()
                            withAnimation(NQMotion.springy) { stage = .choosingWager }
                        }
                        .font(NQText.captionS.font.weight(.bold))
                        .padding(NQTheme.spaceS)
                    }

                mineSelector

                // The board, still covered. Shown before committing so the
                // player can see the shape of what they are about to play.
                emptyBoardPreview
            }
            .padding(NQTheme.spaceL)
            .padding(.bottom, 120)
        }
        .safeAreaInset(edge: .bottom) { startBar }
    }

    /// Twenty-five identical cloches. Inert until the wager is committed.
    private var emptyBoardPreview: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: NQTheme.spaceS), count: columns),
            spacing: NQTheme.spaceS
        ) {
            ForEach(0..<tileCount, id: \.self) { _ in
                RoundedRectangle(cornerRadius: NQTheme.radiusM, style: .continuous)
                    .fill(NQTheme.surface)
                    .overlay {
                        RoundedRectangle(cornerRadius: NQTheme.radiusM, style: .continuous)
                            .strokeBorder(NQTheme.inkDeep.opacity(0.12), lineWidth: 1.5)
                    }
                    .overlay {
                        NQIcon.cauldron.view
                            .frame(width: 20, height: 20)
                            .foregroundStyle(NQTheme.inkFaint.opacity(0.45))
                    }
                    .aspectRatio(1, contentMode: .fit)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(tileCount) covered dishes, \(mines) of them burnt")
    }

    private var startBar: some View {
        NQButton("Start cooking · \(mines) burnt", icon: .flame) {
            confirming = true
        }
        .disabled(selection == nil || gameState.minesBusy)
        .padding(NQTheme.spaceL)
        .background(NQTheme.background.ignoresSafeArea(edges: .bottom))
        .nqElevation(.nav)
    }

    // MARK: - The board

    private func board(_ round: MinesRoundDTO) -> some View {
        VStack(spacing: NQTheme.spaceM) {
            scoreboard(round)

            dishGrid(round)
                .padding(.horizontal, NQTheme.spaceL)

            Spacer(minLength: 0)

            NQButton("Cash out · \(round.netWorth.formatted()) NW", icon: .sparkle) {
                Task { await cashOut(round) }
            }
            .disabled(gameState.minesBusy)
            .padding(.horizontal, NQTheme.spaceL)
            .padding(.bottom, NQTheme.spaceL)
        }
        .padding(.top, NQTheme.spaceM)
    }

    /// Current value on the left, what one more dish buys on the right. This
    /// pairing is the decision the game is made of.
    private func scoreboard(_ round: MinesRoundDTO) -> some View {
        HStack(alignment: .top, spacing: NQTheme.spaceM) {
            VStack(alignment: .leading, spacing: 2) {
                Text("CURRENT")
                    .font(NQText.microXS.font)
                    .tracking(0.8)
                    .foregroundStyle(NQTheme.inkMuted)
                Text(String(format: "%.2fx", round.multiplier))
                    .font(.system(size: 38, weight: .heavy, design: .rounded))
                    .foregroundStyle(heatTint(round.heat))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text("\(round.netWorth.formatted()) NW")
                    .font(NQText.headingL.font.weight(.heavy))
                    .foregroundStyle(NQTheme.ink)
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }

            Spacer()

            if let next = round.next {
                VStack(alignment: .trailing, spacing: 2) {
                    Text("NEXT SAFE DISH")
                        .font(NQText.microXS.font)
                        .tracking(0.8)
                        .foregroundStyle(NQTheme.inkMuted)
                    Text(String(format: "%.2fx", next.multiplier))
                        .font(NQText.displayL.font)
                        .foregroundStyle(NQTheme.inkMuted)
                        .monospacedDigit()
                    Text("\(next.netWorth.formatted()) NW")
                        .font(NQText.caption.font.weight(.bold))
                        .foregroundStyle(NQTheme.inkMuted)
                        .monospacedDigit()
                    Text("\(Int((next.safeChance * 100).rounded()))% safe")
                        .font(NQText.microS.font.weight(.heavy))
                        .foregroundStyle(NQTheme.inkFaint)
                }
            } else {
                Text("BOARD CLEARED")
                    .font(NQText.microS.font.weight(.heavy))
                    .foregroundStyle(NQTheme.success)
            }
        }
        .padding(.horizontal, NQTheme.spaceL)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "At \(String(format: "%.2f", round.multiplier)) times, \(round.netWorth) net worth."
            + (round.next.map { " One more safe dish pays \(String(format: "%.2f", $0.multiplier)) times." } ?? " Board cleared.")
        )
    }

    private func dishGrid(_ round: MinesRoundDTO) -> some View {
        let side = columns
        return LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: NQTheme.spaceS), count: side),
            spacing: NQTheme.spaceS
        ) {
            ForEach(0..<tileCount, id: \.self) { tile in
                dish(tile: tile, round: round)
            }
        }
    }

    /// One covered dish. Every unlifted cloche is identical — nothing about
    /// its look, timing or feel may hint at what is underneath.
    private func dish(tile: Int, round: MinesRoundDTO) -> some View {
        let safeHere = uncovered[tile]
        let isBurnt = burntTile == tile
        let lifted = safeHere != nil || isBurnt

        return Button {
            Task { await lift(tile: tile, round: round) }
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: NQTheme.radiusM, style: .continuous)
                    .fill(lifted ? (isBurnt ? NQTheme.warning.opacity(0.22) : NQTheme.success.opacity(0.18)) : NQTheme.surface)
                    .overlay {
                        RoundedRectangle(cornerRadius: NQTheme.radiusM, style: .continuous)
                            .strokeBorder(
                                isBurnt ? NQTheme.warning : (lifted ? NQTheme.success.opacity(0.5) : NQTheme.inkDeep.opacity(0.12)),
                                lineWidth: isBurnt ? 2.5 : 1.5
                            )
                    }

                if isBurnt {
                    Text("🔥").font(.system(size: 26))
                } else if safeHere != nil {
                    Text(ingredient(for: tile)).font(.system(size: 24))
                } else {
                    // The cloche. One shape for every hidden dish.
                    NQIcon.cauldron.view
                        .frame(width: 22, height: 22)
                        .foregroundStyle(NQTheme.inkFaint.opacity(0.55))
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .scaleEffect(lifted && !reduceMotion ? 1 : 0.98)
            .animation(NQMotion.snappy, value: lifted)
        }
        .buttonStyle(.plain)
        .disabled(lifted || gameState.minesBusy || !round.isActive)
        .accessibilityLabel(
            isBurnt ? "Burnt dish"
                : safeHere != nil ? "Safe ingredient"
                : "Covered dish \(tile + 1)"
        )
    }

    /// Cosmetic only. The ingredient has no effect on odds or payout, so it is
    /// derived from the tile index rather than from anything about the round.
    private func ingredient(for tile: Int) -> String {
        let pantry = ["🥕", "🥦", "🍳", "🌽", "🍅", "🧄", "🫑", "🍄", "🥬", "🧅"]
        return pantry[tile % pantry.count]
    }

    private func heatTint(_ heat: String) -> Color {
        switch heat {
        case "warm": return NQTheme.gold
        case "hot": return NQTheme.flame
        case "searing": return NQTheme.warning
        default: return accent.accentDark
        }
    }

    private func rarityBanner(_ label: String) -> some View {
        Text("\(label.uppercased()) VALUE REACHED")
            .font(NQText.microS.font.weight(.heavy))
            .tracking(0.8)
            .foregroundStyle(NQTheme.background)
            .nqPadding(.banner)
            .background(NQTheme.gold)
            .clipShape(Capsule())
            .nqElevation(.card)
    }

    private func lastRoundCard(_ last: MinesRoundDTO) -> some View {
        HStack(spacing: NQTheme.spaceM) {
            Circle()
                .fill((last.didServe ? NQTheme.success : NQTheme.warning).opacity(0.18))
                .frame(width: 44, height: 44)
                .overlay {
                    Text(last.didServe ? "🍽️" : "🔥").font(.system(size: 20))
                }
            VStack(alignment: .leading, spacing: 2) {
                Text(last.didServe ? "Served" : "Burnt")
                    .font(NQText.heading.font)
                    .foregroundStyle(NQTheme.ink)
                Text(lastRoundDetail(last))
                    .font(NQText.captionS.font)
                    .foregroundStyle(NQTheme.inkMuted)
            }
            Spacer()
            Button("Details") { sheet = .result(last) }
                .font(NQText.captionS.font.weight(.bold))
        }
        .nqPadding(.card)
        .background(NQTheme.background)
        .clipShape(RoundedRectangle(cornerRadius: NQTheme.radiusL))
        .nqElevation(.card)
    }

    private func lastRoundDetail(_ last: MinesRoundDTO) -> String {
        if last.didServe, let reward = last.reward {
            return String(format: "%.2fx · won %@", last.cashOutMultiplier ?? 1, reward.character.name)
        }
        return String(format: "at %.2fx · lost %@ NW", last.cashOutMultiplier ?? 1, last.wagerValue.formatted())
    }

    // MARK: - Actions

    private func start() async {
        guard let dropID = selection else { return }
        guard let started = await gameState.startMinesRound(dropID: dropID, mines: mines) else { return }
        selection = nil
        stage = .choosingWager
        uncovered = [:]
        burntTile = nil
        announcedRarity = started.rarity
        // Neutral "dropped in" cue — the win/loss sound lands on its own
        // outcome, not stacked right behind this one.
        NQJuice.tap()
        if !started.isActive {
            try? await Task.sleep(nanoseconds: 500_000_000)
            finish(started)
        }
    }

    private func lift(tile: Int, round: MinesRoundDTO) async {
        guard let result = await gameState.revealMinesTile(roundID: round.roundId, tile: tile) else { return }

        if result.safe {
            withAnimation(NQMotion.snappy) { uncovered[tile] = true }
            NQJuice.tap()
            announceRarityIfCrossed(result.round)
        } else {
            withAnimation(NQMotion.bouncy) { burntTile = tile }
            NQJuice.wagerResult(won: false)
            // Hold on the burn before the result card lands, so the player
            // actually sees which dish ended it.
            Task {
                try? await Task.sleep(nanoseconds: reduceMotion ? 900_000_000 : 1_500_000_000)
                finish(result.round)
            }
        }
    }

    private func cashOut(_ round: MinesRoundDTO) async {
        guard let served = await gameState.cashOutMines(roundID: round.roundId) else { return }
        NQJuice.wagerResult(won: true)
        finish(served)
    }

    private func finish(_ round: MinesRoundDTO) {
        gameState.applyMinesResult(round)
        rarityToast = nil
        announcedRarity = nil
        sheet = .result(round)
    }

    /// Announce when the pot crosses into a new rarity band. Informational —
    /// it never touches the odds or the board.
    private func announceRarityIfCrossed(_ round: MinesRoundDTO) {
        guard round.rarity != announcedRarity else { return }
        let previous = Rarity(rawValue: announcedRarity ?? "common") ?? .common
        let current = Rarity(rawValue: round.rarity) ?? .common
        announcedRarity = round.rarity
        guard current > previous else { return }

        rarityToast = current.label
        NQHaptic.light()
        Task {
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            if rarityToast == current.label { rarityToast = nil }
        }
    }

    /// QA hook on the existing `-uiGame` convention: `-uiGame mines-setup`
    /// lands on the kitchen with the first monster already chosen, so a
    /// screenshot can reach the mine selector without a tap.
    private func applyLaunchStage() {
        guard round == nil, selection == nil else { return }
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-uiGame"), args.count > i + 1,
              args[i + 1] == "mines-setup", let first = wagerable.first else { return }
        selection = first.id
        stage = .settingUpBoard
    }

    /// Rebuild the local board from a round the server already knows about —
    /// used when returning to a game left running.
    private func syncBoard() {
        guard let round, round.isActive else { return }
        uncovered = Dictionary(uniqueKeysWithValues: round.revealed.map { ($0, true) })
        burntTile = nil
        announcedRarity = round.rarity
    }
}

// MARK: - Result

/// The end of a board: what was served, or what got burnt.
struct MinesResultView: View {
    let round: MinesRoundDTO
    let onDismiss: () -> Void

    @Environment(\.nqAccent) private var accent

    var body: some View {
        VStack(spacing: NQTheme.spaceL) {
            ScrollView {
                if round.didServe, let reward = round.reward {
                    served(reward)
                } else {
                    burnt
                }
            }

            NQButton("Back to the kitchen") { onDismiss() }
                .padding(.horizontal, NQTheme.spaceL)
                .padding(.bottom, NQTheme.spaceL)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .nqPageBackground()
        .presentationDetents([.large])
    }

    private func served(_ reward: CasinoMonsterDTO) -> some View {
        let rarity = Rarity(rawValue: reward.character.rarity) ?? .common
        return VStack(spacing: NQTheme.spaceM) {
            Text(String(format: "🍽️ SERVED @ %.2fx", round.cashOutMultiplier ?? 1))
                .font(NQText.heading.font.weight(.heavy))
                .tracking(0.6)
                .foregroundStyle(NQTheme.success)

            Text("\((round.finalNetWorth ?? 0).formatted()) NW")
                .font(NQText.displayL.font)
                .foregroundStyle(NQTheme.ink)

            CharacterArtwork(
                character: Character(
                    id: reward.character.id,
                    name: reward.character.name,
                    colorHex: reward.character.colorHex,
                    rarity: rarity
                )
            )
            .frame(width: 140, height: 140)

            Text(rarity.label.uppercased())
                .font(NQText.heading.font.weight(.heavy))
                .tracking(1)
                .foregroundStyle(rarity.badgeText)
                .nqPadding(.chip)
                .background(rarity.badgeBackground)
                .clipShape(Capsule())

            Text(reward.character.name)
                .font(NQText.displayL.font)
                .foregroundStyle(NQTheme.ink)

            Text("Net worth \(reward.netWorth.formatted()) · \(String(repeating: "★", count: max(1, reward.stars)))")
                .font(NQText.captionS.font)
                .foregroundStyle(NQTheme.inkMuted)

            Text("\(round.picks) safe \(round.picks == 1 ? "dish" : "dishes") · \(round.mines) burnt on the board")
                .font(NQText.microXS.font)
                .foregroundStyle(NQTheme.inkFaint)
        }
        .padding(NQTheme.spaceL)
        .accessibilityElement(children: .combine)
    }

    private var burnt: some View {
        VStack(spacing: NQTheme.spaceM) {
            Text(String(format: "🔥 BURNT @ %.2fx", round.cashOutMultiplier ?? 1))
                .font(NQText.heading.font.weight(.heavy))
                .tracking(0.6)
                .foregroundStyle(NQTheme.warning)

            Text("🔥").font(.system(size: 64))

            Text("WAGER LOST")
                .font(NQText.displayL.font)
                .foregroundStyle(NQTheme.ink)

            Text("\((round.lostNetWorth ?? round.wagerValue).formatted()) NW")
                .font(NQText.headingL.font.weight(.heavy))
                .foregroundStyle(NQTheme.inkMuted)

            Text(round.wager.character.name)
                .font(NQText.captionS.font)
                .foregroundStyle(NQTheme.inkFaint)

            Text("\(round.picks) safe \(round.picks == 1 ? "dish" : "dishes") before it went wrong")
                .font(NQText.microXS.font)
                .foregroundStyle(NQTheme.inkFaint)
        }
        .padding(NQTheme.spaceL)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Rules

/// Plain-language rules and the real payout ladder for the chosen board.
struct MinesRulesView: View {
    @ObservedObject var gameState: GameState
    let mines: Int

    @Environment(\.dismiss) private var dismiss
    @Environment(\.nqAccent) private var accent
    @State private var payouts: MinesPayoutsResponse?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NQTheme.spaceL) {
                section("How it works") {
                    ruleLine("25 covered dishes. You choose how many are burnt, from 1 to 24.")
                    ruleLine("More burnt dishes means more danger — and a bigger ladder.")
                    ruleLine("Every safe dish you lift raises the multiplier.")
                    ruleLine("Hit a burnt dish and the wagered monster is gone.")
                    ruleLine("Cash out whenever you like; your final net worth buys a new random monster.")
                    ruleLine("Your monster is committed the moment the board is laid.")
                }

                section("The odds are the odds") {
                    Text("Multipliers are not made up. Each one is the real chance of having survived that many dishes, with a \(Int((gameState.minesConfig?.houseEdge ?? 0.05) * 100))% house edge.")
                        .font(NQText.captionS.font)
                        .foregroundStyle(NQTheme.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                    if let howItWorks = gameState.minesConfig?.howItWorks {
                        Text(howItWorks)
                            .font(NQText.microXS.font)
                            .foregroundStyle(NQTheme.inkFaint)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if let payouts {
                    section("\(payouts.mines) burnt · what it pays") {
                        ForEach(payouts.rungs.prefix(12)) { rung in
                            HStack {
                                Text("\(rung.picks) safe")
                                    .font(NQText.caption.font)
                                    .foregroundStyle(NQTheme.inkMuted)
                                Spacer()
                                Text("\(Int((rung.survivalChance * 100).rounded()))%")
                                    .font(NQText.microS.font)
                                    .foregroundStyle(NQTheme.inkFaint)
                                Text(String(format: "%.2fx", rung.multiplier))
                                    .font(NQText.heading.font)
                                    .foregroundStyle(NQTheme.ink)
                                    .monospacedDigit()
                                    .frame(minWidth: 72, alignment: .trailing)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
            }
            .padding(NQTheme.spaceL)
        }
        .nqPageBackground()
        .navigationTitle("Kitchen Mines")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") { dismiss() }
            }
        }
        .task {
            await gameState.loadMinesConfig()
            payouts = try? await APIClient.shared.fetchMinesPayouts(mines: mines)
        }
    }

    private func ruleLine(_ text: String) -> some View {
        HStack(alignment: .top, spacing: NQTheme.spaceS) {
            Text("·").font(NQText.heading.font).foregroundStyle(NQTheme.inkFaint)
            Text(text)
                .font(NQText.captionS.font)
                .foregroundStyle(NQTheme.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: NQTheme.spaceS) {
            NQSectionHeader(title)
            content()
        }
        .nqPadding(.card)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(NQTheme.background)
        .clipShape(RoundedRectangle(cornerRadius: NQTheme.radiusL + 2))
        .nqElevation(.card)
    }
}
