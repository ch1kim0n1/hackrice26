import SwiftUI
import NutriQuestUI

struct RootTabView: View {
    @EnvironmentObject var gameState: GameState
    @State private var selectedTab: NQTab = {
        // QA hook: -uiTab <tab> launch arg deep-links a tab for screenshots.
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-uiTab"), args.count > i + 1 {
            return NQTab(rawValue: args[i + 1]) ?? .home
        }
        return .home
    }()
    @State private var colorMode: ColorMode = .active
    @State private var showCrateOpening = false
    @State private var showOnboarding = !UserDefaults.standard.bool(forKey: "onboarding.done")
    @State private var showLeaderboard = false
    /// One stack shared by every tab. A push from inside a tab (e.g. Casino's
    /// "Loot Box Shop") must not survive a tab switch, or the bottom nav
    /// stops navigating and just sits on top of whatever was last pushed.
    @State private var navPath = NavigationPath()

    /// Single source of truth: starter roster + scans + crate pulls.
    private var characters: [Character] { gameState.collection }

    /// Single source of truth for the showcased character: the server
    /// profile once loaded, falling back to the starter while it isn't.
    /// There is no local override — setting it always goes through
    /// `gameState.setDisplayCharacter`, the same PUT /user/:id the backend
    /// already supports.
    private var activeCharacterID: String? {
        gameState.profile?.activeCharacterId ?? SampleData.characters.first?.id
    }

    private var activeCharacter: Character? {
        characters.first(where: { $0.id == activeCharacterID })
    }

    /// The single accent source: derived from the displayed character and
    /// injected into the environment — every screen and kit component reads
    /// `@Environment(\.nqAccent)`.
    private var accentContext: NQAccentContext {
        NQAccentContext(
            mode: colorMode == .none ? .none : (colorMode == .active ? .active : .bestUnselected),
            character: activeCharacter.map { $0.kitColor }
        )
    }

    var body: some View {
        NavigationStack(path: $navPath) {
            VStack(spacing: 0) {
                Group {
                    switch selectedTab {
                    case .home:
                        HomeView(gameState: gameState)
                    case .collection:
                        CollectionView(characters: characters, activeCharacterID: activeCharacterID, colorMode: colorMode, gameState: gameState)
                    case .scan:
                        ScanView(gameState: gameState)
                    case .casino:
                        CasinoHubView(gameState: gameState)
                    case .profile:
                        ProfileView(
                            profileLoading: gameState.profileLoading,
                            displayCharacter: activeCharacter,
                            // Server profile; local fallback only while the
                            // very first fetch is in flight (never fake data).
                            displayName: gameState.profile?.displayName ?? "Trainer",
                            stats: [
                                ("Characters", "\(characters.filter { !$0.isLocked }.count)"),
                                ("Battles Won", "\(gameState.profile?.battlesWon ?? 0)"),
                                ("Day Streak", "\(gameState.profile?.streakDays ?? 0)")
                            ],
                            rows: [
                                ProfileSettingsRow(label: "Leaderboard", systemImage: "trophy.fill", action: { showLeaderboard = true }),
                                ProfileSettingsRow(label: "Connected devices", systemImage: "applewatch", trailing: gameState.watchLinked ? "Connected" : "Not Connected", isWatchRow: true)
                            ]
                        )
                    }
                }
                .frame(maxHeight: .infinity)
                .id(selectedTab)
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .scale(scale: 0.985)),
                    removal: .opacity
                ))
                .animation(.easeOut(duration: 0.16), value: selectedTab)



                NQBottomNav(selection: $selectedTab)
            }
            .overlay(alignment: .bottom) {
                // Backend errors float above the nav instead of shoving it around.
                if let backendError = gameState.backendError {
                    NQBanner.error(backendError, onDismiss: { gameState.backendError = nil })
                        .padding(.horizontal, NQTheme.spaceL)
                        .padding(.bottom, 84)
                        .transition(NQTransition.slideUp)
                }
            }
            .animation(NQMotion.snappy, value: gameState.backendError)
            .nqPageBackground()
            .overlay {
                // One-shot milestone celebration.
                if let achievement = gameState.achievement {
                    AchievementToast(achievement: achievement) {
                        gameState.achievement = nil
                    }
                    .transition(NQTransition.summon)
                }
            }
            .animation(NQMotion.springy, value: gameState.achievement)
            .overlay {
                // Streak milestone celebration — escalates with the milestone.
                if let milestone = gameState.streakMilestone {
                    StreakMilestoneCelebration(milestone: milestone) {
                        gameState.streakMilestone = nil
                    }
                    .transition(NQTransition.summon)
                }
            }
            .animation(NQMotion.springy, value: gameState.streakMilestone)
        }
        .nqAccentContext(accentContext)
        .onChange(of: selectedTab) { _ in
            // Bottom-nav taps switch tabs, not push screens — anything a tab
            // pushed onto the shared stack (e.g. Casino's "Loot Box Shop")
            // must not still be on top the next time that tab is visited.
            navPath = NavigationPath()
        }
        .sheet(isPresented: $showLeaderboard) {
            NavigationStack { LeaderboardView() }
        }
        .fullScreenCover(isPresented: $showOnboarding) {
            OnboardingView {
                UserDefaults.standard.set(true, forKey: "onboarding.done")
                showOnboarding = false
                selectedTab = .scan
            }
            .environmentObject(gameState)
        }
        .task {
            await gameState.loadProfile()
            await gameState.refreshVitals()
            await gameState.loadCharacterCatalog()
        }
        .task {
            if ProcessInfo.processInfo.arguments.contains("-showCrates") {
                gameState.showCrates = true
            }
        }
        .sheet(isPresented: $gameState.showCrates) {
            CrateOpeningView(gameState: gameState, accentContext: accentContext, onDismiss: { gameState.showCrates = false })
                .nqAccentContext(accentContext)
        }
    }
}

