import XCTest
@testable import NutriQuest

/// The host's per-match state machine, driven directly: no networking, an
/// explicit clock, so every race and timeout is deterministic.
final class LANHostMatchTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private let alice = LANTestFighter(id: "alice", side: 0, squad: LANFixtures.squad("a"))
    private let bob = LANTestFighter(id: "bob", side: 1, squad: LANFixtures.squad("b"))

    // MARK: - Offer

    func testFreeChallengeOffersToTheTargetOnly() {
        let (match, outputs) = LANHostMatch.free(challenger: "alice", target: "bob", now: t0)
        XCTAssertEqual(outputs, [.send(to: "bob", .matchOffer(matchID: match.matchID, challengerID: "alice"))])
        XCTAssertEqual(match.phase, .offered)
    }

    func testOnlyTheTargetCanAccept() {
        var (match, _) = LANHostMatch.free(challenger: "alice", target: "bob", now: t0)
        XCTAssertEqual(match.handle(.offerReply(from: "alice", accept: true), now: t0), [])
        XCTAssertEqual(match.phase, .offered)
    }

    func testAcceptingStartsSquadPickingForBothSides() {
        var (match, _) = LANHostMatch.free(challenger: "alice", target: "bob", now: t0)
        let outputs = match.handle(.offerReply(from: "bob", accept: true), now: t0)
        XCTAssertEqual(match.phase, .picking)
        XCTAssertEqual(outputs, [
            .send(to: "alice", .matchStart(matchID: match.matchID, opponentID: "bob", side: 0,
                                           pickSeconds: Int(LANTimeouts.squadPick), tournament: false)),
            .send(to: "bob", .matchStart(matchID: match.matchID, opponentID: "alice", side: 1,
                                         pickSeconds: Int(LANTimeouts.squadPick), tournament: false))
        ])
    }

    func testDecliningCancels() {
        var (match, _) = LANHostMatch.free(challenger: "alice", target: "bob", now: t0)
        XCTAssertTrue(isCancelled(match.handle(.offerReply(from: "bob", accept: false), now: t0)))
        XCTAssertEqual(match.phase, .finished)
    }

    // MARK: - Commit / reveal

    func testRevealIsRequestedOnlyOnceBothHaveCommitted() {
        var match = picking()
        XCTAssertEqual(match.handle(.commit(from: "alice", hash: alice.commitment(for: match.matchID)), now: t0), [])
        let outputs = match.handle(.commit(from: "bob", hash: bob.commitment(for: match.matchID)), now: t0)
        XCTAssertEqual(outputs, [
            .send(to: "alice", .revealNow(matchID: match.matchID)),
            .send(to: "bob", .revealNow(matchID: match.matchID))
        ])
        XCTAssertEqual(match.phase, .revealing)
    }

    func testOutsiderDuplicateAndMalformedCommitsAreIgnored() {
        var match = picking()
        XCTAssertEqual(match.handle(.commit(from: "mallory", hash: Data(repeating: 1, count: 32)), now: t0), [])
        XCTAssertEqual(match.handle(.commit(from: "alice", hash: Data(repeating: 1, count: 16)), now: t0), [])
        XCTAssertEqual(match.handle(.commit(from: "alice", hash: alice.commitment(for: match.matchID)), now: t0), [])
        // A second commit can't replace the first.
        XCTAssertEqual(match.handle(.commit(from: "alice", hash: Data(repeating: 2, count: 32)), now: t0), [])
        XCTAssertEqual(match.commits["alice"], alice.commitment(for: match.matchID))
        XCTAssertNil(match.commits["mallory"])
    }

    func testAnEarlyRevealIsDropped() {
        var match = picking()
        _ = match.handle(.commit(from: "alice", hash: alice.commitment(for: match.matchID)), now: t0)
        // Bob hasn't committed yet, so nobody may reveal.
        XCTAssertEqual(match.handle(.reveal(from: "alice", nonce: alice.nonce, squadBytes: alice.bytes), now: t0), [])
        XCTAssertEqual(match.phase, .picking)
        XCTAssertTrue(match.reveals.isEmpty)
    }

    func testBothRevealsResolveWithTheCommittedSeed() throws {
        var match = revealing()
        XCTAssertEqual(match.handle(.reveal(from: "alice", nonce: alice.nonce, squadBytes: alice.bytes), now: t0), [])
        let outputs = match.handle(.reveal(from: "bob", nonce: bob.nonce, squadBytes: bob.bytes), now: t0)

        guard case .resolve(let resolution)? = outputs.first, outputs.count == 1 else {
            return XCTFail("expected a single resolve, got \(outputs)")
        }
        XCTAssertEqual(match.phase, .resolving)
        XCTAssertEqual(resolution.squadA, alice.squad)
        XCTAssertEqual(resolution.squadB, bob.squad)
        XCTAssertEqual(resolution.squadBytesA, alice.bytes)
        XCTAssertEqual(resolution.seed, LANCrypto.seed(matchID: match.matchID, nonceA: alice.nonce, nonceB: bob.nonce))
    }

    /// Bob submits Alice's commitment as his own, then replays her reveal to
    /// field her exact squad. The host verifies under Bob's authenticated id
    /// and side, so it can't match.
    func testTheCopyAttackIsRejected() {
        var (match, _) = LANHostMatch.free(challenger: "alice", target: "bob", now: t0)
        _ = match.handle(.offerReply(from: "bob", accept: true), now: t0)
        let aliceHash = alice.commitment(for: match.matchID)
        _ = match.handle(.commit(from: "alice", hash: aliceHash), now: t0)
        _ = match.handle(.commit(from: "bob", hash: aliceHash), now: t0)
        _ = match.handle(.reveal(from: "alice", nonce: alice.nonce, squadBytes: alice.bytes), now: t0)

        let outputs = match.handle(.reveal(from: "bob", nonce: alice.nonce, squadBytes: alice.bytes), now: t0)
        XCTAssertTrue(isCancelled(outputs), "got \(outputs)")
    }

    func testTamperedSquadBytesAreRejected() {
        var match = revealing()
        let swapped = LANFixtures.bytes(LANFixtures.squad("z", power: 100))
        let outputs = match.handle(.reveal(from: "alice", nonce: alice.nonce, squadBytes: swapped), now: t0)
        XCTAssertTrue(isCancelled(outputs))
    }

    func testAnImpossibleSquadIsRejectedEvenWhenHonestlyCommitted() {
        let cheater = LANTestFighter(id: "alice", side: 0, squad: LANFixtures.squad("a", power: 999))
        var match = picking()
        _ = match.handle(.commit(from: "alice", hash: cheater.commitment(for: match.matchID)), now: t0)
        _ = match.handle(.commit(from: "bob", hash: bob.commitment(for: match.matchID)), now: t0)
        let outputs = match.handle(.reveal(from: "alice", nonce: cheater.nonce, squadBytes: cheater.bytes), now: t0)
        XCTAssertTrue(isCancelled(outputs))
    }

    // MARK: - Timeouts

    func testAnUnansweredChallengeExpires() {
        var (match, _) = LANHostMatch.free(challenger: "alice", target: "bob", now: t0)
        XCTAssertEqual(match.handle(.tick, now: t0.addingTimeInterval(LANTimeouts.offerReply - 1)), [])
        XCTAssertTrue(isCancelled(match.handle(.tick, now: t0.addingTimeInterval(LANTimeouts.offerReply))))
    }

    func testAFreeMatchIsCancelledWhenPickingTimesOut() {
        var match = picking()
        _ = match.handle(.commit(from: "alice", hash: alice.commitment(for: match.matchID)), now: t0)
        XCTAssertTrue(isCancelled(match.handle(.tick, now: t0.addingTimeInterval(LANTimeouts.squadPick))))
    }

    func testTheTournamentPlayerWhoDidntPickForfeits() {
        var (match, _) = LANHostMatch.tournament(playerA: "alice", playerB: "bob", now: t0)
        _ = match.handle(.commit(from: "alice", hash: alice.commitment(for: match.matchID)), now: t0)
        // Tournament picks get the longer window.
        XCTAssertEqual(match.handle(.tick, now: t0.addingTimeInterval(LANTimeouts.squadPick)), [])
        let outputs = match.handle(.tick, now: t0.addingTimeInterval(LANTimeouts.tournamentSquadPick))
        XCTAssertEqual(forfeitLoser(outputs), "bob")
    }

    func testWhenNeitherTournamentPlayerPicksTheUpperSlotAdvances() {
        var (match, _) = LANHostMatch.tournament(playerA: "alice", playerB: "bob", now: t0)
        let outputs = match.handle(.tick, now: t0.addingTimeInterval(LANTimeouts.tournamentSquadPick))
        XCTAssertEqual(forfeitLoser(outputs), "bob")
    }

    func testTheTournamentPlayerWhoDidntRevealForfeits() {
        var (match, _) = LANHostMatch.tournament(playerA: "alice", playerB: "bob", now: t0)
        _ = match.handle(.commit(from: "alice", hash: alice.commitment(for: match.matchID)), now: t0)
        _ = match.handle(.commit(from: "bob", hash: bob.commitment(for: match.matchID)), now: t0)
        _ = match.handle(.reveal(from: "bob", nonce: bob.nonce, squadBytes: bob.bytes), now: t0)
        let outputs = match.handle(.tick, now: t0.addingTimeInterval(LANTimeouts.reveal))
        XCTAssertEqual(forfeitLoser(outputs), "alice")
    }

    // MARK: - Leaving

    func testLeavingCancelsAFreeMatchButForfeitsATournamentOne() {
        var free = picking()
        XCTAssertTrue(isCancelled(free.handle(.playerLeft("bob"), now: t0)))

        var (bracket, _) = LANHostMatch.tournament(playerA: "alice", playerB: "bob", now: t0)
        XCTAssertEqual(forfeitLoser(bracket.handle(.playerLeft("bob"), now: t0)), "bob")
    }

    func testLeavingOnceResolvingChangesNothing() {
        var match = revealing()
        _ = match.handle(.reveal(from: "alice", nonce: alice.nonce, squadBytes: alice.bytes), now: t0)
        _ = match.handle(.reveal(from: "bob", nonce: bob.nonce, squadBytes: bob.bytes), now: t0)
        XCTAssertEqual(match.handle(.playerLeft("bob"), now: t0), [])
        XCTAssertEqual(match.phase, .resolving)
    }

    func testAFinishedMatchIgnoresEverything() {
        var (match, _) = LANHostMatch.free(challenger: "alice", target: "bob", now: t0)
        _ = match.handle(.offerReply(from: "bob", accept: false), now: t0)
        XCTAssertEqual(match.handle(.offerReply(from: "bob", accept: true), now: t0), [])
        XCTAssertEqual(match.handle(.tick, now: t0.addingTimeInterval(9999)), [])
    }

    // MARK: - Helpers

    private func picking() -> LANHostMatch {
        var (match, _) = LANHostMatch.free(challenger: "alice", target: "bob", now: t0)
        _ = match.handle(.offerReply(from: "bob", accept: true), now: t0)
        return match
    }

    private func revealing() -> LANHostMatch {
        var match = picking()
        _ = match.handle(.commit(from: "alice", hash: alice.commitment(for: match.matchID)), now: t0)
        _ = match.handle(.commit(from: "bob", hash: bob.commitment(for: match.matchID)), now: t0)
        return match
    }

    private func isCancelled(_ outputs: [LANHostMatch.Output]) -> Bool {
        guard outputs.count == 1, case .cancelled? = outputs.first else { return false }
        return true
    }

    private func forfeitLoser(_ outputs: [LANHostMatch.Output]) -> String? {
        guard outputs.count == 1, case .forfeit(let loser, _)? = outputs.first else { return nil }
        return loser
    }
}
