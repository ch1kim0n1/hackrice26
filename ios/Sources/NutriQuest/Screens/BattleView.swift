import SwiftUI
import BattleKit
import NutriQuestUI

/// What drives a battle screen:
///  - `.ranked`   — POST /battle/simulate resolves authoritatively, then the
///                  returned event stream animates turn by turn.
///  - `.lan`      — the group host already resolved the match; the replay is
///                  handed in verbatim.
///  - `.practice` — a live local `Battle`: the player picks every action for
///                  their side (move buttons with accuracy/mana, voluntary
///                  switches), the rival runs the engine's auto policy.
enum BattleMode {
    case ranked
    case lan(LANBattleContext)
    case practice
}

struct LANBattleContext {
    let replay: BattleReplay
    let opponentName: String
    /// Which engine side you were (0 or 1). Your squad is always drawn at the
    /// bottom, so only the win check and side attribution need it.
    let mySide: Int
    /// Replay unit id → on-screen character id, for side and damage attribution.
    let unitCharacterIDs: [String: String]
    /// Exact unit snapshots from the wire — powers HP bars and mana readouts.
    let unitSpecs: [String: BattleUnitSpec]
}

struct BattleView: View {
    var yourSquad: [Character]
    var opponentSquad: [Character]
    @ObservedObject var gameState: GameState
    var mode: BattleMode = .ranked

    // MARK: - Screen state

    @State private var running = false
    @State private var resultText: String?
    @State private var simulateTrigger = 0
    @State private var defeatTrigger = 0
    /// Pre-battle lead picker (ranked/practice): tap a bench unit to lead.
    @State private var orderedSquad: [Character] = []

    /// Live engine handle — practice mode only.
    @State private var battle: Battle?
    /// Replay cursor for ranked/LAN animation.
    @State private var replayCursor = 0

    /// Presentation state derived from the event stream.
    @State private var scene = BattleScene()

    // Choreography beats.
    @State private var yourLunge = false
    @State private var opponentLunge = false
    @State private var opponentHit = false
    @State private var yourHit = false
    @State private var damagePopups: [BattlePopup] = []
    @State private var impactTrigger = 0

    struct BattlePopup: Identifiable {
        let id = UUID()
        let text: String
        let color: Color
        let side: Int   // 0 = your squad, 1 = opponent
    }

    @Environment(\.nqAccent) private var accent
    @Environment(\.dismiss) private var dismiss

    // MARK: - Derived

    private var lanContext: LANBattleContext? {
        if case .lan(let context) = mode { return context }
        return nil
    }

    private var isPractice: Bool {
        if case .practice = mode { return true }
        return false
    }

    private var displayedSquad: [Character] {
        orderedSquad.isEmpty ? yourSquad : orderedSquad
    }

    /// Engine side rendered at the bottom (yours). 0 for ranked/practice.
    private var myEngineSide: Int { lanContext?.mySide ?? 0 }

    /// The unit ids fighting for each engine side, in squad order.
    private var sideUnitIDs: [[String]] {
        if let lan = lanContext {
            // LAN unit ids are derived (match, side, slot) uuids; order = squad order.
            var out: [[String]] = [[], []]
            for (slot, u) in lan.unitSpecs.sorted(by: { $0.key < $1.key }).enumerated() { _ = (slot, u) }
            out = [[], []]
            // Rebuild deterministically from the id map: ids group by which
            // character they resolve to; my characters → my side.
            var mine: [String] = [], theirs: [String] = []
            for (unitID, charID) in lan.unitCharacterIDs {
                if yourSquad.contains(where: { $0.id == charID }) { mine.append(unitID) }
                else { theirs.append(unitID) }
            }
            // Squad order comes from the character order we know.
            mine.sort { a, b in
                (yourSquad.firstIndex { $0.id == lan.unitCharacterIDs[a] } ?? 0)
                    < (yourSquad.firstIndex { $0.id == lan.unitCharacterIDs[b] } ?? 0)
            }
            theirs.sort { a, b in
                (opponentSquad.firstIndex { $0.id == lan.unitCharacterIDs[a] } ?? 0)
                    < (opponentSquad.firstIndex { $0.id == lan.unitCharacterIDs[b] } ?? 0)
            }
            out[myEngineSide] = mine
            out[1 - myEngineSide] = theirs
            return out
        }
        return [displayedSquad.map(\.id), opponentSquad.map(\.id)]
    }

    /// Best-known snapshot per unit id — real specs where we have them.
    private var specByUnitID: [String: BattleUnitSpec] {
        if let lan = lanContext { return lan.unitSpecs }
        var map: [String: BattleUnitSpec] = [:]
        for c in yourSquad + opponentSquad { map[c.id] = gameState.battleStats(for: c) }
        return map
    }

