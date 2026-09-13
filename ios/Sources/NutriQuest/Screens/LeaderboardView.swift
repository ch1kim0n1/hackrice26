import SwiftUI
import NutriQuestUI

/// Global ranking — one ladder, ordered server-side: RR desc, then ranked
/// wins, then win rate (spec §6).
struct LeaderboardView: View {
    @State private var entries: [LeaderboardEntry] = []
    @State private var loading = true
    @State private var errorMessage: String?

    @Environment(\.nqAccent) private var accent
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(spacing: NQTheme.spaceS) {
                if loading {
                    NQContentState(.loading("Loading rankings…"))
                        .padding(.top, 80)
                } else if let errorMessage {
                    NQContentState(.error(errorMessage, retry: { Task { await load() } }))
                        .padding(.top, 80)
                } else if entries.isEmpty {
                    NQEmptyState(message: "No ranked players yet. Win a ranked battle to claim first place", icon: .trophy)
                        .padding(.top, 80)
                } else {
                    ForEach(entries) { entry in
                        row(entry)
                    }
                }
            }
            .padding(NQTheme.spaceL)
        }
        .background(NQTheme.battleBg.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .navigationTitle("Leaderboard")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Close") { dismiss() }
                    .foregroundStyle(.white)
            }
        }
        .task { await load() }
    }

    private func load() async {
        errorMessage = nil
        do {
            entries = try await APIClient.shared.fetchLeaderboard().entries
        } catch {
            errorMessage = "Couldn't load rankings. Check your connection and retry."
        }
        loading = false
    }

    private func row(_ entry: LeaderboardEntry) -> some View {
        HStack(spacing: NQTheme.spaceM) {
            if entry.rank <= 3 {
                NQAssetImage("battle-badge")
                    .frame(width: 36, height: 36)
            }
            Text(rankLabel(entry.rank))
                .font(NQText.headingL.font.weight(.heavy))
                .foregroundStyle(entry.rank <= 3 ? NQTheme.gold : NQTheme.battleInkMuted)
                .frame(width: 44, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.displayName)
                    .font(NQText.bodyL.font.weight(.bold))
                    .foregroundStyle(NQTheme.battleInk)
                Text("\(entry.rankLabel) · \(entry.rankedWins)W \(entry.rankedLosses)L · \(Int(entry.winRate * 100))%")
                    .font(NQText.captionS.font)
                    .foregroundStyle(NQTheme.battleInkMuted)
            }
            Spacer()
            Text("\(entry.rr) RR")
                .font(NQText.bodyL.font.weight(.heavy))
                .foregroundStyle(entry.isYou ? accent.accent : NQTheme.battleInk)
        }
        .nqPadding(.card)
        .background(entry.isYou ? accent.accent.opacity(0.15) : NQTheme.battleSurface)
        .clipShape(RoundedRectangle(cornerRadius: NQTheme.radiusM))
        .overlay {
            if entry.isYou {
                RoundedRectangle(cornerRadius: NQTheme.radiusM)
                    .strokeBorder(accent.accent, lineWidth: 2)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Rank \(entry.rank): \(entry.displayName), \(entry.rr) rating points, \(entry.rankLabel), \(entry.rankedWins) wins")
    }

    private func rankLabel(_ rank: Int) -> String {
        switch rank {
        case 1: return "1st"
        case 2: return "2nd"
        case 3: return "3rd"
        default: return "\(rank)"
        }
    }
}
