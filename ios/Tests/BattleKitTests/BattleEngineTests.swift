import XCTest
@testable import BattleKit

// ============================================================================
// Swift mirror of the canonical seed table in backend/src/routes/battle.test.ts
// — both suites bake in the same expected (winner, turns) per seed. A drift on
// either side fails the port that moved; the server is authoritative and
// clients replay its exact event stream.
// ============================================================================

// MARK: - Test fixtures

private let strike = BattleMoveSpec(
    id: "strike", name: "Strike", kind: .standard,
    power: 3.5, accuracy: 95, manaCost: 0
)
private let guardMove = BattleMoveSpec(
    id: "guard", name: "Guard", kind: .standard,
    power: 0, accuracy: 100, manaCost: 0,
    statusEffect: .guardUp, statusChance: 100, duration: 2
)
private let blast = BattleMoveSpec(
    id: "blast", name: "Blast", kind: .special,
    power: 8, accuracy: 85, manaCost: 40
)

private func unit(
    _ id: String,
    baseHealth: Double = 100,
    baseAttack: Double = 50,
    rarity: BattleRarity = .common,
    star: Int = 1,
    baseMana: Double? = nil,
    moves: [BattleMoveSpec] = [strike]
) -> BattleUnitSpec {
    BattleUnitSpec(
        id: id, name: id, baseHealth: baseHealth, baseAttack: baseAttack,
        rarity: rarity, star: star, moves: moves, baseMana: baseMana
    )
}

/// The canonical fixtures — identical to `canonicalA`/`canonicalB` in
/// backend/src/routes/battle.test.ts. Keep in sync.
enum BattleFixtures {
    static let squadA: [BattleUnitSpec] = [
        unit("a0", baseHealth: 100, baseAttack: 50, rarity: .common, star: 1, moves: [strike, guardMove]),
        unit("a1", baseHealth: 110, baseAttack: 55, rarity: .rare, star: 2, moves: [strike, guardMove]),
        unit("a2", baseHealth: 95, baseAttack: 60, rarity: .epic, star: 3, baseMana: 90, moves: [strike, guardMove, blast])
    ]
    static let squadB: [BattleUnitSpec] = [
        unit("b0", baseHealth: 105, baseAttack: 45, rarity: .uncommon, star: 1, moves: [strike, guardMove]),
        unit("b1", baseHealth: 120, baseAttack: 50, rarity: .epic, star: 2, baseMana: 120, moves: [strike, guardMove, blast]),
        unit("b2", baseHealth: 90, baseAttack: 55, rarity: .rare, star: 3, moves: [strike, guardMove])
    ]
}

// MARK: - Tests

final class BattleEngineTests: XCTestCase {

    /// Canonical parity table — the same (winner, turns) pairs asserted by
    /// the TypeScript suite. winnerSide 0 = side A, 1 = side B.
    private static let canonical: [UInt64: (winner: Int, turns: Int)] = [
        0: (1, 66),
        1: (0, 72),
        42: (0, 84),
        100: (1, 88),
        9999: (1, 66)
    ]

    // The single most important correctness property: same seed + same
    // squads = identical replay, every time, on every device. If this fails
    // the server-authoritative PvP contract is void.
    func testDeterminism_sameSeedProducesIdenticalReplay() {
        let seed: UInt64 = 0xDEAD_BEEF_CAFE_BABE

        let first = BattleEngine.simulate(squadA: BattleFixtures.squadA, squadB: BattleFixtures.squadB, seed: seed)
        let second = BattleEngine.simulate(squadA: BattleFixtures.squadA, squadB: BattleFixtures.squadB, seed: seed)

        XCTAssertEqual(first, second, "Same seed + squads must produce identical replays")
        XCTAssertEqual(first.seed, seed)
    }

    // Different seeds must (almost always) produce different replays.
    func testDeterminism_differentSeedProducesDifferentReplay() {
        let r1 = BattleEngine.simulate(squadA: BattleFixtures.squadA, squadB: BattleFixtures.squadB, seed: 1)
        let r2 = BattleEngine.simulate(squadA: BattleFixtures.squadA, squadB: BattleFixtures.squadB, seed: 2)

        XCTAssertNotEqual(r1.events, r2.events, "Different seeds should produce different event streams")
    }

    // The replay always opens with battleStart and closes with victory.
    func testReplayShape_startAndEndEvents() {
        let seed: UInt64 = 42
        let replay = BattleEngine.simulate(squadA: BattleFixtures.squadA, squadB: BattleFixtures.squadB, seed: seed)

        guard case .battleStart(let emittedSeed, _) = replay.events.first else {
            return XCTFail("First event must be .battleStart")
        }
        XCTAssertEqual(emittedSeed, String(seed))

        guard case .victory(let winner, let turns, let reason) = replay.events.last else {
            return XCTFail("Last event must be .victory")
        }
        XCTAssertEqual(winner, replay.winnerSide)
        XCTAssertEqual(turns, replay.turns)
        XCTAssertEqual(reason, replay.reason)
    }