    private func name(for unitID: String) -> String {
        let charID = lanContext?.unitCharacterIDs[unitID] ?? unitID
        return (yourSquad + opponentSquad).first { $0.id == charID }?.name
            ?? specByUnitID[unitID]?.name ?? "???"
    }

    private func character(for unitID: String) -> Character? {
        let charID = lanContext?.unitCharacterIDs[unitID] ?? unitID
        return (yourSquad + opponentSquad).first { $0.id == charID }
    }

    /// Which engine side a unit fights for, or -1 if unknown.
    private func side(of unitID: String) -> Int {
        if sideUnitIDs[0].contains(unitID) { return 0 }
        if sideUnitIDs[1].contains(unitID) { return 1 }
        return -1
    }

    var body: some View {
        ScrollView {
            VStack(spacing: NQTheme.spaceL - 2) {
                turnBanner
                arena
                actionSection
                if isPractice { switchRow }
                secondaryActions
            }
            .padding(NQTheme.spaceL)
        }
        .nqSceneBackground(GameArt.scene("battle"))
        .navigationTitle(navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .preferredColorScheme(.dark)
        .nqSuccessBurst(on: simulateTrigger)
        .onAppear {
            if orderedSquad.isEmpty { orderedSquad = yourSquad }
            resetScene()
        }
    }

    private var navigationTitle: String {
        switch mode {
        case .lan: return "LAN Battle"
        case .practice: return "Practice Battle"
        case .ranked: return "Ranked Battle"
        }
    }

    // MARK: - Banner

    private var turnBanner: some View {
        Text(bannerText)
            .font(NQText.captionS.font.weight(.heavy))
            .tracking(0.6)
            .foregroundStyle(accent.accent.readableTextColor())
            .nqPadding(.badge)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background {
                Capsule()
                    .fill(LinearGradient(colors: [accent.accent, accent.accentDark], startPoint: .top, endPoint: .bottom))
                    .nqElevation(.card)
            }
            .contentTransition(.opacity)
            .animation(NQMotion.quick, value: bannerText)
            .accessibilityAddTraits(.isHeader)
    }

    private var bannerText: String {
        if let resultText { return resultText.hasPrefix("VICTORY") ? "Victory" : "Defeat" }
        if running { return scene.turn > 0 ? "Turn \(scene.turn)" : "Battling…" }
        if isPractice, let battle, battle.currentSide == myEngineSide { return "Your move" }
        return "Ready"
    }

    // MARK: - Arena (one active per side + bench)

    private var arena: some View {
        VStack(spacing: NQTheme.spaceM) {
            sideBlock(side: 1 - myEngineSide, label: opponentLabel, fromTop: true)
                .offset(y: opponentLunge ? 14 : 0)
                .scaleEffect(x: opponentLunge ? 1.05 : 1, y: opponentLunge ? 0.95 : 1)
                .overlay { popupLayer(side: 1) }
            vsDivider
            sideBlock(side: myEngineSide, label: "YOUR SQUAD", fromTop: false)
                .offset(y: yourLunge ? -14 : 0)
                .scaleEffect(x: yourLunge ? 1.05 : 1, y: yourLunge ? 0.94 : 1)
                .overlay { popupLayer(side: 0) }
            // Latest event, one line — the play-by-play.
            Text(scene.lastAction)
                .font(NQText.captionS.font.weight(.semibold))
                .foregroundStyle(NQTheme.battleInkMuted)
                .frame(maxWidth: .infinity)
                .multilineTextAlignment(.center)
                .animation(NQMotion.quick, value: scene.lastAction)
        }
        .animation(.spring(response: 0.28, dampingFraction: 0.6), value: yourLunge)
        .animation(.spring(response: 0.28, dampingFraction: 0.6), value: opponentLunge)
        .animation(.easeOut(duration: 0.18), value: opponentHit)
        .animation(.easeOut(duration: 0.18), value: yourHit)
        .nqPadding(.card)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: NQTheme.radiusXL + 2)
                .fill(LinearGradient(colors: [accent.accentSoft, NQTheme.background], startPoint: .topLeading, endPoint: .bottomTrailing))
        )
        .overlay {
            if resultText?.hasPrefix("DEFEAT") == true {
                RoundedRectangle(cornerRadius: NQTheme.radiusXL + 2)
                    .strokeBorder(NQTheme.warning.opacity(0.6), lineWidth: 2)
                    .transition(.opacity)
            }
        }
        .nqImpactShake(on: impactTrigger, intensity: 7)
        .nqShake(on: defeatTrigger)
    }

    private var opponentLabel: String {
        guard let lanContext else { return "OPPONENT · RIVAL SQUAD" }
        return "OPPONENT · \(lanContext.opponentName.uppercased())"
    }

    /// One side of the arena: the active unit large, the bench behind it.
    private func sideBlock(side: Int, label: String, fromTop: Bool) -> some View {
        let ids = sideUnitIDs[side]
        let activeID = ids.indices.contains(scene.active[side]) ? ids[scene.active[side]] : ids.first
        return VStack(alignment: .leading, spacing: NQTheme.spaceS) {
            Text(label)
                .font(NQText.microS.font)
                .tracking(0.4)
                .foregroundStyle(NQTheme.battleInkMuted)

            if let activeID, let unit = scene.units[activeID] {
                activeCard(unitID: activeID, unit: unit, side: side)
            }

            HStack(spacing: NQTheme.spaceS) {
                ForEach(ids, id: \.self) { id in
                    if id != activeID, let unit = scene.units[id] {
                        benchChip(unitID: id, unit: unit)
                    }
                }
            }
        }
        .overlay {
            let hurt = side == 0 ? yourHit : opponentHit
            if hurt {
                RoundedRectangle(cornerRadius: NQTheme.radiusM)
                    .fill((side == 0 ? NQTheme.warning : NQTheme.battleRival).opacity(0.22))
                    .allowsHitTesting(false)
            }
        }
    }

    /// The active unit: artwork, HP bar, mana bar (Epic+), status chips.
    private func activeCard(unitID: String, unit: BattleScene.Unit, side: Int) -> some View {
        HStack(spacing: NQTheme.spaceM) {
            characterArtwork(unitID: unitID, hurt: (side == 0 && yourHit) || (side == 1 && opponentHit), fainted: unit.fainted)
                .frame(width: 64, height: 84)
            VStack(alignment: .leading, spacing: 4) {
                Text(name(for: unitID))
                    .font(NQText.caption.font.weight(.bold))
                    .foregroundStyle(NQTheme.battleInk)
                    .lineLimit(1)
                hpBar(unit: unit)
                if unit.maxMana > 0 {
                    manaBar(unit: unit)
                }
                if !unit.statuses.isEmpty {
                    statusChips(unit)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func hpBar(unit: BattleScene.Unit) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.14))
                    Capsule().fill(unit.hpFraction > 0.35 ? NQTheme.success : NQTheme.warning)
                        .frame(width: max(4, geo.size.width * unit.hpFraction))
                }
            }
            .frame(height: 8)
            .animation(NQMotion.fill, value: unit.hp)
            Text("HP \(Int(unit.hp))/\(Int(unit.maxHP))")
                .font(NQText.micro.font.weight(.semibold))
                .foregroundStyle(NQTheme.battleInkMuted)
                .monospacedDigit()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(Int(unit.hp)) of \(Int(unit.maxHP)) HP")
    }

    private func manaBar(unit: BattleScene.Unit) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "bolt.fill")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(NQTheme.info)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.14))
                    Capsule().fill(NQTheme.info)
                        .frame(width: max(4, geo.size.width * min(1, unit.mana / unit.maxMana)))
                }
            }
            .frame(height: 5)
            Text("\(Int(unit.mana))")
                .font(NQText.micro.font.weight(.bold))
                .foregroundStyle(NQTheme.info)
                .monospacedDigit()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(Int(unit.mana)) mana")
    }

    private func statusChips(_ unit: BattleScene.Unit) -> some View {
        HStack(spacing: 4) {
            ForEach(unit.statuses.sorted(by: { $0.rawValue < $1.rawValue }), id: \.self) { kind in
                Text(kind.displayName)
                    .font(NQText.microXS.font.weight(.heavy))
                    .foregroundStyle(kind.tint)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(kind.tint.opacity(0.16)))
            }
        }
    }

    /// A benched unit: portrait + HP sliver; dimmed once fainted.
    private func benchChip(unitID: String, unit: BattleScene.Unit) -> some View {
        VStack(spacing: 4) {
            characterArtwork(unitID: unitID, fainted: unit.fainted)
                .frame(width: 40, height: 52)
                .opacity(unit.fainted ? 0.35 : 1)
                .saturation(unit.fainted ? 0 : 1)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.14))
                    Capsule().fill(unit.fainted ? NQTheme.inkFaint : NQTheme.success)
                        .frame(width: max(3, geo.size.width * unit.hpFraction))
                }
            }
            .frame(height: 4)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name(for: unitID))\(unit.fainted ? ", fainted" : "")")
    }

    @ViewBuilder private func characterArtwork(unitID: String, hurt: Bool = false, fainted: Bool = false) -> some View {
        let expression: ChibiExpression = {
            if resultText?.hasPrefix("VICTORY") == true { return .sparkle }
            if resultText?.hasPrefix("DEFEAT") == true { return .sleepy }
            if fainted { return .sleepy }
            return hurt ? .hurt : .happy
        }()
        if let character = character(for: unitID) {
            CharacterArtwork(character: character, expression: expression, hurt: hurt || fainted)
        } else {
            ChibiCharacterView(color: NQCharacterColor(name: name(for: unitID), base: NQTheme.inkMuted), statType: .fiber, expression: expression)
        }
    }

    private func popupLayer(side: Int) -> some View {
        ZStack {
            ForEach(damagePopups.filter { $0.side == side }) { popup in
                NQFloatingValue(text: popup.text, color: popup.color, id: popup.id)
                    .offset(x: CGFloat.random(in: -30...30), y: -10)
            }
        }
        .allowsHitTesting(false)
    }

    private var vsDivider: some View {
        HStack(spacing: NQTheme.spaceS + 2) {
            Rectangle().fill(NQTheme.hairline).frame(height: 1.5)
            Text("VS")
                .font(NQText.headingL.font.weight(.heavy))
                .foregroundStyle(NQTheme.ink)
                .nqPadding(.badge)
                .padding(.horizontal, 6)
                .nqPlate(Capsule(), elevation: .soft)
            Rectangle().fill(NQTheme.hairline).frame(height: 1.5)
        }
        .accessibilityHidden(true)
    }

    // MARK: - Action section

    /// Ranked/LAN: a single resolve/play button. Practice: the active unit's
    /// authored moves as real action buttons — accuracy and mana cost shown,
    /// specials disabled without the mana.
    private var actionSection: some View {
        VStack(spacing: NQTheme.spaceS + 2) {
            if isPractice, let battle, let actions = practiceActions(battle) {
                moveButtons(actions.moves)
            } else {
                NQButton(primaryTitle, style: .primary) { startBattle() }
                    .disabled(primaryDisabled)
                    .accessibilityHint("Runs a deterministic battle simulation")
            }

            if running {
                NQDotsLoader(color: accent.accent)
            }

            if let resultText {
                VStack(spacing: NQTheme.spaceS) {
                    NQBanner(
                        resultText,
                        dotColor: resultText.hasPrefix("VICTORY") ? NQTheme.success : NQTheme.warning
                    )
                    ShareLink(item: shareCard, preview: SharePreview("Battle result", image: shareCard)) {
                        Label("Share result", systemImage: "square.and.arrow.up")
                            .font(NQText.caption.font.weight(.bold))
                    }
                    .foregroundStyle(accent.accent)
                }
                .transition(NQTransition.pop)
            }
        }
    }

    private var primaryTitle: String {
        if running { return "Battling…" }
        if lanContext != nil { return resultText == nil ? "Watch the battle" : "Battle over" }
        return "Begin battle"
    }

    private var primaryDisabled: Bool {
        if running { return true }
        return resultText != nil
    }

    /// Practice mode: legal move actions for your active unit.
    private func practiceActions(_ battle: Battle) -> (moves: [(index: Int, move: BattleMoveSpec)], switches: [Int])? {
        guard battle.currentSide == myEngineSide, !battle.isFinished,
              let activeID = sideUnitIDs[myEngineSide].indices.contains(battle.activeIndex(myEngineSide))
                  ? sideUnitIDs[myEngineSide][battle.activeIndex(myEngineSide)] : nil,
              let spec = specByUnitID[activeID] ?? battleSpec(for: activeID) else { return nil }
        let moves: [(Int, BattleMoveSpec)] = battle.legalActions(myEngineSide).compactMap {
            if case .move(let i) = $0, spec.moves.indices.contains(i) { return (i, spec.moves[i]) }
            return nil
        }
        let switches: [Int] = battle.legalActions(myEngineSide).compactMap {
            if case .switchTo(let i) = $0 { return i }
            return nil
        }
        return (moves, switches)
    }

    private func battleSpec(for unitID: String) -> BattleUnitSpec? {
        specByUnitID[unitID]
    }

    private func moveButtons(_ moves: [(index: Int, move: BattleMoveSpec)]) -> some View {
        VStack(alignment: .leading, spacing: NQTheme.spaceS) {
            Text("Choose a move")
                .font(NQText.microS.font)
                .tracking(0.4)
                .foregroundStyle(NQTheme.battleInkMuted)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: NQTheme.spaceS + 2) {
                ForEach(moves, id: \.index) { index, move in
                    moveButton(index: index, move: move)
                }
            }
        }
    }

    private func moveButton(index: Int, move: BattleMoveSpec) -> some View {
        Button {
            NQSound.play(.tapAlt)
            practiceAct(.move(index))
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Image(systemName: move.kind == .special ? "bolt.fill" : "burst.fill")
                        .font(.system(size: NQText.caption.size, weight: .bold))
                        .foregroundStyle(move.kind == .special ? NQTheme.info : accent.accent)
                    Text(move.name)
                        .font(NQText.captionS.font.weight(.bold))
                        .foregroundStyle(NQTheme.battleInk)
                }
                Text(moveSubtitle(move))
                    .font(NQText.micro.font)
                    .foregroundStyle(NQTheme.battleInkMuted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .nqPadding(.badge)
            .padding(NQTheme.spaceS - 4)
            .background(RoundedRectangle(cornerRadius: NQTheme.radiusM).fill(.white.opacity(0.08)))
            .overlay {
                RoundedRectangle(cornerRadius: NQTheme.radiusM)
                    .strokeBorder(accent.accent.opacity(0.35), lineWidth: 1)
            }
        }
        .buttonStyle(.nqPressable(scale: 0.97, haptic: false))
        .accessibilityHint("Use \(move.name)")
    }

    private func moveSubtitle(_ move: BattleMoveSpec) -> String {
        var parts = ["Power \(move.power.formatted(.number.precision(.fractionLength(0...1))))",
                     "\(Int(move.accuracy))% acc"]
        if move.manaCost > 0 { parts.append("\(Int(move.manaCost)) mana") }
        if let effect = move.statusEffect { parts.append(effect.displayName) }
        return parts.joined(separator: " · ")
    }

    /// Bench switch targets — voluntary switches consume the whole turn.
    private var switchRow: some View {
        Group {
            if let battle, let actions = practiceActions(battle), !actions.switches.isEmpty {
                VStack(alignment: .leading, spacing: NQTheme.spaceS) {
                    Text("Switch (uses your turn)")
                        .font(NQText.microS.font)
                        .tracking(0.4)
                        .foregroundStyle(NQTheme.battleInkMuted)
                    HStack(spacing: NQTheme.spaceS) {
                        ForEach(actions.switches, id: \.self) { index in
                            let unitID = sideUnitIDs[myEngineSide][index]
                            Button {
                                NQSound.play(.tapAlt)
                                practiceAct(.switchTo(index))
                            } label: {
                                HStack(spacing: 6) {
                                    if let unit = scene.units[unitID] {
                                        characterArtwork(unitID: unitID, fainted: unit.fainted)
                                            .frame(width: 28, height: 36)
                                    }
                                    Text(name(for: unitID))
                                        .font(NQText.captionS.font.weight(.bold))
                                        .foregroundStyle(NQTheme.battleInk)
                                        .lineLimit(1)
                                }
                                .nqPadding(.badge)
                                .background(RoundedRectangle(cornerRadius: NQTheme.radiusM).fill(.white.opacity(0.08)))
                            }
                            .buttonStyle(.nqPressable(scale: 0.97, haptic: false))
                        }
                    }
                }
            }
        }
    }

    // MARK: - Battle flow

    private func startBattle() {
        guard !running else { return }
        running = true
        resultText = nil
        resetScene()

        switch mode {
        case .lan(let context):
            Task { await animateReplay(context.replay) ; finish(context.replay) }
        case .practice:
            startPractice()
        case .ranked:
            Task {
                guard let replay = await gameState.resolveBattle(
                    yourSquad: displayedSquad,
                    opponentSquad: opponentSquad
                ) else {
                    running = false
                    return
                }
                await animateReplay(replay)
                finish(replay)
            }
        }
    }

    private func resetScene() {
        scene = BattleScene()
        var specs = specByUnitID
        // Practice mode fights with the same snapshots the engine got.
        for (i, ids) in sideUnitIDs.enumerated() {
            for (j, id) in ids.enumerated() {
                if specs[id] == nil { specs[id] = specByUnitID[id] }
                if let spec = specs[id] {
                    scene.units[id] = BattleScene.Unit(
                        hp: spec.maxHP, maxHP: spec.maxHP,
                        mana: Double(spec.startingMana), maxMana: Double(spec.startingMana)
                    )
                } else {
                    scene.units[id] = BattleScene.Unit(hp: 100, maxHP: 100, mana: 0, maxMana: 0)
                }
                _ = (i, j)
            }
        }
        replayCursor = 0
        damagePopups = []
    }

    private func finish(_ replay: BattleReplay) {
        let won = replay.winnerSide == myEngineSide
        resultText = won
            ? "VICTORY · \(replay.turns) turns"
            : "DEFEAT · \(replay.turns) turns"
        running = false
        if won {
            simulateTrigger += 1
            NQJuice.success()
        } else {
            defeatTrigger += 1
            NQJuice.error()
        }
    }

    // MARK: - Practice mode (interactive, local engine)

    private func startPractice() {
        let specsA = displayedSquad.map { gameState.battleStats(for: $0) }
        let specsB = opponentSquad.map { gameState.battleStats(for: $0) }
        let seed = displayedSquad.reduce(UInt64(1469598103934665603)) { acc, c in
            c.id.utf8.reduce(acc) { ($0 ^ UInt64($1)) &* 1099511628211 }
        }
        let b = Battle(squadA: specsA, squadB: specsB, seed: seed, options: .init(firstTurn: .coinFlip))
        battle = b
        drainEngineEvents(b)
        if b.currentSide == 1 - myEngineSide { runOpponentTurns(b) }
    }

    /// Apply one player action, then let the rival's auto policy answer.
    private func practiceAct(_ action: BattleAction) {
        guard let battle, !battle.isFinished, battle.currentSide == myEngineSide else { return }
        running = true
        battle.act(myEngineSide, action: action)
        drainEngineEvents(battle)
        runOpponentTurns(battle)
        running = false
        if battle.isFinished, let replay = practiceReplay(battle) {
            finish(replay)
        }
    }

    private func runOpponentTurns(_ battle: Battle) {
        while !battle.isFinished, let side = battle.currentSide, side != myEngineSide {
            battle.act(side, action: Battle.autoPolicy(battle: battle, side: side))
            drainEngineEvents(battle)
        }
        // If the coin flip gave the rival the opener, it's our turn now.
    }

    private func drainEngineEvents(_ battle: Battle) {
        let newEvents = Array(battle.events.dropFirst(replayCursor))
        replayCursor = battle.events.count
        for event in newEvents { apply(event) }
    }

    private func practiceReplay(_ battle: Battle) -> BattleReplay? {
        guard battle.isFinished, let winner = battle.winner, let reason = battle.victoryReason else { return nil }
        let sides = sideUnitIDs
        let frac: (Int) -> [Double] = { s in
            battle.sideState(s).map { $0.hp / max(1, $0.maxHP) }
        }
        let faint: (Int) -> [String] = { s in
            sides[s].enumerated().compactMap { battle.unitState(s, $0.offset).fainted ? $0.element : nil }
        }
        return BattleReplay(
            seed: battle.events.compactMap { e -> UInt64? in
                if case .battleStart(let s, _) = e { return UInt64(s) }
                return nil
            }.first ?? 0,
            events: battle.events,
            winnerSide: winner, turns: battle.currentTurn, reason: reason,
            hpFractionsA: frac(0), hpFractionsB: frac(1),
            faintedA: faint(0), faintedB: faint(1)
        )
    }

    // MARK: - Replay animation

    /// Walks the authoritative event stream: lunge → hit flash + floating
    /// damage + impact shake (crits shake harder + hit-stop) → next event.
    private func animateReplay(_ replay: BattleReplay) async {
        for event in replay.events {
            if Task.isCancelled { return }
            await animate(event)
            apply(event)
        }
        // Snap end-state to the authoritative fractions (drift-proofing).
        for (i, f) in replay.hpFractionsA.enumerated() {
            guard sideUnitIDs[0].indices.contains(i) else { continue }
            let id = sideUnitIDs[0][i]
            scene.units[id]?.hp = (scene.units[id]?.maxHP ?? 0) * f
        }
        for (i, f) in replay.hpFractionsB.enumerated() {
            guard sideUnitIDs[1].indices.contains(i) else { continue }
            let id = sideUnitIDs[1][i]
            scene.units[id]?.hp = (scene.units[id]?.maxHP ?? 0) * f
        }
    }

    /// One event's choreography beat — the pause between turns.
    private func animate(_ event: BattleEvent) async {
        switch event {
        case .attack(let attacker, let defender, _, _, let damage, let crit):
            let attackerSide = side(of: attacker)
            let defenderSide = side(of: defender)
            guard attackerSide != -1, defenderSide != -1 else { return }

            setLunge(side: attackerSide, active: true)
            try? await Task.sleep(nanoseconds: 300_000_000)
            setLunge(side: attackerSide, active: false)

            setHit(side: defenderSide, active: true)
            if crit {
                showPopup("CRIT −\(damage)", color: NQTheme.gold, side: defenderSide)
            } else {
                showPopup("−\(damage)", color: .white, side: defenderSide)
            }
            impactTrigger += 1
            if crit { NQJuice.crit() } else { NQJuice.hit(heavy: false) }

            try? await Task.sleep(nanoseconds: crit ? 160_000_000 : 90_000_000)
            setHit(side: defenderSide, active: false)
            try? await Task.sleep(nanoseconds: 220_000_000)

        case .miss(_, let defender, _, _):
            showPopup("MISS!", color: NQTheme.battleInkMuted, side: side(of: defender))
            try? await Task.sleep(nanoseconds: 400_000_000)

        case .faint(let unit):
            showPopup("KO!", color: NQTheme.warning, side: side(of: unit))
            NQJuice.hit(heavy: true)
            try? await Task.sleep(nanoseconds: 450_000_000)

        case .switchEvent(let side, _, let newIn, let forced):
            showPopup(forced ? "\(name(for: newIn)) steps in" : "\(name(for: newIn)) tags in",
                      color: NQTheme.info, side: side)
            try? await Task.sleep(nanoseconds: 350_000_000)

        case .status(let unit, let kind, _):
            showPopup(kind.displayName, color: kind.tint, side: side(of: unit))
            try? await Task.sleep(nanoseconds: 250_000_000)

        case .statusTick(let unit, _, let damage):
            showPopup("−\(Int(damage))", color: StatusEffectID.burn.tint, side: side(of: unit))
            try? await Task.sleep(nanoseconds: 200_000_000)

        case .heal(let unit, let amount, _):
            showPopup("+\(Int(amount))", color: NQTheme.success, side: side(of: unit))
            try? await Task.sleep(nanoseconds: 250_000_000)

        case .stunned(let unit):
            showPopup("Stunned!", color: NQTheme.battleInkMuted, side: side(of: unit))
            try? await Task.sleep(nanoseconds: 300_000_000)

        case .victory:
            NQJuice.success()

        case .battleStart, .turnStart, .turnEnd:
            break
        }
    }

    // MARK: - Event → scene reducer

    /// Fold one event into the presentation state (HP, mana, statuses, active
    /// slot, faint flags, ticker text). Shared by replay and practice paths.
    private func apply(_ event: BattleEvent) {
        switch event {
        case .battleStart:
            scene.lastAction = "Battle begins"
        case .turnStart(let turn, _, _):
            scene.turn = turn
        case .turnEnd:
            break
        case .attack(let attacker, let defender, let move, let moveID, let damage, let crit):
            spendMana(attacker: attacker, moveID: moveID)
            if var unit = scene.units[defender] {
                unit.hp = max(0, unit.hp - Double(damage))
                unit.fainted = unit.hp <= 0
                scene.units[defender] = unit
            }
            scene.lastAction = "\(name(for: attacker)) used \(move) — \(damage) dmg\(crit ? " CRIT" : "")"
        case .miss(let attacker, _, let move, let moveID):
            spendMana(attacker: attacker, moveID: moveID)
            scene.lastAction = "\(name(for: attacker)) used \(move) — missed"
        case .status(let unit, let kind, _):
            scene.units[unit]?.statuses.insert(kind)
            scene.lastAction = "\(name(for: unit)): \(kind.displayName)"
        case .statusTick(let unit, let kind, let damage):
            if var u = scene.units[unit] {
                u.hp = max(0, u.hp - damage)
                u.fainted = u.hp <= 0
                scene.units[unit] = u
            }
            scene.lastAction = "\(name(for: unit)) suffers \(Int(damage)) \(kind.displayName)"
        case .heal(let unit, let amount, _):
            if var u = scene.units[unit] {
                u.hp = min(u.maxHP, u.hp + amount)
                scene.units[unit] = u
            }
            scene.lastAction = "\(name(for: unit)) healed \(Int(amount))"
        case .stunned(let unit):
            scene.lastAction = "\(name(for: unit)) is stunned"
        case .switchEvent(let side, _, let newIn, _):
            if let idx = sideUnitIDs[side].firstIndex(of: newIn) {
                scene.active[side] = idx
            }
            scene.lastAction = "\(name(for: newIn)) enters the fight"
        case .faint(let unit):
            scene.units[unit]?.fainted = true
            scene.units[unit]?.statuses = []
            scene.lastAction = "\(name(for: unit)) fainted"
        case .victory(let winner, _, let reason):
            scene.lastAction = reason == .turnLimit
                ? "Turn limit — \(name(for: sideUnitIDs[winner].first ?? ""))'s side holds the field"
                : "\(name(for: sideUnitIDs[winner].first ?? ""))'s side wins"
        }
    }

    /// Specials spend mana on use — the wire doesn't echo the cost, so look
    /// the move up in the unit's snapshot.
    private func spendMana(attacker: String, moveID: String) {
        guard let spec = specByUnitID[attacker],
              let move = spec.moves.first(where: { $0.id == moveID }),
              move.manaCost > 0 else { return }
        scene.units[attacker]?.mana = max(0, (scene.units[attacker]?.mana ?? 0) - move.manaCost)
    }

    private func setLunge(side: Int, active: Bool) {
        if side == myEngineSide { yourLunge = active } else { opponentLunge = active }
    }

    private func setHit(side: Int, active: Bool) {
        if side == myEngineSide { yourHit = active } else { opponentHit = active }
    }

    /// `side` here is the *visual* side for popups: 0 = bottom (you), 1 = top.
    private func showPopup(_ text: String, color: Color, side: Int) {
        guard side != -1 else { return }
        let visual = side == myEngineSide ? 0 : 1
        let popup = BattlePopup(text: text, color: color, side: visual)
        withAnimation(NQMotion.quick) { damagePopups.append(popup) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            damagePopups.removeAll { $0.id == popup.id }
        }
    }

    // MARK: - Share + secondary actions

    /// The victory card rendered to an image for the share sheet.
    @MainActor
    private var shareCard: Image {
        let renderer = ImageRenderer(content: battleShareCard)
        renderer.scale = 3
        return Image(uiImage: renderer.uiImage ?? UIImage())
    }

    /// Static, share-sheet-friendly result card — dark arena, squads, score.
    private var battleShareCard: some View {
        VStack(spacing: NQTheme.spaceM) {
            Text(resultText?.hasPrefix("VICTORY") == true ? "VICTORY" : "DEFEAT")
                .font(NQFont.display.font(28))
                .foregroundStyle(resultText?.hasPrefix("VICTORY") == true ? NQTheme.gold : NQTheme.battleInkMuted)
            HStack(spacing: NQTheme.spaceS) {
                ForEach(displayedSquad.prefix(3)) { c in
                    CharacterArtwork(character: c, expression: resultText?.hasPrefix("VICTORY") == true ? .proud : .hurt, hurt: resultText?.hasPrefix("VICTORY") != true)
                        .frame(width: 56, height: 72)
                }
            }
            Text("vs")
                .font(NQText.captionS.font.weight(.heavy))
                .foregroundStyle(NQTheme.battleInkMuted)
            HStack(spacing: NQTheme.spaceS) {
                ForEach(opponentSquad.prefix(3)) { c in
                    CharacterArtwork(character: c, expression: resultText?.hasPrefix("VICTORY") == true ? .hurt : .proud, hurt: resultText?.hasPrefix("VICTORY") == true)
                        .frame(width: 56, height: 72)
                }
            }
            Text(resultText ?? "")
                .font(NQText.caption.font.weight(.semibold))
                .foregroundStyle(NQTheme.battleInkMuted)
            Text("NutriQuest")
                .font(NQText.micro.font.weight(.bold))
                .foregroundStyle(accent.accent)
        }
        .padding(NQTheme.spaceXL)
        .background(NQTheme.battleBg)
    }

    private var secondaryActions: some View {
        HStack(spacing: NQTheme.spaceS + 2) {
            // Reorder your squad pre-battle to pick the lead — once the fight
            // starts, order is locked (a LAN squad was locked in even earlier).
            if lanContext == nil && !running && resultText == nil && displayedSquad.count > 1 {
                NQButton("Switch lead", style: .secondary, fullWidth: false) {
                    var next = displayedSquad
                    let lead = next.removeFirst()
                    next.append(lead)
                    orderedSquad = next
                }
            }
            NQButton(lanContext == nil ? "Flee" : "Back to lobby", style: .ghost, fullWidth: false) { dismiss() }
        }
    }
}

