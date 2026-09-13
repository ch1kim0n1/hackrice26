import XCTest
@testable import BattleKit

// MARK: - Test fixtures

/// Deterministic character ids so the same squads + seed produce a stable
/// replay that the TypeScript port (backend/src/routes/battle.ts) can be
/// checked against. The ids are stable strings; the parity test in
/// backend/src/routes/battle.test.ts uses the same ids.
private func fixedCharacter(
    id: String,
    name: String,
    element: BattleElement,
    rarity: BattleRarity,
    fusionTier: Int = 0,
    power: Double,
    guard g: Double,
    vitality v: Double,
    tempo t: Double
) -> FoodCharacter {
    FoodCharacter(
        id: UUID(uuidString: id)!,
        name: name,
        barcode: "test-\(id)",
        element: element,
        rarity: rarity,
        fusionTier: fusionTier,
        baseStats: BattleStats(power: power, guard: g, vitality: v, tempo: t)
    )
}

/// Fixed squads used by both the Swift and TS parity tests.
/// Keep these in sync with `FIXTURE_SQUADS` in
/// backend/src/routes/battle.test.ts.
enum BattleFixtures {
    static let proteinHero = fixedCharacter(
        id: "00000000-0000-0000-0000-000000000001",
        name: "Protein Hero",
        element: .protein,
        rarity: .rare,
        power: 80, guard: 40, vitality: 50, tempo: 60
    )
    static let fiberGuardian = fixedCharacter(
        id: "00000000-0000-0000-0000-000000000002",
        name: "Fiber Guardian",
        element: .fiber,
        rarity: .epic,
        power: 40, guard: 90, vitality: 60, tempo: 30
    )
    static let vitaminSage = fixedCharacter(
        id: "00000000-0000-0000-0000-000000000003",
        name: "Vitamin Sage",
        element: .vitamin,
        rarity: .common,
        power: 30, guard: 30, vitality: 80, tempo: 50
    )
    static let hydrationRogue = fixedCharacter(
        id: "00000000-0000-0000-0000-000000000004",
        name: "Hydration Rogue",
        element: .hydration,
        rarity: .legendary,
        power: 50, guard: 50, vitality: 50, tempo: 90
    )
    static let proteinBruiser = fixedCharacter(
        id: "00000000-0000-0000-0000-000000000005",
        name: "Protein Bruiser",
        element: .protein,
        rarity: .common,
        power: 70, guard: 50, vitality: 40, tempo: 40
    )
    static let fiberScout = fixedCharacter(
        id: "00000000-0000-0000-0000-000000000006",
        name: "Fiber Scout",
        element: .fiber,
        rarity: .rare,
        power: 35, guard: 60, vitality: 55, tempo: 45
    )

    /// Squad A: three distinct elements -> squadBonus 1.10.
    static func squadA(mult: Double = 1.2) -> BattleSquad {
        BattleSquad(units: [
            BattleUnit(character: proteinHero, partyMultiplier: mult),
            BattleUnit(character: fiberGuardian, partyMultiplier: mult),
            BattleUnit(character: vitaminSage, partyMultiplier: mult)
        ])
    }

    /// Squad B: two distinct elements -> squadBonus 1.05.
    static func squadB(mult: Double = 1.0) -> BattleSquad {
        BattleSquad(units: [
            BattleUnit(character: hydrationRogue, partyMultiplier: mult),
            BattleUnit(character: proteinBruiser, partyMultiplier: mult),
            BattleUnit(character: fiberScout, partyMultiplier: mult)
        ])
    }
}

// MARK: - Tests

final class BattleEngineTests: XCTestCase {

    private let engine = BattleEngine()

    // The single most important correctness property: same seed + same squads
    // = identical replay, every time, on every device. If this fails the
    // server-authoritative PvP contract is void.
    func testDeterminism_sameSeedProducesIdenticalReplay() async {
        let seed: UInt64 = 0xDEAD_BEEF_CAFE_BABE
        let a = BattleFixtures.squadA()
        let b = BattleFixtures.squadB()

        let first = await engine.simulate(squadA: a, squadB: b, seed: seed)
        let second = await engine.simulate(squadA: a, squadB: b, seed: seed)

        XCTAssertEqual(first, second, "Same seed + squads must produce identical replays")
        XCTAssertEqual(first.seed, seed)
        XCTAssertEqual(second.seed, seed)
    }

    // Different seeds must (almost always) produce different replays. We pick
    // a seed that is not a multiple of the SplitMix64 stride so the first
    // stream differs from the second immediately.
    func testDeterminism_differentSeedProducesDifferentReplay() async {
        let a = BattleFixtures.squadA()
        let b = BattleFixtures.squadB()

        let r1 = await engine.simulate(squadA: a, squadB: b, seed: 1)
        let r2 = await engine.simulate(squadA: a, squadB: b, seed: 2)

        XCTAssertNotEqual(r1.events, r2.events, "Different seeds should produce different event streams")
    }

