import SwiftUI
import NutriQuestUI

/// Portal Wheel.
///
/// Pick a monster, pick a colour, watch it go. The wheel has sixteen equal
/// sections and the four colours own unequal numbers of them, so the entire
/// game is visible before a single tap: fewer wedges, longer odds, bigger
/// payout.
///
/// The outcome is decided server-side before the first frame, and the server
/// sends back the exact SECTION the pointer stopped on — not just the winning
/// colour. The wheel on screen turns to that section, which is what keeps the
/// animation a rendering of the result rather than a performance that happens
/// to agree with it. A colour alone would leave the pointer free to stop on any
/// wedge of that colour, and that much latitude is where a fair game starts
/// telling small lies about where the pointer really was.
struct PortalWheelView: View {
    @ObservedObject var gameState: GameState

    @Environment(\.nqAccent) private var accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var selection: String?
    /// The colour bet. Free to change until SPIN, locked after (spec §12).
    @State private var pick: String?
    @State private var stage: Stage = .choosingWager
    @State private var sheet: PortalWheelSheet?

    @State private var phase: SpinPhase = .idle
    /// The spin being animated, and when the wheel started turning. The disc
    /// interpolates its angle from the clock, so the turn is continuous rather
    /// than a sequence of steps.
    @State private var spinning: PortalWheelSpinDTO?
    @State private var spinStartedAt: Date?

    private enum Stage {
        case choosingWager
        case wheel
    }

    /// Spec §14: the monster is pulled in, the wheel turns, the portal opens.
    private enum SpinPhase: Equatable {
        case idle
        /// Monster glowing, being drawn into the core.
        case pulling
        /// Wheel turning towards the winning section.
        case spinning
        /// Winning colour flaring, portal opening.
        case opening
    }

    private enum PortalWheelSheet: Identifiable {
        case result(PortalWheelSpinDTO)
        case houseRules

        var id: String {
            switch self {
            case .result(let spin): return spin.spinId
            case .houseRules: return "house-rules"
            }
        }
    }

    private var wagerable: [CasinoMonsterDTO] { gameState.portalWheelWagerable }
    private var config: PortalWheelConfigResponse? { gameState.portalWheelConfig }
    private var layout: [String] { config?.layout ?? [] }
    private var colors: [PortalColorDTO] { config?.colors ?? [] }

    private var selectedMonster: CasinoMonsterDTO? {
        wagerable.first { $0.id == selection }
    }

    private var pickedColor: PortalColorDTO? {
        colors.first { $0.color == pick }
    }

    /// The wager is committed the moment SPIN is pressed, so the header keeps
    /// showing the monster from the resolved spin once it has left the bank.
    private var displayedMonster: CasinoMonsterDTO? {
        selectedMonster ?? spinning?.wager
    }

