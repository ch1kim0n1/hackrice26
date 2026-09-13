import SwiftUI
import NutriQuestUI

/// First-run guided tour: the Gatekeeper mascot walks the player through
/// every tab, switching the real screen behind a scrim so the pointer lands
/// on the actual UI. Runs once ever (`TourGate`); Profile's "Replay the
/// tour" row raises `gameState.showTour` to run it again.
struct GuidedTourView: View {
    @ObservedObject var gameState: GameState
    /// The tour drives the real tab bar — the player watches the app change
    /// under the scrim, not a slide deck of screenshots.
    @Binding var selectedTab: NQTab
    var onFinish: () -> Void

    @State private var stepIndex = 0
    @Environment(\.nqAccent) private var accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Where the speech tail points: a bottom-nav item, the centre of the
    /// screen, or nowhere (welcome/farewell floats free).
    private enum Pointer {
        case nav(NQTab)
        case center
        case none
    }

    private struct TourStep {
        let tab: NQTab
        let headline: String
        let message: String
        let pointer: Pointer
    }

    private let steps: [TourStep] = [
        TourStep(
            tab: .home,
            headline: "Welcome to NutriQuest",
            message: "I'm the Gatekeeper: I keep this place running. Quick tour, then I'll get out of your way.",
            pointer: .none
        ),
        TourStep(
            tab: .home,
            headline: "This is you",
            message: "Your display monster sits in the calorie ring: hit your target and it glows. Macros are right underneath.",
            pointer: .center
        ),
        TourStep(
            tab: .home,
            headline: "Daily tasks",
            message: "Three tasks a day pay coins: clear all of them for a bonus, keep a streak going to earn Cookbook Boosts.",
            pointer: .center
        ),
        TourStep(
            tab: .scan,
            headline: "Scan food",
            message: "Point the camera at any barcode. The first time you ever scan one, it summons a monster: every scan logs the meal.",
            pointer: .nav(.scan)
        ),
        TourStep(
            tab: .collection,
            headline: "Your squad",
            message: "Everything you've summoned lives here. Fuse three copies into the next star, sell extras, and pick who's on display.",
            pointer: .nav(.collection)
        ),
        TourStep(
            tab: .casino,
            headline: "The casino floor",
            message: "Cookbooks and Cases mint new monsters. Battles live here too: ranked pays RR and Cases, and bots fill in when nobody's online.",
            pointer: .nav(.casino)
        ),
        TourStep(
            tab: .profile,
            headline: "Trainer card",
            message: "Battle history, watch link, body metrics, settings: and the button that brings this tour back if you ever want it.",
            pointer: .nav(.profile)
        ),
        TourStep(
            tab: .home,
            headline: "That's the grounds",
            message: "Go scan something tasty: your first monster is waiting on a barcode.",
            pointer: .none
        )
    ]

