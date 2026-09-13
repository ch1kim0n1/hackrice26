import SwiftUI
import BattleKit
import NutriQuestUI

/// What drives a battle screen:
///  - `.ranked`   — POST /battle/ranked/begin parks the SBMM matchup; the
///                  player drives every turn locally, then /commit replays
///                  the submitted script server-side for RR + Case + faints.
///  - `.friendly` — same interactive flow against a friend's stored squad
///                  snapshot (begin/commit, no RR).
///  - `.lan`      — the group host already resolved the match; the replay is
///                  handed in verbatim.
///  - `.practice` — a live local `Battle`, no server round-trip at all.
enum BattleMode {
    case ranked
    case friendly(FriendlyBattleContext)
    case lan(LANBattleContext)
    case practice
}

struct FriendlyBattleContext {
    /// The parked interactive match from POST /battle/friendly/begin.
    let match: GameState.InteractiveMatch
    let opponentId: String
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
    /// Ranked picks the opponent server-side (SBMM); the echoed snapshot
    /// squad lands here once the match resolves, replacing the placeholder.
    @State private var serverOpponent: [Character]?
    /// What the last ranked match did to the ladder — drives the result card.
    @State private var rankedOutcome: GameState.RankedOutcome?

    /// Autopilot (#10): when on, the bot policy drives the player's side too
    /// and the choreography runs fast — a deterministic fast-forward, not a
    /// simulation shortcut: the same engine, same seed, same event stream.
    @State private var autopilot = false
    /// Long-press move detail popup (#11).
    @State private var inspectedMove: BattleMoveSpec?
    /// Live engine handle — every interactive mode (ranked/friendly/practice).
    @State private var battle: Battle?
    /// Replay cursor for LAN animation and the interactive event drain.
    @State private var replayCursor = 0
    /// The parked server match + the decisions made so far — what commit sends.
    @State private var match: GameState.InteractiveMatch?
    @State private var script: [BattleActionDTO] = []
    /// Begin/commit in flight — blocks re-entry without freezing the UI.
    @State private var serverBusy = false

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

    private var friendlyContext: FriendlyBattleContext? {
        if case .friendly(let context) = mode { return context }
        return nil
    }

    /// Player-driven modes — ranked/friendly/practice all run the local
    /// engine turn by turn; only LAN is a pure replay.
    private var isInteractive: Bool { lanContext == nil }

    /// True while the player's active monster is down and the bench needs a
    /// pick — the replacement is free and the engine waits for it.
    private var needsReplacement: Bool {
        battle?.needsReplacement(myEngineSide) == true && battle?.isFinished == false
    }

    private var displayedSquad: [Character] {
        orderedSquad.isEmpty ? yourSquad : orderedSquad
    }

    /// The rival squad on screen: the `opponentSquad` argument, or — once a
    /// begin/commit round-trip lands — the real locked squad the server parked.
    private var displayedOpponent: [Character] {
        match?.opponentCharacters ?? serverOpponent ?? opponentSquad
    }

    /// Engine side rendered at the bottom (yours). 0 for every mode but LAN.
    private var myEngineSide: Int { lanContext?.mySide ?? 0 }

