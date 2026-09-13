import Foundation
import BattleKit

/// Converts the server's authoritative battle result into a `BattleReplay`
/// the BattleKit-driven UI can animate.
///
/// The server emits the same event stream as BattleKit with unit ids that are
/// already the squad ids the client sent — `BattleEvent` decodes them
/// directly in `ServerBattleResult`. All that's left here is folding the
/// result envelope into the replay struct and rejecting a malformed stream.
enum BattleReplayMapper {

    static func replay(from result: ServerBattleResult) throws -> BattleReplay {
        var seed: UInt64 = 0
        var reason: VictoryReason?

        for event in result.events {
            switch event {
            case .battleStart(let s, _):
                guard let parsed = UInt64(s) else { throw APIError.decodingFailed }
                seed = parsed
            case .victory(_, _, let r):
                reason = r
            default:
                break
            }
        }

        guard seed != 0, let reason else {
            throw APIError.decodingFailed
        }

        return BattleReplay(
            seed: seed,
            events: result.events,
            winnerSide: result.winnerSide,
            turns: result.rounds,
            reason: reason,
            hpFractionsA: result.hpLeftA,
            hpFractionsB: result.hpLeftB,
            faintedA: result.faintedA,
            faintedB: result.faintedB
        )
    }
}
