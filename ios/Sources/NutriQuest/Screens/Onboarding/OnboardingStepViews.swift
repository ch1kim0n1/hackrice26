import SwiftUI
import NutriQuestUI

// MARK: - Welcome

/// First screen of the flow: phone hero, headline, Get Started, Sign In.
struct OBWelcomeStep: View {
    let onGetStarted: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            

            Spacer(minLength: 16)
            NQAssetImage("onboarding-hero")
                .frame(maxHeight: 440)
            Spacer(minLength: 20)

            Text("Calorie tracking\nmade easy")
                .font(NQFont.display.font(30))
                .foregroundStyle(OBTheme.ink)
                .multilineTextAlignment(.center)

            OBPrimaryButton(title: "Get Started", action: onGetStarted)
                .padding(.top, 22)
        }
    }
}

// MARK: - Gender

/// "Choose your Gender" single-select step.
struct BodySexStep: View {
    @Binding var selection: BodySex?
    let onContinue: () -> Void

    var body: some View {
        OBStepScaffold(
            title: "Choose your Gender",
            subtitle: "This will be used to calibrate your custom plan.",
            buttonEnabled: selection != nil,
            onContinue: onContinue
        ) {
            VStack(spacing: 14) {
                ForEach(BodySex.allCases, id: \.self) { gender in
                    OBOptionCard(
                        title: gender.title,
                        centered: true,
                        selected: selection == gender
                    ) { selection = gender }
                }
            }
        }
    }
}

// MARK: - Height & weight

/// Imperial/metric toggle plus wheel pickers for height and weight.
struct OBHeightWeightStep: View {
    @Binding var isMetric: Bool
    @Binding var heightFeet: Int
    @Binding var heightInches: Int
    @Binding var weightPounds: Int
    @Binding var heightCm: Int
    @Binding var weightKg: Int
    let onContinue: () -> Void

