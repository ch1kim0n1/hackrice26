import XCTest
@testable import NutriQuest

/// A real `LANHost` and real `LANClient`s wired in memory — the whole protocol
/// minus the radio. The host's own player joins through loopback, as on device.
@MainActor
final class LANHostIntegrationTests: XCTestCase {

    // MARK: - Roster & identity

    func testEveryoneSeesTheSameRoster() {
        let group = LANTestGroup()
        group.add("alice")
        group.add("bob")

        for id in ["host", "alice", "bob"] {
            XCTAssertEqual(group[id].players.map(\.id), ["host", "alice", "bob"], id)
            XCTAssertEqual(group[id].hostID, "host")
        }
        XCTAssertTrue(group["host"].isHost)
        XCTAssertFalse(group["alice"].isHost)
    }

    func testAnIDAlreadyInTheGroupCantBeClaimed() {
        let group = LANTestGroup()
        group.add("alice", name: "Alice")
        let impostor = group.add("alice", name: "Not Alice")

        XCTAssertEqual(group.host.players.count, 2)
        XCTAssertEqual(group.host.players["alice"]?.name, "Alice")
        XCTAssertTrue(impostor.players.isEmpty, "the impostor never got a roster")
    }

    func testAConnectionThatNeverSaidHelloIsIgnored() {
        let group = LANTestGroup()
        group.add("alice")
        group.host.receive(LANWire.encode(.challenge(target: "alice")), from: LANPeer(id: "stranger"))
        XCTAssertTrue(group.host.matches.isEmpty)
    }

    func testReplayedEnvelopesAreDropped() {
        let group = LANTestGroup()
        group.add("alice")
        group.add("bob")
        let challenge = LANWire.encode(.challenge(target: "bob"))
        // Deliver the exact same envelope twice from alice's connection.
        group["alice"].send?(challenge)
        group["alice"].send?(challenge)
        XCTAssertEqual(group.host.matches.count, 1)
        // Had the duplicate been processed, it would have bounced as "busy".
        XCTAssertNil(group["alice"].notice)
    }

    // MARK: - Challenges

    func testSimultaneousChallengesProduceOneMatch() {
        let group = LANTestGroup()
        let alice = group.add("alice")
        let bob = group.add("bob")

        alice.challenge("bob")
        bob.challenge("alice")

        XCTAssertEqual(group.host.matches.count, 1)
        XCTAssertNotNil(bob.incomingOffer, "bob sees alice's challenge")
        XCTAssertNotNil(bob.notice, "bob's own challenge was rejected as busy")
        XCTAssertEqual(Set(alice.busy), ["alice", "bob"])
    }

    func testDecliningTellsTheChallenger() {
        let group = LANTestGroup()
        let alice = group.add("alice")
        let bob = group.add("bob")

        alice.challenge("bob")
        bob.respond(accept: false)

        XCTAssertTrue(group.host.matches.isEmpty)
        XCTAssertEqual(alice.notice, "Challenge declined")
        XCTAssertNil(alice.outgoingChallenge)
        XCTAssertNil(alice.activeMatch)
    }

    func testAnIgnoredChallengeExpires() {
        let group = LANTestGroup()
        let alice = group.add("alice")
        let bob = group.add("bob")

        alice.challenge("bob")
        group.advance(LANTimeouts.offerReply)

        XCTAssertNil(bob.incomingOffer)
        XCTAssertNotNil(alice.notice)
        XCTAssertTrue(group.host.matches.isEmpty)
        XCTAssertTrue(alice.busy.isEmpty)
    }

    // MARK: - Full matches

    func testAFullMatchGivesBothFightersTheSameReplay() async throws {
        let group = LANTestGroup()
        let alice = group.add("alice")
        let bob = group.add("bob")

        alice.challenge("bob")
        bob.respond(accept: true)
        alice.lockIn(LANFixtures.squad("a", power: 80))
        bob.lockIn(LANFixtures.squad("b", power: 30))
        await group.host.waitForResolutions()

        let a = try XCTUnwrap(alice.result)
        let b = try XCTUnwrap(bob.result)
        XCTAssertEqual(a.replay, b.replay)
        XCTAssertEqual(a.mySide, 0)
        XCTAssertEqual(b.mySide, 1)
        XCTAssertNotEqual(a.didWin, b.didWin, "exactly one of them won")
        XCTAssertEqual(a.opponentSquad, LANFixtures.squad("b", power: 30))
        XCTAssertEqual(b.opponentSquad, LANFixtures.squad("a", power: 80))

        // Every attack in the replay maps to a character on one side or the other.
        XCTAssertEqual(a.unitCharacterIDs.count, 6)
        XCTAssertEqual(Set(a.unitCharacterIDs.values).count, 6, "opponent ids are namespaced, never colliding")

        XCTAssertTrue(group.host.matches.isEmpty)
        XCTAssertTrue(alice.busy.isEmpty)
    }

