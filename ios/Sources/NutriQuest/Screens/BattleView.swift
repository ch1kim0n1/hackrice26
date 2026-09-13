import SwiftUI
import BattleKit
import NutriQuestUI

struct BattleMove: Identifiable {
    let id = UUID()
    let name: String
    let statType: StatType
    let description: String
}

/// What drives a battle screen: the server (ranked) or a LAN match the group
/// host has already resolved.
enum BattleMode {
    case ranked
    case lan(LANBattleContext)
}

struct LANBattleContext {
    let replay: BattleReplay
    let opponentName: String
    /// Which engine side you were (0 or 1). Your squad is always drawn at the
    /// bottom, so only the win check needs it.
    let mySide: Int
    /// Replay unit id → on-screen character id, for side and damage attribution.
    let unitCharacterIDs: [UUID: String]
}

struct BattleView: View {
    var yourSquad: [Character]
    var opponentSquad: [Character]
    var fatigued: Bool
    var moves: [BattleMove]
    @ObservedObject var gameState: GameState
    var mode: BattleMode = .ranked

    @State private var simulating = false
    @State private var resultText: String?
    @State private var simulateTrigger = 0
    @State private var selectedMove: BattleMove?
    @State private var orderedSquad: [Character] = []
    // Choreography beats — staged theater around the server resolution.
    @State private var yourLunge = false
    @State private var opponentLunge = false
    @State private var opponentHit = false
    @State private var yourHit = false
    // Juice: floating damage numbers + impact shake, driven by the replay.
    @State private var damagePopups: [BattlePopup] = []
    @State private var impactTrigger = 0
    /// Cumulative damage taken per character id — drives the health bars.
    @State private var damageTaken: [String: Double] = [:]

    struct BattlePopup: Identifiable {
        let id = UUID()
        let text: String
        let color: Color
        let side: Int   // 0 = your squad, 1 = opponent
    }

    @Environment(\.nqAccent) private var accent
    @Environment(\.dismiss) private var dismiss

    private var displayedSquad: [Character] {
        orderedSquad.isEmpty ? yourSquad : orderedSquad
    }

    private var lanContext: LANBattleContext? {
        if case .lan(let context) = mode { return context }
        return nil
    }

    private var unitCharacterIDs: [UUID: String] {
        lanContext?.unitCharacterIDs ?? gameState.lastUnitIDs
    }

    var body: some View {
        ScrollView {
            VStack(spacing: NQTheme.spaceL - 2) {
                turnBanner
                if fatigued {
                    NQBanner.warning("Squad fatigued. Buffs reduced until you rest.")
                }
                arena
                simulateSection
                // A LAN squad's order was committed before the battle, and the
                // engine always attacks the first living enemy — so nothing
                // that reorders it can be offered here.
                if lanContext == nil {
                    moveGrid
                }
                secondaryActions
            }
            .padding(NQTheme.spaceL)
        }
        .nqSceneBackground(GameArt.scene("battle"))
        .navigationTitle(lanContext == nil ? "Ranked Battle" : "LAN Battle")
        .navigationBarTitleDisplayMode(.inline)
        .preferredColorScheme(.dark)
        .nqSuccessBurst(on: simulateTrigger)
        .onAppear {
            if orderedSquad.isEmpty { orderedSquad = yourSquad }
        }
    }

    private var turnBanner: some View {
        Text(simulating ? "Battling…" : "Your turn")
            .font(NQText.captionS.font.weight(.heavy))
            .tracking(0.6)
            .foregroundStyle(accent.accent.readableTextColor())
            .nqPadding(.badge)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background {
                Capsule()
                    .fill(
                        LinearGradient(colors: [accent.accent, accent.accentDark], startPoint: .top, endPoint: .bottom)
                    )
                    .nqElevation(.card)
            }
            .contentTransition(.opacity)
            .animation(NQMotion.quick, value: simulating)
            .accessibilityAddTraits(.isHeader)
    }

