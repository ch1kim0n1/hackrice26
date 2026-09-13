import SwiftUI
import NutriQuestUI
import BattleKit

/// LAN Battle entry point: host a group or join one nearby, then challenge
/// anyone in it — or, as host, run a tournament. Casual and unranked: nothing
/// here touches XP, rank or capsules.
struct LANLobbyView: View {
    @ObservedObject var gameState: GameState
    @StateObject private var session = LANSession()

    @Environment(\.nqAccent) private var accent
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var groupName = ""
    @State private var pulse = false

    var body: some View {
        Group {
            if session.isInGroup {
                LANGroupView(session: session, client: session.client, gameState: gameState)
            } else {
                discovery
            }
        }
        .nqPageBackground()
        .navigationTitle("LAN Battle")
        .navigationBarTitleDisplayMode(.inline)
        // In a group you leave deliberately; a stray back-swipe shouldn't
        // drop you out of a tournament.
        .navigationBarBackButtonHidden(session.isInGroup)
        .onChange(of: scenePhase) { phase in
            // iOS tears MultipeerConnectivity down in the background anyway.
            if phase == .background { session.leave() }
        }
        .onDisappear {
            // Popped back to the hub while only browsing.
            if !session.isInGroup { session.leave() }
        }
        .alert("LAN Battle", isPresented: errorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(session.error ?? "")
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { session.error != nil },
            set: { if !$0 { session.error = nil } }
        )
    }

    // MARK: - Discovery

