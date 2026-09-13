import Foundation

/// Deterministic 3v3 battle simulator.
///
/// Pure Swift actor: identical squads + seed produce an identical replay on
/// every device and on the server. No I/O, no clock, no system randomness.
public actor BattleEngine {

    public init() {}

    // MARK: - Tunables (mirror docs/BATTLE-SYSTEM.md §5)

    private let maxRounds = 12
    private let critChance = 0.06
    private let critMultiplier = 1.6
    private let missChance = 0.04
    private let varianceRange: ClosedRange<Double> = 0.92...1.08
    private let defenseConstant = 90.0

    // MARK: - Mutable battle state

    private struct Slot {
        let unit: BattleUnit
        let side: Int
        var hp: Double
        var alive: Bool { hp > 0 }
        var stats: BattleStats { unit.stats }
    }

    // MARK: - Simulation

    /// Runs a full battle. Same squads + same seed -> identical replay.
    public func simulate(squadA: BattleSquad, squadB: BattleSquad, seed: UInt64) -> BattleReplay {
        var rng = SeededRNG(seed: seed)

        var state: [Slot] = []
        for u in squadA.units {
            state.append(Slot(unit: u, side: 0, hp: u.maxHP * squadA.squadBonus))
        }
        for u in squadB.units {
            state.append(Slot(unit: u, side: 1, hp: u.maxHP * squadB.squadBonus))
        }

        var events: [BattleEvent] = [.battleStart(seed: seed)]
        var round = 1

        while round <= maxRounds {
            events.append(.roundStart(round))

            // Turn order: tempo, ties broken by seeded jitter.
            let order = state.indices
                .filter { state[$0].alive }
                .sorted { lhs, rhs in
                    let l = state[lhs].stats.tempo + rng.range(0, 0.5)
                    let r = state[rhs].stats.tempo + rng.range(0, 0.5)
                    return l == r ? lhs < rhs : l > r
                }

            for attackerIndex in order where state[attackerIndex].alive {
                guard let defenderIndex = firstAliveEnemy(of: attackerIndex, in: state) else { continue }
                let result = resolveTurn(
                    attacker: state[attackerIndex],
                    defender: state[defenderIndex],
                    rng: &rng
                )
                events.append(result.event)

                if result.damage > 0 {
                    state[defenderIndex].hp = max(0, state[defenderIndex].hp - result.damage)
                    if !state[defenderIndex].alive {
                        events.append(.faint(unitID: state[defenderIndex].unit.id))
                    }
                }
            }

            events.append(.roundEnd(round))

            if let winner = victorySide(state) {
                events.append(.victory(winnerSide: winner, rounds: round))
                return BattleReplay(seed: seed, events: events, winnerSide: winner, rounds: round)
            }
            round += 1
        }

        // Timeout: higher remaining HP share wins.
        let winner: Int = hpShare(state, side: 0) >= hpShare(state, side: 1) ? 0 : 1
        events.append(.victory(winnerSide: winner, rounds: round))
        return BattleReplay(seed: seed, events: events, winnerSide: winner, rounds: round)
    }

    // MARK: - Turn resolution

    private struct TurnResult {
        let event: BattleEvent
        let damage: Double
    }

    private func resolveTurn(attacker: Slot, defender: Slot, rng: inout SeededRNG) -> TurnResult {
        if rng.chance(missChance) {
            return TurnResult(
                event: .miss(attackerID: attacker.unit.id, defenderID: defender.unit.id),
                damage: 0
            )
        }

        // Signature (highest stat) 50% of the time, else basic strike.
        let moves = attacker.unit.character.moves
        let move = rng.chance(0.5) ? moves[1] : moves[0]
        let atkStat = attacker.unit.stats[move.usesStat]

        let typeMod = attacker.unit.element.typeMod(against: defender.unit.element)
        let crit = rng.chance(critChance)
        let variance = rng.range(varianceRange.lowerBound, varianceRange.upperBound)

        let raw = move.power
            * atkStat
            * typeMod
            * (crit ? critMultiplier : 1.0)
            * variance
            * attacker.unit.partyMultiplier

        let mitigation = 1.0 - defender.unit.stats.guard / (defender.unit.stats.guard + defenseConstant)
        let damage = (raw * mitigation).rounded()

        return TurnResult(
            event: .attack(
                attackerID: attacker.unit.id,
                defenderID: defender.unit.id,
                move: move.name,
                damage: damage,
                crit: crit,
                typeMod: typeMod
            ),
            damage: damage
        )
    }

    // MARK: - Helpers

    private func firstAliveEnemy(of index: Int, in state: [Slot]) -> Int? {
        let side = state[index].side
        return state.firstIndex { $0.side != side && $0.alive }
    }

    private func victorySide(_ state: [Slot]) -> Int? {
        let aAlive = state.contains { $0.side == 0 && $0.alive }
        let bAlive = state.contains { $0.side == 1 && $0.alive }
        if !bAlive { return 0 }
        if !aAlive { return 1 }
        return nil
    }

    private func hpShare(_ state: [Slot], side: Int) -> Double {
        let slots = state.filter { $0.side == side }
        let current = slots.reduce(0.0) { $0 + max(0, $1.hp) }
        let maxHP = slots.reduce(0.0) { $0 + $1.unit.maxHP }
        return maxHP > 0 ? current / maxHP : 0
    }
}