    var body: some View {
        ZStack {
            NQAdventureBackdrop().ignoresSafeArea()

            if stage == .wheel, let monster = displayedMonster {
                wheelScreen(monster)
            } else {
                wagerPicker
            }
        }
        .navigationTitle("Portal Wheel")
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
                .accessibilityLabel("How Portal Wheel works")
            }
        }
        .sheet(item: $sheet) { presented in
            switch presented {
            case .result(let spin):
                PortalWheelResultView(spin: spin, palette: colors) { sheet = nil }
            case .houseRules:
                NavigationStack { PortalWheelRulesView(gameState: gameState) }
            }
        }
        .task {
            await gameState.loadPortalWheelConfig()
            await gameState.refreshPortalWheel()
            applyLaunchStage()
        }
    }

    // MARK: - Step one: pick a monster

    private var wagerPicker: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NQTheme.spaceM) {
                if !gameState.portalWheelRecent.isEmpty {
                    historyStrip
                }

                NQSectionHeader("Choose your wager", trailing: selection == nil ? "0/1" : "1/1")

                if wagerable.isEmpty {
                    NQEmptyState(
                        message: "No monsters to wager yet. Open a crate and come back.",
                        icon: .portal,
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
            withAnimation(NQMotion.snappy) { selection = isSelected ? nil : monster.id }
        } label: {
            VStack(spacing: NQTheme.spaceS) {
                CharacterArtwork(character: artwork(for: monster))
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

    private var historyStrip: some View {
        VStack(alignment: .leading, spacing: NQTheme.spaceS) {
            NQSectionHeader("Recent spins")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: NQTheme.spaceS) {
                    ForEach(gameState.portalWheelRecent) { entry in
                        let tint = colorTint(entry.winningColor)
                        HStack(spacing: 4) {
                            Circle()
                                .fill(tint)
                                .frame(width: 7, height: 7)
                            Text(entry.won ? String(format: "%.2fx", entry.multiplier) : "—")
                                .font(NQText.captionS.font.weight(.heavy))
                                .foregroundStyle(entry.won ? NQTheme.success : NQTheme.inkMuted)
                        }
                        .nqPadding(.chip)
                        .background((entry.won ? NQTheme.success : NQTheme.inkFaint).opacity(0.14))
                        .clipShape(Capsule())
                        .accessibilityLabel(
                            entry.won
                                ? "Won \(String(format: "%.2f", entry.multiplier)) times on \(entry.pick)"
                                : "Lost: chose \(entry.pick), \(entry.winningColor) hit"
                        )
                    }
                }
            }
        }
    }

    private var continueBar: some View {
        VStack(spacing: NQTheme.spaceS) {
            if let monster = selectedMonster {
                HStack {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Wagering")
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

            NQButton(selection == nil ? "Pick a monster" : "Continue", icon: .portal) {
                withAnimation(NQMotion.springy) { stage = .wheel }
            }
            .disabled(selection == nil)
        }
        .padding(NQTheme.spaceL)
        .background(NQTheme.background.ignoresSafeArea(edges: .bottom))
        .nqElevation(.nav)
    }

    // MARK: - Step two: the wheel

    private func wheelScreen(_ monster: CasinoMonsterDTO) -> some View {
        ScrollView {
            VStack(spacing: NQTheme.spaceM) {
                wagerHeader(monster)

                PortalWheelDiscView(
                    layout: layout,
                    palette: colors,
                    highlighted: highlightedSections,
                    winningSection: phase == .opening ? spinning?.section : nil,
                    rotation: rotation(at: Date()),
                    spinStartedAt: phase == .spinning ? spinStartedAt : nil,
                    spinDuration: spinDuration,
                    totalSweep: totalSweep,
                    core: coreContents(monster),
                    coreScale: coreScale,
                    coreGlow: phase != .idle,
                    reduceMotion: reduceMotion
                )
                .frame(maxWidth: 320)
                .aspectRatio(1, contentMode: .fit)
                .frame(maxWidth: .infinity)

                if phase == .idle {
                    colorPicker(monster)
                } else {
                    spinStatus
                }
            }
            .padding(.vertical, NQTheme.spaceM)
            .padding(.bottom, 120)
        }
        .safeAreaInset(edge: .bottom) { spinBar(monster) }
    }

    private func wagerHeader(_ monster: CasinoMonsterDTO) -> some View {
        HStack(spacing: NQTheme.spaceM) {
            CharacterArtwork(character: artwork(for: monster))
                .frame(width: 40, height: 40)
                // The monster is in the portal, not in the header, once it goes.
                .opacity(phase == .idle ? 1 : 0.2)

            VStack(alignment: .leading, spacing: 0) {
                Text(monster.character.name)
                    .font(NQText.heading.font)
                    .foregroundStyle(NQTheme.ink)
                Text("\(monster.netWorth.formatted()) NW at stake")
                    .font(NQText.captionS.font)
                    .foregroundStyle(NQTheme.inkMuted)
            }
            Spacer()
            if phase == .idle && !gameState.portalWheelBusy {
                Button("Change") {
                    NQJuice.tap()
                    withAnimation(NQMotion.springy) { stage = .choosingWager }
                }
                .font(NQText.captionS.font.weight(.bold))
            }
        }
        .nqPadding(.card)
        .background(NQTheme.background)
        .clipShape(RoundedRectangle(cornerRadius: NQTheme.radiusL))
        .nqElevation(.card)
        .padding(.horizontal, NQTheme.spaceL)
    }

    /// The four bets, each carrying its own odds (spec §11). Everything shown
    /// here is the server's own published figure — nothing is recomputed on the
    /// client, so the price quoted is the price charged.
    private func colorPicker(_ monster: CasinoMonsterDTO) -> some View {
        VStack(alignment: .leading, spacing: NQTheme.spaceS) {
            NQSectionHeader("Choose your portal", trailing: pick == nil ? "0/1" : "1/1")

            if colors.isEmpty {
                NQEmptyState(message: "Couldn't reach the wheel's odds.", icon: .wifiOff)
            } else {
                ForEach(colors) { option in
                    colorRow(option, wager: monster.netWorth)
                }
            }
        }
        .padding(.horizontal, NQTheme.spaceL)
    }

    private func colorRow(_ option: PortalColorDTO, wager: Int) -> some View {
        let isPicked = pick == option.color
        let tint = Color(hex: option.colorHex)
        let payout = Int((Double(wager) * option.multiplier).rounded(.down))

        return Button {
            NQJuice.tap()
            withAnimation(NQMotion.snappy) { pick = isPicked ? nil : option.color }
        } label: {
            HStack(spacing: NQTheme.spaceM) {
                ZStack {
                    Circle()
                        .fill(tint.opacity(0.2))
                        .frame(width: 44, height: 44)
                    Circle()
                        .strokeBorder(tint, lineWidth: isPicked ? 3 : 1.5)
                        .frame(width: 44, height: 44)
                    Text("\(option.sections)")
                        .font(NQText.heading.font.weight(.heavy))
                        .foregroundStyle(tint)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(option.label.uppercased())
                        .font(NQText.heading.font.weight(.heavy))
                        .tracking(0.8)
                        .foregroundStyle(NQTheme.ink)
                    Text("\(option.sections)/\(option.totalSections) sections · \(percent(option.probability))")
                        .font(NQText.microXS.font)
                        .foregroundStyle(NQTheme.inkMuted)
                }

                Spacer(minLength: NQTheme.spaceS)

                VStack(alignment: .trailing, spacing: 2) {
                    Text(String(format: "%.2fx", option.multiplier))
                        .font(NQText.headingL.font.weight(.heavy))
                        .foregroundStyle(tint)
                    Text("\(payout.formatted()) NW")
                        .font(NQText.microXS.font)
                        .foregroundStyle(NQTheme.inkMuted)
                }
            }
            .nqPadding(.card)
            .frame(maxWidth: .infinity)
            .background(NQTheme.background)
            .clipShape(RoundedRectangle(cornerRadius: NQTheme.radiusL))
            .overlay {
                RoundedRectangle(cornerRadius: NQTheme.radiusL)
                    .strokeBorder(isPicked ? tint : NQTheme.hairline, lineWidth: isPicked ? 3 : 1)
            }
            .nqElevation(.card)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            "\(option.label): \(option.sections) of \(option.totalSections) sections, "
                + "\(percent(option.probability)) chance, pays \(String(format: "%.2f", option.multiplier)) times, "
                + "\(payout) net worth if it wins"
        )
        .accessibilityAddTraits(isPicked ? .isSelected : [])
    }

    /// What the spin is doing, in the space the colour list occupied. Keeps the
    /// layout from jumping while the wheel is the only thing that should move.
    private var spinStatus: some View {
        VStack(spacing: NQTheme.spaceXS) {
            Text(statusHeadline)
                .font(NQText.heading.font.weight(.heavy))
                .tracking(0.8)
                .foregroundStyle(pickedColor.map { Color(hex: $0.colorHex) } ?? NQTheme.ink)
            if let option = pickedColor {
                Text("\(option.label) · \(percent(option.probability)) · \(String(format: "%.2fx", option.multiplier))")
                    .font(NQText.captionS.font)
                    .foregroundStyle(NQTheme.inkMuted)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, NQTheme.spaceM)
        .accessibilityElement(children: .combine)
    }

    private var statusHeadline: String {
        switch phase {
        case .idle: return ""
        case .pulling: return "INTO THE PORTAL…"
        case .spinning: return "SPINNING…"
        case .opening:
            guard let spin = spinning else { return "" }
            return spin.won ? "PORTAL OPENS" : "\(spin.winningColor.uppercased()) HIT"
        }
    }

    /// Potential value preview (spec §27), then SPIN.
    private func spinBar(_ monster: CasinoMonsterDTO) -> some View {
        VStack(spacing: NQTheme.spaceS) {
            if let option = pickedColor, phase == .idle {
                let payout = Int((Double(monster.netWorth) * option.multiplier).rounded(.down))
                HStack {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("POTENTIAL VALUE")
                            .font(NQText.microXS.font)
                            .tracking(0.6)
                            .foregroundStyle(NQTheme.inkMuted)
                        Text("\(payout.formatted()) NW")
                            .font(NQText.headingL.font.weight(.heavy))
                            .foregroundStyle(NQTheme.ink)
                    }
                    Spacer()
                    if let band = rarityBand(for: payout) {
                        Text(band.label.uppercased())
                            .font(NQText.microS.font.weight(.heavy))
                            .tracking(0.8)
                            .foregroundStyle(Color(hex: band.colorHex))
                            .nqPadding(.chip)
                            .background(Color(hex: band.colorHex).opacity(0.16))
                            .clipShape(Capsule())
                    }
                }
                .accessibilityElement(children: .combine)
            }

            NQButton(spinLabel, icon: .portal) {
                Task { await performSpin(monster) }
            }
            .disabled(pick == nil || phase != .idle || gameState.portalWheelBusy)
        }
        .padding(NQTheme.spaceL)
        .background(NQTheme.background.ignoresSafeArea(edges: .bottom))
        .nqElevation(.nav)
    }

    private var spinLabel: String {
        switch phase {
        case .idle: return pick == nil ? "Pick a portal" : "Spin"
        case .pulling: return "Committing…"
        case .spinning: return "Spinning…"
        case .opening: return "Opening…"
        }
    }

    // MARK: - The spin

    /// Spec §28: about a second to commit, a few seconds of wheel, a moment of
    /// portal. Long enough to be dramatic, short enough to spin again.
    private var pullDuration: Double { reduceMotion ? 0.25 : 0.9 }
    private var spinDuration: Double { reduceMotion ? 0.8 : 4.6 }
    private var openDuration: Double { reduceMotion ? 0.4 : 1.4 }

    /// Full turns before the wheel settles. The landing angle is exact either
    /// way; this is only how much wheel the player gets to watch.
    private var spinTurns: Int { reduceMotion ? 1 : 5 }

    /// Total degrees the wheel travels this spin: whole turns plus whatever it
    /// takes to bring the winning section under the fixed pointer.
    private var totalSweep: Double {
        guard let section = spinning?.section, !layout.isEmpty else { return 0 }
        let sectionAngle = 360.0 / Double(layout.count)
        let centre = (Double(section) + 0.5) * sectionAngle
        // The pointer sits at the top, so the wheel has to turn until that
        // section's centre is back at zero.
        let settle = (360 - centre).truncatingRemainder(dividingBy: 360)
        return Double(spinTurns) * 360 + settle
    }

    /// Where the wheel is right now.
    ///
    /// Derived from the clock rather than driven by a SwiftUI animation, so the
    /// angle is a pure function of elapsed time — the same approach the Plinko
    /// board uses, and the reason the wheel cannot overshoot the section the
    /// server chose.
    private func rotation(at now: Date) -> Double {
        guard let started = spinStartedAt else { return phase == .opening ? totalSweep : 0 }
        let elapsed = now.timeIntervalSince(started)
        guard elapsed > 0 else { return 0 }
        let progress = min(1, elapsed / spinDuration)
        return PortalWheelSpinCurve.eased(progress) * totalSweep
    }

    /// Which sections glow: the bet while choosing, the result once it lands.
    private var highlightedSections: [Int] {
        switch phase {
        case .idle, .pulling:
            return pickedColor?.sectionIndexes ?? []
        case .spinning:
            return []
        case .opening:
            guard let spin = spinning else { return [] }
            // Spec §14.9: every wedge of the winning colour flares together.
            return colors.first { $0.color == spin.winningColor }?.sectionIndexes ?? []
        }
    }

    private var coreScale: Double {
        switch phase {
        case .idle: return 1
        case .pulling: return reduceMotion ? 0.6 : 0.15
        case .spinning: return 0.45
        case .opening: return 1.25
        }
    }

    /// What sits in the middle of the wheel: the wager on the way in, the
    /// reward on the way out (spec §18).
    @ViewBuilder
    private func coreContents(_ monster: CasinoMonsterDTO) -> some View {
        if phase == .opening, let reward = spinning?.reward {
            CharacterArtwork(character: artwork(for: reward))
        } else if phase == .opening {
            Text("✕")
                .font(.system(size: 40, weight: .black, design: .rounded))
                .foregroundStyle(NQTheme.warning)
        } else {
            CharacterArtwork(character: artwork(for: monster))
        }
    }

    private func performSpin(_ monster: CasinoMonsterDTO) async {
        guard phase == .idle, let color = pick else { return }

        // Pull the monster into the core before asking the server, so the wait
        // is inside the animation rather than in front of it.
        withAnimation(.easeIn(duration: pullDuration)) { phase = .pulling }
        NQJuice.reveal()

        async let request = gameState.spinPortalWheel(dropID: monster.id, color: color)
        try? await Task.sleep(nanoseconds: UInt64(pullDuration * 1_000_000_000))

        guard let resolved = await request else {
            withAnimation(NQMotion.quick) { phase = .idle }
            return
        }

        selection = nil
        spinning = resolved
        spinStartedAt = Date()
        withAnimation(NQMotion.quick) { phase = .spinning }

        await tickWhileSpinning()

        withAnimation(NQMotion.bouncy) { phase = .opening }
        NQJuice.wagerResult(won: resolved.won)

        try? await Task.sleep(nanoseconds: UInt64(openDuration * 1_000_000_000))
        gameState.applyPortalWheelResult(resolved)
        sheet = .result(resolved)

        phase = .idle
        spinning = nil
        spinStartedAt = nil
        stage = .choosingWager
    }

    /// A click each time the pointer crosses a section, decelerating with the
    /// wheel.
    ///
    /// The crossing times come from inverting the same easing curve the disc
    /// draws with, so the haptics land on the ticks the player can see rather
    /// than on a fixed cadence that would drift out of step near the end. Only
    /// the last couple of turns are ticked — eighty clicks is noise, not feel.
    private func tickWhileSpinning() async {
        let sweep = totalSweep
        guard !reduceMotion, !layout.isEmpty, sweep > 0 else {
            try? await Task.sleep(nanoseconds: UInt64(spinDuration * 1_000_000_000))
            return
        }

        let sectionAngle = 360.0 / Double(layout.count)
        let firstTicked = max(0, sweep - 720)
        var elapsed: Double = 0
        var angle = ceil(firstTicked / sectionAngle) * sectionAngle

        while angle < sweep {
            let at = PortalWheelSpinCurve.easedInverse(angle / sweep) * spinDuration
            if at > elapsed {
                try? await Task.sleep(nanoseconds: UInt64((at - elapsed) * 1_000_000_000))
                elapsed = at
                NQHaptic.selection()
            }
            angle += sectionAngle
        }

        if elapsed < spinDuration {
            try? await Task.sleep(nanoseconds: UInt64((spinDuration - elapsed) * 1_000_000_000))
        }
    }

    // MARK: - Helpers

    private func artwork(for monster: CasinoMonsterDTO) -> Character {
        Character(
            id: monster.character.id,
            name: monster.character.name,
            colorHex: monster.character.colorHex,
            rarity: Rarity(rawValue: monster.character.rarity) ?? .common,
            statType: StatType(rawValue: monster.character.statType) ?? .fiber,
            isShiny: monster.shiny
        )
    }

    private func colorTint(_ color: String) -> Color {
        colors.first { $0.color == color }.map { Color(hex: $0.colorHex) } ?? NQTheme.inkFaint
    }

    /// Which rarity band a net worth lands in, using the server's own ranges —
    /// the preview must not invent a band the economy would disagree with.
    private func rarityBand(for netWorth: Int) -> CauldronRarityRangeDTO? {
        config?.rarityRanges.first { range in
            netWorth >= range.min && (range.max.map { netWorth <= $0 } ?? true)
        }
    }

    private func percent(_ value: Double) -> String {
        String(format: "%.2f%%", value * 100)
    }

    /// QA hook on the existing `-uiGame` convention: `-uiGame wheel-board`
    /// lands on the wheel with the first monster and a colour chosen, and
    /// `wheel-spin` commits it too, so the spin can be captured without a tap.
    private func applyLaunchStage() {
        guard selection == nil, phase == .idle else { return }
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-uiGame"), args.count > i + 1,
              let first = wagerable.first else { return }
        let game = args[i + 1]
        guard game == "wheel-board" || game == "wheel-spin" else { return }

        selection = first.id
        pick = pick ?? "green"
        stage = .wheel
        guard game == "wheel-spin" else { return }
        Task {
            try? await Task.sleep(nanoseconds: 600_000_000)
            await performSpin(first)
        }
    }
}

// MARK: - The spin curve

/// How the wheel decelerates.
///
/// Its own type rather than a member of the disc view: the screen needs the
/// curve to work out when the pointer crosses each section, and asking a
/// generic view for a static function means naming its generic parameter for no
/// reason. The inverse lives beside the curve so the two cannot drift.
enum PortalWheelSpinCurve {
    /// Starts fast, coasts to a stop — spec §28's "fast spin then slowdown" as
    /// one continuous function rather than two phases stitched at a seam.
    static let exponent: Double = 3.4

    static func eased(_ progress: Double) -> Double {
        1 - pow(1 - min(1, max(0, progress)), exponent)
    }

    /// Given how far round the wheel has travelled, when it got there.
    static func easedInverse(_ fraction: Double) -> Double {
        1 - pow(1 - min(1, max(0, fraction)), 1 / exponent)
    }
}

// MARK: - The wheel

/// The portal wheel: sixteen equal wedges, a fixed pointer, and a core.
///
/// Knows nothing about odds. It is handed the section layout and an angle, and
/// draws exactly that — every wedge the same size, because on this wheel every
/// wedge really is equally likely (spec §22). A wedge drawn wider than its
/// probability would be the one lie this game cannot afford.
struct PortalWheelDiscView<Core: View>: View {
    let layout: [String]
    let palette: [PortalColorDTO]
    /// Sections to light up: the bet, or the winning colour once it lands.
    let highlighted: [Int]
    /// The section the pointer stopped on, once the wheel has settled.
    let winningSection: Int?
    /// Fallback angle, used when no spin is in flight.
    let rotation: Double
    /// Non-nil while the wheel is turning; the clock drives the angle then.
    let spinStartedAt: Date?
    let spinDuration: Double
    let totalSweep: Double
    let core: Core
    let coreScale: Double
    let coreGlow: Bool
    let reduceMotion: Bool

    var body: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height)
            let centre = CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2)
            let outer = side / 2 - side * 0.045
            let inner = side * 0.19

            TimelineView(.animation(minimumInterval: reduceMotion ? 1.0 / 20 : 1.0 / 60)) { timeline in
                let angle = currentRotation(at: timeline.date)

                ZStack {
                    energyHalo(side: side)

                    wedges(centre: centre, outer: outer, inner: inner)
                        .rotationEffect(.degrees(angle))

                    rim(side: side)
                    coreView(side: side)
                    pointer(centre: centre, outer: outer, side: side)
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Portal wheel with \(layout.count) equal sections")
    }

    private func currentRotation(at now: Date) -> Double {
        guard let started = spinStartedAt, spinDuration > 0 else { return rotation }
        let elapsed = now.timeIntervalSince(started)
        guard elapsed > 0 else { return 0 }
        return PortalWheelSpinCurve.eased(elapsed / spinDuration) * totalSweep
    }

    // MARK: - Pieces

    /// Magical energy around the wheel (spec §6). Breathes while a spin is
    /// live, still otherwise.
    private func energyHalo(side: CGFloat) -> some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [NQTheme.gold.opacity(coreGlow ? 0.22 : 0.12), .clear],
                    center: .center,
                    startRadius: side * 0.28,
                    endRadius: side * 0.56
                )
            )
            .blur(radius: 12)
    }

    private func wedges(centre: CGPoint, outer: CGFloat, inner: CGFloat) -> some View {
        ZStack {
            ForEach(Array(layout.enumerated()), id: \.offset) { index, color in
                let tint = tint(for: color)
                let isLit = highlighted.contains(index)
                let isWinner = winningSection == index

                wedgePath(index: index, centre: centre, outer: outer, inner: inner)
                    .fill(
                        LinearGradient(
                            colors: [tint.opacity(isLit ? 0.98 : 0.62), tint.opacity(isLit ? 0.72 : 0.34)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .overlay {
                        wedgePath(index: index, centre: centre, outer: outer, inner: inner)
                            .stroke(
                                isWinner ? Color.white : Color.white.opacity(isLit ? 0.7 : 0.22),
                                lineWidth: isWinner ? 3 : 1
                            )
                    }
                    .shadow(color: isLit ? tint.opacity(0.8) : .clear, radius: isWinner ? 14 : 6)
            }
        }
    }

    /// One equal section. Every wedge is `360 / count` degrees wide, full stop.
    private func wedgePath(index: Int, centre: CGPoint, outer: CGFloat, inner: CGFloat) -> Path {
        guard !layout.isEmpty else { return Path() }
        let step = 360.0 / Double(layout.count)
        // Angles run from the top, clockwise, because that is where the pointer
        // is and how the sections are numbered.
        let start = Angle.degrees(-90 + Double(index) * step)
        let end = Angle.degrees(-90 + Double(index + 1) * step)

        var path = Path()
        path.addArc(center: centre, radius: outer, startAngle: start, endAngle: end, clockwise: false)
        path.addArc(center: centre, radius: inner, startAngle: end, endAngle: start, clockwise: true)
        path.closeSubpath()
        return path
    }

    /// The portal mechanism the sections sit inside.
    private func rim(side: CGFloat) -> some View {
        ZStack {
            Circle()
                .strokeBorder(NQTheme.ink.opacity(0.16), lineWidth: side * 0.022)
            Circle()
                .strokeBorder(NQTheme.gold.opacity(0.45), lineWidth: 1.5)
                .padding(side * 0.035)
        }
    }

    /// The central portal core, with whatever is passing through it.
    private func coreView(side: CGFloat) -> some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            .white.opacity(coreGlow ? 0.8 : 0.7),
                            NQTheme.gold.opacity(coreGlow ? 0.75 : 0.25)
                        ],
                        center: .center,
                        startRadius: 1,
                        endRadius: side * 0.2
                    )
                )
                .frame(width: side * 0.38, height: side * 0.38)
                .overlay {
                    Circle().strokeBorder(NQTheme.gold.opacity(0.7), lineWidth: 2)
                }
                .shadow(color: NQTheme.gold.opacity(coreGlow ? 0.7 : 0.2), radius: coreGlow ? 18 : 6)

            core
                .frame(width: side * 0.26, height: side * 0.26)
                .clipShape(Circle())
                .scaleEffect(coreScale)
                .opacity(coreScale < 0.25 ? 0 : 1)
                .animation(reduceMotion ? .none : NQMotion.springy, value: coreScale)
        }
    }

    /// The fixed result indicator (spec §24). It never moves: the wheel turns
    /// beneath it, which is what makes the result readable.
    private func pointer(centre: CGPoint, outer: CGFloat, side: CGFloat) -> some View {
        let width = side * 0.075
        return Path { path in
            let tipY = centre.y - outer + side * 0.012
            path.move(to: CGPoint(x: centre.x, y: tipY + width * 1.25))
            path.addLine(to: CGPoint(x: centre.x - width / 2, y: tipY - width * 0.3))
            path.addLine(to: CGPoint(x: centre.x + width / 2, y: tipY - width * 0.3))
            path.closeSubpath()
        }
        .fill(NQTheme.gold)
        .overlay {
            Circle()
                .fill(NQTheme.gold)
                .frame(width: width * 0.5, height: width * 0.5)
                .position(x: centre.x, y: centre.y - outer - width * 0.35)
        }
        .shadow(color: NQTheme.gold.opacity(0.6), radius: 6)
    }

    private func tint(for color: String) -> Color {
        palette.first { $0.color == color }.map { Color(hex: $0.colorHex) } ?? NQTheme.inkFaint
    }
}

