import Foundation
import BattleKit

/// A resolved LAN match, from one fighter's point of view.
struct LANMatchResult: Equatable {
    let matchID: UUID
    let opponentID: String
    let mySide: Int
    let replay: BattleReplay
    let mySquad: LANSquad
    let opponentSquad: LANSquad

    var didWin: Bool { replay.winnerSide == mySide }

    var myCharacters: [Character] { mySquad.units.map(\.character) }

    /// Namespaced: every player starts with the same roster ids, and
    /// BattleView attributes sides and health bars by character id.
    var opponentCharacters: [Character] { opponentSquad.units.map { $0.character.asLANOpponent() } }

    /// Replay unit id → on-screen character id. Unit ids are derived from
    /// (match, side, slot), so this is rebuilt locally rather than sent.
    var unitCharacterIDs: [UUID: String] {
        var map: [UUID: String] = [:]
        for (slot, character) in myCharacters.enumerated() {
            map[LANCrypto.unitID(matchID: matchID, side: mySide, slot: slot)] = character.id
        }
        for (slot, character) in opponentCharacters.enumerated() {
            map[LANCrypto.unitID(matchID: matchID, side: 1 - mySide, slot: slot)] = character.id
        }
        return map
    }
}

/// One player's view of the group — including the host's own player, who
/// talks to `LANHost` through an in-process loopback like everyone else.
@MainActor
final class LANClient: ObservableObject {
    struct Offer: Identifiable, Equatable {
        let matchID: UUID
        let challengerID: String
        var id: UUID { matchID }
    }

    enum MatchPhase: Equatable {
        case picking(deadline: Date)
        /// Committed; waiting for the opponent to lock in.
        case waiting
        case revealing
        case resolved(LANMatchResult)
        case cancelled(String)
    }

    struct ActiveMatch: Equatable {
        let matchID: UUID
        let opponentID: String
        let side: Int
        let isTournament: Bool
        var phase: MatchPhase
    }

    let me: LANPlayer
    /// Outbound to the host (MPC, or loopback on the host device).
    var send: ((Data) -> Void)?

    @Published private(set) var players: [LANPlayer] = []
    @Published private(set) var busy: Set<String> = []
    @Published private(set) var hostID: String?
    @Published private(set) var bracket: LANBracket?
    @Published var incomingOffer: Offer?
    @Published private(set) var outgoingChallenge: String?
    @Published private(set) var activeMatch: ActiveMatch?
    @Published var notice: String?
    /// Every name ever seen, so a bracket still reads after someone leaves.
    @Published private(set) var names: [String: String] = [:]

    private let clock: () -> Date
    private var pendingReveal: (matchID: UUID, nonce: Data, squadBytes: Data, squad: LANSquad)?
    /// A bracket match that started while a result was still on screen. The
    /// host moves the bracket on immediately; the player shouldn't lose the
    /// battle they were watching.
    private var queuedMatch: ActiveMatch?
    private var seen: Set<UUID> = []
    private var inbox: [Data] = []
    private var draining = false

    init(me: LANPlayer, clock: @escaping () -> Date = { Date() }) {
        self.me = me
        self.clock = clock
        self.names[me.id] = me.name
    }

    var isHost: Bool { hostID == me.id }

    /// A bracket match is waiting behind the result on screen.
    var hasQueuedMatch: Bool { queuedMatch != nil }

    func name(for id: String) -> String { names[id] ?? "Player" }

    // MARK: - Actions

    func connect() { post(.hello(player: me)) }

    func challenge(_ playerID: String) {
        outgoingChallenge = playerID
        post(.challenge(target: playerID))
    }

    func respond(accept: Bool) {
        guard let offer = incomingOffer else { return }
        incomingOffer = nil
        post(.offerReply(matchID: offer.matchID, accept: accept))
    }

    func startTournament() { post(.startTournament) }

    func leave() { post(.leave) }

    /// Commit to a squad without revealing it. The reveal only goes out once
    /// the host confirms both fighters have committed.
    func lockIn(_ squad: LANSquad) {
        guard var match = activeMatch, case .picking = match.phase else { return }
        guard (try? squad.validate()) != nil, let bytes = try? JSONEncoder().encode(squad) else {
            notice = "That squad can't be used — pick three different characters."
            return
        }
        let nonce = LANCrypto.makeNonce()
        let hash = LANCrypto.commitment(matchID: match.matchID, playerID: me.id, side: match.side,
                                        nonce: nonce, squadBytes: bytes)
        pendingReveal = (match.matchID, nonce, bytes, squad)
        match.phase = .waiting
        activeMatch = match
        post(.commit(matchID: match.matchID, hash: hash))
    }

