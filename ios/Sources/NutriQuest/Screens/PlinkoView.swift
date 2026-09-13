import SwiftUI
import NutriQuestUI

/// Plinko.
///
/// The simplest game at the table: pick a monster, press DROP, watch. No
/// decisions once the orb is falling, which is the whole appeal — the tension
/// is entirely in the fall.
///
/// The outcome is decided server-side before the first frame, and the server
/// sends back the exact left/right path it rolled. The orb on screen follows
/// that path peg by peg, so the animation is a rendering of the result rather
/// than a performance that happens to agree with it.
struct PlinkoView: View {
    @ObservedObject var gameState: GameState

    @Environment(\.nqAccent) private var accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var selection: String?
    @State private var stage: Stage = .choosingWager
    @State private var sheet: PlinkoSheet?

    /// The drop being animated, and when the orb was released. The board
    /// interpolates everything else from the clock, so the fall is continuous
    /// rather than a step per row.
    @State private var falling: PlinkoDropDTO?
    @State private var releasedAt: Date?
    @State private var orbCondensing = false
    /// Slot lit up once the orb arrives.
    @State private var landedSlot: Int?

    private enum Stage {
        case choosingWager
        case board
    }

    private enum PlinkoSheet: Identifiable {
        case result(PlinkoDropDTO)
        case houseRules

        var id: String {
            switch self {
            case .result(let drop): return drop.dropId
            case .houseRules: return "house-rules"
            }
        }
    }

    private var wagerable: [CasinoMonsterDTO] { gameState.plinkoWagerable }
    private var config: PlinkoConfigResponse? { gameState.plinkoConfig }
    private var pegRows: Int { config?.pegRows ?? 12 }
    private var slotCount: Int { config?.slotCount ?? 13 }
    private var multipliers: [Double] { config?.multipliers ?? [] }

    private var selectedMonster: CasinoMonsterDTO? {
        wagerable.first { $0.id == selection }
    }

