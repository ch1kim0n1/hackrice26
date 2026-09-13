import Foundation

/// What a cash-out attempt actually did, once the server (or a reconcile GET)
/// has had its say. The pending UI is optimistic; this is the verdict.
enum CauldronCashOutVerdict: Equatable {
    /// The tap beat the crash. Show the reward at the server's multiplier.
    case cashedOut(CauldronRoundDTO)
    /// The tap was late, or the cauldron blew up while the request was in flight.
    case crashed(CauldronRoundDTO)
    /// The round is still bubbling — unfreeze and let them tap again.
    case stillLive
    /// Not enough information to decide. Treat as still-live at the call site
    /// after one reconcile, rather than hanging on a pending spinner.
    case unknown
}

/// Pure reducer for cash-out latency: POST body first, then GET /cauldron/state.
enum CauldronCashOut {
    /// Decides the outcome of a cash-out given the POST body (if any) and the
    /// latest GET /cauldron/state snapshot.
    ///
    /// A dropped POST that actually succeeded is recovered from `lastRound`.
    /// A dropped POST that never landed, with the round still `ACTIVE`, is
    /// `stillLive` so the player can tap again.
    static func resolve(
        roundId: String,
        posted: CauldronRoundDTO?,
        liveRound: CauldronRoundDTO?,
        lastRound: CauldronRoundDTO?
    ) -> CauldronCashOutVerdict {
        if let posted, posted.roundId == roundId, let verdict = verdict(for: posted) {
            return verdict
        }
        if let lastRound, lastRound.roundId == roundId, let verdict = verdict(for: lastRound) {
            return verdict
        }
        if let liveRound, liveRound.roundId == roundId, liveRound.isActive {
            return .stillLive
        }
        return .unknown
    }

    /// Whether `finish` should present this round. A second call for the same
    /// `roundId` is a no-op, so a poll and a cash-out POST cannot both play
    /// the blast or bump the win counter.
    static func shouldApply(_ round: CauldronRoundDTO, resolvedRoundId: String?) -> Bool {
        !round.isActive && resolvedRoundId != round.roundId
    }

    /// Maps a round's status onto a verdict, or nil when the status is unused.
    private static func verdict(for round: CauldronRoundDTO) -> CauldronCashOutVerdict? {
        if round.didCashOut { return .cashedOut(round) }
        if round.didCrash { return .crashed(round) }
        if round.isActive { return .stillLive }
        return nil
    }
}