    /// Dismiss a finished or cancelled match — straight into the next bracket
    /// match if one is waiting. An in-progress match stays put.
    func clearMatch() {
        guard let match = activeMatch else { return }
        switch match.phase {
        case .resolved, .cancelled:
            pendingReveal = nil
            activeMatch = queuedMatch
            queuedMatch = nil
        case .picking, .waiting, .revealing:
            break
        }
    }

    /// A finished match still on screen (result or cancellation).
    private var isShowingOutcome: Bool {
        switch activeMatch?.phase {
        case .resolved?, .cancelled?: return true
        default: return false
        }
    }

    /// Forget the group entirely (on leave).
    func reset() {
        send = nil
        players = []
        busy = []
        hostID = nil
        bracket = nil
        incomingOffer = nil
        outgoingChallenge = nil
        activeMatch = nil
        notice = nil
        pendingReveal = nil
        queuedMatch = nil
        seen = []
        inbox = []
    }

    // MARK: - Inbound

    func receive(_ data: Data) {
        inbox.append(data)
        guard !draining else { return }
        draining = true
        while !inbox.isEmpty {
            process(inbox.removeFirst())
        }
        draining = false
    }

    private func process(_ data: Data) {
        guard let envelope = LANWire.decode(data), seen.insert(envelope.id).inserted else { return }

        switch envelope.message {
        case .roster(let players, let busy, let hostID):
            self.players = players
            self.busy = Set(busy)
            self.hostID = hostID
            for player in players { names[player.id] = player.name }

        case .challengeRejected(_, let reason):
            outgoingChallenge = nil
            notice = reason

        case .matchOffer(let matchID, let challengerID):
            // Already mid-match: decline rather than stack offers.
            guard activeMatch == nil else {
                post(.offerReply(matchID: matchID, accept: false))
                return
            }
            incomingOffer = Offer(matchID: matchID, challengerID: challengerID)

        case .matchStart(let matchID, let opponentID, let side, let pickSeconds, let tournament):
            incomingOffer = nil
            outgoingChallenge = nil
            let next = ActiveMatch(
                matchID: matchID,
                opponentID: opponentID,
                side: side,
                isTournament: tournament,
                phase: .picking(deadline: clock().addingTimeInterval(TimeInterval(pickSeconds)))
            )
            // Don't yank a result off screen mid-watch; queue the next match.
            if isShowingOutcome {
                queuedMatch = next
                notice = "Your next match vs \(name(for: opponentID)) is ready — head back to pick your squad."
                return
            }
            pendingReveal = nil
            activeMatch = next

        case .revealNow(let matchID):
            guard let pending = pendingReveal, pending.matchID == matchID,
                  var match = activeMatch, match.matchID == matchID else { return }
            match.phase = .revealing
            activeMatch = match
            post(.reveal(matchID: matchID, nonce: pending.nonce, squad: pending.squadBytes))

        case .replay(let matchID, let opponentData, let wireReplay):
            guard let pending = pendingReveal, pending.matchID == matchID,
                  var match = activeMatch, match.matchID == matchID,
                  let opponent = try? JSONDecoder().decode(LANSquad.self, from: opponentData),
                  (try? opponent.validate()) != nil,
                  let replay = wireReplay.battleReplay else { return }
            match.phase = .resolved(LANMatchResult(
                matchID: matchID,
                opponentID: match.opponentID,
                mySide: match.side,
                replay: replay,
                mySquad: pending.squad,
                opponentSquad: opponent
            ))
            activeMatch = match

        case .matchCancelled(let matchID, let reason):
            if incomingOffer?.matchID == matchID { incomingOffer = nil }
            guard var match = activeMatch, match.matchID == matchID else {
                // A challenge that was declined or ignored before it started.
                outgoingChallenge = nil
                notice = reason
                return
            }
            // A result already on screen stands.
            if case .resolved = match.phase { return }
            match.phase = .cancelled(reason)
            activeMatch = match

        case .bracket(let bracket):
            self.bracket = bracket

        case .hello, .challenge, .offerReply, .commit, .reveal, .startTournament, .leave:
            // Client → host messages; never expected here.
            break
        }
    }

    private func post(_ message: LANMessage) {
        send?(LANWire.encode(message))
    }
}
