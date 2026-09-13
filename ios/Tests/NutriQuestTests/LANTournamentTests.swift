import XCTest
@testable import NutriQuest

final class LANTournamentTests: XCTestCase {

    private func players(_ n: Int) -> [String] { (1...n).map { "p\($0)" } }

    func testStandardSeedOrder() {
        XCTAssertEqual(LANTournament.seedOrder(size: 2), [1, 2])
        XCTAssertEqual(LANTournament.seedOrder(size: 4), [1, 4, 2, 3])
        XCTAssertEqual(LANTournament.seedOrder(size: 8), [1, 8, 4, 5, 2, 7, 3, 6])
    }

    func testBracketShapeForEverySupportedSize() {
        for n in 2...8 {
            let tournament = LANTournament(seeds: players(n))
            var size = 2
            while size < n { size *= 2 }
            let expectedRounds = Int(log2(Double(size)))
            XCTAssertEqual(tournament.rounds.count, expectedRounds, "n=\(n)")

            let firstRound = tournament.rounds[0]
            let placed = firstRound.flatMap { [$0.a, $0.b] }.compactMap { $0 }
            XCTAssertEqual(placed.sorted(), players(n).sorted(), "every player placed exactly once, n=\(n)")
            XCTAssertFalse(firstRound.contains { $0.a == nil && $0.b == nil }, "no bye-vs-bye, n=\(n)")
        }
    }

    /// Byes go to the top seeds, and each one is paired with a real player.
    func testByesGoToTheTopSeeds() {
        for n in [3, 5, 6, 7] {
            var size = 2
            while size < n { size *= 2 }
            let byes = size - n
            let tournament = LANTournament(seeds: players(n))

            let advancedOnBye = tournament.rounds[0]
                .filter { ($0.a == nil) != ($0.b == nil) }
                .compactMap(\.winner)
            XCTAssertEqual(Set(advancedOnBye), Set(players(n).prefix(byes)), "n=\(n)")
        }
    }

    func testTwoPlayersIsASingleFinal() {
        var tournament = LANTournament(seeds: ["p1", "p2"])
        XCTAssertEqual(tournament.ready.count, 1)
        tournament.record(winner: "p2", round: 0, index: 0)
        XCTAssertEqual(tournament.champion, "p2")
        XCTAssertTrue(tournament.isFinished)
    }

    func testPlayingEveryMatchCrownsOneChampion() {
        for n in 2...8 {
            var tournament = LANTournament(seeds: players(n))
            var guardCount = 0
            while let next = tournament.ready.first, guardCount < 20 {
                tournament.record(winner: next.a, round: next.round, index: next.index)
                guardCount += 1
            }
            XCTAssertNotNil(tournament.champion, "n=\(n)")
            XCTAssertEqual(tournament.eliminated.count, n - 1, "n=\(n)")
        }
    }

    func testAWinnerMustBeInThePairing() {
        var tournament = LANTournament(seeds: ["p1", "p2"])
        tournament.record(winner: "stranger", round: 0, index: 0)
        XCTAssertNil(tournament.champion)
    }

    func testLeavingBeforeYourMatchIsAWalkover() {
        // 4 players: round 1 is p1 vs p4, p2 vs p3.
        var tournament = LANTournament(seeds: players(4))
        tournament.playerLeft("p4")
        XCTAssertEqual(tournament.rounds[0][0].winner, "p1")
        XCTAssertEqual(tournament.rounds[1][0].a, "p1")
    }

    /// p2 wins their semi, then leaves before p1's semi is over. p1 must still
    /// get the final by walkover once their own match finishes.
    func testPendingWalkoverResolvesWhenTheOpponentArrives() {
        var tournament = LANTournament(seeds: players(4))
        tournament.markLive(round: 0, index: 0)
        tournament.markLive(round: 0, index: 1)

        tournament.record(winner: "p2", round: 0, index: 1)
        tournament.playerLeft("p2")
        XCTAssertNil(tournament.champion, "the final waits for p1's semi")

        tournament.record(winner: "p1", round: 0, index: 0)
        XCTAssertEqual(tournament.champion, "p1")
    }

    func testALiveMatchIsLeftToTheHostToForfeit() {
        var tournament = LANTournament(seeds: players(2))
        tournament.markLive(round: 0, index: 0)
        tournament.playerLeft("p2")
        // The match reducer forfeits live matches; the bracket must not also
        // decide it, or the result would be recorded twice.
        XCTAssertNil(tournament.rounds[0][0].winner)
    }

    func testActiveParticipants() {
        var tournament = LANTournament(seeds: players(4))
        XCTAssertTrue(tournament.isActiveParticipant("p1"))
        XCTAssertFalse(tournament.isActiveParticipant("latecomer"))

        tournament.record(winner: "p1", round: 0, index: 0)
        XCTAssertFalse(tournament.isActiveParticipant("p4"), "eliminated")

        tournament.playerLeft("p2")
        XCTAssertFalse(tournament.isActiveParticipant("p2"), "gone")
    }
}