    var body: some View {
        OBStepScaffold(
            title: "Height & weight",
            subtitle: "This will be used to calibrate your custom plan.",
            onContinue: onContinue
        ) {
            VStack(spacing: 26) {
                unitToggle
                HStack(alignment: .top, spacing: 0) {
                    VStack(spacing: 8) {
                        Text("Height")
                            .font(NQFont.heading.font(15))
                            .foregroundStyle(OBTheme.ink)
                        heightPickers
                    }
                    .frame(maxWidth: .infinity)
                    VStack(spacing: 8) {
                        Text("Weight")
                            .font(NQFont.heading.font(15))
                            .foregroundStyle(OBTheme.ink)
                        weightPicker
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }

    /// Imperial/Metric labels flanking a custom switch.
    private var unitToggle: some View {
        HStack(spacing: 14) {
            Text("Imperial")
                .font(NQFont.heading.font(17))
                .foregroundStyle(isMetric ? NQTheme.inkFaint : OBTheme.ink)
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { isMetric.toggle() }
            } label: {
                Capsule()
                    .fill(OBTheme.accent)
                    .frame(width: 52, height: 32)
                    .overlay(Capsule().strokeBorder(NQTheme.inkDeep.opacity(0.22), lineWidth: 1.5))
                    .overlay(alignment: isMetric ? .trailing : .leading) {
                        Circle()
                            .fill(.white)
                            .padding(3)
                    }
            }
            .accessibilityLabel("Units")
            .accessibilityValue(isMetric ? "Metric" : "Imperial")
            Text("Metric")
                .font(NQFont.heading.font(17))
                .foregroundStyle(isMetric ? OBTheme.ink : NQTheme.inkFaint)
        }
        .frame(maxWidth: .infinity)
    }

    /// Height wheels: ft + in for imperial, cm for metric.
    @ViewBuilder private var heightPickers: some View {
        if isMetric {
            Picker("Height", selection: $heightCm) {
                ForEach(120...220, id: \.self) { Text("\($0) cm").tag($0) }
            }
            .pickerStyle(.wheel)
            .frame(height: 180)
            .clipped()
        } else {
            HStack(spacing: 0) {
                Picker("Feet", selection: $heightFeet) {
                    ForEach(2...8, id: \.self) { Text("\($0) ft").tag($0) }
                }
                .pickerStyle(.wheel)
                .frame(width: 82, height: 180)
                .clipped()
                Picker("Inches", selection: $heightInches) {
                    ForEach(0...11, id: \.self) { Text("\($0) in").tag($0) }
                }
                .pickerStyle(.wheel)
                .frame(width: 82, height: 180)
                .clipped()
            }
        }
    }

    /// Weight wheel: lb for imperial, kg for metric.
    @ViewBuilder private var weightPicker: some View {
        if isMetric {
            Picker("Weight", selection: $weightKg) {
                ForEach(35...200, id: \.self) { Text("\($0) kg").tag($0) }
            }
            .pickerStyle(.wheel)
            .frame(height: 180)
            .clipped()
        } else {
            Picker("Weight", selection: $weightPounds) {
                ForEach(80...400, id: \.self) { Text("\($0) lb").tag($0) }
            }
            .pickerStyle(.wheel)
            .frame(height: 180)
            .clipped()
        }
    }
}

// MARK: - Birthdate

/// "When were you born?" wheel date picker.
struct OBBirthdateStep: View {
    @Binding var birthdate: Date
    let onContinue: () -> Void

    var body: some View {
        OBStepScaffold(
            title: "When were you born?",
            subtitle: "This will be used to calibrate your custom plan.",
            onContinue: onContinue
        ) {
            DatePicker(
                "Birthdate",
                selection: $birthdate,
                in: ...Date(),
                displayedComponents: .date
            )
            .datePickerStyle(.wheel)
            .labelsHidden()
            .frame(maxWidth: .infinity)
        }
    }
}

// MARK: - Goal

/// "What is your goal?" single-select step.
struct WeightGoalStep: View {
    @Binding var selection: WeightGoal?
    let onContinue: () -> Void

    var body: some View {
        OBStepScaffold(
            title: "What is your goal?",
            subtitle: "This helps us generate a plan for your calorie intake.",
            buttonEnabled: selection != nil,
            onContinue: onContinue
        ) {
            VStack(spacing: 14) {
                ForEach(WeightGoal.allCases, id: \.self) { goal in
                    OBOptionCard(title: goal.title, selected: selection == goal) {
                        selection = goal
                    }
                }
            }
        }
    }
}

// MARK: - Desired weight

/// Ruler-slider step for picking a target weight.
struct OBDesiredWeightStep: View {
    let goal: WeightGoal
    @Binding var desiredWeightKg: Double
    let onContinue: () -> Void

    var body: some View {
        OBStepScaffold(title: "What is your desired weight?", onContinue: onContinue) {
            VStack(spacing: 14) {
                Text(goal.title)
                    .font(NQFont.body.font(15))
                    .foregroundStyle(OBTheme.subtitle)
                Text(String(format: "%.1f kg", desiredWeightKg))
                    .font(NQFont.display.font(34))
                    .foregroundStyle(OBTheme.ink)
                    .monospacedDigit()
                OBRulerSlider(value: $desiredWeightKg)
                    .padding(.horizontal, -OBTheme.screenInset)
            }
        }
    }
}

// MARK: - Motivation

/// Interstitial reassurance screen: "Losing X kg is a realistic target."
struct OBMotivationStep: View {
    let goal: WeightGoal
    /// Absolute difference between current and desired weight, in kg.
    let deltaKg: Double
    let onContinue: () -> Void

    var body: some View {
        OBStepScaffold(title: "", buttonTitle: "Continue", onContinue: onContinue) {
            VStack(spacing: 22) {
                headline
                    .font(NQFont.display.font(26))
                    .multilineTextAlignment(.center)
                Text("90% of users say that the change is obvious after using hackrice and it is not easy to rebound.")
                    .font(NQFont.body.font(14))
                    .foregroundStyle(OBTheme.subtitle)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12)
            }
            .frame(maxWidth: .infinity)
        }
    }

    /// Headline with the kg delta highlighted in orange, matching the design.
    private var headline: Text {
        if goal == .maintain || deltaKg < 0.5 {
            return Text("Maintaining your weight is a realistic target. It's not hard at all!")
                .foregroundColor(OBTheme.ink)
        }
        let verb = goal == .lose ? "Losing " : "Gaining "
        let amount = String(format: deltaKg.truncatingRemainder(dividingBy: 1) == 0 ? "%.0f kg" : "%.1f kg", deltaKg)
        return Text(verb).foregroundColor(OBTheme.ink)
            + Text(amount).foregroundColor(OBTheme.accent)
            + Text(" is a realistic target. It's not hard at all!").foregroundColor(OBTheme.ink)
    }
}

// MARK: - Speed

/// "How fast do you want to reach your goal?" slider with pace mascots.
struct OBSpeedStep: View {
    let goal: WeightGoal
    @Binding var speedKgPerWeek: Double
    let onContinue: () -> Void

    /// Recommended pace band, kg per week.
    private let recommended: ClosedRange<Double> = 0.5...1.1

    var body: some View {
        OBStepScaffold(title: "How fast do you want to reach your goal?", onContinue: onContinue) {
            VStack(spacing: 16) {
                Text(goal == .gain ? "Gain weight speed per week" : "Loss weight speed per week")
                    .font(NQFont.body.font(15))
                    .foregroundStyle(OBTheme.subtitle)
                Text(String(format: "%.1f kg", speedKgPerWeek))
                    .font(NQFont.display.font(30))
                    .foregroundStyle(OBTheme.ink)
                    .monospacedDigit()

                HStack {
                    paceIcon("tortoise.fill", active: speedKgPerWeek < recommended.lowerBound)
                    Spacer()
                    paceIcon("hare.fill", active: recommended.contains(speedKgPerWeek))
                    Spacer()
                    paceIcon("bolt.fill", active: speedKgPerWeek > recommended.upperBound)
                }
                .padding(.horizontal, 6)

                Slider(value: $speedKgPerWeek, in: 0.1...1.5, step: 0.1)
                    .tint(OBTheme.accent)

                HStack {
                    Text("0.1 kg")
                    Spacer()
                    Text("0.8 kg")
                    Spacer()
                    Text("1.5 kg")
                }
                .font(NQFont.body.font(14))
                .foregroundStyle(OBTheme.subtitle)

                if recommended.contains(speedKgPerWeek) {
                    Text("Recommended")
                        .font(NQFont.heading.font(15))
                        .foregroundStyle(OBTheme.accentDark)
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                        .background(RoundedRectangle(cornerRadius: 14).fill(NQTheme.accentSoft))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14)
                                .strokeBorder(NQTheme.inkDeep.opacity(0.14), lineWidth: 1.5)
                        )
                        .padding(.top, 10)
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.2), value: recommended.contains(speedKgPerWeek))
        }
    }

