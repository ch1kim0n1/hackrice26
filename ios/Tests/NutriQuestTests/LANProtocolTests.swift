import XCTest
@testable import NutriQuest

@MainActor
final class LANProtocolTests: XCTestCase {

    // MARK: - Wire

    func testEveryMessageRoundTrips() {
        let id = UUID()
        let messages: [LANMessage] = [
            .hello(player: LANPlayer(id: "a", name: "Ann")),
            .challenge(target: "b"),
            .offerReply(matchID: id, accept: true),
            .commit(matchID: id, hash: Data(repeating: 7, count: 32)),
            .reveal(matchID: id, nonce: Data(repeating: 1, count: 32), squad: Data("{}".utf8)),
            .startTournament,
            .leave,
            .roster(players: [LANPlayer(id: "a", name: "Ann")], busy: ["a"], hostID: "a"),
            .challengeRejected(target: "b", reason: "busy"),
            .matchOffer(matchID: id, challengerID: "a"),
            .matchStart(matchID: id, opponentID: "b", side: 1, pickSeconds: 60, tournament: true),
            .revealNow(matchID: id),
            .replay(matchID: id, opponentSquad: Data([1, 2, 3]),
                    replay: LANReplay(seed: "42", events: [.turnStart(turn: 1, side: 0, unit: "u")],
                                      winnerSide: 0, turns: 1, reason: "wipeout",
                                      hpFractionsA: [1, 0.5, 0], hpFractionsB: [0, 0, 0],
                                      faintedA: ["a2"], faintedB: ["b0", "b1", "b2"])),
            .matchCancelled(matchID: id, reason: "left"),
            .bracket(LANBracket(rounds: [[LANPairing(a: "a", b: "b", winner: "a")]], champion: "a"))
        ]
        for message in messages {
            XCTAssertEqual(LANWire.decode(LANWire.encode(message))?.message, message, "\(message)")
        }
    }

    func testEachEnvelopeGetsAUniqueID() {
        let a = LANWire.decode(LANWire.encode(.leave))
        let b = LANWire.decode(LANWire.encode(.leave))
        XCTAssertNotNil(a)
        XCTAssertNotEqual(a?.id, b?.id)
    }

    func testRejectsOtherVersionsAndGarbage() throws {
        let future = LANEnvelope(v: LANProtocolVersion.current + 1, id: UUID(), message: .leave)
        XCTAssertNil(LANWire.decode(try JSONEncoder().encode(future)))
        XCTAssertNil(LANWire.decode(Data("not json".utf8)))
    }

    // MARK: - Replay mapping

    func testReplayRoundTripsThroughBattleKitIncludingAMaxSeed() throws {
        let a = "unit-a"
        let b = "unit-b"
        let wire = LANReplay(seed: String(UInt64.max), events: [
            .battleStart(seed: String(UInt64.max), first: 0),
            .turnStart(turn: 1, side: 0, unit: a),
            .attack(attacker: a, defender: b, move: "Strike", moveID: "strike", damage: 12, crit: true),
            .miss(attacker: b, defender: a, move: "Strike", moveID: "strike"),
            .faint(unit: b),
            .turnEnd(turn: 1),
            .victory(winner: 0, turns: 1, reason: .wipeout)
        ], winnerSide: 0, turns: 1, reason: "wipeout",
            hpFractionsA: [1, 0, 0], hpFractionsB: [0, 0, 0],
            faintedA: [], faintedB: [b])

        let battle = try XCTUnwrap(wire.battleReplay)
        XCTAssertEqual(battle.seed, UInt64.max)
        XCTAssertEqual(LANReplay(battle), wire)
    }

