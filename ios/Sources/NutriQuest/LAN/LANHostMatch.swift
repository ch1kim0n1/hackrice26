import Foundation

/// Everything the host needs to run the engine once both squads are revealed.
struct LANResolution: Equatable {
    let matchID: UUID
    let squadA: LANSquad
    let squadB: LANSquad
    let squadBytesA: Data
    let squadBytesB: Data
    let seed: UInt64
}

/// One match, as the host sees it. A pure state machine: feed it an event and
/// the current time, get back what to send. No networking, no clock of its own,
/// so every race and timeout is unit-testable.
///
///   offered ──accept──▶ picking ──both commits──▶ revealing ──both reveals──▶ resolving
///      │                   │                          │
///      └─ decline/timeout ─┴───── timeout / leave ────┴─▶ finished (cancel or forfeit)
///
/// Tournament matches skip `offered`: the bracket already paired them.
struct LANHostMatch {
    enum Phase: Equatable {
        case offered, picking, revealing, resolving, finished
    }

    enum Event {
        case offerReply(from: String, accept: Bool)
        case commit(from: String, hash: Data)
        case reveal(from: String, nonce: Data, squadBytes: Data)
        case playerLeft(String)
        case tick
    }

    enum Output: Equatable {
        case send(to: String, LANMessage)
        case resolve(LANResolution)
        /// Free matches just end. Both fighters are told why.
        case cancelled(reason: String)
        /// Tournament matches need a winner, so a failure hands it to the other side.
        case forfeit(loser: String, reason: String)
    }

    struct Revealed: Equatable {
        let nonce: Data
        let squadBytes: Data
        let squad: LANSquad
    }

    let matchID: UUID
    /// Side 0 — the challenger, or the upper bracket slot.
    let playerA: String
    /// Side 1.
    let playerB: String
    let isTournament: Bool
    private(set) var phase: Phase
    private(set) var phaseStarted: Date
    private(set) var commits: [String: Data] = [:]
    private(set) var reveals: [String: Revealed] = [:]

    private init(matchID: UUID, playerA: String, playerB: String, isTournament: Bool, phase: Phase, now: Date) {
        self.matchID = matchID
        self.playerA = playerA
        self.playerB = playerB
        self.isTournament = isTournament
        self.phase = phase
        self.phaseStarted = now
    }

    /// A free 1v1: the target must accept first.
    static func free(matchID: UUID = UUID(), challenger: String, target: String, now: Date) -> (LANHostMatch, [Output]) {
        let match = LANHostMatch(matchID: matchID, playerA: challenger, playerB: target,
                                 isTournament: false, phase: .offered, now: now)
        return (match, [.send(to: target, .matchOffer(matchID: matchID, challengerID: challenger))])
    }

    /// A bracket match: straight to squad picking.
    static func tournament(matchID: UUID = UUID(), playerA: String, playerB: String, now: Date) -> (LANHostMatch, [Output]) {
        let match = LANHostMatch(matchID: matchID, playerA: playerA, playerB: playerB,
                                 isTournament: true, phase: .picking, now: now)
        return (match, match.pickingOutputs())
    }

    var participants: [String] { [playerA, playerB] }

    func side(of player: String) -> Int? {
        if player == playerA { return 0 }
        if player == playerB { return 1 }
        return nil
    }

    func opponent(of player: String) -> String? {
        if player == playerA { return playerB }
        if player == playerB { return playerA }
        return nil
    }

    /// Called by the host once the replay has been delivered.
    mutating func markFinished() {
        phase = .finished
    }

