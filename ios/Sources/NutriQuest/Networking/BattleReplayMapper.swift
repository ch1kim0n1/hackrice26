import Foundation
import BattleKit

/// Converts the server's authoritative battle result into a `BattleReplay`
/// the existing BattleKit-driven UI can animate.
///
/// The server (backend/src/routes/battle.ts) emits the same event stream as
/// BattleKit but with string unit IDs and a leaner attack payload (no move
/// name / type modifier), so we map IDs through the squads that were sent
/// and fill presentation-only fields with neutral values.
enum BattleReplayMapper {

    static func replay(
        from result: ServerBattleResult,
        unitIDs: [String: UUID]
    ) throws -> BattleReplay {
        let zero = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

        var seed: UInt64 = 0
        var events: [BattleEvent] = []
        events.reserveCapacity(result.events.count)

        for event in result.events {
            switch event {
            case .battleStart(let s):
                seed = s
                events.append(.battleStart(seed: s))
            case .roundStart(let round):
                events.append(.roundStart(round))
            case .attack(let attacker, let defender, let damage, let crit, let move, let typeMod):
                events.append(.attack(
                    attackerID: unitIDs[attacker] ?? zero,
                    defenderID: unitIDs[defender] ?? zero,
                    move: move ?? "",
                    damage: Double(damage),
                    crit: crit,
                    typeMod: typeMod ?? 1.0
                ))
            case .miss(let attacker, let defender):
                events.append(.miss(
                    attackerID: unitIDs[attacker] ?? zero,
                    defenderID: defender.flatMap { unitIDs[$0] } ?? zero
                ))
            case .faint(let unit):
                events.append(.faint(unitID: unitIDs[unit] ?? zero))
            case .roundEnd(let round):
                events.append(.roundEnd(round))
            case .victory(let winnerSide, let rounds):
                events.append(.victory(winnerSide: winnerSide, rounds: rounds))
            }
        }

        let hasVictory = events.contains { if case .victory = $0 { return true } else { return false } }
        guard seed != 0, hasVictory else {
            throw APIError.decodingFailed
        }

        return BattleReplay(
            seed: seed,
            events: events,
            winnerSide: result.winnerSide,
            rounds: result.rounds
        )
    }
}
