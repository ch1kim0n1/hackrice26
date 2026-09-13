import SwiftUI
import NutriQuestUI

struct ProfileSettingsRow: Identifiable {
    let id = UUID()
    let label: String
    let systemImage: String
    var trailing: String? = nil
    var isDestructive: Bool = false
    var isWatchRow: Bool = false
    var action: (() -> Void)? = nil
}

struct ProfileView: View {
    var profileLoading: Bool = false
    var displayCharacter: Character?
    var displayName: String
    var stats: [(label: String, value: String)]
    var rows: [ProfileSettingsRow]

    @Environment(\.nqAccent) private var accent
    @State private var showJourney = false
    /// QA hook, matching RootTabView's `-uiTab`: `-uiHumanGate` launches
    /// straight into the human-gate web game for screenshots/demo.
    @State private var showHumanGate = ProcessInfo.processInfo.arguments.contains("-uiHumanGate")
    /// `-uiWatch` opens Connected devices (WatchConnectView) directly.
    @State private var showWatchQA = ProcessInfo.processInfo.arguments.contains("-uiWatch")
    /// QA hook: `-uiBodyMetrics` opens the body-and-goals editor directly.
    @State private var showBodyMetrics = ProcessInfo.processInfo.arguments.contains("-uiBodyMetrics")
    @State private var showAccount = false

