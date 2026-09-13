import SwiftUI
import NutriQuestUI

/// Cauldron Crash.
///
/// Drop 1-3 monsters in, watch the multiplier climb, and decide whether the
/// value you have now is worth more than the one you might have in a second.
///
/// The client animates; it never adjudicates. The multiplier on screen is
/// re-derived from the round's start time and the growth rate the server
/// published, and the crash point is not on this device at all — the round
/// ends when the server says it ended, which the poll below asks about a
/// couple of times a second.
struct CauldronCrashView: View {
    @ObservedObject var gameState: GameState

    @Environment(\.nqAccent) private var accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Selected monster ids, in the order they were tapped.
    @State private var selection: [String] = []
    @State private var confirming = false
    /// Ticks the displayed multiplier. Driven by the round's start time, not
    /// by accumulation, so a dropped frame cannot drift the number.
    @State private var displayedMultiplier: Double = 1
    @State private var announcedBracket: String?
    @State private var bracketToast: String?
    /// The round that just blew up, held on screen for the blast. The result
    /// card waits for this; otherwise it covers the explosion instantly and
    /// the cauldron appears to simply vanish.
    @State private var exploding: CauldronRoundDTO?
    @State private var explodedAt: Date?
    @State private var sheet: CrashSheet?
    /// A cash-out POST is in flight. The round is still active server-side,
    /// so the poll cannot end it — only the POST's verdict (cashed out vs
    /// crashed) is what leaves this state.
    @State private var cashOutPending = false
    /// The roundId already finished through `finish`, so a late poll result
    /// and the cash-out POST cannot both play the blast or the win counter.
    @State private var resolvedRoundId: String?
    /// When the current `serverTime` snapshot arrived — `CauldronClock` needs
    /// it to keep the multiplier on the server clock between polls.
    @State private var serverTimeReceivedAt = Date()

    /// Everything this screen can present. One enum, so the result card and
    /// the rules cannot both try to own the sheet slot.
    private enum CrashSheet: Identifiable {
        case result(CauldronRoundDTO)
        case houseRules

        var id: String {
            switch self {
            case .result(let round): return round.roundId
            case .houseRules: return "house-rules"
            }
        }
    }

    private let tick = Timer.publish(every: 1.0 / 30.0, on: .main, in: .common).autoconnect()

    private var round: CauldronRoundDTO? { gameState.cauldronRound }

    private var wagerable: [CauldronMonsterDTO] { gameState.cauldronWagerable }

    private var selectedMonsters: [CauldronMonsterDTO] {
        selection.compactMap { id in wagerable.first { $0.id == id } }
    }

    private var pot: Int { selectedMonsters.reduce(0) { $0 + $1.netWorth } }

    private var maxWager: Int { gameState.cauldronConfig?.maxWagerMonsters ?? 3 }

    /// Live pot value at the displayed multiplier.
    private var liveNetWorth: Int {
        guard let round else { return pot }
        return Int((Double(round.startingNetWorth) * displayedMultiplier).rounded(.down))
    }

