import Foundation
import BattleKit

/// A connection to the host: a remote joiner, or the host's own player via
/// in-process loopback. Opaque on purpose — identity comes from `hello`.
struct LANPeer: Hashable {
    let id: String

    /// The host device's own player.
    static let local = LANPeer(id: "local")
}

/// The group host: sole authority for the roster, match creation, busy locks,
/// timeouts, commit/reveal checking, **simulation**, and the bracket.
///
/// Senders are identified by the connection a message arrived on (recorded at
/// `hello`), never by anything inside the message. Every entry point runs
/// through one serial queue, so a synchronous reply from the local player
/// can't re-enter the host halfway through an update.
@MainActor
final class LANHost {
    let hostID: String
    /// Outbound delivery, wired by LANSession (MPC + loopback) or by tests.
    var send: ((Data, LANPeer) -> Void)?

    private let clock: () -> Date

    private(set) var players: [String: LANPlayer] = [:]
    /// Join order, for a stable roster.
    private var order: [String] = []
    private var peerToPlayer: [LANPeer: String] = [:]
    private var playerToPeer: [String: LANPeer] = [:]
    private(set) var matches: [UUID: LANHostMatch] = [:]
    private var bracketSlots: [UUID: (round: Int, index: Int)] = [:]
    private(set) var tournament: LANTournament?

    private var seenMessages: Set<UUID> = []
    private var inbox: [(Data, LANPeer)] = []
    private var draining = false

    init(hostID: String, clock: @escaping () -> Date = { Date() }) {
        self.hostID = hostID
        self.clock = clock
    }

    /// Players in an unfinished match (including one still being offered).
    var busyPlayers: Set<String> {
        Set(matches.values.filter { $0.phase != .finished }.flatMap { $0.participants })
    }

    // MARK: - Entry points

    func receive(_ data: Data, from peer: LANPeer) {
        inbox.append((data, peer))
        serialized {}
    }

    func peerDisconnected(_ peer: LANPeer) {
        serialized {
            guard let id = peerToPlayer[peer] else { return }
            removePlayer(id)
        }
    }

    /// Call about once a second; drives the match timeouts.
    func tick() {
        serialized {
            for id in Array(matches.keys) {
                route(id, .tick)
            }
        }
    }

    /// Tests: resolution is synchronous now, so there is never anything
    /// in flight — kept so the test group's drive loop reads unchanged.
    func waitForResolutions() async {}

    // MARK: - Serial processing

    private func serialized(_ work: () -> Void) {
        if draining {
            work()
            return
        }
        draining = true
        work()
        while !inbox.isEmpty {
            let (data, peer) = inbox.removeFirst()
            process(data, from: peer)
        }
        draining = false
    }

    private func process(_ data: Data, from peer: LANPeer) {
        guard let envelope = LANWire.decode(data) else { return }
        guard seenMessages.insert(envelope.id).inserted else { return }
        if seenMessages.count > 4096 { seenMessages.removeAll() }

        if case .hello(let player) = envelope.message {
            handleHello(player, from: peer)
            return
        }
        // Nothing counts until the connection has said who it is.
        guard let from = peerToPlayer[peer] else { return }

        switch envelope.message {
        case .challenge(let target):
            handleChallenge(from: from, target: target)
        case .offerReply(let matchID, let accept):
            route(matchID, .offerReply(from: from, accept: accept))
        case .commit(let matchID, let hash):
            route(matchID, .commit(from: from, hash: hash))
        case .reveal(let matchID, let nonce, let squad):
            route(matchID, .reveal(from: from, nonce: nonce, squadBytes: squad))
        case .startTournament:
            if from == hostID { startTournament() }
        case .leave:
            removePlayer(from)
        default:
            // Host → client messages have no meaning arriving here.
            break
        }
    }

    // MARK: - Roster

    private func handleHello(_ player: LANPlayer, from peer: LANPeer) {
        let id = player.id.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = player.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, id.count <= LANLimits.maxPlayerIDLength, !name.isEmpty else { return }
        // One identity per connection, and an id already held by another
        // connection can't be claimed — that would be impersonation.
        guard peerToPlayer[peer] == nil, players[id] == nil,
              players.count < LANLimits.maxPlayers else { return }

        players[id] = LANPlayer(id: id, name: String(name.prefix(LANLimits.maxNameLength)))
        order.append(id)
        peerToPlayer[peer] = id
        playerToPeer[id] = peer
        broadcastRoster()
        if let tournament {
            deliver(.bracket(tournament.bracket), to: id)
        }
    }

    private func removePlayer(_ id: String) {
        // Stop delivering to them first…
        if let peer = playerToPeer.removeValue(forKey: id) {
            peerToPlayer[peer] = nil
        }
        // …but settle their matches while their name is still known, so the
        // opponent sees "Cara forfeited", not "A player forfeited".
        for matchID in Array(matches.keys) where matches[matchID]?.participants.contains(id) == true {
            route(matchID, .playerLeft(id))
        }
        players[id] = nil
        order.removeAll { $0 == id }
        tournament?.playerLeft(id)
        startReadyTournamentMatches()
        broadcastRoster()
        broadcastBracket()
    }

    // MARK: - Matches