    func testMalformedReplayIsRejected() {
        let bad = LANReplay(seed: "not a number", events: [], winnerSide: 0, turns: 1, reason: "wipeout",
                            hpFractionsA: [], hpFractionsB: [], faintedA: [], faintedB: [])
        XCTAssertNil(bad.battleReplay)
        let badSide = LANReplay(seed: "1", events: [], winnerSide: 5, turns: 1, reason: "wipeout",
                                hpFractionsA: [], hpFractionsB: [], faintedA: [], faintedB: [])
        XCTAssertNil(badSide.battleReplay)
        let badReason = LANReplay(seed: "1", events: [], winnerSide: 0, turns: 1, reason: "cheated",
                                  hpFractionsA: [], hpFractionsB: [], faintedA: [], faintedB: [])
        XCTAssertNil(badReason.battleReplay)
    }

    // MARK: - Squad validation

    func testAValidSquadPasses() {
        XCTAssertNoThrow(try LANFixtures.squad().validate())
    }

    func testSquadMustBeExactlyThree() {
        let two = LANSquad(units: Array(LANFixtures.squad().units.prefix(2)))
        expect(.wrongSize, two)
    }

    func testDuplicateCharactersAreRejected() {
        let unit = LANFixtures.unit("same")
        expect(.duplicateCharacters, LANSquad(units: [unit, unit, unit]))
    }

    func testStatsOutsideTheGameRangeAreRejected() {
        expect(.statOutOfRange, LANFixtures.squad(health: 9_999))
        expect(.statOutOfRange, LANFixtures.squad(attack: 999))
        expect(.statOutOfRange, LANFixtures.squad(health: .nan))
    }

    func testUnknownRarityIsRejected() {
        var bad = LANFixtures.unit("x")
        bad = LANUnit(character: bad.character, rarity: "plasma", star: bad.star,
                      baseHealth: bad.baseHealth, baseAttack: bad.baseAttack,
                      baseMana: bad.baseMana, moves: bad.moves)
        expect(.unknownRarity, LANSquad(units: [bad, LANFixtures.unit("y"), LANFixtures.unit("z")]))
    }

    func testEmptyMovesAreRejected() {
        let bad = LANUnit(character: LANFixtures.unit("x").character, rarity: "common", star: 1,
                          baseHealth: 100, baseAttack: 50, baseMana: nil, moves: [])
        expect(.badMoves, LANSquad(units: [bad, LANFixtures.unit("y"), LANFixtures.unit("z")]))
    }

    func testOverlongNameIsRejected() {
        let bad = LANFixtures.unit("x", name: String(repeating: "A", count: 40))
        expect(.badName, LANSquad(units: [bad, LANFixtures.unit("y"), LANFixtures.unit("z")]))
    }

    // MARK: - Building your own squad

    func testYourOwnUnitIsClampedSoItAlwaysValidates() throws {
        let gameState = GameState()
        let odd = AppCharacter(id: "odd", name: String(repeating: "Very long product name ", count: 5),
                               colorHex: "not-a-colour", rarity: .rare)
        let unit = LANUnit(character: odd, spec: gameState.battleStats(for: odd))

        XCTAssertLessThanOrEqual(unit.character.name.count, LANLimits.maxNameLength)
        XCTAssertEqual(unit.character.colorHex, "#9C978F")
        XCTAssertEqual(unit.rarity, "rare")
    }

    func testSquadFromCollectionKeepsPickOrderAndValidates() throws {
        let gameState = GameState()
        let picked = Array(SampleData.characters.filter { !$0.isLocked }.prefix(3)).reversed()
        let squad = try XCTUnwrap(gameState.lanSquad(from: Array(picked)))
        XCTAssertNoThrow(try squad.validate())
        XCTAssertEqual(squad.units.map(\.character.id), picked.map(\.id))
    }

    func testCommittedOrderIsTheEngineOrder() {
        let squad = LANFixtures.squad("k")
        let matchID = UUID()
        let specs = squad.battleSpecs(matchID: matchID, side: 1)
        XCTAssertEqual(specs.map(\.id), (0..<3).map { LANCrypto.unitID(matchID: matchID, side: 1, slot: $0).uuidString })
        XCTAssertEqual(specs.map(\.name), ["Unit", "Unit", "Unit"])
    }

    // MARK: - Opponent namespacing