    /// The unit ids fighting for each engine side, in squad order.
    private var sideUnitIDs: [[String]] {
        if let lan = lanContext {
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
                (displayedOpponent.firstIndex { $0.id == lan.unitCharacterIDs[a] } ?? 0)
                    < (displayedOpponent.firstIndex { $0.id == lan.unitCharacterIDs[b] } ?? 0)
            }
            var out: [[String]] = [[], []]
            out[myEngineSide] = mine
            out[1 - myEngineSide] = theirs
            return out
        }
        // A parked match carries the server-resolved unit ids — identical
        // for the player's own squad, authoritative for the opponent's.
        let mine = match?.yourSpecs.map(\.id) ?? displayedSquad.map(\.id)
        let theirs = match?.opponentSpecs.map(\.id) ?? displayedOpponent.map(\.id)
        return [mine, theirs]
    }

    /// Best-known snapshot per unit id — real specs where we have them.
    private var specByUnitID: [String: BattleUnitSpec] {
        if let lan = lanContext { return lan.unitSpecs }
        if let match {
            var map: [String: BattleUnitSpec] = [:]
            for s in match.yourSpecs + match.opponentSpecs { map[s.id] = s }
            return map
        }
        var map: [String: BattleUnitSpec] = [:]
        for c in yourSquad + displayedOpponent { map[c.id] = gameState.battleStats(for: c) }
        return map
    }

    private func name(for unitID: String) -> String {
        let charID = lanContext?.unitCharacterIDs[unitID] ?? unitID
        return (yourSquad + displayedOpponent).first { $0.id == charID }?.name
            ?? specByUnitID[unitID]?.name ?? "???"
    }

    private func character(for unitID: String) -> Character? {
        let charID = lanContext?.unitCharacterIDs[unitID] ?? unitID
        return (yourSquad + displayedOpponent).first { $0.id == charID }
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
                battleLog
                actionSection
                if isInteractive { switchRow }
                secondaryActions
            }
            .padding(NQTheme.spaceL)
        }
        .nqSceneBackground(GameArt.scene("battle"))
        .navigationTitle(navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .preferredColorScheme(.dark)
        .nqSuccessBurst(on: simulateTrigger)
        .overlay { replacementOverlay }
        .overlay { moveInfoOverlay }
        .onAppear {
            if orderedSquad.isEmpty { orderedSquad = yourSquad }
            if case .friendly(let ctx) = mode { match = ctx.match }
            resetScene()
        }
    }

    private var navigationTitle: String {
        switch mode {
        case .lan: return "LAN Battle"
        case .friendly: return "Friendly Battle"
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
                NQTicketShape()
                    .fill(LinearGradient(colors: [accent.accent, accent.accentDark], startPoint: .top, endPoint: .bottom))
                    .nqElevation(.card)
            }
            .contentTransition(.opacity)
            .animation(NQMotion.quick, value: bannerText)
            .accessibilityAddTraits(.isHeader)
    }

    private var bannerText: String {
        if let resultText { return resultText.hasPrefix("VICTORY") ? "Victory" : "Defeat" }
        if needsReplacement { return "Choose your next monster" }
        if serverBusy { return match == nil ? "Finding match…" : "Reporting result…" }
        if autopilot, let battle, !battle.isFinished {
            return scene.turn > 0 ? "Turn \(scene.turn) · AUTO" : "Auto-battling…"
        }
        if isInteractive, let battle, !battle.isFinished {
            return battle.currentSide == myEngineSide ? "Your move" : "Rival's turn…"
        }
        if running { return scene.turn > 0 ? "Turn \(scene.turn)" : "Battling…" }
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
        if let lanContext { return "OPPONENT · \(lanContext.opponentName.uppercased())" }
        if case .friendly(let ctx) = mode { return "OPPONENT · \(ctx.opponentId.uppercased())" }
        return "OPPONENT · RIVAL SQUAD"
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

    /// The active unit: large artwork in a rarity-glow ring, HP bar, mana
    /// bar (Epic+), status chips. Faints slump and grey out.
    private func activeCard(unitID: String, unit: BattleScene.Unit, side: Int) -> some View {
        // Hurt pose: on the hit flash, and persistently while the unit is
        // low on HP — a battered monster shouldn't look fresh.
        let hurt = (side == 0 && yourHit) || (side == 1 && opponentHit)
            || (!unit.fainted && unit.hpFraction <= 0.3)
        let rarity = character(for: unitID)?.rarity.kitRarity
        return HStack(spacing: NQTheme.spaceM) {
            ZStack {
                if let rarity {
                    Circle()
                        .fill(rarity.outline.opacity(0.28))
                        .frame(width: 108, height: 108)
                        .blur(radius: 14)
                }
                characterArtwork(unitID: unitID, hurt: hurt, fainted: unit.fainted)
                    .frame(width: 104, height: 132)
                    .scaleEffect(unit.fainted ? 0.9 : 1)
                    .opacity(unit.fainted ? 0.35 : 1)
                    .saturation(unit.fainted ? 0 : 1)
                    .rotationEffect(.degrees(unit.fainted ? (side == myEngineSide ? -10 : 10) : 0))
                    .offset(y: unit.fainted ? 12 : 0)
                    .animation(NQMotion.quick, value: unit.fainted)
                    .animation(NQMotion.quick, value: hurt)
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(name(for: unitID))
                        .font(NQText.caption.font.weight(.bold))
                        .foregroundStyle(NQTheme.battleInk)
                        .lineLimit(1)
                    if let rarity {
                        NQChip(rarity.rawValue.capitalized, tint: rarity.outline)
                    }
                }
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
                    .background(NQTicketShape().fill(kind.tint.opacity(0.16)))
            }
        }
    }

    /// A benched unit: portrait + HP sliver; dimmed once fainted.
    private func benchChip(unitID: String, unit: BattleScene.Unit) -> some View {
        VStack(spacing: 4) {
            characterArtwork(unitID: unitID, hurt: !unit.fainted && unit.hpFraction <= 0.3, fainted: unit.fainted)
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
                .nqPlate(NQTicketShape(), elevation: .soft)
            Rectangle().fill(NQTheme.hairline).frame(height: 1.5)
        }
        .accessibilityHidden(true)
    }

    /// Scrolling play-by-play — the last few beats, newest on top.
    private var battleLog: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(scene.log.prefix(3).enumerated()), id: \.offset) { index, line in
                Text(line)
                    .font(NQText.captionS.font.weight(index == 0 ? .bold : .regular))
                    .foregroundStyle(index == 0 ? NQTheme.battleInk : NQTheme.battleInkMuted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(1)
            }
        }
        .frame(minHeight: 54)
        .nqPadding(.badge)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: NQTheme.radiusM).fill(.white.opacity(0.05)))
        .animation(NQMotion.quick, value: scene.log)
    }

    // MARK: - Action section

    /// Interactive modes: the active unit's authored moves as real action
    /// buttons once it's your turn. LAN: a single watch button. Before any
    /// battle exists, the big button starts (or parks) the fight.
    private var actionSection: some View {
        VStack(spacing: NQTheme.spaceS + 2) {
            if isInteractive, let battle, !autopilot, let actions = availableActions(battle) {
                moveButtons(actions.moves)
            } else if battle == nil {
                NQButton(primaryTitle, style: .primary) { startBattle() }
                    .disabled(primaryDisabled)
                    .accessibilityHint("Starts a deterministic battle")
            } else if serverBusy || running {
                NQDotsLoader(color: accent.accent)
            }

            // Fast-forward (#10): the deterministic bot takes over your side.
            if isInteractive, let b = battle, !b.isFinished, resultText == nil {
                Button {
                    NQSound.play(.toggle)
                    autopilot.toggle()
                    if autopilot { kickPump(b) }
                } label: {
                    Label(autopilot ? "Auto battling…" : "Fast-forward (auto play)",
                          systemImage: autopilot ? "pause.fill" : "forward.fill")
                        .font(NQText.captionS.font.weight(.heavy))
                        .foregroundStyle(NQTheme.battleInk)
                        .nqPadding(.badge)
                        .frame(maxWidth: .infinity)
                        .background(RoundedRectangle(cornerRadius: NQTheme.radiusM).fill(.white.opacity(0.08)))
                        .overlay {
                            RoundedRectangle(cornerRadius: NQTheme.radiusM)
                                .strokeBorder(autopilot ? accent.accent : accent.accent.opacity(0.35), lineWidth: 1)
                        }
                }
                .buttonStyle(.nqPressable(scale: 0.97, haptic: false))
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
        if serverBusy { return match == nil ? "Finding match…" : "Reporting…" }
        // LAN arrives with the result already resolved by the host.
        if lanContext != nil {
            return resultText == nil ? "Watch the battle" : "Battle over"
        }
        return resultText == nil ? "Begin battle" : "Battle over"
    }

    private var primaryDisabled: Bool {
        if running || serverBusy { return true }
        return resultText != nil
    }

    /// Legal move + switch actions for your active unit — same for practice,
    /// ranked and friendly; the engine decides what's legal.
    private func availableActions(_ battle: Battle) -> (moves: [(index: Int, move: BattleMoveSpec)], switches: [Int])? {
        guard battle.currentSide == myEngineSide, !battle.isFinished,
              !battle.needsReplacement(myEngineSide),
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
            playerAct(.move(index))
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
        .onLongPressGesture {
            NQHaptic.light()
            inspectedMove = move
        }
        .accessibilityHint("Use \(move.name). Long-press for details")
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
            if let battle, let actions = availableActions(battle), !actions.switches.isEmpty {
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
                                playerAct(.switchTo(index))
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
        guard !running, !serverBusy else { return }
        resultText = nil
        resetScene()

        switch mode {
        case .lan(let context):
            running = true
            Task { await animateReplay(context.replay) ; finish(context.replay) }
        case .practice:
            launchInteractive()
        case .friendly(let context):
            // The match was parked before this screen was pushed — the seed,
            // specs and opponent are already locked server-side.
            match = context.match
            launchInteractive()
        case .ranked:
            Task { await beginRanked() }
        }
    }

    /// POST /battle/ranked/begin — SBMM parks the matchup and returns the
    /// locked specs + seed, then the fight runs locally off those specs.
    private func beginRanked() async {
        serverBusy = true
        let parked = await gameState.beginRankedBattle(squad: displayedSquad)
        serverBusy = false
        guard let parked else {
            logLine("No match: check your connection")
            return
        }
        match = parked
        resetScene()
        launchInteractive()
    }

    /// Build the live engine over the locked specs, then play it out —
    /// the player acts through `playerAct`, the rival through autoPolicy.
    private func launchInteractive() {
        let specsA = sideUnitIDs[0].compactMap { specByUnitID[$0] }
        let specsB = sideUnitIDs[1].compactMap { specByUnitID[$0] }
        guard specsA.count == 3, specsB.count == 3 else { return }
        // Practice has no parked seed — derive one locally, still seeded.
        let seed = match?.seed ?? displayedSquad.reduce(UInt64(1469598103934665603)) { acc, c in
            c.id.utf8.reduce(acc) { ($0 ^ UInt64($1)) &* 1099511628211 }
        }
        let b = Battle(squadA: specsA, squadB: specsB, seed: seed,
                       options: .init(firstTurn: .coinFlip, manualReplacement: myEngineSide))
        battle = b
        script = []
        Task { await runInteractive(b) }
    }

    /// One player decision: apply it locally (and onto the commit script),
    /// animate the fallout, then let the rival answer until it's our turn.
    private func playerAct(_ action: BattleAction) {
        guard !autopilot, let b = battle, !b.isFinished, b.currentSide == myEngineSide else { return }
        b.act(myEngineSide, action: action)
        if match != nil { script.append(action.scriptEntry) }
        running = true
        Task { await runInteractive(b) }
    }

    /// Pick the next monster after a faint — free action, no turn consumed.
    private func playerChooseReplacement(_ unitIndex: Int) {
        guard let b = battle, b.needsReplacement(myEngineSide) else { return }
        b.chooseReplacement(myEngineSide, unitIndex: unitIndex)
        if match != nil { script.append(.choose(unitIndex)) }
        running = true
        Task { await runInteractive(b) }
    }

    /// Re-start the pump after a player action or an autopilot toggle.
    private func kickPump(_ b: Battle) {
        running = true
        Task { await runInteractive(b) }
    }

    /// Choreography clock: autopilot compresses every beat so a fast-forward
    /// plays the same events ~6× faster instead of skipping them.
    private func pace(_ ns: UInt64) async {
        let d = autopilot ? ns / 6 : ns
        guard d > 1_000_000 else { return }
        try? await Task.sleep(nanoseconds: d)
    }

    /// The turn pump: animate pending events, auto-drive the rival, stop at
    /// a decision point (player turn / faint pick) or the final commit.
    /// With autopilot on, the bot policy answers our decision points too.
    private func runInteractive(_ b: Battle) async {
        while !b.isFinished {
            await drainAnimated(b)
            if needsReplacement {
                guard autopilot,
                      let pick = sideUnitIDs[myEngineSide].indices
                        .first(where: { !b.unitState(myEngineSide, $0).fainted })
                else { running = false; return }
                b.chooseReplacement(myEngineSide, unitIndex: pick)
                if match != nil { script.append(.choose(pick)) }
                continue
            }
            guard let side = b.currentSide else { break }
            if side == myEngineSide && !autopilot { break }
            await pace(300_000_000)
            b.act(side, action: Battle.autoPolicy(battle: b, side: side))
        }
        await drainAnimated(b)
        running = false
        if b.isFinished { autopilot = false; await concludeInteractive(b) }
    }

    /// Settle the fight: practice reports locally; parked matches submit the
    /// recorded script — the server's replay is what counts for RR/Cases.
    private func concludeInteractive(_ b: Battle) async {
        guard let replay = localReplay(b) else { return }
        guard let match else { finish(replay); return }
        serverBusy = true
        switch match.kind {
        case .ranked:
            if let outcome = await gameState.commitRankedBattle(match, actions: script) {
                rankedOutcome = outcome
                serverOpponent = outcome.opponentSquad
            } else {
                logLine("Result sync failed: showing local replay")
            }
        case .friendly:
            if await gameState.commitFriendlyBattle(match, actions: script) == nil {
                logLine("Result sync failed: showing local replay")
            }
        }
        serverBusy = false
        finish(replay)
    }

    private func resetScene() {
        scene = BattleScene()
        let specs = specByUnitID
        for ids in sideUnitIDs {
            for id in ids {
                if let spec = specs[id] {
                    scene.units[id] = BattleScene.Unit(
                        hp: spec.maxHP, maxHP: spec.maxHP,
                        mana: Double(spec.startingMana), maxMana: Double(spec.startingMana)
                    )
                } else {
                    scene.units[id] = BattleScene.Unit(hp: 100, maxHP: 100, mana: 0, maxMana: 0)
                }
            }
        }
        replayCursor = 0
        damagePopups = []
    }

    private func finish(_ replay: BattleReplay) {
        let won = replay.winnerSide == myEngineSide
        var text = won
            ? "VICTORY · \(replay.turns) turns"
            : "DEFEAT · \(replay.turns) turns"
        // Ranked reports what the ladder did: RR movement, promotion, and
        // the rarity of the Case a win granted.
        if let outcome = rankedOutcome {
            let sign = outcome.rrDelta >= 0 ? "+" : ""
            text += " · \(sign)\(outcome.rrDelta) RR"
            if outcome.promoted { text += " · PROMOTED" }
            if let caseRarity = outcome.caseRarity {
                text += " · \(caseRarity.capitalized) Case"
            }
        }
        resultText = text
        running = false
        if won {
            simulateTrigger += 1
            NQJuice.success()
        } else {
            defeatTrigger += 1
            NQJuice.error()
        }
    }

    // MARK: - Interactive engine drive

    /// Animate each new engine event with its choreography beat, then fold
    /// it into the scene — the interactive version of `animateReplay`.
    private func drainAnimated(_ battle: Battle) async {
        let newEvents = Array(battle.events.dropFirst(replayCursor))
        replayCursor = battle.events.count
        for event in newEvents {
            if Task.isCancelled { return }
            await animate(event)
            apply(event)
        }
    }

    /// Long-press move detail (#11): name, kind, the full stat line and the
    /// authored description — so a status move explains itself before you
    /// spend the turn on it.
    @ViewBuilder private var moveInfoOverlay: some View {
        if let move = inspectedMove {
            ZStack {
                Color.black.opacity(0.55)
                    .ignoresSafeArea()
                    .onTapGesture { inspectedMove = nil }
                VStack(alignment: .leading, spacing: NQTheme.spaceS) {
                    HStack {
                        Image(systemName: move.kind == .special ? "bolt.fill" : "burst.fill")
                            .foregroundStyle(move.kind == .special ? NQTheme.info : accent.accent)
                        Text(move.name)
                            .font(NQText.heading.font.weight(.heavy))
                            .foregroundStyle(NQTheme.battleInk)
                        Spacer()
                        Button { inspectedMove = nil } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: NQText.heading.size))
                                .foregroundStyle(NQTheme.battleInkMuted)
                        }
                        .accessibilityLabel("Close move details")
                    }
                    Text(move.kind == .special ? "SPECIAL · SPENDS MANA" : "STANDARD")
                        .font(NQText.microS.font)
                        .tracking(0.6)
                        .foregroundStyle(NQTheme.battleInkMuted)
                    Text(moveSubtitle(move))
                        .font(NQText.captionS.font.weight(.bold))
                        .foregroundStyle(NQTheme.battleInk)
                    if let effect = move.statusEffect {
                        Text("Effect: \(effect.displayName)\(move.statusChance.map { " · \(Int($0))% chance" } ?? "")\(move.duration.map { " · \($0) turns" } ?? "")")
                            .font(NQText.captionS.font)
                            .foregroundStyle(NQTheme.info)
                    }
                    if let description = move.description, !description.isEmpty {
                        Text(description)
                            .font(NQText.caption.font)
                            .foregroundStyle(NQTheme.battleInkMuted)
                    }
                }
                .nqPadding(.card)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: NQTheme.radiusXL).fill(NQTheme.battleBg))
                .overlay {
                    RoundedRectangle(cornerRadius: NQTheme.radiusXL)
                        .strokeBorder(accent.accent.opacity(0.5), lineWidth: 1.5)
                }
                .padding(NQTheme.spaceL)
            }
            .transition(NQTransition.pop)
            .zIndex(20)
        }
    }

    /// Faint replacement overlay — dim the arena, offer the living bench.
    /// The pick is free and recorded onto the commit script.
    @ViewBuilder private var replacementOverlay: some View {
        if needsReplacement, let b = battle {
            let candidates = sideUnitIDs[myEngineSide].indices.filter {
                !b.unitState(myEngineSide, $0).fainted
            }
            ZStack {
                Color.black.opacity(0.55)
                    .ignoresSafeArea()
                VStack(spacing: NQTheme.spaceM) {
                    Text("Choose your next monster")
                        .font(NQText.headingL.font.weight(.bold))
                        .foregroundStyle(NQTheme.battleInk)
                    HStack(spacing: NQTheme.spaceS) {
                        ForEach(candidates, id: \.self) { index in
                            let unitID = sideUnitIDs[myEngineSide][index]
                            Button {
                                NQSound.play(.tapAlt)
                                playerChooseReplacement(index)
                            } label: {
                                VStack(spacing: 4) {
                                    characterArtwork(unitID: unitID)
                                        .frame(width: 56, height: 72)
                                    Text(name(for: unitID))
                                        .font(NQText.captionS.font.weight(.bold))
                                        .foregroundStyle(NQTheme.battleInk)
                                        .lineLimit(1)
                                    if let u = scene.units[unitID] {
                                        Text("\(Int(u.hp)) HP")
                                            .font(NQText.micro.font.weight(.semibold))
                                            .foregroundStyle(NQTheme.battleInkMuted)
                                            .monospacedDigit()
                                    }
                                }
                                .nqPadding(.badge)
                                .frame(maxWidth: .infinity)
                                .nqPlate(RoundedRectangle(cornerRadius: NQTheme.radiusL), elevation: .card)
                            }
                            .buttonStyle(.nqPressable(scale: 0.96, haptic: false))
                        }
                    }
                }
                .nqPadding(.card)
                .frame(maxWidth: .infinity)
                .background(RoundedRectangle(cornerRadius: NQTheme.radiusXL).fill(NQTheme.battleBg))
                .padding(NQTheme.spaceL)
            }
            .transition(NQTransition.pop)
            .zIndex(10)
        }
    }

    private func localReplay(_ battle: Battle) -> BattleReplay? {
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
            await pace(300_000_000)
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
            await pace(220_000_000)

        case .miss(_, let defender, _, _):
            showPopup("MISS!", color: NQTheme.battleInkMuted, side: side(of: defender))
            await pace(400_000_000)

        case .faint(let unit):
            showPopup("KO!", color: NQTheme.warning, side: side(of: unit))
            NQJuice.hit(heavy: true)
            await pace(450_000_000)

        case .switchEvent(let side, _, let newIn, let forced):
            showPopup(forced ? "\(name(for: newIn)) steps in" : "\(name(for: newIn)) tags in",
                      color: NQTheme.info, side: side)
            await pace(350_000_000)

        case .status(let unit, let kind, _):
            showPopup(kind.displayName, color: kind.tint, side: side(of: unit))
            await pace(250_000_000)

        case .statusTick(let unit, _, let damage):
            showPopup("−\(Int(damage))", color: StatusEffectID.burn.tint, side: side(of: unit))
            await pace(200_000_000)

        case .heal(let unit, let amount, _):
            showPopup("+\(Int(amount))", color: NQTheme.success, side: side(of: unit))
            await pace(250_000_000)

        case .stunned(let unit):
            showPopup("Stunned!", color: NQTheme.battleInkMuted, side: side(of: unit))
            await pace(300_000_000)

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
            logLine("Battle begins")
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
            logLine("\(name(for: attacker)) used \(move): \(damage) dmg\(crit ? " CRIT" : "")")
        case .miss(let attacker, _, let move, let moveID):
            spendMana(attacker: attacker, moveID: moveID)
            logLine("\(name(for: attacker)) used \(move): missed")
        case .status(let unit, let kind, _):
            scene.units[unit]?.statuses.insert(kind)
            logLine("\(name(for: unit)): \(kind.displayName)")
        case .statusTick(let unit, let kind, let damage):
            if var u = scene.units[unit] {
                u.hp = max(0, u.hp - damage)
                u.fainted = u.hp <= 0
                scene.units[unit] = u
            }
            logLine("\(name(for: unit)) suffers \(Int(damage)) \(kind.displayName)")
        case .heal(let unit, let amount, _):
            if var u = scene.units[unit] {
                u.hp = min(u.maxHP, u.hp + amount)
                scene.units[unit] = u
            }
            logLine("\(name(for: unit)) healed \(Int(amount))")
        case .stunned(let unit):
            logLine("\(name(for: unit)) is stunned")
        case .switchEvent(let side, _, let newIn, _):
            if let idx = sideUnitIDs[side].firstIndex(of: newIn) {
                scene.active[side] = idx
            }
            logLine("\(name(for: newIn)) enters the fight")
        case .faint(let unit):
            scene.units[unit]?.fainted = true
            scene.units[unit]?.statuses = []
            logLine("\(name(for: unit)) fainted")
        case .victory(let winner, _, let reason):
            logLine(reason == .turnLimit
                ? "Turn limit: \(name(for: sideUnitIDs[winner].first ?? ""))'s side holds the field"
                : "\(name(for: sideUnitIDs[winner].first ?? ""))'s side wins")
        }
    }

    /// Ticker + log in one place — the newest beat leads the log.
    private func logLine(_ text: String) {
        scene.lastAction = text
        scene.log.insert(text, at: 0)
        if scene.log.count > 24 { scene.log.removeLast() }
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
                ForEach(displayedOpponent.prefix(3)) { c in
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
    /// Recent play-by-play lines, newest first — drives the battle log.
    var log: [String] = []
}

// MARK: - Action → script entry

/// The local engine action → the wire shape `battleActionSchema` replays.
private extension BattleAction {
    var scriptEntry: BattleActionDTO {
        switch self {
        case .move(let i): return .move(i)
        case .switchTo(let i): return .switchTo(i)
        }
    }
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