    mutating func handle(_ event: Event, now: Date) -> [Output] {
        guard phase != .finished else { return [] }

        switch event {
        case .offerReply(let from, let accept):
            guard phase == .offered, from == playerB else { return [] }
            guard accept else { return finish(.cancelled(reason: "Challenge declined")) }
            phase = .picking
            phaseStarted = now
            return pickingOutputs()

        case .commit(let from, let hash):
            // Late, duplicate, or outsider commits are ignored; the first one counts.
            guard phase == .picking, side(of: from) != nil,
                  hash.count == 32, commits[from] == nil else { return [] }
            commits[from] = hash
            guard commits.count == 2 else { return [] }
            phase = .revealing
            phaseStarted = now
            return [
                .send(to: playerA, .revealNow(matchID: matchID)),
                .send(to: playerB, .revealNow(matchID: matchID))
            ]

        case .reveal(let from, let nonce, let squadBytes):
            // An early reveal (before both commits) is simply dropped.
            guard phase == .revealing, let senderSide = side(of: from),
                  reveals[from] == nil, let committed = commits[from] else { return [] }

            // Hash the exact bytes received, under the *authenticated* sender
            // and the side the host assigned — never values from the message.
            // A copied commitment can't verify under a different player id.
            let recomputed = LANCrypto.commitment(matchID: matchID, playerID: from, side: senderSide,
                                                  nonce: nonce, squadBytes: squadBytes)
            guard nonce.count == LANCrypto.nonceLength, recomputed == committed,
                  let squad = try? JSONDecoder().decode(LANSquad.self, from: squadBytes),
                  (try? squad.validate()) != nil
            else {
                return fail(from, cancelReason: "A player sent an invalid squad", forfeitReason: "sent an invalid squad")
            }

            reveals[from] = Revealed(nonce: nonce, squadBytes: squadBytes, squad: squad)
            guard let a = reveals[playerA], let b = reveals[playerB] else { return [] }
            phase = .resolving
            return [.resolve(LANResolution(
                matchID: matchID,
                squadA: a.squad,
                squadB: b.squad,
                squadBytesA: a.squadBytes,
                squadBytesB: b.squadBytes,
                seed: LANCrypto.seed(matchID: matchID, nonceA: a.nonce, nonceB: b.nonce)
            ))]

        case .playerLeft(let player):
            // Once resolving, the outcome is already fixed by the commits.
            guard side(of: player) != nil, phase != .resolving else { return [] }
            return fail(player, cancelReason: "Your opponent left", forfeitReason: "left the group")

        case .tick:
            return checkTimeout(now: now)
        }
    }

    // MARK: - Private

    private var pickTimeout: TimeInterval {
        isTournament ? LANTimeouts.tournamentSquadPick : LANTimeouts.squadPick
    }

    private func pickingOutputs() -> [Output] {
        let seconds = Int(pickTimeout)
        return [
            .send(to: playerA, .matchStart(matchID: matchID, opponentID: playerB, side: 0,
                                           pickSeconds: seconds, tournament: isTournament)),
            .send(to: playerB, .matchStart(matchID: matchID, opponentID: playerA, side: 1,
                                           pickSeconds: seconds, tournament: isTournament))
        ]
    }

    private mutating func checkTimeout(now: Date) -> [Output] {
        let elapsed = now.timeIntervalSince(phaseStarted)
        switch phase {
        case .offered:
            guard elapsed >= LANTimeouts.offerReply else { return [] }
            return finish(.cancelled(reason: "Challenge wasn't answered"))
        case .picking:
            guard elapsed >= pickTimeout else { return [] }
            return timedOut(missing: participants.filter { commits[$0] == nil })
        case .revealing:
            guard elapsed >= LANTimeouts.reveal else { return [] }
            return timedOut(missing: participants.filter { reveals[$0] == nil })
        case .resolving, .finished:
            return []
        }
    }

    /// Whoever failed to act forfeits. If both did, the upper slot (side A)
    /// advances — a bracket match must produce a winner.
    private mutating func timedOut(missing: [String]) -> [Output] {
        guard isTournament else { return finish(.cancelled(reason: "Match timed out")) }
        let loser = missing.count == 1 ? missing[0] : playerB
        return finish(.forfeit(loser: loser, reason: "ran out of time"))
    }

    /// Free matches just end; bracket matches hand the win to the other side.
    private mutating func fail(_ player: String, cancelReason: String, forfeitReason: String) -> [Output] {
        isTournament
            ? finish(.forfeit(loser: player, reason: forfeitReason))
            : finish(.cancelled(reason: cancelReason))
    }

    private mutating func finish(_ output: Output) -> [Output] {
        phase = .finished
        return [output]
    }
}