    func testOpponentCharactersNeverCollideButKeepTheirArt() throws {
        let bud = try XCTUnwrap(SampleData.characters.first { $0.id == "broccoli-bud" })
        let opponent = bud.asLANOpponent()

        XCTAssertNotEqual(opponent.id, bud.id)
        XCTAssertEqual(opponent.baseID, bud.id)
        XCTAssertEqual(opponent.artworkAssetName, bud.artworkAssetName)
        XCTAssertEqual(opponent.artworkRemoteURL, bud.artworkRemoteURL)
        XCTAssertEqual(opponent.asLANOpponent().id, opponent.id, "Namespacing twice is a no-op")
    }

    // MARK: - Helpers

    private func expect(_ error: LANSquadError, _ squad: LANSquad,
                        file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try squad.validate(), file: file, line: line) { thrown in
            XCTAssertEqual(thrown as? LANSquadError, error, file: file, line: line)
        }
    }
}

final class LANCryptoTests: XCTestCase {
    private let matchID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

    func testNoncesAre32FreshBytes() {
        let a = LANCrypto.makeNonce()
        let b = LANCrypto.makeNonce()
        XCTAssertEqual(a.count, 32)
        XCTAssertNotEqual(a, b)
    }

    func testCommitmentIsDeterministic() {
        let nonce = Data(repeating: 9, count: 32)
        let bytes = Data("squad".utf8)
        XCTAssertEqual(
            LANCrypto.commitment(matchID: matchID, playerID: "ann", side: 0, nonce: nonce, squadBytes: bytes),
            LANCrypto.commitment(matchID: matchID, playerID: "ann", side: 0, nonce: nonce, squadBytes: bytes)
        )
    }

    /// Changing any one input changes the hash — this is what stops a copied
    /// commitment verifying for a different player, side or match.
    func testCommitmentBindsEveryInput() {
        let nonce = Data(repeating: 9, count: 32)
        let bytes = Data("squad".utf8)
        let base = LANCrypto.commitment(matchID: matchID, playerID: "ann", side: 0, nonce: nonce, squadBytes: bytes)
        let variants = [
            LANCrypto.commitment(matchID: UUID(), playerID: "ann", side: 0, nonce: nonce, squadBytes: bytes),
            LANCrypto.commitment(matchID: matchID, playerID: "bob", side: 0, nonce: nonce, squadBytes: bytes),
            LANCrypto.commitment(matchID: matchID, playerID: "ann", side: 1, nonce: nonce, squadBytes: bytes),
            LANCrypto.commitment(matchID: matchID, playerID: "ann", side: 0, nonce: Data(repeating: 8, count: 32), squadBytes: bytes),
            LANCrypto.commitment(matchID: matchID, playerID: "ann", side: 0, nonce: nonce, squadBytes: Data("other".utf8))
        ]
        for variant in variants {
            XCTAssertNotEqual(variant, base)
        }
    }

    func testSeedIsDeterministicAndOrderSensitive() {
        let a = Data(repeating: 1, count: 32)
        let b = Data(repeating: 2, count: 32)
        XCTAssertEqual(LANCrypto.seed(matchID: matchID, nonceA: a, nonceB: b),
                       LANCrypto.seed(matchID: matchID, nonceA: a, nonceB: b))
        XCTAssertNotEqual(LANCrypto.seed(matchID: matchID, nonceA: a, nonceB: b),
                          LANCrypto.seed(matchID: matchID, nonceA: b, nonceB: a))
        XCTAssertNotEqual(LANCrypto.seed(matchID: matchID, nonceA: a, nonceB: b),
                          LANCrypto.seed(matchID: UUID(), nonceA: a, nonceB: b))
    }

    func testUnitIDsAreStableAndDistinct() {
        let ids = (0...1).flatMap { side in (0..<3).map { LANCrypto.unitID(matchID: matchID, side: side, slot: $0) } }
        XCTAssertEqual(Set(ids).count, 6)
        XCTAssertEqual(LANCrypto.unitID(matchID: matchID, side: 1, slot: 2), ids[5])
        XCTAssertNotEqual(LANCrypto.unitID(matchID: UUID(), side: 1, slot: 2), ids[5])
    }
}