// MARK: - Result

struct PortalWheelResultView: View {
    let spin: PortalWheelSpinDTO
    let palette: [PortalColorDTO]
    let onDismiss: () -> Void

    @Environment(\.nqAccent) private var accent

    var body: some View {
        VStack(spacing: NQTheme.spaceL) {
            ScrollView {
                if let reward = spin.reward, spin.won {
                    won(reward)
                } else {
                    lost
                }
            }

            NQButton("Back to the wheel") { onDismiss() }
                .padding(.horizontal, NQTheme.spaceL)
                .padding(.bottom, NQTheme.spaceL)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .nqPageBackground()
        .presentationDetents([.large])
    }

    private func won(_ reward: CasinoMonsterDTO) -> some View {
        let rarity = Rarity(rawValue: reward.character.rarity) ?? .common
        return VStack(spacing: NQTheme.spaceM) {
            Text("\(label(spin.winningColor).uppercased()) PORTAL · \(String(format: "%.2fx", spin.multiplier))")
                .font(NQText.heading.font.weight(.heavy))
                .tracking(0.8)
                .foregroundStyle(tint(spin.winningColor))

            Text("\(spin.wagerValue.formatted()) NW → \(spin.finalNetWorth.formatted()) NW")
                .font(NQText.headingL.font.weight(.heavy))
                .foregroundStyle(NQTheme.inkMuted)

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
            .background {
                Circle()
                    .fill(tint(spin.winningColor).opacity(0.25))
                    .blur(radius: 22)
            }

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

            Text("\(spin.wager.character.name) went into the portal and did not come back.")
                .font(NQText.microXS.font)
                .foregroundStyle(NQTheme.inkFaint)
                .multilineTextAlignment(.center)
        }
        .padding(NQTheme.spaceL)
        .accessibilityElement(children: .combine)
    }

    /// Spec §17: name the colour that hit, name the colour that was chosen, and
    /// say plainly that the wager is gone.
    private var lost: some View {
        VStack(spacing: NQTheme.spaceM) {
            Text("\(label(spin.winningColor).uppercased()) HIT")
                .font(NQText.heading.font.weight(.heavy))
                .tracking(0.8)
                .foregroundStyle(tint(spin.winningColor))

            HStack(spacing: NQTheme.spaceM) {
                portalDot(spin.pick, caption: "You chose")
                Text("→")
                    .font(NQText.headingL.font)
                    .foregroundStyle(NQTheme.inkFaint)
                portalDot(spin.winningColor, caption: "Wheel gave")
            }
            .padding(.vertical, NQTheme.spaceS)

            Text("WAGER LOST")
                .font(NQText.displayL.font)
                .foregroundStyle(NQTheme.ink)

            Text("\(spin.wagerValue.formatted()) NW")
                .font(NQText.headingL.font.weight(.heavy))
                .foregroundStyle(NQTheme.inkMuted)

            Text(spin.wager.character.name)
                .font(NQText.captionS.font)
                .foregroundStyle(NQTheme.inkFaint)

            Text("The portal closed on a different colour. No reward.")
                .font(NQText.microXS.font)
                .foregroundStyle(NQTheme.inkFaint)
        }
        .padding(NQTheme.spaceL)
        .accessibilityElement(children: .combine)
    }

    private func portalDot(_ color: String, caption: String) -> some View {
        VStack(spacing: NQTheme.spaceXS) {
            Circle()
                .fill(tint(color).opacity(0.28))
                .frame(width: 54, height: 54)
                .overlay { Circle().strokeBorder(tint(color), lineWidth: 2) }
            Text(label(color).uppercased())
                .font(NQText.microS.font.weight(.heavy))
                .foregroundStyle(tint(color))
            Text(caption)
                .font(NQText.microXS.font)
                .foregroundStyle(NQTheme.inkFaint)
        }
    }

    private func tint(_ color: String) -> Color {
        palette.first { $0.color == color }.map { Color(hex: $0.colorHex) } ?? NQTheme.inkFaint
    }

    private func label(_ color: String) -> String {
        palette.first { $0.color == color }?.label ?? color
    }
}

// MARK: - Rules

/// The published rules, straight from the server's own config endpoint. The
/// table is generated from the wheel that is actually in play (spec §26), so it
/// cannot end up describing a wheel that was retuned last week.
struct PortalWheelRulesView: View {
    @ObservedObject var gameState: GameState