    /// One of the three pace mascots; the active band is tinted coral.
    private func paceIcon(_ systemName: String, active: Bool) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 26, weight: .semibold))
            .foregroundStyle(active ? OBTheme.accent : NQTheme.inkFaint)
    }
}

// MARK: - Apple Health

/// "Connect to Apple Health" step with a recreated sync illustration.
struct OBAppleHealthStep: View {
    var isConnecting = false
    let onContinue: () -> Void
    let onSkip: () -> Void

    var body: some View {
        OBStepScaffold(
            title: "",
            buttonTitle: isConnecting ? "Connecting…" : "Continue",
            buttonEnabled: !isConnecting,
            secondaryTitle: "Not now",
            onSecondary: onSkip,
            onContinue: onContinue
        ) {
            VStack(alignment: .leading, spacing: 26) {
                illustration
                    .frame(maxWidth: .infinity)
                VStack(alignment: .leading, spacing: 10) {
                    Text("Connect to\nApple Health")
                        .font(NQFont.display.font(28))
                        .foregroundStyle(OBTheme.ink)
                    Text("Sync your daily activity between hackrice and Apple Watch")
                        .font(NQFont.body.font(15))
                        .foregroundStyle(OBTheme.subtitle)
                }
            }
        }
    }

    /// Health-sync illustration: heart card and apple card over a soft
    /// circle, joined by a checkmark, with activity label pills.
    private var illustration: some View {
        ZStack {
            Circle()
                .fill(NQTheme.accentSoft)
                .frame(width: 216, height: 216)

            RoundedRectangle(cornerRadius: 20)
                .fill(.white)
                .frame(width: 84, height: 84)
                .nqInkStroke(RoundedRectangle(cornerRadius: 20))
                .nqElevation(.sticker)
                .overlay {
                    Image(systemName: "heart.fill")
                        .font(.system(size: 40))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [Color(hex: 0xFF6482), Color(hex: 0xFA3C57)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                }
                .offset(x: -62, y: 42)

            RoundedRectangle(cornerRadius: 18)
                .fill(OBTheme.ink)
                .frame(width: 72, height: 72)
                .overlay {
                    Image(systemName: "apple.logo")
                        .font(.system(size: 36))
                        .foregroundStyle(.white)
                }
                .offset(x: 66, y: -50)

            ZStack {
                Circle().fill(OBTheme.accent).frame(width: 26, height: 26)
                Circle().strokeBorder(NQTheme.inkDeep.opacity(0.22), lineWidth: 1.5).frame(width: 26, height: 26)
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(OBTheme.accent.readableTextColor())
            }
            .offset(x: 0, y: -8)

            labelPill("Walking").offset(x: -90, y: -80)
            labelPill("Running").offset(x: -104, y: -46)
            labelPill("Yoga").offset(x: 100, y: 16)
            labelPill("Sleep").offset(x: 84, y: 50)
        }
        .frame(height: 250)
        .accessibilityHidden(true)
    }

    /// Small white capsule label used around the illustration, styled like
    /// home's streak pill (white, ink stroke, sticker shadow).
    private func labelPill(_ text: String) -> some View {
        Text(text)
            .font(NQFont.body.font(13))
            .foregroundStyle(OBTheme.ink)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .nqPlate(Capsule(), elevation: .sticker, inkStroke: true, lineWidth: 1.5)
    }
}

// MARK: - Plan ready

/// Final step: celebration header and the daily recommendation card with
/// macro rings and health score.
struct OBPlanReadyStep: View {
    let plan: OBPlanTargets
    let onFinish: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 14) {
                    ZStack {
                        Circle().fill(OBTheme.accent).frame(width: 34, height: 34)
                        Circle().strokeBorder(NQTheme.inkDeep.opacity(0.22), lineWidth: 2).frame(width: 34, height: 34)
                        Image(systemName: "checkmark")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(OBTheme.accent.readableTextColor())
                    }
                    .padding(.top, 8)

                    Text("Congratulations\nyour custom plan is ready!")
                        .font(NQFont.display.font(24))
                        .foregroundStyle(OBTheme.ink)
                        .multilineTextAlignment(.center)

                    recommendationCard
                        .padding(.top, 10)
                }
                .padding(.bottom, 14)
            }
            OBPrimaryButton(title: "Let's get started!", action: onFinish)
        }
    }

    /// Daily recommendation card: 2x2 macro ring tiles plus health score.
    private var recommendationCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Daily recommendation")
                .font(NQFont.heading.font(17))
                .foregroundStyle(OBTheme.ink)
            Text("You can edit this anytime")
                .font(NQFont.body.font(13))
                .foregroundStyle(OBTheme.subtitle)

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible())], spacing: 12) {
                OBMacroTile(name: "Calories", systemIcon: "flame.fill", color: OBTheme.ink,
                            value: "\(plan.calories)", unit: "", progress: 0.72)
                OBMacroTile(name: "Carbs", systemIcon: "leaf.fill", color: Color(hex: 0xE8A05F),
                            value: "\(plan.carbsG)", unit: "g", progress: 0.6)
                OBMacroTile(name: "Protein", systemIcon: "fork.knife", color: Color(hex: 0xEE7C7C),
                            value: "\(plan.proteinG)", unit: "g", progress: 0.65)
                OBMacroTile(name: "Fats", systemIcon: "drop.fill", color: Color(hex: 0x7CA9EE),
                            value: "\(plan.fatsG)", unit: "g", progress: 0.5)
            }
            .padding(.top, 12)

            healthScoreRow
                .padding(.top, 4)
        }
        .padding(16)
        .nqPlate(RoundedRectangle(cornerRadius: NQTheme.radiusXL), elevation: .sticker, inkStroke: true)
    }

    /// "Health Score 7/10" row with a leaf-green progress bar, on the
    /// theme's surface tint like home's inner sections.
    private var healthScoreRow: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(NQTheme.accentSoft)
                    .frame(width: 42, height: 42)
                Image(systemName: "heart.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(OBTheme.accent)
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Health Score")
                        .font(NQFont.heading.font(15))
                        .foregroundStyle(OBTheme.ink)
                    Spacer()
                    Text("\(plan.healthScore)/10")
                        .font(NQFont.heading.font(15))
                        .foregroundStyle(OBTheme.ink)
                }
                ProgressView(value: Double(plan.healthScore) / 10)
                    .tint(NQTheme.leaf)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: NQTheme.radiusM).fill(NQTheme.surface))
        .overlay(
            RoundedRectangle(cornerRadius: NQTheme.radiusM)
                .strokeBorder(NQTheme.hairline, lineWidth: 1.5)
        )
    }
}