    var body: some View {
        ScrollView {
            VStack(spacing: NQTheme.spaceL) {
                pfp.nqPopIn()
                Text(displayName)
                    .font(NQText.displayL.font)
                    .foregroundStyle(NQTheme.ink)
                    .nqSlideUp(delay: 0.05)
                rankCard.nqSlideUp(delay: 0.1)
                if profileLoading && gameState.profile == nil {
                    NQSkeleton(height: 64, cornerRadius: NQTheme.radiusL)
                    NQSkeleton(height: 180, cornerRadius: NQTheme.radiusL)
                } else {
                    if gameState.profile == nil, gameState.backendError != nil {
                        offlineNote
                    }
                    statChips.nqSlideUp(delay: 0.15)
                    recentBattlesCard.nqSlideUp(delay: 0.18)
                    trophyCase.nqSlideUp(delay: 0.2)
                    settingsList.nqSlideUp(delay: 0.25)
                }
            }
            .padding(NQTheme.spaceL)
        }
        .nqPageBackground()
        .navigationTitle("Profile")
        .navigationBarTitleDisplayMode(.inline)
        .task { await gameState.refreshBattleHistory() }
        .fullScreenCover(isPresented: $showJourney) {
            JourneyView()
                .environmentObject(gameState)
        }
        .fullScreenCover(isPresented: $showHumanGate, onDismiss: {
            // Auth swaps the player identity — reload everything keyed on it.
            Task {
                await gameState.loadProfile()
                await gameState.refreshTasks()
                await gameState.refreshInventory(limit: 200)
            }
        }) {
            HumanGateView()
        }
        .fullScreenCover(isPresented: $showWatchQA) {
            NavigationStack {
                WatchConnectView(step: .prompt)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Close") { showWatchQA = false }
                        }
                    }
            }
            .environmentObject(gameState)
        }
        .sheet(isPresented: $showAccount) {
            AccountSheet(displayName: displayName)
                .environmentObject(gameState)
                .presentationDetents([.medium])
        }
        .fullScreenCover(isPresented: $showBodyMetrics) {
            NavigationStack {
                BodyMetricsView(gameState: gameState, metrics: gameState.bodyMetrics)
            }
        }
    }

    // MARK: - Rank card

    /// Ranked standing (spec §5): rank label + RR inside the 100-RR band,
    /// with the ranked record and nutrition streak alongside. No XP — the
    /// spec has no levels.
    private var rankCard: some View {
        let rr = gameState.rank?.rr ?? gameState.profile?.rr ?? 0
        let label = gameState.rank?.rankLabel ?? "Iron"
        // Progress within the current rank band: RR modulo the band floor.
        let bandProgress = Double(rr % 100) / 100
        let toNext = gameState.rank?.rrToNextRank
        let wins = gameState.record?.rankedWins ?? 0
        let losses = gameState.record?.rankedLosses ?? 0
        let winRate = gameState.record?.winRate ?? 0

        return VStack(spacing: NQTheme.spaceXS) {
            HStack {
                HStack(spacing: 6) {
                    NQIcon.sparkle.view.frame(width: 12, height: 12)
                        .foregroundStyle(NQTheme.gold)
                    Text(label)
                        .font(NQText.caption.font.weight(.bold))
                        .foregroundStyle(NQTheme.ink)
                }
                Spacer()
                Text(toNext.map { "\($0) RR to next rank" } ?? "Top rank")
                    .font(NQText.captionS.font)
                    .foregroundStyle(NQTheme.inkMuted)
                    .contentTransition(.numericText())
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(NQTheme.hairline)
                    Capsule()
                        .fill(LinearGradient(colors: [NQTheme.gold, NQTheme.flame],
                                             startPoint: .leading, endPoint: .trailing))
                        .frame(width: geo.size.width * bandProgress)
                        .animation(NQMotion.springy, value: bandProgress)
                }
            }
            .frame(height: 10)

            HStack {
                Text("\(rr) RR")
                    .font(NQText.captionS.font.weight(.bold))
                    .foregroundStyle(NQTheme.gold)
                Spacer()
                Text("\(wins)W \(losses)L · \(Int(winRate * 100))%")
                    .font(NQText.captionS.font)
                    .foregroundStyle(NQTheme.inkMuted)
                if let streakDays = gameState.streak?.days, streakDays > 0 {
                    Text("·")
                        .foregroundStyle(NQTheme.inkFaint)
                    Text("\(streakDays)d streak")
                        .font(NQText.captionS.font)
                        .foregroundStyle(NQTheme.inkMuted)
                }
            }
        }
        .nqPadding(.card)
        .nqSurface(.sticker)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label) rank, \(rr) rating points, \(wins) wins, \(losses) losses")
    }

    // MARK: - Recent battles (spec §6)

    /// The last few recorded fights — result, mode, opponent and RR movement.
    /// Ranked moves RR; friendly and dungeon don't.
    private var recentBattlesCard: some View {
        VStack(alignment: .leading, spacing: NQTheme.spaceS) {
            Text("Recent battles")
                .font(NQText.microXS.font)
                .tracking(0.4)
                .foregroundStyle(NQTheme.inkMuted)
                .padding(.leading, 4)

            VStack(spacing: 0) {
                if gameState.battleHistory.isEmpty {
                    Text("No battles yet — ranked, friendly and dungeon fights land here.")
                        .font(NQText.captionS.font)
                        .foregroundStyle(NQTheme.inkMuted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, NQTheme.spaceS)
                } else {
                    ForEach(gameState.battleHistory.prefix(5)) { entry in
                        battleRow(entry)
                        if entry.id != gameState.battleHistory.prefix(5).last?.id {
                            Divider().overlay(NQTheme.hairline)
                        }
                    }
                }
            }
            .nqPadding(.card)
            .nqSurface(.sticker)
        }
    }

    private func battleRow(_ entry: BattleHistoryEntry) -> some View {
        let won = entry.result == "win"
        return HStack(spacing: NQTheme.spaceS) {
            ZStack {
                Circle()
                    .fill((won ? NQTheme.success : NQTheme.inkFaint).opacity(0.16))
                    .frame(width: 30, height: 30)
                (won ? NQIcon.trophy : NQIcon.shield).view
                    .frame(width: 14, height: 14)
                    .foregroundStyle(won ? NQTheme.success : NQTheme.inkMuted)
            }
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: NQTheme.spaceXS) {
                    Text(won ? "Victory" : "Defeat")
                        .font(NQText.caption.font.weight(.bold))
                        .foregroundStyle(NQTheme.ink)
                    Text(entry.mode.capitalized)
                        .font(NQText.micro.font)
                        .foregroundStyle(NQTheme.inkMuted)
                }
                Text(battleRowSubtitle(entry))
                    .font(NQText.micro.font)
                    .foregroundStyle(NQTheme.inkFaint)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if entry.rrDelta != 0 {
                Text("\(entry.rrDelta > 0 ? "+" : "")\(entry.rrDelta) RR")
                    .font(NQText.captionS.font.weight(.bold))
                    .foregroundStyle(entry.rrDelta > 0 ? NQTheme.success : NQTheme.inkMuted)
            }
        }
        .padding(.vertical, NQTheme.spaceXS + 2)
        .accessibilityElement(children: .combine)
    }

    private func battleRowSubtitle(_ entry: BattleHistoryEntry) -> String {
        var parts: [String] = []
        if let opponent = entry.opponent { parts.append("vs \(opponent)") }
        if let rounds = entry.detail?.rounds { parts.append("\(rounds) turns") }
        if let floors = entry.detail?.floorsCleared { parts.append("floor \(floors)") }
        if let coins = entry.detail?.coinsEarned, coins > 0 { parts.append("+\(coins) coins") }
        if let caseRarity = entry.detail?.caseReward { parts.append("\(caseRarity.capitalized) Case") }
        return parts.isEmpty ? entry.at : parts.joined(separator: " · ")
    }

    @EnvironmentObject private var gameState: GameState

    /// Offline note: explains plainly and offers recovery — never blocks content.
    private var offlineNote: some View {
        HStack(spacing: NQTheme.spaceS) {
            NQIcon.wifiOff.view
                .frame(width: 16, height: 16)
                .foregroundStyle(NQTheme.inkMuted)
            VStack(alignment: .leading, spacing: 2) {
                Text("You're offline")
                    .font(NQText.caption.font.weight(.bold))
                    .foregroundStyle(NQTheme.ink)
                Text("Showing your last saved stats.")
                    .font(NQText.captionS.font)
                    .foregroundStyle(NQTheme.inkMuted)
            }
            Spacer()
            Button("Retry") {
                Task { await gameState.loadProfile() }
            }
            .font(NQText.caption.font.weight(.bold))
            .foregroundStyle(accent.accentDark)
        }
        .nqPadding(.card)
        .nqSurface(.sticker)
    }

    /// Trophy case — the game layer of the profile: every milestone, locked
    /// or unlocked, so progress reads as a collection too.
    private var trophyCase: some View {
        let unlocked = Achievements.unlockedIDs()
        return VStack(alignment: .leading, spacing: NQTheme.spaceS) {
            Text("Trophy case")
                .font(NQText.microXS.font)
                .tracking(0.4)
                .foregroundStyle(NQTheme.inkMuted)
                .padding(.leading, 4)
            VStack(spacing: 0) {
                ForEach(Array(Achievements.all.enumerated()), id: \.element.id) { index, achievement in
                    let isUnlocked = unlocked.contains(achievement.id)
                    HStack(spacing: NQTheme.spaceM) {
                        ZStack {
                            RoundedRectangle(cornerRadius: NQTheme.radiusS, style: .continuous)
                                .fill(isUnlocked ? NQTheme.gold.opacity(0.18) : NQTheme.inkFaint.opacity(0.12))
                                .frame(width: 32, height: 32)
                            achievement.icon.view
                                .frame(width: 17, height: 17)
                                .foregroundStyle(isUnlocked ? NQTheme.gold : NQTheme.inkFaint)
                        }
                        VStack(alignment: .leading, spacing: 1) {
                            Text(achievement.title)
                                .font(NQText.caption.font.weight(.bold))
                                .foregroundStyle(isUnlocked ? NQTheme.ink : NQTheme.inkFaint)
                            Text(achievement.detail)
                                .font(NQText.captionS.font)
                                .foregroundStyle(NQTheme.inkMuted)
                        }
                        Spacer()
                        if isUnlocked {
                            Image(systemName: "checkmark.seal.fill")
                                .foregroundStyle(NQTheme.success)
                        }
                    }
                    .nqPadding(.card)
                    .opacity(isUnlocked ? 1 : 0.65)
                    if index < Achievements.all.count - 1 {
                        Divider().foregroundStyle(NQTheme.hairline)
                    }
                }
            }
            .nqSurface(.sticker)
        }
    }

    private var pfp: some View {
        ZStack(alignment: .bottomTrailing) {
            Circle()
                .fill(NQTheme.background)
                .frame(width: 104, height: 104)
                .overlay(Circle().strokeBorder(accent.accent, lineWidth: 4))
                .overlay {
                    Group {
                        if let displayCharacter {
                            characterArtwork(displayCharacter)
                        } else {
                            ChibiCharacterView(
                                color: NQCharacterColor(name: displayName, base: accent.accent),
                                statType: .fiber
                            )
                        }
                    }
                    .frame(width: 86, height: 106)
                    .offset(y: 22)
                    .clipShape(Circle())
                }
                .nqElevation(.raised)
        }
    }

    @ViewBuilder private func characterArtwork(_ character: Character) -> some View {
        CharacterArtwork(character: character)
    }

    private var statChips: some View {
        HStack(spacing: NQTheme.spaceS + 2) {
            ForEach(stats, id: \.label) { stat in
                VStack(spacing: 2) {
                    Text(stat.value)
                        .font(NQText.headingL.font.weight(.heavy))
                        .foregroundStyle(NQTheme.ink)
                    Text(stat.label)
                        .font(NQText.microXS.font)
                        .foregroundStyle(NQTheme.inkMuted)
                }
                .frame(maxWidth: .infinity)
                .nqPadding(.badge)
                .padding(.vertical, 6)
                .nqSurface(.sticker)
                .accessibilityElement(children: .combine)
            }
        }
    }

    private var settingsList: some View {
        VStack(alignment: .leading, spacing: NQTheme.spaceS) {
            Text("Settings")
                .font(NQText.microXS.font)
                .tracking(0.4)
                .foregroundStyle(NQTheme.inkMuted)
                .padding(.leading, 4)
            VStack(spacing: 0) {
                soundToggle
                Divider().foregroundStyle(NQTheme.hairline)
                hapticsToggle
                Divider().foregroundStyle(NQTheme.hairline)
                Button {
                    showJourney = true
                } label: {
                    rowContent(ProfileSettingsRow(label: "Your journey", systemImage: "chart.bar.fill"))
                }
                .buttonStyle(.nqPressable(scale: 0.98, haptic: false))
                Divider().foregroundStyle(NQTheme.hairline)
                NavigationLink {
                    HealthDashboardView(gameState: gameState)
                } label: {
                    rowContent(ProfileSettingsRow(label: "Health dashboard", systemImage: "heart.fill"))
                }
                .buttonStyle(.nqPressable(scale: 0.98, haptic: false))
                Divider().foregroundStyle(NQTheme.hairline)
                NavigationLink {
                    BodyMetricsView(gameState: gameState, metrics: gameState.bodyMetrics)
                } label: {
                    rowContent(ProfileSettingsRow(label: "Body & goals", systemImage: "figure.stand"))
                }
                .buttonStyle(.nqPressable(scale: 0.98, haptic: false))
                Divider().foregroundStyle(NQTheme.hairline)
                Button {
                    showAccount = true
                } label: {
                    rowContent(ProfileSettingsRow(label: "Account & info", systemImage: "person.text.rectangle.fill"))
                }
                .buttonStyle(.nqPressable(scale: 0.98, haptic: false))
                Divider().foregroundStyle(NQTheme.hairline)
                Button {
                    showHumanGate = true
                } label: {
                    rowContent(ProfileSettingsRow(label: "Are You a Human?", systemImage: "person.crop.circle.badge.questionmark"))
                }
                .buttonStyle(.nqPressable(scale: 0.98, haptic: false))
                Divider().foregroundStyle(NQTheme.hairline)

                ForEach(rows) { row in
                    Group {
                        if row.isWatchRow {
                            NavigationLink {
                                WatchConnectView(step: .prompt)
                            } label: {
                                rowContent(row)
                            }
                            .buttonStyle(.nqPressable(scale: 0.98, haptic: false))
                        } else if let action = row.action {
                            Button(action: action) {
                                rowContent(row)
                            }
                            .buttonStyle(.nqPressable(scale: 0.98, haptic: false))
                        } else {
                            rowContent(row)
                        }
                    }
                    Divider().foregroundStyle(NQTheme.hairline)
                }
            }
            .nqSurface(.sticker)
        }
    }

    @AppStorage(NQFeedbackSettings.soundKey) private var soundEnabled = true
    @AppStorage(NQFeedbackSettings.hapticsKey) private var hapticsEnabled = true

    private var soundToggle: some View {
        HStack(spacing: NQTheme.spaceM) {
            ZStack {
                RoundedRectangle(cornerRadius: NQTheme.radiusS, style: .continuous)
                    .fill(accent.accentSoft)
                    .frame(width: 32, height: 32)
                Image(systemName: "speaker.wave.2.fill")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(accent.accentDark)
            }
            .accessibilityHidden(true)
            Text("Sound effects")
                .font(NQText.bodyL.font)
                .foregroundStyle(NQTheme.ink)
            Spacer()
            Toggle("", isOn: $soundEnabled)
                .labelsHidden()
                .tint(accent.accent)
        }
        .nqPadding(.card)
        .padding(.horizontal, 2)
        .accessibilityElement(children: .combine)
    }

    private var hapticsToggle: some View {
        HStack(spacing: NQTheme.spaceM) {
            ZStack {
                RoundedRectangle(cornerRadius: NQTheme.radiusS, style: .continuous)
                    .fill(accent.accentSoft)
                    .frame(width: 32, height: 32)
                Image(systemName: "iphone.radiowaves.left.and.right")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(accent.accentDark)
            }
            .accessibilityHidden(true)
            Text("Haptics")
                .font(NQText.bodyL.font)
                .foregroundStyle(NQTheme.ink)
            Spacer()
            Toggle("", isOn: $hapticsEnabled)
                .labelsHidden()
                .tint(accent.accent)
        }
        .nqPadding(.card)
        .padding(.horizontal, 2)
        .accessibilityElement(children: .combine)
    }

    /// A flat gray glyph floating in whitespace is what makes a settings list
    /// read as stock iOS. A colored rounded chip behind the icon is the same
    /// row, but it reads as this app instead of the Settings app.
    private func rowContent(_ row: ProfileSettingsRow) -> some View {
        HStack(spacing: NQTheme.spaceM) {
            ZStack {
                RoundedRectangle(cornerRadius: NQTheme.radiusS, style: .continuous)
                    .fill(row.isDestructive ? NQTheme.warning.opacity(0.15) : accent.accentSoft)
                    .frame(width: 32, height: 32)
                Image(systemName: row.systemImage)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(row.isDestructive ? NQTheme.warning : accent.accentDark)
            }
            .accessibilityHidden(true)
            Text(row.label)
                .font(NQText.bodyL.font)
                .foregroundStyle(row.isDestructive ? NQTheme.warning : NQTheme.ink)
            Spacer()
            if let trailing = row.trailing {
                Text(trailing)
                    .font(NQText.microS.font.weight(.bold))
                    .foregroundStyle(NQTheme.inkFaint)
            }
            if !row.isDestructive {
                Image(systemName: "chevron.right")
                    .font(.system(size: NQText.caption.size, weight: .semibold))
                    .foregroundStyle(NQTheme.inkFaint)
                    .accessibilityHidden(true)
            }
        }
        .nqPadding(.card)
        .padding(.horizontal, 2)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// Read-only account card — identity + watch link state (#31: a way into
/// "user info" from the profile).
private struct AccountSheet: View {
    var displayName: String
    @EnvironmentObject private var gameState: GameState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: NQTheme.spaceL) {
            HStack {
                NQSectionHeader("Account")
                Spacer()
                Button("Done") { dismiss() }
                    .font(NQText.heading.font.weight(.bold))
                    .foregroundStyle(NQTheme.ink)
            }
            VStack(spacing: 0) {
                infoRow("Name", displayName)
                Divider().foregroundStyle(NQTheme.hairline)
                infoRow("Username", SessionStore.shared.username ?? "—")
                Divider().foregroundStyle(NQTheme.hairline)
                infoRow("Player ID", gameState.playerID)
                Divider().foregroundStyle(NQTheme.hairline)
                infoRow("Apple Watch", gameState.watchLinked ? "Linked" : "Not linked")
            }
            .nqElevation(.card)
            Spacer()
        }
        .nqPadding(.screen)
        .background(NQTheme.inkFaint.opacity(0.4).ignoresSafeArea())
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label.uppercased())
                .font(NQText.body.font)
                .foregroundStyle(NQTheme.inkMuted)
            Spacer()
            Text(value)
                .font(NQText.body.font.weight(.semibold))
                .foregroundStyle(NQTheme.inkFaint)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .nqPadding(.card)
    }
}