    private func handleChallenge(from: String, target: String) {
        func reject(_ reason: String) {
            deliver(.challengeRejected(target: target, reason: reason), to: from)
        }
        guard target != from, players[target] != nil else { return reject("That player isn't in the group") }
        let busy = busyPlayers
        guard !busy.contains(from) else { return reject("You're already in a match") }
        let targetName = players[target]?.name ?? "That player"
        guard !busy.contains(target) else { return reject("\(targetName) is busy right now") }
        if let tournament, tournament.isActiveParticipant(from) || tournament.isActiveParticipant(target) {
            return reject("Tournament players can't take free challenges")
        }

        let (match, outputs) = LANHostMatch.free(challenger: from, target: target, now: clock())
        matches[match.matchID] = match
        perform(outputs, matchID: match.matchID)
        broadcastRoster()
    }

    private func route(_ matchID: UUID, _ event: LANHostMatch.Event) {
        guard var match = matches[matchID] else { return }
        let outputs = match.handle(event, now: clock())
        matches[matchID] = match
        perform(outputs, matchID: matchID)
    }

    private func perform(_ outputs: [LANHostMatch.Output], matchID: UUID) {
        for output in outputs {
            switch output {
            case .send(let to, let message):
                deliver(message, to: to)

            case .resolve(let resolution):
                resolve(resolution)

            case .cancelled(let reason):
                if let match = matches[matchID] {
                    for player in match.participants {
                        deliver(.matchCancelled(matchID: matchID, reason: reason), to: player)
                    }
                }
                matches[matchID] = nil
                broadcastRoster()

            case .forfeit(let loser, let reason):
                guard let match = matches[matchID] else { break }
                let loserName = players[loser]?.name ?? "A player"
                for player in match.participants {
                    deliver(.matchCancelled(matchID: matchID, reason: "\(loserName) forfeited: \(reason)"), to: player)
                }
                matches[matchID] = nil
                if let winner = match.opponent(of: loser) {
                    recordTournamentResult(matchID: matchID, winner: winner)
                }
                broadcastRoster()
            }
        }
    }

    /// Runs the unchanged BattleKit engine. Only the host ever simulates, so
    /// devices on different iOS versions can't disagree about an outcome.
    /// The engine is synchronous and pure — resolution completes inline.
    private func resolve(_ resolution: LANResolution) {
        let squadA = resolution.squadA.battleSpecs(matchID: resolution.matchID, side: 0)
        let squadB = resolution.squadB.battleSpecs(matchID: resolution.matchID, side: 1)
        let replay = BattleEngine.simulate(squadA: squadA, squadB: squadB, seed: resolution.seed)
        serialized {
            deliverResolution(resolution, replay: replay)
        }
    }

    private func deliverResolution(_ resolution: LANResolution, replay: BattleReplay) {
        guard let match = matches[resolution.matchID] else { return }
        matches[resolution.matchID] = nil

        let wire = LANReplay(replay)
        // Each fighter gets the other's revealed bytes, verbatim.
        deliver(.replay(matchID: resolution.matchID, opponentSquad: resolution.squadBytesB, replay: wire), to: match.playerA)
        deliver(.replay(matchID: resolution.matchID, opponentSquad: resolution.squadBytesA, replay: wire), to: match.playerB)

        let winner = replay.winnerSide == 0 ? match.playerA : match.playerB
        recordTournamentResult(matchID: resolution.matchID, winner: winner)
        broadcastRoster()
    }

    // MARK: - Tournament

    /// Host-only. `seeding` lets tests fix the order; otherwise it's shuffled.
    func startTournament(seeding: [String]? = nil) {
        serialized {
            guard tournament == nil || tournament?.isFinished == true else { return }
            guard busyPlayers.isEmpty else {
                deliver(.challengeRejected(target: "", reason: "Finish the current matches first"), to: hostID)
                return
            }
            let ids = seeding ?? order.shuffled()
            guard ids.count >= 2 else {
                deliver(.challengeRejected(target: "", reason: "A tournament needs at least 2 players"), to: hostID)
                return
            }
            tournament = LANTournament(seeds: ids)
            bracketSlots = [:]
            startReadyTournamentMatches()
            broadcastBracket()
        }
    }

    private func startReadyTournamentMatches() {
        guard let ready = tournament?.ready else { return }
        for pairing in ready {
            let (match, outputs) = LANHostMatch.tournament(playerA: pairing.a, playerB: pairing.b, now: clock())
            tournament?.markLive(round: pairing.round, index: pairing.index)
            matches[match.matchID] = match
            bracketSlots[match.matchID] = (pairing.round, pairing.index)
            perform(outputs, matchID: match.matchID)
        }
    }

    private func recordTournamentResult(matchID: UUID, winner: String) {
        guard let slot = bracketSlots.removeValue(forKey: matchID) else { return }
        tournament?.record(winner: winner, round: slot.round, index: slot.index)
        startReadyTournamentMatches()
        broadcastBracket()
    }

    // MARK: - Delivery

    private func broadcastRoster() {
        let roster = LANMessage.roster(
            players: order.compactMap { players[$0] },
            busy: busyPlayers.sorted(),
            hostID: hostID
        )
        for id in order {
            deliver(roster, to: id)
        }
    }

    private func broadcastBracket() {
        guard let tournament else { return }
        for id in order {
            deliver(.bracket(tournament.bracket), to: id)
        }
    }

    private func deliver(_ message: LANMessage, to playerID: String) {
        guard let peer = playerToPeer[playerID] else { return }
        send?(LANWire.encode(message), peer)
    }
}