// MARK: - Presentation state

/// HP/mana/status/active-slot projection of the event stream. The engine is
/// the source of truth for outcomes; this is only what the screen draws.
private struct BattleScene {
    struct Unit {
        var hp: Double
        var maxHP: Double
        var mana: Double
        var maxMana: Double
        var fainted = false
        var statuses: Set<StatusEffectID> = []

        var hpFraction: Double { maxHP > 0 ? max(0, min(1, hp / maxHP)) : 0 }
    }

    var units: [String: Unit] = [:]
    /// Active squad index per engine side.
    var active: [Int] = [0, 0]
    var turn = 0
    var lastAction = "Battle begins"
}

// MARK: - Status presentation

private extension StatusEffectID {
    var displayName: String {
        switch self {
        case .burn: return "Burn"
        case .accDown: return "Accuracy down"
        case .atkUp: return "Attack up"
        case .guardUp: return "Guard up"
        case .stun: return "Stun"
        case .heal: return "Heal"
        case .leech: return "Leech"
        }
    }

    var tint: Color {
        switch self {
        case .burn: return NQTheme.warning
        case .accDown: return NQTheme.battleInkMuted
        case .atkUp: return NQTheme.gold
        case .guardUp: return NQTheme.info
        case .stun: return NQTheme.battleRival
        case .heal, .leech: return NQTheme.success
        }
    }
}
