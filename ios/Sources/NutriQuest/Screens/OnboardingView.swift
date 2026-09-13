import SwiftUI
import NutriQuestUI

/// One-shot milestone celebration — "you did X" made visible.
struct AchievementToast: View {
    let achievement: Achievement
    var onDismiss: () -> Void

    var body: some View {
        VStack(spacing: NQTheme.spaceM) {
            ZStack {
                Circle()
                    .fill(NQTheme.gold.opacity(0.25))
                    .frame(width: 110, height: 110)
                    .blur(radius: 14)
                if achievement.icon == .trophy {
                    NQAssetImage("battle-badge")
                        .frame(width: 72, height: 72)
                } else if achievement.icon == .star || achievement.icon == .crown {
                    NQAssetImage("star-badge")
                        .frame(width: 72, height: 72)
                } else {
                    achievement.icon.view
                        .frame(width: 44, height: 44)
                        .foregroundStyle(NQTheme.gold)
                }
            }
            Text("Milestone unlocked")
                .font(NQText.microS.font)
                .foregroundStyle(NQTheme.inkMuted)
            Text(achievement.title)
                .font(NQText.headingL.font.weight(.heavy))
                .foregroundStyle(NQTheme.ink)
            Text(achievement.detail)
                .font(NQText.caption.font)
                .foregroundStyle(NQTheme.inkMuted)
            NQButton("Nice", style: .secondary, fullWidth: false) { onDismiss() }
        }
        .nqPadding(.card)
        .nqSurface(.sticker)
        .padding(NQTheme.spaceXL)
    }
}

// MARK: - Answer models
//
// `BodySex`, `WeightGoal` and the calorie maths live in Models/BodyMetrics.swift,
// shared with the Profile > Body & goals editor so both produce the same plan.

/// Daily nutrition targets shown on the plan-ready screen.
struct OBPlanTargets {
    let calories: Int
    let proteinG: Int
    let carbsG: Int
    let fatsG: Int
    let healthScore: Int
}

/// Everything the user answers during onboarding, with plan derivation.
struct OBAnswers {
    var gender: BodySex?
    var isMetric = false
    var heightFeet = 5
    var heightInches = 6
    var weightPounds = 120
    var heightCm = 170
    var weightKg = 65
    var birthdate = Calendar.current.date(byAdding: .year, value: -22, to: Date()) ?? Date()
    var activity: ActivityLevel?
    var goal: WeightGoal?
    var desiredWeightKg = 65.0
    var speedKgPerWeek = 1.0

    /// Current body weight normalized to kilograms.
    var currentWeightKg: Double {
        isMetric ? Double(weightKg) : Double(weightPounds) * 0.4536
    }

    /// Current height normalized to centimeters.
    var currentHeightCm: Double {
        isMetric ? Double(heightCm) : (Double(heightFeet) * 12 + Double(heightInches)) * 2.54
    }

    /// Age in whole years derived from the birthdate.
    var ageYears: Int {
        Calendar.current.dateComponents([.year], from: birthdate, to: Date()).year ?? 22
    }

    /// Absolute gap between current and desired weight, in kg.
    var deltaKg: Double {
        abs(currentWeightKg - desiredWeightKg)
    }

    /// Projected date the target is reached at the chosen weekly pace.
    var targetDate: Date {
        guard speedKgPerWeek > 0 else { return Date() }
        let weeks = max(1, deltaKg / speedKgPerWeek)
        return Calendar.current.date(byAdding: .day, value: Int(weeks * 7), to: Date()) ?? Date()
    }

    /// The answers as the app's shared body-metrics model. The activity step
    /// can't be skipped, so the `.light` fallback only covers an unset answer.
    var bodyMetrics: BodyMetrics {
        BodyMetrics(
            sex: gender ?? .other,
            heightCm: currentHeightCm,
            weightKg: currentWeightKg,
            birthdate: birthdate,
            activity: activity ?? .light,
            goal: goal ?? .maintain,
            paceKgPerWeek: speedKgPerWeek,
            usesMetric: isMetric
        ).normalized()
    }

    /// Daily targets for the plan-ready screen, derived by the same
    /// Mifflin-St Jeor maths the settings editor uses.
    func planTargets() -> OBPlanTargets {
        let plan = bodyMetrics.targets
        return OBPlanTargets(
            calories: plan.calories,
            proteinG: plan.proteinG,
            carbsG: plan.carbsG,
            fatsG: plan.fatsG,
            healthScore: 7
        )
    }
}

// MARK: - Flow

/// hackrice onboarding flow, implemented from the Figma reference:
/// welcome, an account (sign up, or log in through Persona), a calibration
/// questionnaire (gender, height and
/// weight, birthdate, activity, goal, desired weight, pace), Apple Health connect,
/// and the plan-ready celebration.
struct OnboardingView: View {
    var onFinish: () -> Void
    @EnvironmentObject var gameState: GameState

    /// Ordered steps of the flow. Raw value doubles as progress index.
    enum Step: Int, CaseIterable {
        case welcome, account, gender, heightWeight, birthdate, activity, goal
        case desiredWeight, motivation, speed, appleHealth, planReady
    }

    @State private var step: Step = .welcome
    @State private var answers = OBAnswers()
    /// Whether the account step opens on signup or login.
    @State private var accountMode: HumanGateMode = .signup
    /// Apple Health step: true while the permission sheet + first upload run.
    @State private var connectingHealth = false