    // The replay always opens with battleStart(seed) and closes with victory.
    func testReplayShape_startAndEndEvents() async {
        let a = BattleFixtures.squadA()
        let b = BattleFixtures.squadB()
        let seed: UInt64 = 42

        let replay = await engine.simulate(squadA: a, squadB: b, seed: seed)

        guard case .battleStart(let emittedSeed) = replay.events.first else {
            return XCTFail("First event must be .battleStart")
        }
        XCTAssertEqual(emittedSeed, seed)

        guard case .victory(let winnerSide, let rounds) = replay.events.last else {
            return XCTFail("Last event must be .victory")
        }
        XCTAssertEqual(winnerSide, replay.winnerSide)
        XCTAssertEqual(rounds, replay.rounds)
    }

    // The engine must terminate: rounds is bounded by maxRounds (12) plus the
    // final victory round. A runaway loop would hang the test.
    func testTermination_roundsBoundedByMaxPlusOne() async {
        let a = BattleFixtures.squadA()
        let b = BattleFixtures.squadB()

        let replay = await engine.simulate(squadA: a, squadB: b, seed: 0xCAFE)

        XCTAssertLessThanOrEqual(replay.rounds, 13, "Battle must terminate within maxRounds + 1")
        XCTAssertGreaterThanOrEqual(replay.rounds, 1)
    }

    // Winner side is always 0 or 1.
    func testWinnerSide_isValidSide() async {
        let a = BattleFixtures.squadA()
        let b = BattleFixtures.squadB()

        for seed in [UInt64(1), 100, 9999, 0xFFFF_FFFF] {
            let replay = await engine.simulate(squadA: a, squadB: b, seed: seed)
            XCTAssertTrue(replay.winnerSide == 0 || replay.winnerSide == 1,
                          "winnerSide must be 0 or 1, got \(replay.winnerSide) for seed \(seed)")
        }
    }

    // Seed 0 is a sentinel: SeededRNG rewrites it to the SplitMix64 golden
    // constant. Two battles with seed 0 must still be deterministic.
    func testSeedZero_isRewrittenAndDeterministic() async {
        let a = BattleFixtures.squadA()
        let b = BattleFixtures.squadB()

        let r1 = await engine.simulate(squadA: a, squadB: b, seed: 0)
        let r2 = await engine.simulate(squadA: a, squadB: b, seed: 0)

        XCTAssertEqual(r1, r2, "Seed 0 must be rewritten deterministically")
    }

    // A squad with overwhelming stat advantage should win the large majority
    // of seeded matchups. This is a smoke test that the engine is not
    // accidentally inverting damage or healing the defender.
    func testBalance_strongSquadWinsMostMatches() async {
        let strong = BattleSquad(units: [
            BattleUnit(character: fixedCharacter(
                id: "00000000-0000-0000-0000-000000000010",
                name: "Strong A",
                element: .protein, rarity: .legendary, fusionTier: 5,
                power: 100, guard: 100, vitality: 100, tempo: 100
            ), partyMultiplier: 1.5),
            BattleUnit(character: fixedCharacter(
                id: "00000000-0000-0000-0000-000000000011",
                name: "Strong B",
                element: .fiber, rarity: .legendary, fusionTier: 5,
                power: 100, guard: 100, vitality: 100, tempo: 100
            ), partyMultiplier: 1.5),
            BattleUnit(character: fixedCharacter(
                id: "00000000-0000-0000-0000-000000000012",
                name: "Strong C",
                element: .hydration, rarity: .legendary, fusionTier: 5,
                power: 100, guard: 100, vitality: 100, tempo: 100
            ), partyMultiplier: 1.5)
        ])
        let weak = BattleSquad(units: [
            BattleUnit(character: fixedCharacter(
                id: "00000000-0000-0000-0000-000000000020",
                name: "Weak A",
                element: .protein, rarity: .common, fusionTier: 0,
                power: 10, guard: 10, vitality: 10, tempo: 10
            ), partyMultiplier: 1.0),
            BattleUnit(character: fixedCharacter(
                id: "00000000-0000-0000-0000-000000000021",
                name: "Weak B",
                element: .fiber, rarity: .common, fusionTier: 0,
                power: 10, guard: 10, vitality: 10, tempo: 10
            ), partyMultiplier: 1.0),
            BattleUnit(character: fixedCharacter(
                id: "00000000-0000-0000-0000-000000000022",
                name: "Weak C",
                element: .vitamin, rarity: .common, fusionTier: 0,
                power: 10, guard: 10, vitality: 10, tempo: 10
            ), partyMultiplier: 1.0)
        ])

        var strongWins = 0
        for seed in 0..<50 {
            let replay = await engine.simulate(squadA: strong, squadB: weak, seed: UInt64(seed))
            if replay.winnerSide == 0 { strongWins += 1 }
        }
        XCTAssertGreaterThanOrEqual(strongWins, 45,
            "Legendary+fusion5 squad should win >=45/50 vs common squad, won \(strongWins)/50")
    }

