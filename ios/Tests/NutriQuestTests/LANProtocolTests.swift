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
                    replay: LANReplay(seed: "42", events: [.roundStart(round: 1)], winnerSide: 0, rounds: 1)),
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
        let a = UUID()
        let b = UUID()
        let wire = LANReplay(seed: String(UInt64.max), events: [
            .battleStart(seed: String(UInt64.max)),
            .roundStart(round: 1),
            .attack(attacker: a, defender: b, move: "Strike", damage: 12, crit: true, typeMod: 1.25),
            .miss(attacker: b, defender: a),
            .faint(unit: b),
            .roundEnd(round: 1),
            .victory(winnerSide: 0, rounds: 1)
        ], winnerSide: 0, rounds: 1)

        let battle = try XCTUnwrap(wire.battleReplay)
        XCTAssertEqual(battle.seed, UInt64.max)
        XCTAssertEqual(LANReplay(battle), wire)
    }

    func testMalformedReplayIsRejected() {
        XCTAssertNil(LANReplay(seed: "not a number", events: [], winnerSide: 0, rounds: 1).battleReplay)
        XCTAssertNil(LANReplay(seed: "1", events: [], winnerSide: 5, rounds: 1).battleReplay)
    }

    // MARK: - Squad validation

    func testAValidSquadPasses() {
        XCTAssertNoThrow(try LANFixtures.squad().validate())
    }

    func testSquadMustBeExactlyThree() {
        let two = LANSquad(units: Array(LANFixtures.squad().units.prefix(2)), partyMultiplier: 1)
        expect(.wrongSize, two)
    }

    func testDuplicateCharactersAreRejected() {
        let unit = LANFixtures.unit("same")
        expect(.duplicateCharacters, LANSquad(units: [unit, unit, unit], partyMultiplier: 1))
    }

    func testStatsOutsideTheGameRangeAreRejected() {
        expect(.statOutOfRange, LANFixtures.squad(power: 500))
        expect(.statOutOfRange, LANFixtures.squad(power: 2))
        expect(.statOutOfRange, LANFixtures.squad(power: .nan))
    }

    func testMultiplierOutsideTheDailyClampIsRejected() {
        expect(.multiplierOutOfRange, LANFixtures.squad(multiplier: 2.0))
        expect(.multiplierOutOfRange, LANFixtures.squad(multiplier: 0.5))
    }

    func testUnknownElementIsRejected() {
        let bad = LANFixtures.unit("x", element: "plasma")
        expect(.unknownElement, LANSquad(units: [bad, LANFixtures.unit("y"), LANFixtures.unit("z")], partyMultiplier: 1))
    }

    func testOverlongNameIsRejected() {
        let bad = LANFixtures.unit("x", name: String(repeating: "A", count: 40))
        expect(.badName, LANSquad(units: [bad, LANFixtures.unit("y"), LANFixtures.unit("z")], partyMultiplier: 1))
    }

    // MARK: - Building your own squad

    func testYourOwnUnitIsClampedSoItAlwaysValidates() throws {
        let gameState = GameState()
        let odd = AppCharacter(id: "odd", name: String(repeating: "Very long product name ", count: 5),
                               colorHex: "not-a-colour", rarity: .rare, statType: .fiber)
        let stats = try XCTUnwrap(gameState.battleStats(for: odd))
        let unit = LANUnit(character: odd, stats: stats)

        XCTAssertLessThanOrEqual(unit.character.name.count, LANLimits.maxNameLength)
        XCTAssertEqual(unit.character.colorHex, "#9C978F")
        XCTAssertEqual(unit.rarity, "rare")
        XCTAssertEqual(unit.element, "fiber")
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
        let battle = squad.battleSquad(matchID: matchID, side: 1)
        XCTAssertEqual(battle.units.map(\.id), (0..<3).map { LANCrypto.unitID(matchID: matchID, side: 1, slot: $0) })
        XCTAssertEqual(battle.units.map(\.character.barcode), ["k1", "k2", "k3"])
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