    var body: some View {
        ZStack {
            NQAdventureBackdrop().ignoresSafeArea()

            if let exploding {
                crashStage(exploding)
            } else if let round {
                activeRound(round)
            } else {
                wagerSelection
            }
        }
        .navigationTitle("Cauldron Crash")
        .navigationBarTitleDisplayMode(.inline)
        .overlay(alignment: .top) {
            if let bracketToast {
                bracketBanner(bracketToast)
                    .padding(.top, NQTheme.spaceS)
                    .transition(NQTransition.slideUp)
            }
        }
        .animation(NQMotion.snappy, value: bracketToast)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    NQJuice.tap()
                    sheet = .houseRules
                } label: {
                    Image(systemName: "questionmark.circle")
                        .font(.system(size: 17, weight: .bold))
                }
                .accessibilityLabel("House rules")
                .accessibilityHint("Published odds, rarity brackets and the house edge.")
            }
        }
        .sheet(item: $sheet) { presented in
            switch presented {
            case .result(let finished):
                CauldronResultView(round: finished) { sheet = nil }
            case .houseRules:
                NavigationStack { CauldronOddsView(gameState: gameState) }
            }
        }
        .confirmationDialog(
            "Wager \(selection.count == 1 ? "this monster" : "these \(selection.count) monsters")?",
            isPresented: $confirming,
            titleVisibility: .visible
        ) {
            Button("Drop them in · \(pot.formatted()) NW", role: .destructive) {
                Task { await start() }
            }
            Button("Keep them", role: .cancel) {}
        } message: {
            Text("If the cauldron crashes before you cash out, \(selection.count == 1 ? "it is" : "they are") gone for good.")
        }
        .task {
            await gameState.loadCauldronConfig()
            if let refreshed = await gameState.refreshCauldron() {
                rememberServerTime(refreshed.serverTime)
            }
            syncMultiplier()
        }
        .onReceive(tick) { _ in
            guard round != nil, !cashOutPending else { return }
            syncMultiplier()
        }
        .task(id: round?.roundId) {
            // While a round is live, the server is the only thing that knows
            // where it crashes — so ask, steadily, until it says the round is
            // over.
            guard round != nil else { return }
            while !Task.isCancelled, gameState.cauldronRound != nil {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard !Task.isCancelled else { return }
                await pollForCrash()
            }
        }
    }

    // MARK: - Wager selection

    private var wagerSelection: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NQTheme.spaceM) {
                if let last = gameState.cauldronLastRound {
                    lastRoundCard(last)
                }

                NQSectionHeader(
                    "Choose your wager",
                    trailing: "\(selection.count)/\(maxWager)"
                )

                if wagerable.isEmpty {
                    NQEmptyState(
                        message: "No monsters to wager yet. Open a crate and come back.",
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
            .padding(.bottom, 120)
        }
        .safeAreaInset(edge: .bottom) { potBar }
    }

    private func monsterTile(_ monster: CauldronMonsterDTO) -> some View {
        let isSelected = selection.contains(monster.id)
        let rarity = Rarity(rawValue: monster.character.rarity) ?? .common
        let atCapacity = selection.count >= maxWager && !isSelected

        return Button {
            NQJuice.tap()
            withAnimation(NQMotion.snappy) { toggle(monster) }
        } label: {
            VStack(spacing: NQTheme.spaceS) {
                CharacterArtwork(
                    character: Character(
                        id: monster.character.id,
                        name: monster.character.name,
                        colorHex: monster.character.colorHex,
                        rarity: rarity,
                        statType: StatType(rawValue: monster.character.statType) ?? .fiber,
                        isShiny: monster.shiny
                    )
                )
                .frame(width: 64, height: 64)
                Text(monster.character.name)
                    .font(NQText.heading.font)
                    .foregroundStyle(NQTheme.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(rarity.label)
                    .font(NQText.microS.font.weight(.heavy))
                    .foregroundStyle(rarity.badgeText)
                    .nqPadding(.badge)
                    .background(rarity.badgeBackground)
                    .clipShape(Capsule())
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
            .opacity(atCapacity ? 0.45 : 1)
            .scaleEffect(isSelected && !reduceMotion ? 1.03 : 1)
        }
        .buttonStyle(.plain)
        .disabled(atCapacity)
        .accessibilityLabel("\(monster.character.name), \(rarity.label), \(monster.netWorth) net worth")
        .accessibilityHint(isSelected ? "Selected. Double tap to remove from the wager." : "Double tap to add to the wager.")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// Sticky footer: the pot, and the only button that can start a round.
    private var potBar: some View {
        VStack(spacing: NQTheme.spaceS) {
            HStack {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Total pot")
                        .font(NQText.microXS.font)
                        .tracking(0.6)
                        .foregroundStyle(NQTheme.inkMuted)
                    Text("\(pot.formatted()) NW")
                        .font(NQText.displayL.font)
                        .foregroundStyle(NQTheme.ink)
                        .contentTransition(.numericText())
                }
                Spacer()
                if pot > 0 {
                    let rarity = bracket(for: pot)
                    Text(rarity.label)
                        .font(NQText.microS.font.weight(.heavy))
                        .foregroundStyle(rarity.badgeText)
                        .nqPadding(.chip)
                        .background(rarity.badgeBackground)
                        .clipShape(Capsule())
                }
            }

            NQButton(
                selection.isEmpty ? "Pick a monster" : "Start crash · \(pot.formatted()) NW",
                icon: .cauldron
            ) {
                confirming = true
            }
            .disabled(selection.isEmpty || gameState.cauldronBusy)
        }
        .padding(NQTheme.spaceL)
        .background(NQTheme.background.ignoresSafeArea(edges: .bottom))
        .nqElevation(.nav)
    }

    // MARK: - Live round

    private func activeRound(_ round: CauldronRoundDTO) -> some View {
        VStack(spacing: NQTheme.spaceL) {
            Spacer(minLength: 0)

            VStack(spacing: 2) {
                Text(String(format: "%.2fx", displayedMultiplier))
                    .font(.system(size: 64, weight: .heavy, design: .rounded))
                    .foregroundStyle(intensityTint)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .accessibilityLabel(String(format: "%.2f times", displayedMultiplier))

                Text("\(liveNetWorth.formatted()) NW")
                    .font(NQText.headingL.font.weight(.heavy))
                    .foregroundStyle(NQTheme.ink)
                    .monospacedDigit()
                    .contentTransition(.numericText())

                Text(bracket(for: liveNetWorth).label)
                    .font(NQText.microS.font.weight(.heavy))
                    .foregroundStyle(bracket(for: liveNetWorth).badgeText)
                    .nqPadding(.chip)
                    .background(bracket(for: liveNetWorth).badgeBackground)
                    .clipShape(Capsule())
            }

            CauldronVesselView(
                multiplier: displayedMultiplier,
                tint: intensityTint,
                reduceMotion: reduceMotion
            )
            .frame(height: 200)

            // What is actually at stake, so the decision is never abstract.
            HStack(spacing: NQTheme.spaceS) {
                ForEach(round.wager) { monster in
                    VStack(spacing: 2) {
                        Text(monster.character.name)
                            .font(NQText.microS.font.weight(.heavy))
                            .lineLimit(1)
                        Text("\(monster.netWorth.formatted())")
                            .font(NQText.microXS.font)
                    }
                    .foregroundStyle(NQTheme.inkMuted)
                    .nqPadding(.chip)
                    .background(NQTheme.surface)
                    .clipShape(Capsule())
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("At stake: \(round.wager.map(\.character.name).joined(separator: ", "))")

            Spacer(minLength: 0)

            NQButton("Cash out · \(liveNetWorth.formatted()) NW", icon: .sparkle) {
                Task { await cashOut(round) }
            }
            .disabled(gameState.cauldronBusy || cashOutPending)
            .accessibilityLabel(cashOutPending ? "Cashing out" : "Cash out")
            .padding(.horizontal, NQTheme.spaceL)
            .padding(.bottom, NQTheme.spaceL)
        }
    }

    /// Cauldron heat. Reads only the displayed multiplier — it cannot hint at
    /// the crash point, because this device does not know it.
    private var intensityTint: Color {
        switch displayedMultiplier {
        case ..<2: return accent.accentDark
        case ..<3: return NQTheme.gold
        case ..<5: return NQTheme.flame
        default: return NQTheme.warning
        }
    }

    private func bracketBanner(_ label: String) -> some View {
        Text("\(label.uppercased()) VALUE REACHED")
            .font(NQText.microS.font.weight(.heavy))
            .tracking(0.8)
            .foregroundStyle(NQTheme.background)
            .nqPadding(.banner)
            .background(NQTheme.gold)
            .clipShape(Capsule())
            .nqElevation(.card)
            .accessibilityAddTraits(.isStaticText)
    }

    private func lastRoundCard(_ last: CauldronRoundDTO) -> some View {
        HStack(spacing: NQTheme.spaceM) {
            Circle()
                .fill((last.didCashOut ? NQTheme.success : NQTheme.warning).opacity(0.18))
                .frame(width: 44, height: 44)
                .overlay {
                    (last.didCashOut ? NQIcon.sparkle : NQIcon.flame).view
                        .frame(width: 20, height: 20)
                        .foregroundStyle(last.didCashOut ? NQTheme.success : NQTheme.warning)
                }
            VStack(alignment: .leading, spacing: 2) {
                Text(last.didCashOut ? "Cashed out" : "Crashed")
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

    private func lastRoundDetail(_ last: CauldronRoundDTO) -> String {
        if last.didCashOut, let multiplier = last.cashOutMultiplier, let reward = last.reward {
            return String(format: "%.2fx · won %@", multiplier, reward.character.name)
        }
        if let crash = last.crashMultiplier {
            return String(format: "at %.2fx · lost %@ NW", crash, last.startingNetWorth.formatted())
        }
        return "\(last.startingNetWorth.formatted()) NW"
    }

    // MARK: - Actions

    private func toggle(_ monster: CauldronMonsterDTO) {
        if let index = selection.firstIndex(of: monster.id) {
            selection.remove(at: index)
        } else if selection.count < maxWager {
            selection.append(monster.id)
        }
    }

    private func start() async {
        let wagered = selection
        guard let started = await gameState.startCauldronRound(dropIDs: wagered) else { return }
        selection = []
        cashOutPending = false
        resolvedRoundId = nil
        rememberServerTime(started.serverTime)
        announcedBracket = bracket(for: started.startingNetWorth).rawValue
        displayedMultiplier = CauldronClock.multiplier(
            startedAt: started.startedAt,
            serverTime: started.serverTime,
            growthRate: started.growthRate,
            receivedAt: serverTimeReceivedAt
        )
        // Neutral "dropped in" cue — not the win fanfare or the loss beep,
        // since placement itself is neither.
        NQJuice.tap()
        // A round can crash on contact (the house edge, 5% of the time). Hold
        // a beat so the placement sound isn't immediately trailed by the
        // crash sound in the same breath — it read as "dropping a character
        // in plays a losing sound."
        if !started.isActive {
            try? await Task.sleep(nanoseconds: 500_000_000)
            finish(started)
        }
    }

    /// Freeze the number, POST cash-out, then present whatever the server
    /// actually did — including a late crash, or a dropped response that
    /// still landed.
    private func cashOut(_ round: CauldronRoundDTO) async {
        guard !cashOutPending else { return }
        cashOutPending = true
        displayedMultiplier = CauldronClock.multiplier(
            startedAt: round.startedAt,
            serverTime: round.serverTime,
            growthRate: round.growthRate,
            receivedAt: serverTimeReceivedAt
        )
        guard let result = await gameState.cashOutCauldron(roundID: round.roundId) else {
            cashOutPending = false
            return
        }
        finish(result)
    }

    /// Learn from the server whether the cauldron has already blown up.
    /// Skipped while a cash-out is pending: that POST (or its reconcile GET)
    /// is the only thing allowed to leave the pending state.
    private func pollForCrash() async {
        guard !cashOutPending else { return }
        guard let live = gameState.cauldronRound else { return }
        let refreshed = await gameState.refreshCauldron()
        if let refreshed {
            rememberServerTime(refreshed.serverTime)
        }
        if refreshed == nil, let ended = gameState.cauldronLastRound, ended.roundId == live.roundId {
            finish(ended)
        }
    }

    /// Stamps when the newest `serverTime` snapshot arrived, so
    /// `CauldronClock` can keep advancing the multiplier on the server clock
    /// between polls.
    private func rememberServerTime(_ serverTime: String) {
        if CauldronClock.parse(serverTime) != nil { serverTimeReceivedAt = Date() }
    }

    /// Present a finished round once. Sets the blast (if any) before clearing
    /// the live round so the wager table cannot flash through.
    private func finish(_ round: CauldronRoundDTO) {
        guard CauldronCashOut.shouldApply(round, resolvedRoundId: resolvedRoundId) else { return }
        resolvedRoundId = round.roundId
        cashOutPending = false
        gameState.applyCauldronResult(round)
        displayedMultiplier = round.cashOutMultiplier ?? round.crashMultiplier ?? displayedMultiplier
        bracketToast = nil
        announcedBracket = nil

        guard round.didCrash else {
            NQJuice.wagerResult(won: true)
            sheet = .result(round)
            return
        }

        // Let the thing actually explode before the result card lands on top
        // of it.
        NQJuice.wagerResult(won: false)
        explodedAt = Date()
        exploding = round
        Task {
            try? await Task.sleep(nanoseconds: UInt64(blastHold * 1_000_000_000))
            guard !Task.isCancelled else { return }
            exploding = nil
            explodedAt = nil
            sheet = .result(round)
        }
    }

    /// How long the wreckage stays up. Long enough to read as an explosion,
    /// short enough that it never feels like a loading screen — and shorter
    /// still when the player has asked for less motion.
    private var blastHold: Double { reduceMotion ? 0.9 : 1.6 }

    /// The moment of loss: the multiplier frozen where it died, the cauldron
    /// coming apart, and the monsters it took with it.
    private func crashStage(_ round: CauldronRoundDTO) -> some View {
        VStack(spacing: NQTheme.spaceL) {
            Spacer(minLength: 0)

            VStack(spacing: 2) {
                Text(String(format: "%.2fx", round.crashMultiplier ?? displayedMultiplier))
                    .font(.system(size: 64, weight: .heavy, design: .rounded))
                    .foregroundStyle(NQTheme.warning)
                    .monospacedDigit()
                Text("CRASHED")
                    .font(NQText.microS.font.weight(.heavy))
                    .tracking(1.2)
                    .foregroundStyle(NQTheme.warning)
            }

            CauldronVesselView(
                multiplier: round.crashMultiplier ?? displayedMultiplier,
                tint: NQTheme.warning,
                reduceMotion: reduceMotion,
                explodedAt: explodedAt
            )
            .frame(height: 200)

            HStack(spacing: NQTheme.spaceS) {
                ForEach(round.wager) { monster in
                    VStack(spacing: 2) {
                        Text(monster.character.name)
                            .font(NQText.microS.font.weight(.heavy))
                            .lineLimit(1)
                        Text("\(monster.netWorth.formatted())")
                            .font(NQText.microXS.font)
                    }
                    .foregroundStyle(NQTheme.inkFaint)
                    .nqPadding(.chip)
                    .background(NQTheme.surface)
                    .clipShape(Capsule())
                    .strikethrough(true, color: NQTheme.warning)
                }
            }

            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "Crashed at \(String(format: "%.2f", round.crashMultiplier ?? displayedMultiplier)) times. "
            + "Wager lost: \(round.wager.map(\.character.name).joined(separator: ", "))."
        )
    }

    /// Recompute the displayed multiplier from the round's start time.
    ///
    /// `m(t) = e^(rate * t)` is the same curve the server prices a cash-out
    /// with, so the number under the player's thumb is the number they get.
    private func syncMultiplier() {
        guard let round, round.isActive, !cashOutPending else { return }
        let next = CauldronClock.multiplier(
            startedAt: round.startedAt,
            serverTime: round.serverTime,
            growthRate: round.growthRate,
            receivedAt: serverTimeReceivedAt
        )
        guard next != displayedMultiplier else { return }
        displayedMultiplier = next

        // Threshold feedback: announce a bracket the moment the pot enters it,
        // without pausing anything (spec §12).
        let crossed = bracket(for: liveNetWorth)
        if crossed.rawValue != announcedBracket {
            announcedBracket = crossed.rawValue
            if crossed > bracket(for: round.startingNetWorth) {
                bracketToast = crossed.label
                NQHaptic.light()
                Task {
                    try? await Task.sleep(nanoseconds: 1_600_000_000)
                    if bracketToast == crossed.label { bracketToast = nil }
                }
            }
        }
    }

    /// Which rarity a net worth buys, from the server's published brackets.
    private func bracket(for netWorth: Int) -> Rarity {
        guard let ranges = gameState.cauldronConfig?.rarityRanges else { return .common }
        let match = ranges.last { netWorth >= $0.min }
        return Rarity(rawValue: match?.rarity ?? "common") ?? .common
    }
}

// MARK: - Result

/// The end of a round: what came out of the cauldron, or what went up in it.
struct CauldronResultView: View {
    let round: CauldronRoundDTO
    let onDismiss: () -> Void

    @Environment(\.nqAccent) private var accent

    var body: some View {
        VStack(spacing: NQTheme.spaceL) {
            // Scrolls rather than clips: a cash-out card is taller than a
            // crash card, and taller again at large Dynamic Type sizes.
            ScrollView {
                if round.didCashOut, let reward = round.reward {
                    cashedOut(reward)
                } else {
                    crashed
                }
            }

            NQButton("Back to the table") { onDismiss() }
                .padding(.horizontal, NQTheme.spaceL)
                .padding(.bottom, NQTheme.spaceL)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .nqPageBackground()
        .presentationDetents([.large])
    }

    private func cashedOut(_ reward: CauldronMonsterDTO) -> some View {
        let rarity = Rarity(rawValue: reward.character.rarity) ?? .common
        return VStack(spacing: NQTheme.spaceM) {
            Text(String(format: "CASHED OUT @ %.2fx", round.cashOutMultiplier ?? 0))
                .font(NQText.microS.font.weight(.heavy))
                .tracking(0.8)
                .foregroundStyle(NQTheme.success)

            Text("\((round.finalNetWorth ?? 0).formatted()) NW")
                .font(NQText.displayL.font)
                .foregroundStyle(NQTheme.ink)

            CharacterArtwork(
                character: Character(
                    id: reward.character.id,
                    name: reward.character.name,
                    colorHex: reward.character.colorHex,
                    rarity: rarity,
                    statType: StatType(rawValue: reward.character.statType) ?? .fiber,
                    isShiny: reward.shiny
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

            if let crash = round.crashMultiplier {
                Text(String(format: "It would have crashed at %.2fx", crash))
                    .font(NQText.microXS.font)
                    .foregroundStyle(NQTheme.inkFaint)
            }
        }
        .padding(NQTheme.spaceL)
        .accessibilityElement(children: .combine)
    }

    private var crashed: some View {
        VStack(spacing: NQTheme.spaceM) {
            Text(String(format: "CRASHED @ %.2fx", round.crashMultiplier ?? 1))
                .font(NQText.microS.font.weight(.heavy))
                .tracking(0.8)
                .foregroundStyle(NQTheme.warning)

            NQIcon.flame.view
                .frame(width: 72, height: 72)
                .foregroundStyle(NQTheme.warning)

            Text("WAGER LOST")
                .font(NQText.displayL.font)
                .foregroundStyle(NQTheme.ink)

            Text("\((round.lostNetWorth ?? round.startingNetWorth).formatted()) NW")
                .font(NQText.headingL.font.weight(.heavy))
                .foregroundStyle(NQTheme.inkMuted)

            Text(round.wager.map(\.character.name).joined(separator: " · "))
                .font(NQText.captionS.font)
                .foregroundStyle(NQTheme.inkFaint)
                .multilineTextAlignment(.center)
        }
        .padding(NQTheme.spaceL)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - The cauldron itself

/// The vessel. Bubbles faster, glows hotter and shakes harder as the
/// multiplier climbs — and only as the multiplier climbs. Nothing here is
/// wired to the crash point, so no amount of watching the animation tells a
/// player when to jump.
struct CauldronVesselView: View {
    let multiplier: Double
    let tint: Color
    let reduceMotion: Bool
    /// Set to the instant the cauldron blew up; nil while the round is live.
    /// The blast animates off this date rather than off a state flag, so it
    /// plays at the same speed regardless of when the view happens to redraw.
    var explodedAt: Date? = nil

    /// 0 at 1.00x, 1 at 10x and beyond. Drives every effect below.
    private var heat: Double {
        min(1, max(0, (multiplier - 1) / 9))
    }

    /// The beat of violent shaking before the burst. Short on purpose: a long
    /// wind-up would imply the player still had time to get out (spec §14).
    private let fuse: Double = 0.14

    var body: some View {
        TimelineView(.animation(minimumInterval: reduceMotion ? 0.5 : 1.0 / 30.0)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate

            ZStack {
                if let explodedAt {
                    explosion(elapsed: max(0, timeline.date.timeIntervalSince(explodedAt)))
                } else {
                    bubblingCauldron(t: t)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .accessibilityHidden(true)
    }

    private func bubblingCauldron(t: Double) -> some View {
        let shake = reduceMotion ? 0 : sin(t * (6 + heat * 22)) * heat * 4
        return ZStack {
            Circle()
                .fill(tint.opacity(0.12 + heat * 0.25))
                .blur(radius: 26)
                .frame(width: 200, height: 200)

            bubbles(t: t)

            vessel
                .offset(x: shake)
        }
    }

    // MARK: - The blast

    private func explosion(elapsed: Double) -> some View {
        let burst = max(0, elapsed - fuse)
        let progress = min(1, burst / 0.9)
        let shaking = elapsed < fuse && !reduceMotion
        let shake = shaking ? sin(elapsed * 170) * 7 : 0
        // The vessel survives the fuse, then is gone in a blink.
        let vesselOpacity = burst > 0 ? max(0, 1 - burst / 0.16) : 1

        return ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [NQTheme.gold.opacity(0.85 * (1 - progress)), .clear],
                        center: .center,
                        startRadius: 0,
                        endRadius: 110
                    )
                )
                .frame(width: 240, height: 240)
                .scaleEffect(0.35 + progress * 1.5)
                .opacity(burst > 0 ? 1 : 0)

            if burst > 0 && !reduceMotion {
                shards(progress)
                smoke(progress)
            }

            vessel
                .offset(x: shake)
                .scaleEffect(1 + progress * 0.22)
                .opacity(vesselOpacity)
        }
    }

    /// Pieces of the pot, thrown outward and pulled back down.
    private func shards(_ progress: Double) -> some View {
        ZStack {
            ForEach(0..<14, id: \.self) { index in
                let angle = Double(index) / 14 * 2 * .pi
                let distance = progress * (72 + Double(index % 4) * 24)
                let gravity = progress * progress * 70
                RoundedRectangle(cornerRadius: 2)
                    .fill(index % 3 == 0 ? tint : NQTheme.inkDeep)
                    .frame(width: 11 - Double(index % 3) * 2, height: 8)
                    .rotationEffect(.degrees(Double(index) * 47 + progress * 240))
                    .offset(x: cos(angle) * distance, y: sin(angle) * distance + gravity)
                    .opacity(1 - progress)
            }
        }
    }

    private func smoke(_ progress: Double) -> some View {
        ZStack {
            ForEach(0..<5, id: \.self) { index in
                Circle()
                    .fill(NQTheme.inkMuted.opacity(0.32 * (1 - progress)))
                    .frame(width: 28 + Double(index) * 7, height: 28 + Double(index) * 7)
                    .offset(
                        x: sin(Double(index) * 1.7) * 32,
                        y: -progress * (55 + Double(index) * 12)
                    )
                    .blur(radius: 7)
            }
        }
    }

    private var vessel: some View {
        ZStack {
            // Bowl
            Path { path in
                path.move(to: CGPoint(x: 24, y: 40))
                path.addCurve(
                    to: CGPoint(x: 136, y: 40),
                    control1: CGPoint(x: 34, y: 132),
                    control2: CGPoint(x: 126, y: 132)
                )
                path.closeSubpath()
            }
            .fill(
                LinearGradient(
                    colors: [NQTheme.chrome, NQTheme.inkDeep],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .frame(width: 160, height: 140)

            // Rim, so the bowl reads as a vessel with a lip rather than a
            // dome with a disc balanced on top.
            Ellipse()
                .strokeBorder(NQTheme.chrome, lineWidth: 5)
                .frame(width: 120, height: 30)
                .offset(y: -30)

            // Brew, lit from within
            Ellipse()
                .fill(
                    RadialGradient(
                        colors: [tint.opacity(0.95), tint.opacity(0.55)],
                        center: .center,
                        startRadius: 4,
                        endRadius: 60
                    )
                )
                .frame(width: 108, height: 24)
                .offset(y: -30)
                .shadow(color: tint.opacity(0.5 + heat * 0.4), radius: 12 + heat * 18)

            // Legs, tucked under the bowl.
            HStack(spacing: 64) {
                Capsule().fill(NQTheme.inkDeep).frame(width: 12, height: 20)
                Capsule().fill(NQTheme.inkDeep).frame(width: 12, height: 20)
            }
            .offset(y: 46)
        }
    }

    /// Bubbles rise faster and more often with heat. Their phase comes from
    /// the clock and their index — never from anything about the round.
    private func bubbles(t: Double) -> some View {
        let count = reduceMotion ? 3 : 4 + Int(heat * 5)
        return ZStack {
            ForEach(0..<count, id: \.self) { index in
                let speed = 0.5 + heat * 1.4 + Double(index % 3) * 0.18
                let phase = (t * speed + Double(index) * 0.37).truncatingRemainder(dividingBy: 1)
                let size = 6.0 + Double(index % 3) * 4 + heat * 5
                Circle()
                    .fill(tint.opacity(0.75 * (1 - phase)))
                    .frame(width: size, height: size)
                    .offset(
                        x: CGFloat(sin(Double(index) * 2.1) * 34),
                        y: CGFloat(-30 - phase * (70 + heat * 40))
                    )
            }
        }
    }
}

// MARK: - Plumbing

extension CauldronRoundDTO: Identifiable {
    var id: String { roundId }
}