    var body: some View {
        VStack(spacing: 0) {
            if step != .welcome {
                OBProgressHeader(progress: progress, onBack: goBack)
                    .padding(.top, 8)
            }
            stepView
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .id(step)
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .move(edge: .leading).combined(with: .opacity)
                ))
        }
        .padding(.horizontal, OBTheme.screenInset)
        .padding(.bottom, 10)
        .nqPageBackground()
        .animation(.easeInOut(duration: 0.3), value: step)
        .preferredColorScheme(.dark)
    }

    /// Progress through the questionnaire, 0...1.
    private var progress: Double {
        Double(step.rawValue) / Double(Step.allCases.count - 1)
    }

    /// The view for the current step.
    @ViewBuilder private var stepView: some View {
        switch step {
        case .welcome:
            OBWelcomeStep(
                onGetStarted: { startAccount(.signup) },
                onLogIn: { startAccount(.login) }
            )
        case .account:
            OBAccountStep(mode: accountMode) {
                // The session now belongs to the account, so everything the
                // app loaded as a guest is re-fetched for that player.
                Task { await gameState.loadProfile() }
                advance(to: .gender)
            }
        case .gender:
            BodySexStep(selection: $answers.gender) { advance(to: .heightWeight) }
        case .heightWeight:
            OBHeightWeightStep(
                isMetric: $answers.isMetric,
                heightFeet: $answers.heightFeet,
                heightInches: $answers.heightInches,
                weightPounds: $answers.weightPounds,
                heightCm: $answers.heightCm,
                weightKg: $answers.weightKg
            ) { advance(to: .birthdate) }
        case .birthdate:
            OBBirthdateStep(birthdate: $answers.birthdate) { advance(to: .activity) }
        case .activity:
            OBActivityStep(selection: $answers.activity) { advance(to: .goal) }
        case .goal:
            WeightGoalStep(selection: $answers.goal) {
                seedDesiredWeight()
                advance(to: .desiredWeight)
            }
        case .desiredWeight:
            OBDesiredWeightStep(
                goal: answers.goal ?? .maintain,
                isMetric: answers.isMetric,
                desiredWeightKg: $answers.desiredWeightKg
            ) {
                advance(to: answers.goal == .maintain ? .speed : .motivation)
            }
        case .motivation:
            OBMotivationStep(
                goal: answers.goal ?? .maintain,
                isMetric: answers.isMetric,
                currentWeightKg: answers.currentWeightKg,
                desiredWeightKg: answers.desiredWeightKg,
                heightCm: answers.currentHeightCm
            ) {
                advance(to: .speed)
            }
        case .speed:
            OBSpeedStep(goal: answers.goal ?? .maintain, isMetric: answers.isMetric, speedKgPerWeek: $answers.speedKgPerWeek) {
                advance(to: .appleHealth)
            }
        case .appleHealth:
            OBAppleHealthStep(
                isConnecting: connectingHealth,
                onContinue: {
                    // Real connect: Health sheet + first upload. A failure is
                    // not fatal to onboarding — Profile › Connected devices
                    // is the retry path — so always move on.
                    guard !connectingHealth else { return }
                    connectingHealth = true
                    Task {
                        try? await gameState.connectAppleWatch()
                        connectingHealth = false
                        advance(to: .planReady)
                    }
                },
                onSkip: { advance(to: .planReady) }
            )
        case .planReady:
            OBPlanReadyStep(
                plan: answers.planTargets(),
                onFinish: {
                    // Persist the answers themselves, not just the plan: the
                    // home gauge, the health dashboard, the daily multiplier
                    // and the Body & goals editor all read back from them.
                    gameState.applyBodyMetrics(answers.bodyMetrics)
                    onFinish()
                }
            )
        }
    }

    /// Moves forward to the given step with the push animation.
    private func advance(to next: Step) {
        withAnimation { step = next }
    }

    /// Opens the account step, or skips it when already signed in.
    private func startAccount(_ mode: HumanGateMode) {
        guard !SessionStore.shared.isAuthenticated else {
            advance(to: .gender)
            return
        }
        accountMode = mode
        advance(to: .account)
    }

    /// Moves one step back; the branch skips mirror the forward path.
    private func goBack() {
        let previous: Step
        switch step {
        case .speed where answers.goal == .maintain:
            previous = .desiredWeight
        case .gender:
            // The account step is done once signed in; back goes home.
            previous = .welcome
        default:
            previous = Step(rawValue: step.rawValue - 1) ?? .welcome
        }
        withAnimation { step = previous }
    }

    /// Pre-fills the desired weight relative to the current weight so the
    /// ruler starts from a sensible position for the chosen goal.
    private func seedDesiredWeight() {
        let current = answers.currentWeightKg
        // Offset in the chosen unit (5 kg or 10 lb) and land on a whole value
        // of that unit, so an Imperial ruler never starts on a converted kg.
        let offset = answers.isMetric ? 5.0 : 10.0 / BodyUnits.poundsPerKg
        let target: Double
        switch answers.goal {
        case .lose: target = current - offset
        case .gain: target = current + offset
        default: target = current
        }
        answers.desiredWeightKg = answers.isMetric
            ? target.rounded()
            : BodyUnits.kg(fromPounds: BodyUnits.pounds(fromKg: target))
    }
}