/// One macro tile in the daily recommendation grid: icon, name, and a
/// progress ring around the target value.
struct OBMacroTile: View {
    let name: String
    let systemIcon: String
    let color: Color
    let value: String
    let unit: String
    /// Ring sweep, 0...1 (decorative, mirrors the design).
    let progress: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ZStack {
                    Circle().fill(color.opacity(0.14)).frame(width: 26, height: 26)
                    Image(systemName: systemIcon)
                        .font(.system(size: 11))
                        .foregroundStyle(color)
                }
                Text(name)
                    .font(NQFont.heading.font(14))
                    .foregroundStyle(OBTheme.ink)
            }
            ZStack {
                Circle()
                    .stroke(NQTheme.hairline, lineWidth: 7)
                    .frame(width: 62, height: 62)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(color, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: 62, height: 62)
                (Text(value).font(NQFont.heading.font(15))
                    + Text(unit).font(NQFont.body.font(10)))
                    .foregroundColor(OBTheme.ink)
            }
            .frame(maxWidth: .infinity)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: NQTheme.radiusM).fill(NQTheme.surface))
        .overlay(
            RoundedRectangle(cornerRadius: NQTheme.radiusM)
                .strokeBorder(NQTheme.hairline, lineWidth: 1.5)
        )
        .overlay(alignment: .bottomTrailing) {
            Image(systemName: "pencil")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(OBTheme.accent.readableTextColor())
                .frame(width: 22, height: 22)
                .background(Circle().fill(OBTheme.accent))
                .padding(8)
        }
    }
}