    var body: some View {
        ZStack {
            NQAdventureBackdrop().ignoresSafeArea()

            if stage == .board, let monster = selectedMonster ?? falling?.wager {
                boardScreen(monster)
            } else {
                wagerPicker
            }
        }
        .navigationTitle("Plinko")
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
                .accessibilityLabel("How Plinko works")
            }
        }
        .sheet(item: $sheet) { presented in
            switch presented {
            case .result(let drop):
                PlinkoResultView(drop: drop) { sheet = nil }
            case .houseRules:
                NavigationStack { PlinkoRulesView(gameState: gameState) }
            }
        }
        .task {
            await gameState.loadPlinkoConfig()
            await gameState.refreshPlinko()
            applyLaunchStage()
        }
    }

    // MARK: - Step one: pick a monster

    private var wagerPicker: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NQTheme.spaceM) {
                if !gameState.plinkoRecent.isEmpty {
                    historyStrip
                }

                NQSectionHeader("Choose your wager", trailing: selection == nil ? "0/1" : "1/1")

                if wagerable.isEmpty {
                    NQEmptyState(
                        message: "No monsters to drop yet. Open a crate and come back.",
                        icon: .chips,
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

    private var historyStrip: some View {
        VStack(alignment: .leading, spacing: NQTheme.spaceS) {
            NQSectionHeader("Recent drops")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: NQTheme.spaceS) {
                    ForEach(gameState.plinkoRecent) { entry in
                        Text(String(format: "%.2gx", entry.multiplier))
                            .font(NQText.captionS.font.weight(.heavy))
                            .foregroundStyle(entry.multiplier >= 1 ? NQTheme.success : NQTheme.inkMuted)
                            .nqPadding(.chip)
                            .background((entry.multiplier >= 1 ? NQTheme.success : NQTheme.inkFaint).opacity(0.14))
                            .clipShape(Capsule())
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
                        Text("Dropping")
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

            NQButton(selection == nil ? "Pick a monster" : "Continue", icon: .chips) {
                withAnimation(NQMotion.springy) { stage = .board }
            }
            .disabled(selection == nil)
        }
        .padding(NQTheme.spaceL)
        .background(NQTheme.background.ignoresSafeArea(edges: .bottom))
        .nqElevation(.nav)
    }

    // MARK: - Step two: the board

    private func boardScreen(_ monster: CasinoMonsterDTO) -> some View {
        VStack(spacing: NQTheme.spaceM) {
            wagerHeader(monster)

            PlinkoBoardView(
                pegRows: pegRows,
                slotCount: slotCount,
                multipliers: multipliers,
                path: falling?.path,
                releasedAt: releasedAt,
                fallDuration: fallDuration,
                orbTint: Color(hex: monster.character.colorHex),
                landedSlot: landedSlot,
                condensing: orbCondensing,
                reduceMotion: reduceMotion
            )
            .padding(.horizontal, NQTheme.spaceS)
            .frame(maxHeight: .infinity)

            NQButton(falling == nil ? "Drop" : "Falling…", icon: .chips) {
                Task { await performDrop(monster) }
            }
            .disabled(gameState.plinkoBusy || falling != nil)
            .padding(.horizontal, NQTheme.spaceL)
            .padding(.bottom, NQTheme.spaceL)
        }
        .padding(.top, NQTheme.spaceM)
    }

    private func wagerHeader(_ monster: CasinoMonsterDTO) -> some View {
        HStack(spacing: NQTheme.spaceM) {
            CharacterArtwork(
                character: Character(
                    id: monster.character.id,
                    name: monster.character.name,
                    colorHex: monster.character.colorHex,
                    rarity: Rarity(rawValue: monster.character.rarity) ?? .common
                )
            )
            .frame(width: 40, height: 40)
            .opacity(orbCondensing || falling != nil ? 0.25 : 1)

            VStack(alignment: .leading, spacing: 0) {
                Text(monster.character.name)
                    .font(NQText.heading.font)
                    .foregroundStyle(NQTheme.ink)
                Text("\(monster.netWorth.formatted()) NW at stake")
                    .font(NQText.captionS.font)
                    .foregroundStyle(NQTheme.inkMuted)
            }
            Spacer()
            if falling == nil && !gameState.plinkoBusy {
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

    /// How long the orb takes to reach the slots. The spec asks for 3-6
    /// seconds; short enough to keep rounds quick, long enough that the last
    /// few rows are genuinely tense.
    private var fallDuration: Double { reduceMotion ? 0.7 : 3.2 }

    // MARK: - The drop

    private func performDrop(_ monster: CasinoMonsterDTO) async {
        guard falling == nil else { return }

        // Condense the monster into the orb before asking the server, so the
        // wait is inside the animation rather than in front of it.
        withAnimation(.easeIn(duration: reduceMotion ? 0.2 : 0.55)) { orbCondensing = true }
        NQJuice.reveal()

        guard let resolved = await gameState.dropPlinko(dropID: monster.id) else {
            withAnimation(NQMotion.quick) { orbCondensing = false }
            return
        }

        selection = nil
        landedSlot = nil
        falling = resolved
        releasedAt = Date()

        // The board interpolates the whole fall from that release time; all
        // this has to do is tick a haptic per peg row and wait it out.
        let perRow = fallDuration / Double(resolved.path.count)
        for _ in resolved.path {
            try? await Task.sleep(nanoseconds: UInt64(perRow * 1_000_000_000))
            if !reduceMotion { NQHaptic.selection() }
        }

        try? await Task.sleep(nanoseconds: UInt64(0.2 * 1_000_000_000))
        withAnimation(NQMotion.bouncy) { landedSlot = resolved.slot }
        NQJuice.wagerResult(won: !resolved.busted)

        try? await Task.sleep(nanoseconds: UInt64((reduceMotion ? 0.5 : 1.0) * 1_000_000_000))
        gameState.applyPlinkoResult(resolved)
        sheet = .result(resolved)

        falling = nil
        releasedAt = nil
        orbCondensing = false
        stage = .choosingWager
    }

    /// QA hook on the existing `-uiGame` convention: `-uiGame plinko-board`
    /// lands on the board with the first monster chosen, and `plinko-drop`
    /// releases the orb as well, so the fall can be captured without a tap.
    private func applyLaunchStage() {
        guard selection == nil, falling == nil else { return }
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-uiGame"), args.count > i + 1,
              let first = wagerable.first else { return }
        let game = args[i + 1]
        guard game == "plinko-board" || game == "plinko-drop" else { return }

        selection = first.id
        stage = .board
        guard game == "plinko-drop" else { return }
        Task {
            try? await Task.sleep(nanoseconds: 600_000_000)
            await performDrop(first)
        }
    }
}

// MARK: - The board

/// Pegboard, orb and landing slots.
///
/// Knows nothing about odds. It is handed the path the server rolled and the
/// instant the orb was released, and interpolates everything else from the
/// clock — so the fall is continuous and physical-looking while still ending
/// in exactly the slot the server chose. Every wobble here is cosmetic and
/// decays to zero before the orb lands.
struct PlinkoBoardView: View {
    let pegRows: Int
    let slotCount: Int
    let multipliers: [Double]
    /// The server's left/right decisions. nil when no orb is in flight.
    let path: [Bool]?
    let releasedAt: Date?
    let fallDuration: Double
    let orbTint: Color
    let landedSlot: Int?
    let condensing: Bool
    let reduceMotion: Bool

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let slotWidth = width / CGFloat(slotCount)
            let slotHeight = slotWidth * 1.15
            let rowHeight = (geometry.size.height - slotHeight - slotWidth * 0.4)
                / CGFloat(pegRows + 1)

            TimelineView(.animation(minimumInterval: reduceMotion ? 1.0 / 20 : 1.0 / 60)) { timeline in
                let fall = fallState(at: timeline.date)

                ZStack(alignment: .topLeading) {
                    pegs(slotWidth: slotWidth, rowHeight: rowHeight, fall: fall)

                    if let fall {
                        impactRing(fall: fall, slotWidth: slotWidth, rowHeight: rowHeight)
                        orb(fall: fall, slotWidth: slotWidth, rowHeight: rowHeight)
                    } else if condensing {
                        restingOrb(slotWidth: slotWidth, rowHeight: rowHeight)
                    }

                    slots(slotWidth: slotWidth, slotHeight: slotHeight,
                          top: rowHeight * CGFloat(pegRows + 1))
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Plinko board, \(pegRows) peg rows and \(slotCount) landing slots")
    }

    // MARK: - Where the orb is

    /// Everything about the orb at one instant, derived from the release time.
    private struct FallState {
        /// Horizontal position in slot units.
        let column: Double
        /// Vertical position in peg-row units.
        let row: Double
        /// 0 at a peg strike, decaying to 1 by the time the next one lands.
        let sinceImpact: Double
        /// The peg row just struck.
        let lastPegRow: Int
        /// Which way it deflected off that peg.
        let deflectedRight: Bool
        let finished: Bool
    }

    private func fallState(at now: Date) -> FallState? {
        guard let path, let releasedAt, !path.isEmpty else { return nil }

        let elapsed = now.timeIntervalSince(releasedAt)
        guard elapsed >= 0 else { return nil }

        let rows = path.count
        // Gravity: later rows pass quicker, so the orb visibly accelerates
        // down the board instead of ticking along at one speed.
        let progress = min(1, elapsed / fallDuration)
        let travelled = accelerate(progress) * Double(rows)
        let index = min(rows - 1, Int(travelled))
        let t = min(1, travelled - Double(index))

        let from = column(after: index, path: path)
        let to = column(after: index + 1, path: path)

        // The deflection happens fast and then settles, the way a ball leaves
        // a peg: most of the sideways movement is over in the first third.
        let eased = deflect(t)
        var column = from + (to - from) * eased

        // A little residual sway, decaying to nothing so the landing is exact.
        if !reduceMotion {
            let decay = 1 - progress
            column += sin(elapsed * 17 + Double(index)) * 0.035 * decay
        }

        return FallState(
            column: column,
            row: Double(index) + fallWithin(t),
            sinceImpact: t,
            lastPegRow: index,
            deflectedRight: to > from,
            finished: progress >= 1
        )
    }

    /// Column after `steps` of the path have been taken, in slot units.
    private func column(after steps: Int, path: [Bool]) -> Double {
        let taken = path.prefix(max(0, steps))
        let rights = taken.filter { $0 }.count
        let lefts = taken.count - rights
        return Double(slotCount - 1) / 2 + (Double(rights) - Double(lefts)) / 2
    }

    /// Overall acceleration down the board.
    private func accelerate(_ p: Double) -> Double {
        p * (0.55 + 0.45 * p)
    }

    /// Vertical travel between two peg rows: a fall, so it speeds up.
    private func fallWithin(_ t: Double) -> Double {
        t * t * (1.1 - 0.1 * t)
    }

    /// Sideways travel off a peg: quick kick, then settle.
    private func deflect(_ t: Double) -> Double {
        1 - pow(1 - t, 2.6)
    }

    // MARK: - Pieces

    private func pegs(slotWidth: CGFloat, rowHeight: CGFloat, fall: FallState?) -> some View {
        ForEach(0..<pegRows, id: \.self) { row in
            let pegCount = row + 2
            ForEach(0..<pegCount, id: \.self) { peg in
                let centre = CGFloat(slotCount - 1) / 2
                let x = (centre + CGFloat(peg) - CGFloat(pegCount - 1) / 2 + 0.5) * slotWidth
                let struck = isStruck(row: row, x: x, slotWidth: slotWidth, fall: fall)
                Circle()
                    .fill(struck ? orbTint : NQTheme.inkFaint.opacity(0.4))
                    .frame(width: pegSize(slotWidth, struck: struck),
                           height: pegSize(slotWidth, struck: struck))
                    .position(x: x, y: rowHeight * CGFloat(row + 1))
            }
        }
    }

    /// A peg lights up briefly as the orb comes off it.
    private func isStruck(row: Int, x: CGFloat, slotWidth: CGFloat, fall: FallState?) -> Bool {
        guard let fall, !reduceMotion, fall.lastPegRow == row, fall.sinceImpact < 0.35 else {
            return false
        }
        let orbX = (CGFloat(fall.column) + 0.5) * slotWidth
        return abs(orbX - x) < slotWidth * 0.75
    }

    private func pegSize(_ slotWidth: CGFloat, struck: Bool) -> CGFloat {
        let base = max(6, slotWidth * 0.2)
        return struck ? base * 1.7 : base
    }

    /// Shockwave at the peg the orb just came off.
    private func impactRing(fall: FallState, slotWidth: CGFloat, rowHeight: CGFloat) -> some View {
        let spread = fall.sinceImpact / 0.4
        return Circle()
            .strokeBorder(orbTint.opacity(max(0, 0.5 - spread * 0.5)), lineWidth: 2)
            .frame(width: slotWidth * (0.3 + spread * 0.9), height: slotWidth * (0.3 + spread * 0.9))
            .position(
                x: (CGFloat(fall.column) + 0.5) * slotWidth,
                y: rowHeight * CGFloat(fall.lastPegRow + 1)
            )
            .opacity(reduceMotion || spread > 1 ? 0 : 1)
    }

    private func orb(fall: FallState, slotWidth: CGFloat, rowHeight: CGFloat) -> some View {
        let size = slotWidth * 0.66
        // Squashes on impact and stretches as it falls away again.
        let squash = reduceMotion ? 0 : max(0, 0.3 - fall.sinceImpact) / 0.3
        return orbBody(size: size)
            .scaleEffect(x: 1 + squash * 0.28, y: 1 - squash * 0.22)
            .rotationEffect(.degrees(fall.deflectedRight ? fall.sinceImpact * 50 : -fall.sinceImpact * 50))
            .position(
                x: (CGFloat(fall.column) + 0.5) * slotWidth,
                y: rowHeight * CGFloat(fall.row) + rowHeight * 0.5
            )
    }

    private func restingOrb(slotWidth: CGFloat, rowHeight: CGFloat) -> some View {
        orbBody(size: slotWidth * 0.5)
            .position(x: (CGFloat(slotCount - 1) / 2 + 0.5) * slotWidth, y: rowHeight * 0.5)
    }

    private func orbBody(size: CGFloat) -> some View {
        ZStack {
            Circle()
                .fill(orbTint.opacity(0.4))
                .blur(radius: 8)
                .frame(width: size * 1.9, height: size * 1.9)
            Circle()
                .fill(
                    RadialGradient(
                        colors: [.white.opacity(0.95), orbTint],
                        center: .init(x: 0.34, y: 0.3),
                        startRadius: 1,
                        endRadius: size
                    )
                )
                .frame(width: size, height: size)
                .overlay { Circle().strokeBorder(.white.opacity(0.55), lineWidth: 1) }
        }
        .shadow(color: orbTint.opacity(0.55), radius: 10)
    }

    private func slots(slotWidth: CGFloat, slotHeight: CGFloat, top: CGFloat) -> some View {
        ForEach(0..<slotCount, id: \.self) { slot in
            let multiplier = slot < multipliers.count ? multipliers[slot] : 0
            let isLanded = landedSlot == slot

            Text(multiplierLabel(multiplier))
                .font(.system(size: max(10, slotWidth * 0.36), weight: .heavy, design: .rounded))
                .foregroundStyle(isLanded ? NQTheme.background : slotTint(multiplier))
                .minimumScaleFactor(0.55)
                .lineLimit(1)
                .frame(width: slotWidth * 0.94, height: slotHeight)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(isLanded ? slotTint(multiplier) : slotTint(multiplier).opacity(0.18))
                )
                .scaleEffect(isLanded && !reduceMotion ? 1.2 : 1)
                .animation(NQMotion.bouncy, value: isLanded)
                .position(x: (CGFloat(slot) + 0.5) * slotWidth, y: top + slotHeight / 2)
        }
    }

    private func multiplierLabel(_ multiplier: Double) -> String {
        if multiplier == 0 { return "0x" }
        if multiplier >= 10 { return "\(Int(multiplier))x" }
        return multiplier == multiplier.rounded()
            ? "\(Int(multiplier))x"
            : String(format: "%.1fx", multiplier)
    }

    private func slotTint(_ multiplier: Double) -> Color {
        switch multiplier {
        case 0: return NQTheme.warning
        case ..<1: return NQTheme.inkMuted
        case ..<2: return NQTheme.info
        case ..<20: return NQTheme.success
        default: return NQTheme.gold
        }
    }
}

// MARK: - Result

struct PlinkoResultView: View {
    let drop: PlinkoDropDTO
    let onDismiss: () -> Void

    @Environment(\.nqAccent) private var accent

    var body: some View {
        VStack(spacing: NQTheme.spaceL) {
            ScrollView {
                if drop.busted {
                    busted
                } else if let reward = drop.reward {
                    landed(reward)
                }
            }

            NQButton("Back to the board") { onDismiss() }
                .padding(.horizontal, NQTheme.spaceL)
                .padding(.bottom, NQTheme.spaceL)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .nqPageBackground()
        .presentationDetents([.large])
    }

    private func landed(_ reward: CasinoMonsterDTO) -> some View {
        let rarity = Rarity(rawValue: reward.character.rarity) ?? .common
        return VStack(spacing: NQTheme.spaceM) {
            Text(String(format: "LANDED @ %.2fx", drop.multiplier))
                .font(NQText.heading.font.weight(.heavy))
                .tracking(0.8)
                .foregroundStyle(NQTheme.success)

            Text("\(drop.wagerValue.formatted()) NW → \(drop.finalNetWorth.formatted()) NW")
                .font(NQText.headingL.font.weight(.heavy))
                .foregroundStyle(NQTheme.inkMuted)

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
        }
        .padding(NQTheme.spaceL)
        .accessibilityElement(children: .combine)
    }

    private var busted: some View {
        VStack(spacing: NQTheme.spaceM) {
            Text("💥 BUSTED @ 0x")
                .font(NQText.heading.font.weight(.heavy))
                .tracking(0.8)
                .foregroundStyle(NQTheme.warning)

            Text("💥").font(.system(size: 64))

            Text("NO REWARD")
                .font(NQText.displayL.font)
                .foregroundStyle(NQTheme.ink)

            Text("\(drop.wagerValue.formatted()) NW")
                .font(NQText.headingL.font.weight(.heavy))
                .foregroundStyle(NQTheme.inkMuted)

            Text(drop.wager.character.name)
                .font(NQText.captionS.font)
                .foregroundStyle(NQTheme.inkFaint)

            Text("The orb found the centre slot.")
                .font(NQText.microXS.font)
                .foregroundStyle(NQTheme.inkFaint)
        }
        .padding(NQTheme.spaceL)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Rules

struct PlinkoRulesView: View {
    @ObservedObject var gameState: GameState

    @Environment(\.dismiss) private var dismiss
    @Environment(\.nqAccent) private var accent

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NQTheme.spaceL) {
                section("How it works") {
                    ruleLine("One monster per drop. Pressing Drop commits it for good.")
                    ruleLine("The monster condenses into an orb and falls through the pegs.")
                    ruleLine("Whichever slot it lands in decides the multiplier.")
                    ruleLine("Centre slots are far more common, and pay the least.")
                    ruleLine("The outer slots are rare and pay the most.")
                    ruleLine("Final net worth = your monster's worth × the landing multiplier.")
                    ruleLine("A 0x landing means no reward at all.")
                    ruleLine("Any other landing buys one new random monster at that value.")
                }

                if let config = gameState.plinkoConfig {
                    section("The real odds") {
                        Text("Every drop is \(config.pegRows) left-or-right bounces, so there are \(config.totalPaths.formatted()) possible paths. These are the actual chances, not a sample.")
                            .font(NQText.captionS.font)
                            .foregroundStyle(NQTheme.inkMuted)
                            .fixedSize(horizontal: false, vertical: true)

                        ForEach(config.slots.prefix((config.slotCount + 1) / 2)) { slot in
                            HStack {
                                Text(slot.multiplier == 0 ? "0x" : String(format: "%.4gx", slot.multiplier))
                                    .font(NQText.heading.font)
                                    .foregroundStyle(NQTheme.ink)
                                    .frame(minWidth: 56, alignment: .leading)
                                Text(slot.slot == config.slotCount / 2 ? "centre" : "×2 slots")
                                    .font(NQText.microXS.font)
                                    .foregroundStyle(NQTheme.inkFaint)
                                Spacer()
                                Text(String(format: "%.2f%%", slot.probability * 100 * (slot.slot == config.slotCount / 2 ? 1 : 2)))
                                    .font(NQText.caption.font.weight(.bold))
                                    .foregroundStyle(NQTheme.inkMuted)
                            }
                            .accessibilityElement(children: .combine)
                        }

                        Text("Across the whole board the table pays back about \(String(format: "%.1f", config.expectedMultiplier * 100))% — a \(String(format: "%.0f", config.actualHouseEdge * 100))% house edge, the same as the other games.")
                            .font(NQText.microXS.font)
                            .foregroundStyle(NQTheme.inkFaint)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(NQTheme.spaceL)
        }
        .nqPageBackground()
        .navigationTitle("Plinko")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") { dismiss() }
            }
        }
        .task { await gameState.loadPlinkoConfig() }
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