    func testIdenticalStartersDontCollideOnScreen() async throws {
        let group = LANTestGroup()
        let alice = group.add("alice")
        let bob = group.add("bob")

        alice.challenge("bob")
        bob.respond(accept: true)
        // Both field the same character ids — the normal case for new players.
        alice.lockIn(LANFixtures.squad("starter"))
        bob.lockIn(LANFixtures.squad("starter"))
        await group.host.waitForResolutions()

        let result = try XCTUnwrap(alice.result)
        let mine = Set(result.myCharacters.map(\.id))
        let theirs = Set(result.opponentCharacters.map(\.id))
        XCTAssertTrue(mine.isDisjoint(with: theirs))
    }

    func testTheHostCanFightThroughLoopback() async throws {
        let group = LANTestGroup()
        let host = group["host"]
        let alice = group.add("alice")

        host.challenge("alice")
        alice.respond(accept: true)
        host.lockIn(LANFixtures.squad("h"))
        alice.lockIn(LANFixtures.squad("a"))
        await group.host.waitForResolutions()

        let h = try XCTUnwrap(host.result)
        let a = try XCTUnwrap(alice.result)
        XCTAssertEqual(h.replay, a.replay)
    }

    func testLeavingMidMatchCancelsAFreeMatch() {
        let group = LANTestGroup()
        let alice = group.add("alice")
        group.add("bob")

        alice.challenge("bob")
        group["bob"].respond(accept: true)
        group.disconnect("bob")

        XCTAssertEqual(alice.cancellationReason, "Your opponent left")
        XCTAssertFalse(alice.players.contains { $0.id == "bob" })
    }

    // MARK: - Tournament

    func testATournamentRunsToAChampion() async throws {
        let group = LANTestGroup()
        group.add("alice")
        group.add("bob")

        group.host.startTournament(seeding: ["host", "alice", "bob"])
        await group.playOutMatches()

        let champion = try XCTUnwrap(group["host"].bracket?.champion)
        for id in ["host", "alice", "bob"] {
            XCTAssertEqual(group[id].bracket?.champion, champion, id)
        }
        XCTAssertTrue(group.host.matches.isEmpty)
    }

    func testTournamentPlayersCantTakeFreeChallenges() {
        let group = LANTestGroup()
        group.add("alice")
        group.add("bob")
        // Host has a bye, so is in the bracket but not currently in a match.
        group.host.startTournament(seeding: ["host", "alice", "bob"])
        let late = group.add("late")

        late.challenge("host")
        XCTAssertEqual(late.notice, "Tournament players can't take free challenges")
        XCTAssertNotNil(late.bracket, "a late joiner still sees the bracket")
    }

    func testLeavingATournamentHandsTheOpponentAWalkover() async throws {
        let group = LANTestGroup()
        group.add("alice")
        group.add("bob")
        group.add("cara")
        // Round 1: host vs cara, alice vs bob.
        group.host.startTournament(seeding: ["host", "alice", "bob", "cara"])
        group.disconnect("cara")
        await group.playOutMatches()

        let bracket = try XCTUnwrap(group["host"].bracket)
        XCTAssertEqual(bracket.rounds[0][0].winner, "host", "cara's leaving handed host the match")
        XCTAssertNotNil(bracket.champion)
    }

    func testANextBracketMatchWaitsBehindTheResultOnScreen() async throws {
        let group = LANTestGroup()
        let alice = group.add("alice")
        group.add("bob")
        // Round 1: host has a bye; alice vs bob. The winner meets host at once.
        group.host.startTournament(seeding: ["host", "alice", "bob"])
        alice.lockIn(LANFixtures.squad("a", power: 100))
        group["bob"].lockIn(LANFixtures.squad("b", power: 10))
        await group.host.waitForResolutions()

        let winner = try XCTUnwrap(["alice", "bob"].first { group[$0].result?.didWin == true })
        let client = group[winner]
        XCTAssertNotNil(client.result, "the semi-final result stays on screen")
        XCTAssertTrue(client.hasQueuedMatch)

        client.clearMatch()
        guard case .picking? = client.activeMatch?.phase else {
            return XCTFail("dismissing the result should open the final's squad pick")
        }
    }
}