    // Squad bonus is +5% per distinct element beyond the first, capped at
    // +10%. Three distinct elements -> 1.10. Two distinct -> 1.05. One -> 1.00.
    func testSquadBonus_distinctElementsCappedAtTenPercent() {
        let oneElement = BattleSquad(units: [
            BattleUnit(character: BattleFixtures.proteinHero, partyMultiplier: 1.0),
            BattleUnit(character: BattleFixtures.proteinBruiser, partyMultiplier: 1.0),
            BattleUnit(character: BattleFixtures.proteinHero, partyMultiplier: 1.0)
        ])
        let twoElements = BattleSquad(units: [
            BattleUnit(character: BattleFixtures.proteinHero, partyMultiplier: 1.0),
            BattleUnit(character: BattleFixtures.fiberGuardian, partyMultiplier: 1.0),
            BattleUnit(character: BattleFixtures.proteinBruiser, partyMultiplier: 1.0)
        ])
        let threeElements = BattleFixtures.squadA(mult: 1.0)

        XCTAssertEqual(oneElement.squadBonus, 1.00, accuracy: 1e-9)
        XCTAssertEqual(twoElements.squadBonus, 1.05, accuracy: 1e-9)
        XCTAssertEqual(threeElements.squadBonus, 1.10, accuracy: 1e-9)
    }

    // Type advantage triangle: Protein -> Fiber -> Hydration -> Protein (1.25x),
    // Vitamin is wildcard (no advantage, no disadvantage).
    func testTypeMod_advantageTriangle() {
        XCTAssertEqual(BattleElement.protein.typeMod(against: .fiber), 1.25, accuracy: 1e-9)
        XCTAssertEqual(BattleElement.fiber.typeMod(against: .hydration), 1.25, accuracy: 1e-9)
        XCTAssertEqual(BattleElement.hydration.typeMod(against: .protein), 1.25, accuracy: 1e-9)
        XCTAssertEqual(BattleElement.fiber.typeMod(against: .protein), 0.8, accuracy: 1e-9)
        XCTAssertEqual(BattleElement.protein.typeMod(against: .vitamin), 1.0, accuracy: 1e-9)
        XCTAssertEqual(BattleElement.vitamin.typeMod(against: .protein), 1.0, accuracy: 1e-9)
    }

    // HP formula: 55 + vitality * 1.1, then scaled by partyMultiplier.
    func testMaxHP_formula() {
        let unit = BattleUnit(character: BattleFixtures.vitaminSage, partyMultiplier: 1.2)
        // vitality common = 80, no rarity/fusion scaling for common.
        XCTAssertEqual(unit.maxHP, (55 + 80 * 1.1) * 1.2, accuracy: 1e-9)
    }

    // Rarity + fusion scaling: stat = base * rarityMult * (1 + 0.08 * tier).
    func testStatScaling_rarityAndFusion() {
        let legendary5 = fixedCharacter(
            id: "00000000-0000-0000-0000-000000000030",
            name: "L5",
            element: .protein, rarity: .legendary, fusionTier: 5,
            power: 100, guard: 100, vitality: 100, tempo: 100
        )
        // legendary = 1.4, fusion5 = 1.4 -> 1.4 * 1.4 = 1.96
        XCTAssertEqual(legendary5.stats.power, 100 * 1.4 * 1.4, accuracy: 1e-9)
    }

    // Signature move power: 1.45 base, x1.25 at fusion tier >= 3.
    func testSignatureMove_fusion3Boost() {
        let stats = BattleStats(power: 80, guard: 40, vitality: 50, tempo: 60)
        let basic = BattleMove.basic()
        let sig0 = BattleMove.signature(name: "Special", stats: stats, fusionTier: 0)
        let sig3 = BattleMove.signature(name: "Special", stats: stats, fusionTier: 3)
        let sig5 = BattleMove.signature(name: "Special", stats: stats, fusionTier: 5)

        XCTAssertEqual(basic.power, 1.0, accuracy: 1e-9)
        XCTAssertEqual(sig0.power, 1.45, accuracy: 1e-9)
        XCTAssertEqual(sig3.power, 1.45 * 1.25, accuracy: 1e-9)
        XCTAssertEqual(sig5.power, 1.45 * 1.25, accuracy: 1e-9)
    }

    // Squad is capped at 3 units (prefix(3)).
    func testSquadCapsAtThree() {
        let four = BattleSquad(units: [
            BattleUnit(character: BattleFixtures.proteinHero, partyMultiplier: 1.0),
            BattleUnit(character: BattleFixtures.fiberGuardian, partyMultiplier: 1.0),
            BattleUnit(character: BattleFixtures.vitaminSage, partyMultiplier: 1.0),
            BattleUnit(character: BattleFixtures.hydrationRogue, partyMultiplier: 1.0)
        ])
        XCTAssertEqual(four.units.count, 3)
    }
}
