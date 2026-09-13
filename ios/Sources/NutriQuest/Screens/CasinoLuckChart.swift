import SwiftUI
import Charts
import NutriQuestUI

/// "How has my luck actually run" — the casino tab's trend strip.
///
/// The series comes from `analytics.gamble_hourly`, a TimescaleDB continuous
/// aggregate: the database has already rolled every wager into hourly buckets,
/// so this asks for 72 buckets rather than three days of individual rounds, and
/// the request costs the same on day one as it does after a month of play.
///
/// Deliberately shows the *net swing* rather than a win count. Casino games pay
/// asymmetrically — a single Plinko jackpot outweighs a dozen small losses — so
/// counting wins would tell the player something true and useless.
struct CasinoLuckChart: View {
    @Environment(\.nqAccent) private var accent

    @State private var points: [CasinoTrendPoint] = []
    @State private var state: LoadState = .loading

    private enum LoadState: Equatable {
        case loading
        case ready
        /// The backend runs without Postgres, so there is no history to show.
        case unavailable
        case failed
    }

    /// How far back the strip looks. Three days is enough to read a streak
    /// without turning into a wall of empty buckets for a casual player.
    private let windowHours = 72

    var body: some View {
        VStack(alignment: .leading, spacing: NQTheme.spaceS) {
            Text("YOUR LUCK")
                .font(NQText.microXS.font)
                .tracking(0.4)
                .foregroundStyle(NQTheme.inkMuted)
                .padding(.leading, 4)

            NQCard {
                VStack(alignment: .leading, spacing: NQTheme.spaceM) {
                    header
                    content
                }
            }
        }
        .task { await load() }
    }

    // MARK: - Pieces

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Net swing, last 3 days")
                .font(NQText.bodyL.font.weight(.semibold))
                .foregroundStyle(NQTheme.ink)
            Spacer()
            if state == .ready {
                Text(netTotal >= 0 ? "+\(netTotal)" : "\(netTotal)")
                    .font(NQText.bodyL.font.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(netTotal >= 0 ? accent.accent : NQTheme.error)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .loading:
            placeholder("Reading your history…")
        case .unavailable:
            placeholder("Luck history turns on once the cloud database is connected.")
        case .failed:
            placeholder("Couldn't load your luck history just now.")
        case .ready:
            if hourly.isEmpty {
                placeholder("Play a round and your luck shows up here.")
            } else {
                chart
                modeBreakdown
            }
        }
    }

    private func placeholder(_ message: String) -> some View {
        Text(message)
            .font(NQText.body.font)
            .foregroundStyle(NQTheme.inkMuted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 60, alignment: .center)
    }

    private var chart: some View {
        Chart(hourly, id: \.start) { bucket in
            BarMark(
                x: .value("Hour", bucket.start),
                y: .value("Net", bucket.net)
            )
            // Green when the hour ended up, danger red when it ended down —
            // the one thing a player wants to read at a glance.
            .foregroundStyle(bucket.net >= 0 ? accent.accent : NQTheme.error)
            .cornerRadius(3)
        }
        // A zero rule, because a bar chart that crosses zero is meaningless
        // without one.
        .chartYAxis {
            AxisMarks { value in
                AxisGridLine().foregroundStyle(NQTheme.inkSubtle.opacity(0.25))
                AxisValueLabel {
                    if let v = value.as(Int.self) {
                        Text("\(v)")
                            .font(NQText.microXS.font)
                            .foregroundStyle(NQTheme.inkMuted)
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .hour, count: 12)) { value in
                AxisValueLabel(format: .dateTime.hour())
                    .font(NQText.microXS.font)
                    .foregroundStyle(NQTheme.inkMuted)
            }
        }
        .frame(height: 150)
    }

    /// Per-game summary under the chart. Casino modes pay differently, so the
    /// aggregate rows are worth keeping separated rather than only summed.
    private var modeBreakdown: some View {
        VStack(spacing: NQTheme.spaceXS) {
            ForEach(modeTotals, id: \.mode) { row in
                HStack {
                    Text(label(for: row.mode))
                        .font(NQText.body.font)
                        .foregroundStyle(NQTheme.ink)
                    Spacer()
                    Text("\(row.plays) played")
                        .font(NQText.microXS.font)
                        .monospacedDigit()
                        .foregroundStyle(NQTheme.inkMuted)
                    Text(row.net >= 0 ? "+\(row.net)" : "\(row.net)")
                        .font(NQText.body.font.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(row.net >= 0 ? accent.accent : NQTheme.error)
                        .frame(minWidth: 62, alignment: .trailing)
                }
            }
        }
    }

    // MARK: - Shaping

    /// One entry per hour, summed across every game mode.
    private struct HourBucket {
        let start: Date
        let net: Int
    }

    private var hourly: [HourBucket] {
        var byStart: [Date: Int] = [:]
        for point in points {
            guard let date = point.bucketDate else { continue }
            byStart[date, default: 0] += point.netChange
        }
        return byStart
            .map { HourBucket(start: $0.key, net: $0.value) }
            .sorted { $0.start < $1.start }
    }

    private struct ModeTotal {
        let mode: String
        let plays: Int
        let net: Int
    }

    private var modeTotals: [ModeTotal] {
        var plays: [String: Int] = [:]
        var net: [String: Int] = [:]
        for point in points {
            plays[point.mode, default: 0] += point.plays
            net[point.mode, default: 0] += point.netChange
        }
        return plays.keys
            .sorted()
            .map { ModeTotal(mode: $0, plays: plays[$0] ?? 0, net: net[$0] ?? 0) }
    }

    private var netTotal: Int {
        points.reduce(0) { $0 + $1.netChange }
    }

    private func label(for mode: String) -> String {
        switch mode {
        case "crash":  return "Cauldron Crash"
        case "mines":  return "Kitchen Mines"
        case "plinko": return "Plinko"
        case "wheel":  return "Portal Wheel"
        default:       return mode.capitalized
        }
    }

    // MARK: - Loading

    private func load() async {
        do {
            let response = try await APIClient().fetchCasinoTrend(hours: windowHours)
            points = response.points
            state = response.available ? .ready : .unavailable
        } catch {
            state = .failed
        }
    }
}