    @Environment(\.dismiss) private var dismiss
    @Environment(\.nqAccent) private var accent

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NQTheme.spaceL) {
                section("How it works") {
                    ruleLine("Wager one monster and pick one portal: blue, red, yellow or green.")
                    ruleLine("Each colour owns a different number of sections on the wheel.")
                    ruleLine("Fewer sections means a lower chance but a larger multiplier.")
                    ruleLine("More sections means a higher chance but a smaller multiplier.")
                    ruleLine("Only the colour you picked wins. Landing next to it is a loss.")
                    ruleLine("Pressing Spin commits the monster for good.")
                    ruleLine("Final net worth = your monster's worth × the winning multiplier.")
                    ruleLine("Losing gives no reward at all.")
                    ruleLine("Winning creates one new random monster at that value.")
                }

                if let config = gameState.portalWheelConfig {
                    section("The real odds") {
                        Text("The wheel has \(config.totalSections) equal sections. These are the actual counts, not a sample — the wedges you see are the odds.")
                            .font(NQText.captionS.font)
                            .foregroundStyle(NQTheme.inkMuted)
                            .fixedSize(horizontal: false, vertical: true)

                        ForEach(config.colors) { entry in
                            HStack(spacing: NQTheme.spaceS) {
                                Circle()
                                    .fill(Color(hex: entry.colorHex))
                                    .frame(width: 10, height: 10)
                                Text(entry.label)
                                    .font(NQText.heading.font)
                                    .foregroundStyle(NQTheme.ink)
                                    .frame(minWidth: 54, alignment: .leading)
                                Text("\(entry.sections)/\(entry.totalSections)")
                                    .font(NQText.microXS.font)
                                    .foregroundStyle(NQTheme.inkFaint)
                                Spacer()
                                Text(String(format: "%.2f%%", entry.probability * 100))
                                    .font(NQText.caption.font.weight(.bold))
                                    .foregroundStyle(NQTheme.inkMuted)
                                Text(String(format: "%.2fx", entry.multiplier))
                                    .font(NQText.caption.font.weight(.heavy))
                                    .foregroundStyle(Color(hex: entry.colorHex))
                                    .frame(minWidth: 52, alignment: .trailing)
                            }
                            .accessibilityElement(children: .combine)
                        }

                        Text("Every payout is (1 − edge) ÷ chance, at a \(String(format: "%.0f", config.houseEdge * 100))% house edge — the same as the other games.")
                            .font(NQText.microXS.font)
                            .foregroundStyle(NQTheme.inkFaint)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    section("Rarity brackets") {
                        Text("Where your final net worth lands decides which monster comes out of the portal.")
                            .font(NQText.captionS.font)
                            .foregroundStyle(NQTheme.inkMuted)
                        ForEach(config.rarityRanges) { range in
                            HStack {
                                Circle()
                                    .fill(Color(hex: range.colorHex))
                                    .frame(width: 10, height: 10)
                                Text(range.label)
                                    .font(NQText.heading.font)
                                    .foregroundStyle(NQTheme.ink)
                                Spacer()
                                Text(range.max.map { "\(range.min.formatted())–\($0.formatted())" }
                                     ?? "\(range.min.formatted())+")
                                    .font(NQText.caption.font.weight(.bold))
                                    .foregroundStyle(NQTheme.inkMuted)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }

                    section("How the winning section is drawn") {
                        Text(config.howItWorks)
                            .font(NQText.captionS.font)
                            .foregroundStyle(NQTheme.inkMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(NQTheme.spaceL)
        }
        .nqPageBackground()
        .navigationTitle("Portal Wheel")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") { dismiss() }
            }
        }
        .task { await gameState.loadPortalWheelConfig() }
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