    private var step: TourStep { steps[stepIndex] }
    private var isLast: Bool { stepIndex == steps.count - 1 }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottom) {
                NQTheme.inkDeep.opacity(0.78)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture(perform: advance)

                spotlight(in: geo.size)

                VStack(spacing: 0) {
                    Spacer()
                    guideRow(in: geo.size)
                    Spacer(minLength: tourBottomClearance)
                }
            }
        }
        .onAppear { selectedTab = step.tab }
        .accessibilityElement(children: .contain)
    }

    /// Room to leave at the bottom so the bubble clears the tab bar plus
    /// the speech tail when pointing at a nav item.
    private var tourBottomClearance: CGFloat { 150 }

    // MARK: - Spotlight

    /// A soft hole in the scrim over whatever the step is talking about —
    /// the nav item for tab steps, the hero card for home steps.
    @ViewBuilder
    private func spotlight(in size: CGSize) -> some View {
        switch step.pointer {
        case .nav(let tab):
            // Bottom-nav x-position: 5 equal cells, centre of the tapped one.
            let x = size.width * (CGFloat(NQTab.allCases.firstIndex(of: tab) ?? 0) + 0.5) / 5
            Circle()
                .fill(accent.accent.opacity(0.9))
                .frame(width: 74, height: 74)
                .blur(radius: 26)
                .position(x: x, y: size.height - 52)
        case .center:
            RoundedRectangle(cornerRadius: NQTheme.radiusXL)
                .fill(accent.accent.opacity(0.55))
                .frame(width: size.width - 80, height: size.height * 0.34)
                .blur(radius: 34)
                .position(x: size.width / 2, y: size.height * 0.3)
        case .none:
            EmptyView()
        }
    }

    // MARK: - Guide + speech

    /// The Gatekeeper on the left, its bubble on the right. The bubble is
    /// the tap target — anywhere on it (or the scrim) advances.
    private func guideRow(in size: CGSize) -> some View {
        HStack(alignment: .bottom, spacing: NQTheme.spaceS) {
            NQAssetImage("gatekeeper-mascot")
                .frame(width: 92, height: 92)
                .nqSquish()

            VStack(alignment: .leading, spacing: NQTheme.spaceS) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(step.headline)
                        .font(NQText.heading.font.weight(.heavy))
                        .foregroundStyle(NQTheme.inkDeep)
                    Text(step.message)
                        .font(NQText.caption.font.weight(.semibold))
                        .foregroundStyle(NQTheme.inkDeep.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .nqPadding(.card)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(NQPanelShape(cut: NQTheme.radiusM).fill(NQTheme.ink))
                .overlay {
                    NQPanelShape(cut: NQTheme.radiusM)
                        .strokeBorder(NQTheme.inkDeep, lineWidth: 2.5)
                }

                controls
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, NQTheme.spaceL)
        .id(stepIndex)
        .transition(.asymmetric(
            insertion: .move(edge: .trailing).combined(with: .opacity),
            removal: .move(edge: .leading).combined(with: .opacity)
        ))
    }

    private var controls: some View {
        HStack(spacing: NQTheme.spaceM) {
            // Progress pips — the tour is short, so dots beat a bar.
            HStack(spacing: 5) {
                ForEach(0..<steps.count, id: \.self) { i in
                    Circle()
                        .fill(i <= stepIndex ? accent.accent : NQTheme.inkMuted)
                        .frame(width: 7, height: 7)
                }
            }
            Spacer()
            Button("Skip") { finish() }
                .font(NQText.caption.font.weight(.bold))
                .foregroundStyle(NQTheme.inkMuted)
            Button {
                advance()
            } label: {
                Text(isLast ? "Done" : "Next")
                    .font(NQText.caption.font.weight(.heavy))
                    .foregroundStyle(accent.accent.readableTextColor())
                    .padding(.horizontal, NQTheme.spaceM)
                    .padding(.vertical, NQTheme.spaceS)
                    .background(NQPanelShape(cut: NQTheme.radiusS).fill(accent.accent))
                    .overlay {
                        NQPanelShape(cut: NQTheme.radiusS)
                            .strokeBorder(NQTheme.inkDeep, lineWidth: 2)
                    }
            }
            .buttonStyle(NQPressableStyle(scale: 0.94, haptic: false, ledge: 3))
            .accessibilityHint(isLast ? "Finishes the tour" : "Next tour stop")
        }
    }

    private func advance() {
        guard !isLast else { finish(); return }
        NQHaptic.selection()
        withAnimation(NQMotion.snappy) {
            stepIndex += 1
            selectedTab = step.tab
        }
    }

    private func finish() {
        NQJuice.tap()
        TourGate.markSeen()
        onFinish()
    }
}

// MARK: - Gate

/// The tour is a once-ever thing — unlike onboarding's per-build re-run,
/// seeing the grounds once is enough. Profile's replay row bypasses the
/// gate deliberately.
enum TourGate {
    private static let key = "tour.seen"
    static var seen: Bool { UserDefaults.standard.bool(forKey: key) }
    static func markSeen() { UserDefaults.standard.set(true, forKey: key) }
}
