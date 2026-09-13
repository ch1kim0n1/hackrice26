import Foundation

/// Server-clock math for the Cauldron Crash multiplier.
///
/// The round payload carries `serverTime` so the number on screen can follow
/// the same `m(t) = e^(rate * t)` curve the server prices a cash-out with,
/// even when the device clock is minutes off. `serverTime` is a snapshot from
/// the moment the payload was minted, not a live clock — callers must pass
/// the `Date` they received it so elapsed time keeps advancing between polls.
enum CauldronClock {
    /// Parses the backend's fractional-second ISO-8601 timestamps.
    static func parse(_ iso: String) -> Date? {
        ISO8601DateFormatter.cauldron.date(from: iso)
    }

    /// How far this device's clock sits ahead of the server's, measured at
    /// the instant `serverTime` arrived. Positive if the device is ahead.
    static func deviceOffset(serverTime: String, receivedAt: Date) -> TimeInterval {
        guard let server = parse(serverTime) else { return 0 }
        return receivedAt.timeIntervalSince(server)
    }

    /// Seconds the round has been running on the server clock.
    static func elapsed(
        startedAt: String,
        serverTime: String,
        receivedAt: Date,
        now: Date = Date()
    ) -> TimeInterval {
        guard let started = parse(startedAt) else { return 0 }
        let offset = deviceOffset(serverTime: serverTime, receivedAt: receivedAt)
        return max(0, now.timeIntervalSince(started) - offset)
    }

    /// Floors a multiplier to two decimals, matching `quantizeMultiplier` on
    /// the server so a binary leftover cannot dock a hundredth the player reached.
    static func quantize(_ multiplier: Double) -> Double {
        max(1, floor(multiplier * 100 + 1e-9) / 100)
    }

    /// `m(t) = e^(rate * t)` after `elapsed` seconds, quoted to two decimals.
    static func multiplier(elapsed: TimeInterval, growthRate: Double) -> Double {
        guard elapsed > 0 else { return 1 }
        return quantize(exp(growthRate * elapsed))
    }

    /// Live multiplier for a round, corrected onto the server clock.
    static func multiplier(
        startedAt: String,
        serverTime: String,
        growthRate: Double,
        receivedAt: Date,
        now: Date = Date()
    ) -> Double {
        multiplier(
            elapsed: elapsed(
                startedAt: startedAt,
                serverTime: serverTime,
                receivedAt: receivedAt,
                now: now
            ),
            growthRate: growthRate
        )
    }
}

extension ISO8601DateFormatter {
    /// The backend timestamps rounds with fractional seconds.
    static let cauldron: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