/// Full-screen streak milestone celebration. Escalates by milestone size:
/// 3-day = flame + count-up, 7 = success burst, 14/30 = confetti,
/// 100 = confetti + sparkles + shine. Auto-dismiss or tap.
struct StreakMilestoneCelebration: View {
    let milestone: Int
    let onDismiss: () -> Void

    @State private var appeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var headline: String {
        switch milestone {
        case 100: return "100 DAYS. LEGENDARY."
        case 30: return "30-day streak!"
        case 14: return "Two weeks strong!"
        case 7: return "7-day streak!"
        default: return "3-day streak!"
        }
    }

    /// Escalation tier: 0 = flicker, 1 = burst, 2 = confetti, 3 = everything.
    private var tier: Int {
        switch milestone {
        case 100: return 3
        case 30, 14: return 2
        case 7: return 1
        default: return 0
        }
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.78)
                .ignoresSafeArea()
                .onTapGesture(perform: dismiss)

            if tier >= 2 {
                NQConfetti(trigger: 1)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }
            if tier >= 3 {
                NQFloatingSparkles(count: 12, color: NQTheme.gold)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }

            VStack(spacing: NQTheme.spaceL) {
                Spacer()
                ZStack {
                    Circle()
                        .fill(NQTheme.flame.opacity(0.18))
                        .frame(width: 150, height: 150)
                    NQAssetImage(GameArt.streakBadge(days: milestone))
                        .frame(width: 96, height: 96)
                        .scaleEffect(appeared && !reduceMotion ? 1 : 0.3)
                }
                .nqBreathingGlow(color: NQTheme.flame)

                Text("DAY \(milestone)")
                    .font(NQText.microXS.font)
                    .tracking(1.2)
                    .foregroundStyle(NQTheme.flame)
                NQCountUpText(value: milestone, font: NQFont.display.font(56), color: NQTheme.ink)
                Text(headline)
                    .font(NQText.heading.font.weight(.heavy))
                    .foregroundStyle(NQTheme.ink)

                Spacer()

                NQButton("Keep it burning", icon: .flame) { dismiss() }
                    .padding(.horizontal, NQTheme.spaceXL)
            }
            .padding(.vertical, NQTheme.spaceXL)
        }
        .nqSuccessBurst(on: appeared ? 1 : 0)
        .onAppear {
            NQJuice.reveal()
            withAnimation(.spring(response: 0.5, dampingFraction: 0.6)) { appeared = true }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(milestone) day streak milestone reached")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { dismiss() }
    }

    private func dismiss() {
        NQHaptic.light()
        onDismiss()
    }
}