    // The engine must terminate: turns is bounded by the anti-stall cap.
    func testTermination_turnsBoundedByMax() {
        let replay = BattleEngine.simulate(squadA: BattleFixtures.squadA, squadB: BattleFixtures.squadB, seed: 0xCAFE)

        XCTAssertLessThanOrEqual(replay.turns, Battle.maxTurns)
        XCTAssertGreaterThanOrEqual(replay.turns, 1)
    }

    // Canonical seed table — the cross-port parity lock.
    func testCanonicalSeedTable_matchesTypeScriptPort() {
        for (seed, expected) in Self.canonical {
            let replay = BattleEngine.simulate(squadA: BattleFixtures.squadA, squadB: BattleFixtures.squadB, seed: seed)
            XCTAssertEqual(replay.winnerSide, expected.winner, "seed \(seed): wrong winner")
            XCTAssertEqual(replay.turns, expected.turns, "seed \(seed): wrong turn count")
        }
    }

    // Winner side is always 0 or 1.
    func testWinnerSide_isValidSide() {
        for seed in [UInt64(1), 100, 9999, 0xFFFF_FFFF] {
            let replay = BattleEngine.simulate(squadA: BattleFixtures.squadA, squadB: BattleFixtures.squadB, seed: seed)
            XCTAssertTrue(replay.winnerSide == 0 || replay.winnerSide == 1,
                          "winnerSide must be 0 or 1, got \(replay.winnerSide) for seed \(seed)")
        }
    }

    // Seed 0 must still be deterministic.
    func testSeedZero_isDeterministic() {
        let r1 = BattleEngine.simulate(squadA: BattleFixtures.squadA, squadB: BattleFixtures.squadB, seed: 0)
        let r2 = BattleEngine.simulate(squadA: BattleFixtures.squadA, squadB: BattleFixtures.squadB, seed: 0)

        XCTAssertEqual(r1, r2, "Seed 0 must be deterministic")
    }

    // A squad with overwhelming stat advantage should win the large majority
    // of seeded matchups — smoke test that damage isn't inverted.
    func testBalance_strongSquadWinsMostMatches() {
        let strong = (0..<3).map { unit("s\($0)", baseHealth: 200, baseAttack: 100, rarity: .legendary, star: 5, moves: [strike, blast]) }
        let weak = (0..<3).map { unit("w\($0)", baseHealth: 40, baseAttack: 10, rarity: .common, star: 1) }

        var strongWins = 0
        for seed in 0..<50 {
            let replay = BattleEngine.simulate(squadA: strong, squadB: weak, seed: UInt64(seed))
            if replay.winnerSide == 0 { strongWins += 1 }
        }
        XCTAssertGreaterThanOrEqual(strongWins, 45,
            "Legendary ★5 squad should win >=45/50 vs common ★1 squad, won \(strongWins)/50")
    }

    // EffectiveStat = base × rarityMult × starMult — Epic ★2 beats Common ★1
    // on identical bases.
    func testStatScaling_rarityAndStars() {
        let plain = unit("p", baseHealth: 100, baseAttack: 100, rarity: .common, star: 1)
        let epic = unit("e", baseHealth: 100, baseAttack: 100, rarity: .epic, star: 2)

        XCTAssertEqual(plain.maxHP, 100, accuracy: 1e-9)
        XCTAssertGreaterThan(epic.maxHP, plain.maxHP)
        XCTAssertEqual(epic.maxHP, NQSpec.effectiveStat(100, rarity: .epic, stars: 2), accuracy: 1e-9)
    }

    // Mana only exists for Epic+ — sub-Epic instances start at 0 regardless
    // of a baseMana field, and Secret caps at ★2.
    func testMana_epicGateAndSecretStarCap() {
        let rareWithMana = unit("r", rarity: .rare, star: 5, baseMana: 100)
        let epic = unit("e", rarity: .epic, star: 1, baseMana: 100)
        let secret = unit("s", rarity: .secret, star: 5, baseMana: 100)
        let secretCapped = unit("s2", rarity: .secret, star: 2, baseMana: 100)

        XCTAssertEqual(rareWithMana.startingMana, 0)
        XCTAssertGreaterThan(epic.startingMana, 0)
        XCTAssertEqual(secret.startingMana, secretCapped.startingMana,
                       "Secret stars clamp to ★2 — ★5 must not add mana")
    }

    // A hit never deals less than MIN_DAMAGE even at the weakest end.
    func testMinDamage_floorOfOne() {
        let tickle = BattleMoveSpec(id: "t", name: "T", kind: .standard, power: 0.1, accuracy: 100, manaCost: 0)
        let attacker = (0..<3).map { unit("a\($0)", baseHealth: 100, baseAttack: 5, moves: [tickle]) }
        let wall = (0..<3).map { unit("w\($0)", baseHealth: 500, baseAttack: 5) }

        let replay = BattleEngine.simulate(squadA: attacker, squadB: wall, seed: 7)
        let hits = replay.events.compactMap { e -> Int? in
            if case .attack(_, _, _, _, let damage, _) = e { return damage }
            return nil
        }
        XCTAssertFalse(hits.isEmpty)
        XCTAssertTrue(hits.allSatisfy { $0 >= 1 }, "Every hit must deal >= MIN_DAMAGE")
    }
}