    private var discovery: some View {
        ScrollView {
            VStack(spacing: NQTheme.spaceL) {
                radar

                VStack(spacing: 4) {
                    Text("Battle friends nearby")
                        .font(NQText.headingL.font.weight(.heavy))
                        .foregroundStyle(NQTheme.ink)
                    Text("Everyone on the same Wi-Fi can join. Casual play — no XP or rank on the line.")
                        .font(NQText.captionS.font)
                        .foregroundStyle(NQTheme.inkMuted)
                        .multilineTextAlignment(.center)
                }

                hostCard

                VStack(alignment: .leading, spacing: NQTheme.spaceS) {
                    NQSectionHeader("Groups nearby")
                    if session.groups.isEmpty {
                        HStack(spacing: NQTheme.spaceS) {
                            NQDotsLoader(color: accent.accentDark)
                            Text("Looking for groups…")
                                .font(NQText.captionS.font)
                                .foregroundStyle(NQTheme.inkMuted)
                        }
                        .accessibilityElement(children: .combine)
                    } else {
                        ForEach(session.groups) { group in
                            groupRow(group)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if session.showPermissionHint {
                    NQBanner.warning("Nothing found yet. Check Settings › Privacy & Security › Local Network and make sure NutriQuest is on.")
                }
            }
            .padding(NQTheme.spaceL)
        }
        .onAppear {
            session.browse()
            pulse = true
        }
    }

    private var radar: some View {
        ZStack {
            if !reduceMotion {
                ForEach(0..<2, id: \.self) { i in
                    Circle()
                        .stroke(accent.accent.opacity(0.35), lineWidth: 2)
                        .frame(width: pulse ? 150 : 70, height: pulse ? 150 : 70)
                        .opacity(pulse ? 0 : 1)
                        .animation(
                            .easeOut(duration: 1.4).repeatForever(autoreverses: false).delay(Double(i) * 0.6),
                            value: pulse
                        )
                }
            }
            Circle()
                .fill(accent.accent)
                .frame(width: 64, height: 64)
                .overlay {
                    NQIcon.battle.view
                        .frame(width: 28, height: 28)
                        .foregroundStyle(accent.accent.readableTextColor())
                }
        }
        .frame(height: 150)
        .accessibilityHidden(true)
    }

    private var hostCard: some View {
        NQCard {
            VStack(alignment: .leading, spacing: NQTheme.spaceS) {
                Text("Host a group")
                    .font(NQText.bodyL.font.weight(.bold))
                    .foregroundStyle(NQTheme.ink)
                TextField("\(session.me.name)'s group", text: $groupName)
                    .font(NQText.body.font)
                    .nqPadding(.chip)
                    .background(accent.accentBg)
                    .clipShape(RoundedRectangle(cornerRadius: NQTheme.radiusM))
                NQButton("Host", icon: .crown) {
                    session.hostGroup(named: groupName)
                }
                .disabled(session.role == .joining)
            }
        }
    }

    private func groupRow(_ group: LANDiscoveredGroup) -> some View {
        let compatible = group.version == LANProtocolVersion.current
        return HStack(spacing: NQTheme.spaceM) {
            VStack(alignment: .leading, spacing: 2) {
                Text(group.name)
                    .font(NQText.bodyL.font.weight(.bold))
                    .foregroundStyle(NQTheme.ink)
                Text(compatible ? "Tap to join" : "Different app version")
                    .font(NQText.captionS.font)
                    .foregroundStyle(compatible ? NQTheme.inkMuted : NQTheme.warning)
            }
            Spacer()
            NQButton(session.role == .joining ? "Joining…" : "Join", style: .secondary, fullWidth: false) {
                session.join(group)
            }
            .disabled(!compatible || session.role == .joining)
        }
        .nqPadding(.card)
        .background(NQTheme.background)
        .clipShape(RoundedRectangle(cornerRadius: NQTheme.radiusM))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - In a group

struct LANGroupView: View {
    @ObservedObject var session: LANSession
    @ObservedObject var client: LANClient
    @ObservedObject var gameState: GameState

    @Environment(\.nqAccent) private var accent

    var body: some View {
        ScrollView {
            VStack(spacing: NQTheme.spaceL) {
                header

                if let notice = client.notice {
                    NQBanner(notice, onDismiss: { client.notice = nil })
                }

                if let bracket = client.bracket {
                    LANBracketView(bracket: bracket, names: client.names)
                }

                if client.isHost {
                    tournamentButton
                }

                VStack(alignment: .leading, spacing: NQTheme.spaceS) {
                    NQSectionHeader("Players", trailing: "\(client.players.count)/\(LANLimits.maxPlayers)")
                    ForEach(client.players, id: \.id) { player in
                        rosterRow(player)
                    }
                }

                NQButton("Leave group", style: .ghost) { session.leave() }
            }
            .padding(NQTheme.spaceL)
        }
        .alert("Challenge!", isPresented: offerBinding, presenting: client.incomingOffer) { _ in
            Button("Battle") { client.respond(accept: true) }
            Button("Not now", role: .cancel) { client.respond(accept: false) }
        } message: { offer in
            Text("\(client.name(for: offer.challengerID)) wants to battle.")
        }
        .fullScreenCover(isPresented: matchBinding) {
            LANMatchView(client: client, gameState: gameState)
        }
    }

    private var offerBinding: Binding<Bool> {
        Binding(get: { client.incomingOffer != nil }, set: { _ in })
    }

    private var matchBinding: Binding<Bool> {
        Binding(
            get: { client.activeMatch != nil },
            set: { if !$0 { client.clearMatch() } }
        )
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(client.isHost ? "You're hosting" : "In a group")
                .font(NQText.microXS.font)
                .tracking(0.6)
                .foregroundStyle(accent.accentDark)
            Text(session.groupName ?? "LAN group")
                .font(NQText.headingL.font.weight(.heavy))
                .foregroundStyle(NQTheme.ink)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var tournamentButton: some View {
        let running = client.bracket.map { $0.champion == nil } ?? false
        return NQButton(running ? "Tournament in progress" : "Start tournament", icon: .trophy) {
            client.startTournament()
        }
        .disabled(running || client.players.count < 2 || !client.busy.isEmpty)
        .accessibilityHint("Pairs everyone in the group into a knockout bracket.")
    }

    private func rosterRow(_ player: LANPlayer) -> some View {
        let isYou = player.id == client.me.id
        let isBusy = client.busy.contains(player.id)
        let waiting = client.outgoingChallenge == player.id
        let status: String = {
            var parts: [String] = []
            if player.id == client.hostID { parts.append("Host") }
            parts.append(isBusy ? "In a match" : "Ready")
            return parts.joined(separator: " · ")
        }()

        return HStack(spacing: NQTheme.spaceM) {
            Circle()
                .fill(isYou ? accent.accent : NQTheme.inkFaint.opacity(0.3))
                .frame(width: 40, height: 40)
                .overlay {
                    Text(String(player.name.prefix(1)).uppercased())
                        .font(NQText.bodyL.font.weight(.heavy))
                        .foregroundStyle(isYou ? accent.accent.readableTextColor() : NQTheme.ink)
                }
            VStack(alignment: .leading, spacing: 2) {
                Text(isYou ? "\(player.name) (you)" : player.name)
                    .font(NQText.bodyL.font.weight(.bold))
                    .foregroundStyle(NQTheme.ink)
                Text(status)
                    .font(NQText.captionS.font)
                    .foregroundStyle(NQTheme.inkMuted)
            }
            Spacer()
            if !isYou {
                NQButton(waiting ? "Waiting…" : "Challenge", icon: .battle, style: .secondary, fullWidth: false) {
                    client.challenge(player.id)
                }
                .disabled(isBusy || waiting || client.busy.contains(client.me.id) || client.activeMatch != nil)
            }
        }
        .nqPadding(.card)
        .background(isYou ? accent.accent.opacity(0.15) : NQTheme.background)
        .clipShape(RoundedRectangle(cornerRadius: NQTheme.radiusM))
        .overlay {
            if isYou {
                RoundedRectangle(cornerRadius: NQTheme.radiusM)
                    .strokeBorder(accent.accent, lineWidth: 2)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Bracket

struct LANBracketView: View {
    let bracket: LANBracket
    let names: [String: String]

    @Environment(\.nqAccent) private var accent

    var body: some View {
        VStack(alignment: .leading, spacing: NQTheme.spaceS) {
            NQSectionHeader("Tournament", trailing: bracket.champion == nil ? "Live" : "Finished")

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .center, spacing: NQTheme.spaceM) {
                    ForEach(Array(bracket.rounds.enumerated()), id: \.offset) { roundIndex, round in
                        VStack(spacing: NQTheme.spaceS) {
                            Text(title(for: roundIndex))
                                .font(NQText.microS.font)
                                .tracking(0.4)
                                .foregroundStyle(NQTheme.inkMuted)
                            ForEach(Array(round.enumerated()), id: \.offset) { _, pairing in
                                pairingCard(pairing)
                            }
                        }
                    }
                }
            }

            if let champion = bracket.champion {
                NQBanner("**\(name(champion))** wins the tournament!", dotColor: NQTheme.gold)
            }
        }
    }

    private func title(for round: Int) -> String {
        let total = bracket.rounds.count
        if round == total - 1 { return "FINAL" }
        if round == total - 2 { return "SEMIS" }
        return "ROUND \(round + 1)"
    }

    private func name(_ id: String) -> String { names[id] ?? "Player" }

    private func pairingCard(_ pairing: LANPairing) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            slot(pairing.a, pairing: pairing)
            slot(pairing.b, pairing: pairing)
        }
        .padding(8)
        .frame(width: 130, alignment: .leading)
        .background(NQTheme.background)
        .clipShape(RoundedRectangle(cornerRadius: NQTheme.radiusM))
        .overlay {
            if pairing.live {
                RoundedRectangle(cornerRadius: NQTheme.radiusM)
                    .strokeBorder(accent.accent, lineWidth: 2)
            }
        }
    }

    private func slot(_ player: String?, pairing: LANPairing) -> some View {
        let isWinner = player != nil && player == pairing.winner
        let isLoser = pairing.winner != nil && player != nil && player != pairing.winner
        return Text(player.map { name($0) } ?? "—")
            .font(NQText.captionS.font.weight(isWinner ? .heavy : .regular))
            .foregroundStyle(isWinner ? NQTheme.ink : (isLoser ? NQTheme.inkFaint : NQTheme.inkMuted))
            .strikethrough(isLoser)
            .lineLimit(1)
    }
}

// MARK: - Match flow

/// Full-screen for the length of one match: pick → wait → battle (or a
/// cancellation). The squad order locked here is the order that fights.
struct LANMatchView: View {
    @ObservedObject var client: LANClient
    @ObservedObject var gameState: GameState

    @Environment(\.nqAccent) private var accent

    var body: some View {
        NavigationStack {
            Group {
                if let match = client.activeMatch {
                    content(match)
                } else {
                    Color.clear
                }
            }
            .safeAreaInset(edge: .top) {
                if let notice = client.notice {
                    NQBanner(notice, onDismiss: { client.notice = nil })
                        .padding(.horizontal, NQTheme.spaceL)
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if isFinished {
                        Button(client.hasQueuedMatch ? "Next match" : "Lobby") { client.clearMatch() }
                    }
                }
            }
        }
    }

    private var isFinished: Bool {
        guard let match = client.activeMatch else { return true }
        switch match.phase {
        case .resolved, .cancelled: return true
        case .picking, .waiting, .revealing: return false
        }
    }

    @ViewBuilder
    private func content(_ match: LANClient.ActiveMatch) -> some View {
        switch match.phase {
        case .picking(let deadline):
            SquadPickerView(
                characters: gameState.collection.filter { !$0.isLocked },
                opponentName: client.name(for: match.opponentID),
                deadline: deadline
            ) { chosen in
                if let squad = gameState.lanSquad(from: chosen) {
                    client.lockIn(squad)
                } else {
                    client.notice = "Couldn't build that squad — try three different characters."
                }
            }

        case .waiting, .revealing:
            waiting(match)

        case .resolved(let result):
            BattleView(
                yourSquad: result.myCharacters,
                opponentSquad: result.opponentCharacters,
                fatigued: false,
                moves: [],
                gameState: gameState,
                mode: .lan(LANBattleContext(
                    replay: result.replay,
                    opponentName: client.name(for: result.opponentID),
                    mySide: result.mySide,
                    unitCharacterIDs: result.unitCharacterIDs
                ))
            )

        case .cancelled(let reason):
            cancelled(reason)
        }
    }

    private func waiting(_ match: LANClient.ActiveMatch) -> some View {
        VStack(spacing: NQTheme.spaceM) {
            NQDotsLoader(color: accent.accent)
            Text(match.phase == .revealing
                 ? "Both squads locked — revealing…"
                 : "Waiting for \(client.name(for: match.opponentID)) to lock in…")
                .font(NQText.bodyL.font.weight(.semibold))
                .foregroundStyle(NQTheme.ink)
                .multilineTextAlignment(.center)
            Text("Squads stay hidden until both are locked, so nobody can counter-pick.")
                .font(NQText.captionS.font)
                .foregroundStyle(NQTheme.inkMuted)
                .multilineTextAlignment(.center)
        }
        .padding(NQTheme.spaceXL)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .nqPageBackground()
        .accessibilityElement(children: .combine)
    }

    private func cancelled(_ reason: String) -> some View {
        VStack(spacing: NQTheme.spaceM) {
            NQIcon.alert.view
                .frame(width: 36, height: 36)
                .foregroundStyle(NQTheme.warning)
            Text("Match ended")
                .font(NQText.headingL.font.weight(.heavy))
                .foregroundStyle(NQTheme.ink)
            Text(reason)
                .font(NQText.body.font)
                .foregroundStyle(NQTheme.inkMuted)
                .multilineTextAlignment(.center)
            NQButton("Back to lobby") { client.clearMatch() }
        }
        .padding(NQTheme.spaceXL)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .nqPageBackground()
        .accessibilityElement(children: .combine)
    }
}
