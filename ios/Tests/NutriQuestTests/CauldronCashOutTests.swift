import XCTest
@testable import NutriQuest

// ============================================================================
// Cauldron Crash cash-out latency (#129).
//
// The number on screen is derived from the server clock, and a cash-out tap
// is optimistic until the POST (or a reconcile GET) says what actually
// happened. These tests pin that math so a late tap cannot look like a win
// and a skewed device clock cannot freeze the wrong multiplier.
// ============================================================================

final class CauldronCashOutTests: XCTestCase {

    private let growthRate = 0.115

    // MARK: - Clock

    /// Builds a pair of ISO timestamps `serverElapsed` seconds into a round,
    /// with the device clock `deviceLag` seconds behind the server.
    private func clockSample(
        serverElapsed: TimeInterval,
        deviceLag: TimeInterval
    ) -> (startedAt: String, serverTime: String, receivedAt: Date) {
        let started = Date(timeIntervalSince1970: 1_700_000_000)
        let startedAt = ISO8601DateFormatter.cauldron.string(from: started)
        let serverNow = started.addingTimeInterval(serverElapsed)
        let serverTime = ISO8601DateFormatter.cauldron.string(from: serverNow)
        let receivedAt = serverNow.addingTimeInterval(-deviceLag)
        return (startedAt, serverTime, receivedAt)
    }

    func testMultiplierFollowsServerElapsedNotDeviceClock() {
        let sample = clockSample(serverElapsed: 10, deviceLag: 2)
        let naiveElapsed = sample.receivedAt.timeIntervalSince(
            ISO8601DateFormatter.cauldron.date(from: sample.startedAt) ?? sample.receivedAt
        )
        XCTAssertEqual(naiveElapsed, 8, accuracy: 0.05)

        let elapsed = CauldronClock.elapsed(
            startedAt: sample.startedAt,
            serverTime: sample.serverTime,
            receivedAt: sample.receivedAt,
            now: sample.receivedAt
        )
        XCTAssertEqual(elapsed, 10, accuracy: 0.05)

        let naive = CauldronClock.multiplier(elapsed: naiveElapsed, growthRate: growthRate)
        let corrected = CauldronClock.multiplier(
            startedAt: sample.startedAt,
            serverTime: sample.serverTime,
            growthRate: growthRate,
            receivedAt: sample.receivedAt,
            now: sample.receivedAt
        )
        XCTAssertEqual(
            corrected,
            CauldronClock.multiplier(elapsed: 10, growthRate: growthRate),
            accuracy: 0.001
        )
        XCTAssertNotEqual(corrected, naive)
    }

    func testElapsedKeepsClimbingAfterTheSnapshot() {
        let sample = clockSample(serverElapsed: 10, deviceLag: 2)
        let later = sample.receivedAt.addingTimeInterval(1)
        let elapsed = CauldronClock.elapsed(
            startedAt: sample.startedAt,
            serverTime: sample.serverTime,
            receivedAt: sample.receivedAt,
            now: later
        )
        XCTAssertEqual(elapsed, 11, accuracy: 0.05)
    }

    func testMultiplierIsOneAtTheStart() {
        XCTAssertEqual(CauldronClock.multiplier(elapsed: 0, growthRate: growthRate), 1.0, accuracy: 0.001)
        XCTAssertEqual(CauldronClock.multiplier(elapsed: -1, growthRate: growthRate), 1.0, accuracy: 0.001)
    }

    func testQuantizeFloorsHundredthsWithoutIeeeDocking() {
        XCTAssertEqual(CauldronClock.quantize(4.749999999999999), 4.75, accuracy: 0.001)
        XCTAssertEqual(CauldronClock.quantize(1.009), 1.00, accuracy: 0.001)
        XCTAssertEqual(CauldronClock.quantize(0.5), 1.0, accuracy: 0.001)
    }

    // MARK: - Verdict

    func testPostedCashOutWins() {
        let posted = makeRound(status: "CASHED_OUT", cashOutMultiplier: 2.4)
        let verdict = CauldronCashOut.resolve(
            roundId: posted.roundId,
            posted: posted,
            liveRound: makeRound(status: "ACTIVE"),
            lastRound: nil
        )
        XCTAssertEqual(verdict, .cashedOut(posted))
    }

    func testPostedCrashIsALateTap() {
        let posted = makeRound(status: "CRASHED", crashMultiplier: 3.1)
        let verdict = CauldronCashOut.resolve(
            roundId: posted.roundId,
            posted: posted,
            liveRound: nil,
            lastRound: posted
        )
        XCTAssertEqual(verdict, .crashed(posted))
    }

    func testDroppedPostThatSucceededIsRecoveredFromLastRound() {
        let cashed = makeRound(status: "CASHED_OUT", cashOutMultiplier: 1.8)
        let verdict = CauldronCashOut.resolve(
            roundId: cashed.roundId,
            posted: nil,
            liveRound: nil,
            lastRound: cashed
        )
        XCTAssertEqual(verdict, .cashedOut(cashed))
    }

    func testDroppedPostThatNeverLandedStaysLive() {
        let live = makeRound(status: "ACTIVE")
        let verdict = CauldronCashOut.resolve(
            roundId: live.roundId,
            posted: nil,
            liveRound: live,
            lastRound: nil
        )
        XCTAssertEqual(verdict, .stillLive)
    }

    func testUnknownRoundIdDoesNotInheritAnotherPlayersLastRound() {
        let other = makeRound(id: "other", status: "CASHED_OUT", cashOutMultiplier: 5)
        let verdict = CauldronCashOut.resolve(
            roundId: "missing",
            posted: nil,
            liveRound: nil,
            lastRound: other
        )
        XCTAssertEqual(verdict, .unknown)
    }

    func testShouldApplyRejectsASecondFinishForTheSameRound() {
        let crashed = makeRound(status: "CRASHED", crashMultiplier: 2)
        XCTAssertTrue(CauldronCashOut.shouldApply(crashed, resolvedRoundId: nil))
        XCTAssertFalse(CauldronCashOut.shouldApply(crashed, resolvedRoundId: crashed.roundId))
        XCTAssertFalse(CauldronCashOut.shouldApply(makeRound(status: "ACTIVE"), resolvedRoundId: nil))
    }

    /// Builds a round DTO with the fields a verdict / clock test actually reads.
    private func makeRound(
        id: String = "round-1",
        status: String,
        cashOutMultiplier: Double? = nil,
        crashMultiplier: Double? = nil
    ) -> CauldronRoundDTO {
        CauldronRoundDTO(
            roundId: id,
            status: status,
            startedAt: "2026-01-01T00:00:00.000Z",
            serverTime: "2026-01-01T00:00:05.000Z",
            wager: [],
            startingNetWorth: 1_000,
            startingRarity: "common",
            multiplier: cashOutMultiplier ?? crashMultiplier ?? 1.5,
            netWorth: 1_500,
            rarity: "common",
            intensity: "calm",
            growthRate: growthRate,
            crashMultiplier: crashMultiplier,
            cashOutMultiplier: cashOutMultiplier,
            finalNetWorth: status == "CASHED_OUT" ? 1_800 : nil,
            lostNetWorth: status == "CRASHED" ? 1_000 : nil,
            reward: nil,
            completedAt: status == "ACTIVE" ? nil : "2026-01-01T00:00:05.000Z"
        )
    }
}