    private var arena: some View {
        VStack(spacing: NQTheme.spaceM) {
            squadRow(opponentSquad, activeID: nil, label: opponentLabel, entranceDelay: 0.05, fromTop: true, side: 1)
                .offset(y: opponentLunge ? 14 : 0)
                .scaleEffect(x: opponentLunge ? 1.05 : 1, y: opponentLunge ? 0.95 : 1)
                .overlay {
                    if opponentHit {
                        RoundedRectangle(cornerRadius: NQTheme.radiusM)
                            .fill(NQTheme.battleRival.opacity(0.22))
                            .allowsHitTesting(false)
                    }
                }
                .overlay { popupLayer(side: 1) }
            vsDivider
            squadRow(displayedSquad, activeID: displayedSquad.first?.id, label: "YOUR SQUAD", entranceDelay: 0.15, fromTop: false, side: 0)
                .offset(y: yourLunge ? -14 : 0)
                .scaleEffect(x: yourLunge ? 1.05 : 1, y: yourLunge ? 0.94 : 1)
                .overlay {
                    if yourHit {
                        RoundedRectangle(cornerRadius: NQTheme.radiusM)
                            .fill(NQTheme.warning.opacity(0.22))
                            .allowsHitTesting(false)
                    }
                }
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
                .fill(
                    LinearGradient(colors: [accent.accentSoft, NQTheme.background], startPoint: .topLeading, endPoint: .bottomTrailing)
                )
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

    /// Floating damage numbers for one side of the arena.
    private func popupLayer(side: Int) -> some View {
        ZStack {
            ForEach(damagePopups.filter { $0.side == side }) { popup in
                NQFloatingValue(text: popup.text, color: popup.color, id: popup.id)
                    .offset(x: CGFloat.random(in: -30...30), y: -10)
            }
        }
        .allowsHitTesting(false)
    }

    @State private var defeatTrigger = 0

    /// Health readout: real damage taken during the replay, normalized
    /// against a nominal HP pool; falls back to static fractions pre-battle.
    private func healthFraction(active: Bool, characterID: String?) -> CGFloat {
        if let id = characterID, let taken = damageTaken[id] {
            return max(0.08, 1 - taken / 140)
        }
        if simulating { return active ? 0.35 : 0.2 }
        return active ? 0.85 : 0.6
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

    private func squadRow(_ squad: [Character], activeID: String?, label: String, entranceDelay: Double = 0, fromTop: Bool = false, side: Int = 0) -> some View {
        VStack(alignment: .leading, spacing: NQTheme.spaceS) {
            Text(label)
                .font(NQText.microS.font)
                .tracking(0.4)
                .foregroundStyle(NQTheme.battleInkMuted)
            HStack(alignment: .top, spacing: NQTheme.spaceS) {
                ForEach(squad) { character in
                    let color = character.kitColor
                    VStack(spacing: 5) {
                        characterArtwork(character, hurt: (side == 0 && yourHit) || (side == 1 && opponentHit))
                            .frame(width: character.id == activeID ? 58 : 52, height: character.id == activeID ? 74 : 66)
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(.white.opacity(0.14))
                                Capsule().fill(color.accent)
                                    .frame(width: max(4, geo.size.width * healthFraction(active: character.id == activeID, characterID: character.id)))
                            }
                        }
                        .frame(height: 6)
                        .animation(NQMotion.fill, value: damageTaken)
                        .animation(NQMotion.fill, value: simulating)
                        .accessibilityHidden(true)
                        if character.id == activeID {
                            Text("Active")
                                .font(NQText.microXS.font.weight(.heavy))
                                .foregroundStyle(.white)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(character.name), \(character.id == activeID ? "active" : "ready")")
                }
            }
        }
    }

    @ViewBuilder private func characterArtwork(_ character: Character, hurt: Bool = false) -> some View {
        // Mascot reacts to the result: star-struck on a win, deflated on a loss.
        let expression: ChibiExpression = {
            if resultText?.hasPrefix("VICTORY") == true { return .sparkle }
            if resultText?.hasPrefix("DEFEAT") == true { return .sleepy }
            return hurt ? .hurt : .happy
        }()
        CharacterArtwork(character: character, expression: expression, hurt: hurt)
    }

    private var moveGrid: some View {
        VStack(alignment: .leading, spacing: NQTheme.spaceS) {
            Text("Choose a move")
                .font(NQText.microS.font)
                .tracking(0.4)
                .foregroundStyle(NQTheme.battleInkMuted)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: NQTheme.spaceS + 2) {
                ForEach(moves) { move in
                    moveCard(move)
                }
            }
        }
    }

    /// Moves are real choices now: selectable, highlighted, and the battle
    /// button names the chosen move.
    private func moveCard(_ move: BattleMove) -> some View {
        let isSelected = selectedMove?.id == move.id
        return Button {
            NQSound.play(.tapAlt)
            selectedMove = move
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if move.statType == .protein {
                        NQAssetImage("nutriquest-strength-bolt-512")
                            .frame(width: 14, height: 14)
                            .colorMultiply(isSelected ? accent.accent : NQTheme.battleInkMuted)
                    } else {
                        Image(systemName: move.statType.systemImageName)
                            .font(.system(size: NQText.caption.size, weight: .bold))
                            .foregroundStyle(isSelected ? accent.accent : NQTheme.battleInkMuted)
                    }
                    Text(move.name)
                        .font(NQText.captionS.font.weight(.bold))
                        .foregroundStyle(NQTheme.battleInk)
                }
                Text(move.description)
                    .font(NQText.micro.font)
                    .foregroundStyle(NQTheme.battleInkMuted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .nqPadding(.badge)
            .padding(NQTheme.spaceS - 4)
            .background(RoundedRectangle(cornerRadius: NQTheme.radiusM).fill(isSelected ? accent.accent.opacity(0.18) : .white.opacity(0.08)))
            .overlay {
                RoundedRectangle(cornerRadius: NQTheme.radiusM)
                    .strokeBorder(isSelected ? accent.accent : accent.accent.opacity(0.35), lineWidth: isSelected ? 2 : 1)
            }
        }
        .buttonStyle(.nqPressable(scale: 0.97, haptic: false))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityHint("Selects this move for the battle")
    }

    /// Server-authoritative resolution: POST /battle/simulate, then the
    /// returned replay drives the local BattleKit animation. If the backend
    /// is unreachable the error surfaces via the root banner — no local
    /// fallback resolution.
    private var opponentLabel: String {
        guard let lanContext else { return "OPPONENT · RIVAL SQUAD" }
        return "OPPONENT · \(lanContext.opponentName.uppercased())"
    }

    private var primaryTitle: String {
        if simulating { return "Battling…" }
        if lanContext != nil { return resultText == nil ? "Watch the battle" : "Battle over" }
        return selectedMove.map { "Attack with \($0.name)" } ?? "Choose a move first"
    }

    /// A LAN battle is already decided; it plays once. Ranked needs a move.
    private var primaryDisabled: Bool {
        if simulating { return true }
        if lanContext != nil { return resultText != nil }
        return selectedMove == nil
    }

    private var simulateSection: some View {
        VStack(spacing: NQTheme.spaceS + 2) {
            NQButton(primaryTitle, style: .primary) {
                guard !simulating else { return }

                // LAN: the group host already simulated this; just play it.
                if let context = lanContext {
                    simulating = true
                    resultText = nil
                    damageTaken = [:]
                    Task {
                        await playChoreography()
                        defer { simulating = false }
                        await present(context.replay, mySide: context.mySide)
                    }
                    return
                }

                guard let move = selectedMove else { return }
                simulating = true
                resultText = nil
                damageTaken = [:]
                var squad = displayedSquad
                if let idx = squad.firstIndex(where: { $0.statType == move.statType }) {
                    let lead = squad.remove(at: idx)
                    squad.insert(lead, at: 0)
                    orderedSquad = squad
                }
                Task {
                    await playChoreography()
                    defer { simulating = false }
                    guard let replay = await gameState.resolveBattle(
                        yourSquad: squad,
                        opponentSquad: opponentSquad,
                        chosenMove: move.name
                    ) else {
                        resultText = nil
                        return
                    }
                    await present(replay, mySide: 0)
                }
            }
            .disabled(primaryDisabled)
            .accessibilityHint("Runs a deterministic battle simulation")

            if simulating {
                NQDotsLoader(color: accent.accent)
            }

            if let resultText {
                VStack(spacing: NQTheme.spaceS) {
                    NQBanner(
                        resultText,
                        dotColor: resultText.hasPrefix("VICTORY") ? NQTheme.success : NQTheme.warning
                    )
                    // Bragging rights — the result rendered as a share image.
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

    /// Staged beats: your lunge → opponent impact → counter → your impact →
    /// settle. Runs while the server resolves; the replay lands on the beat.
    private func playChoreography() async {
        yourLunge = true
        try? await Task.sleep(nanoseconds: 350_000_000)
        yourLunge = false
        opponentHit = true
        NQJuice.tap()
        try? await Task.sleep(nanoseconds: 250_000_000)
        opponentHit = false
        try? await Task.sleep(nanoseconds: 200_000_000)
        opponentLunge = true
        try? await Task.sleep(nanoseconds: 350_000_000)
        opponentLunge = false
        yourHit = true
        NQJuice.tap()
        try? await Task.sleep(nanoseconds: 250_000_000)
        yourHit = false
    }

    // MARK: - Replay-driven juice

    /// Animate the replay, then call the result from *your* side's view.
    private func present(_ replay: BattleReplay, mySide: Int) async {
        await animateReplay(replay)
        let won = replay.winnerSide == mySide
        resultText = won
            ? "VICTORY · \(replay.rounds) rounds"
            : "DEFEAT · \(replay.rounds) rounds"
        if won {
            simulateTrigger += 1
            NQJuice.success()
        } else {
            defeatTrigger += 1
            NQJuice.error()
        }
    }

    /// Walks the authoritative event stream: lunge → hit flash + floating
    /// damage + impact shake (crits shake harder + hit-stop) → next event.
    private func animateReplay(_ replay: BattleReplay) async {
        for event in replay.events {
            switch event {
            case .attack(let attackerID, let defenderID, _, let damage, let crit, let typeMod):
                let attackerSide = side(of: attackerID)
                let defenderSide = side(of: defenderID)
                guard attackerSide != -1, defenderSide != -1 else { continue }

                // Lunge (squash & stretch handled by the arena modifiers).
                setLunge(side: attackerSide, active: true)
                try? await Task.sleep(nanoseconds: 300_000_000)
                setLunge(side: attackerSide, active: false)

                // Impact: flash + popup + shake + juice.
                setHit(side: defenderSide, active: true)
                let isSuper = typeMod > 1.05
                let isResisted = typeMod < 0.95
                if crit {
                    showPopup("CRIT −\(Int(damage))", color: NQTheme.gold, side: defenderSide)
                } else {
                    showPopup("−\(Int(damage))", color: isSuper ? NQTheme.success : .white, side: defenderSide)
                }
                if isSuper { showPopup("Super effective!", color: NQTheme.success, side: defenderSide) }
                if isResisted { showPopup("Not very effective…", color: NQTheme.battleInkMuted, side: defenderSide) }
                impactTrigger += 1
                if crit { NQJuice.crit() } else { NQJuice.hit(heavy: isSuper) }
                recordDamage(damage, on: defenderID)

                // Hit-stop: freeze the beat briefly on heavy hits.
                try? await Task.sleep(nanoseconds: crit ? 160_000_000 : 90_000_000)
                setHit(side: defenderSide, active: false)
                try? await Task.sleep(nanoseconds: 220_000_000)

            case .miss(_, let defenderID):
                showPopup("MISS!", color: NQTheme.battleInkMuted, side: side(of: defenderID))
                try? await Task.sleep(nanoseconds: 400_000_000)

            case .faint(let unitID):
                showPopup("KO!", color: NQTheme.warning, side: side(of: unitID))
                NQJuice.hit(heavy: true)
                try? await Task.sleep(nanoseconds: 450_000_000)

            case .victory:
                NQJuice.success()

            case .roundStart, .roundEnd, .battleStart:
                break
            }
        }
    }

    private func side(of unitID: UUID) -> Int {
        guard let charID = unitCharacterIDs[unitID] else { return -1 }
        if displayedSquad.contains(where: { $0.id == charID }) { return 0 }
        if opponentSquad.contains(where: { $0.id == charID }) { return 1 }
        return -1
    }

    private func setLunge(side: Int, active: Bool) {
        if side == 0 { yourLunge = active } else { opponentLunge = active }
    }

    private func setHit(side: Int, active: Bool) {
        if side == 0 { yourHit = active } else { opponentHit = active }
    }

    private func showPopup(_ text: String, color: Color, side: Int) {
        guard side != -1 else { return }
        let popup = BattlePopup(text: text, color: color, side: side)
        withAnimation(NQMotion.quick) { damagePopups.append(popup) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            damagePopups.removeAll { $0.id == popup.id }
        }
    }

    private func recordDamage(_ damage: Double, on unitID: UUID) {
        guard let charID = unitCharacterIDs[unitID] else { return }
        damageTaken[charID, default: 0] += damage
    }

    private var secondaryActions: some View {
        HStack(spacing: NQTheme.spaceS + 2) {
            // Reordering is a ranked-only choice; a LAN squad is locked in.
            if lanContext == nil && displayedSquad.count > 1 {
                NQButton("Switch Character", style: .secondary, fullWidth: false) {
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
