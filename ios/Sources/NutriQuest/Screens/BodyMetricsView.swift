import SwiftUI
import NutriQuestUI

/// Profile > Body & goals — edit the measurements onboarding collected and
/// watch the plan recalculate before saving.
///
/// Everything on screen is derived from the draft, so the targets card is a
/// live preview: change a number and the calories, macros and deficit update
/// in place. Saving hands the draft to `GameState.applyBodyMetrics`, which
/// re-derives the home gauge, the health dashboard and the daily multiplier.
struct BodyMetricsView: View {
    @ObservedObject var gameState: GameState

    @Environment(\.dismiss) private var dismiss
    @Environment(\.nqAccent) private var accent

    @State private var draft: BodyMetrics

    /// Seeds the editable copy from the player's saved metrics.
    init(gameState: GameState, metrics: BodyMetrics) {
        self.gameState = gameState
        _draft = State(initialValue: metrics)
    }

    /// Save is only offered when something actually moved.
    private var hasChanges: Bool { draft.normalized() != gameState.bodyMetrics }

    var body: some View {
        ScrollView {
            VStack(spacing: NQTheme.spaceL) {
                targetsCard
                measurementsCard
                sexCard
                activityCard
                goalCard
                saveButton
            }
            .padding(NQTheme.spaceL)
        }
        .nqPageBackground()
        .navigationTitle("Body & goals")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Live targets preview

    private var targetsCard: some View {
        let plan = draft.targets
        let saved = gameState.dailyPlan
        let difference = plan.calories - saved.calories

        return VStack(spacing: NQTheme.spaceM) {
            VStack(spacing: 2) {
                Text("DAILY TARGET")
                    .font(NQText.microS.font)
                    .tracking(0.6)
                    .foregroundStyle(NQTheme.inkMuted)
                Text("\(plan.calories)")
                    .font(NQText.displayL.font)
                    .foregroundStyle(NQTheme.ink)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text("kcal a day")
                    .font(NQText.caption.font)
                    .foregroundStyle(NQTheme.inkMuted)
                if difference != 0 {
                    Text("\(difference > 0 ? "+" : "")\(difference) kcal vs your current plan")
                        .font(NQText.captionS.font.weight(.bold))
                        .foregroundStyle(accent.accentDark)
                        .padding(.top, 2)
                }
            }

            Divider().foregroundStyle(NQTheme.hairline)

            HStack(spacing: NQTheme.spaceM) {
                figure("Burn", "\(Int(draft.maintenanceCalories.rounded()))", "kcal maintenance")
                figure(
                    draft.goal == .lose ? "Deficit" : (draft.goal == .gain ? "Surplus" : "Adjust"),
                    draft.goal == .maintain ? "0" : "\(Int(abs(draft.calorieDelta).rounded()))",
                    draft.goal == .maintain ? "holding steady" : "kcal a day"
                )
                figure("BMI", String(format: "%.1f", draft.bmi), "kg/m\u{00B2}")
            }

            Divider().foregroundStyle(NQTheme.hairline)

            HStack(spacing: NQTheme.spaceS) {
                macroPill("Protein", plan.proteinG, NQTheme.protein)
                macroPill("Carbs", plan.carbsG, NQTheme.carbs)
                macroPill("Fat", plan.fatsG, NQTheme.fat)
                macroPill("Fibre", Int(draft.fiberTargetG.rounded()), NQTheme.fibre)
            }
        }
        .nqPadding(.card)
        .frame(maxWidth: .infinity)
        .nqPlate(RoundedRectangle(cornerRadius: NQTheme.radiusXL), elevation: .raised)
        .animation(NQMotion.fill, value: plan)
    }

    /// One labelled number in the summary strip.
    private func figure(_ label: String, _ value: String, _ caption: String) -> some View {
        VStack(spacing: 1) {
            Text(label)
                .font(NQText.microS.font)
                .foregroundStyle(NQTheme.inkFaint)
            Text(value)
                .font(NQText.heading.font.weight(.heavy))
                .foregroundStyle(NQTheme.ink)
                .monospacedDigit()
            Text(caption)
                .font(NQText.microXS.font)
                .foregroundStyle(NQTheme.inkMuted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label), \(value) \(caption)")
    }

    /// One macro target chip.
    private func macroPill(_ label: String, _ grams: Int, _ color: Color) -> some View {
        VStack(spacing: 1) {
            Text("\(grams)g")
                .font(NQText.caption.font.weight(.heavy))
                .foregroundStyle(NQTheme.ink)
                .monospacedDigit()
            Text(label)
                .font(NQText.microXS.font)
                .foregroundStyle(NQTheme.inkMuted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, NQTheme.spaceS)
        .background(color.opacity(0.16))
        .clipShape(RoundedRectangle(cornerRadius: NQTheme.radiusS))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label) \(grams) grams")
    }

    // MARK: - Measurements

    private var measurementsCard: some View {
        card(title: "Measurements") {
            unitToggle
            Divider().foregroundStyle(NQTheme.hairline)
            stepperRow(
                label: "Height",
                value: heightText,
                binding: heightBinding,
                range: heightRange,
                step: 1
            )
            Divider().foregroundStyle(NQTheme.hairline)
            stepperRow(
                label: "Weight",
                value: weightText,
                binding: weightBinding,
                range: weightRange,
                step: draft.usesMetric ? 0.5 : 1
            )
            Divider().foregroundStyle(NQTheme.hairline)
            birthdateRow
        }
    }

    /// Imperial/metric switch. Only changes how the numbers are shown — the
    /// stored values stay metric. Persists on tap: a display preference
    /// shouldn't wait on the Save button at the bottom of the form.
    private var unitToggle: some View {
        HStack(spacing: NQTheme.spaceM) {
            Text("Units")
                .font(NQText.bodyL.font)
                .foregroundStyle(NQTheme.ink)
            Spacer()
            Picker("Units", selection: $draft.usesMetric) {
                Text("Imperial").tag(false)
                Text("Metric").tag(true)
            }
            .pickerStyle(.segmented)
            .frame(width: 190)
            // Persisting inside the Picker's set made the segmented control
            // snap back mid-gesture; onChange lands after it settles.
            .onChange(of: draft.usesMetric) { gameState.setUnitsPreference($0) }
        }
        .padding(.vertical, NQTheme.spaceS)
    }

    /// A measurement row: name, formatted value, and a native stepper so the
    /// plus/minus keys auto-repeat on a long press.
    private func stepperRow(
        label: String,
        value: String,
        binding: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double
    ) -> some View {
        HStack(spacing: NQTheme.spaceM) {
            Text(label)
                .font(NQText.bodyL.font)
                .foregroundStyle(NQTheme.ink)
            Spacer()
            Text(value)
                .font(NQText.heading.font.weight(.heavy))
                .foregroundStyle(NQTheme.ink)
                .monospacedDigit()
            Stepper(label, value: binding, in: range, step: step)
                .labelsHidden()
        }
        .padding(.vertical, NQTheme.spaceS)
        .accessibilityElement(children: .contain)
    }

    private var birthdateRow: some View {
        HStack(spacing: NQTheme.spaceM) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Date of birth")
                    .font(NQText.bodyL.font)
                    .foregroundStyle(NQTheme.ink)
                Text("\(draft.ageYears) years old")
                    .font(NQText.captionS.font)
                    .foregroundStyle(NQTheme.inkMuted)
            }
            Spacer()
            DatePicker(
                "Date of birth",
                selection: $draft.birthdate,
                in: ...Date(),
                displayedComponents: .date
            )
            .labelsHidden()
        }
        .padding(.vertical, NQTheme.spaceS)
    }

    // MARK: - Sex, activity, goal

    private var sexCard: some View {
        card(title: "Sex", footnote: "The Mifflin-St Jeor equation uses a different constant for each; Other takes the midpoint.") {
            HStack(spacing: NQTheme.spaceS) {
                ForEach(BodySex.allCases) { option in
                    chip(option.title, selected: draft.sex == option) { draft.sex = option }
                }
            }
        }
    }

    private var activityCard: some View {
        card(title: "Activity", footnote: "Scales your resting burn into the calories you actually spend in a day.") {
            VStack(spacing: NQTheme.spaceS) {
                ForEach(ActivityLevel.allCases) { option in
                    optionRow(
                        title: option.title,
                        detail: option.detail,
                        trailing: String(format: "\u{00D7}%g", option.factor),
                        selected: draft.activity == option
                    ) { draft.activity = option }
                }
            }
        }
    }

    private var goalCard: some View {
        card(title: "Goal") {
            HStack(spacing: NQTheme.spaceS) {
                ForEach(WeightGoal.allCases) { option in
                    chip(option.title, selected: draft.goal == option) {
                        draft.goal = option
                        if option == .maintain {
                            draft.paceKgPerWeek = 0
                        } else if draft.paceKgPerWeek <= 0 {
                            draft.paceKgPerWeek = 0.5
                        }
                    }
                }
            }
            if draft.goal != .maintain {
                VStack(spacing: NQTheme.spaceXS) {
                    HStack {
                        Text(draft.goal == .gain ? "Gain per week" : "Lose per week")
                            .font(NQText.caption.font)
                            .foregroundStyle(NQTheme.inkMuted)
                        Spacer()
                        Text(paceText)
                            .font(NQText.caption.font.weight(.heavy))
                            .foregroundStyle(NQTheme.ink)
                            .monospacedDigit()
                    }
                    Slider(
                        value: $draft.paceKgPerWeek,
                        in: BodyMetrics.paceRangeKgPerWeek,
                        step: 0.1
                    )
                    .tint(accent.accent)
                    .accessibilityLabel("Weekly pace")
                    .accessibilityValue(paceText)
                }
                .padding(.top, NQTheme.spaceS)
            }
        }
    }

    private var saveButton: some View {
        VStack(spacing: NQTheme.spaceS) {
            NQButton("Save changes") {
                gameState.applyBodyMetrics(draft)
                dismiss()
            }
            .disabled(!hasChanges)
            Text("Saving recalculates your daily calories, macros and squad boost targets.")
                .font(NQText.microS.font)
                .foregroundStyle(NQTheme.inkMuted)
                .multilineTextAlignment(.center)
        }
    }

    // MARK: - Building blocks

    /// Section shell: small caps heading, white card, optional footnote.
    private func card<Content: View>(
        title: String,
        footnote: String? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: NQTheme.spaceS) {
            Text(title.uppercased())
                .font(NQText.microXS.font)
                .tracking(0.4)
                .foregroundStyle(NQTheme.inkMuted)
                .padding(.leading, 4)
            VStack(alignment: .leading, spacing: 0) {
                content()
            }
            .nqPadding(.card)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(NQTheme.background)
            .clipShape(RoundedRectangle(cornerRadius: NQTheme.radiusL))
            .nqElevation(.soft)
            if let footnote {
                Text(footnote)
                    .font(NQText.microS.font)
                    .foregroundStyle(NQTheme.inkMuted)
                    .padding(.horizontal, 4)
            }
        }
    }

    /// Compact single-select chip.
    private func chip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(NQText.caption.font.weight(.bold))
                .foregroundStyle(selected ? accent.accent.readableTextColor() : NQTheme.ink)
                .frame(maxWidth: .infinity)
                .padding(.vertical, NQTheme.spaceM - 2)
                .background(selected ? accent.accent : NQTheme.surface)
                .clipShape(RoundedRectangle(cornerRadius: NQTheme.radiusS))
                .overlay {
                    RoundedRectangle(cornerRadius: NQTheme.radiusS)
                        .strokeBorder(NQTheme.inkDeep.opacity(selected ? 0.22 : 0.08), lineWidth: 1.5)
                }
        }
        .buttonStyle(.nqPressable(scale: 0.97, haptic: false))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// Single-select row with an explanation, used for activity levels.
    private func optionRow(
        title: String,
        detail: String,
        trailing: String,
        selected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: NQTheme.spaceM) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: NQText.headingL.size, weight: .semibold))
                    .foregroundStyle(selected ? accent.accent : NQTheme.inkFaint)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(NQText.body.font.weight(.bold))
                        .foregroundStyle(NQTheme.ink)
                    Text(detail)
                        .font(NQText.captionS.font)
                        .foregroundStyle(NQTheme.inkMuted)
                }
                Spacer()
                Text(trailing)
                    .font(NQText.captionS.font.weight(.bold))
                    .foregroundStyle(NQTheme.inkFaint)
                    .monospacedDigit()
            }
            .padding(.vertical, NQTheme.spaceXS + 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.nqPressable(scale: 0.99, haptic: false))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // MARK: - Unit-aware bindings and formatting

    /// Height in display units: centimetres when metric, whole inches when not.
    private var heightBinding: Binding<Double> {
        Binding(
            get: { draft.usesMetric ? draft.heightCm : (draft.heightCm / BodyUnits.cmPerInch).rounded() },
            set: { draft.heightCm = draft.usesMetric ? $0 : $0 * BodyUnits.cmPerInch }
        )
    }

    private var heightRange: ClosedRange<Double> {
        let range = BodyMetrics.heightRangeCm
        guard !draft.usesMetric else { return range }
        return (range.lowerBound / BodyUnits.cmPerInch).rounded()...(range.upperBound / BodyUnits.cmPerInch).rounded()
    }

    private var heightText: String {
        if draft.usesMetric { return "\(Int(draft.heightCm.rounded())) cm" }
        let imperial = BodyUnits.feetInches(fromCm: draft.heightCm)
        return "\(imperial.feet)' \(imperial.inches)\""
    }

    /// Weight in display units: kilograms when metric, pounds when not.
    private var weightBinding: Binding<Double> {
        Binding(
            get: { draft.usesMetric ? draft.weightKg : (draft.weightKg * BodyUnits.poundsPerKg).rounded() },
            set: { draft.weightKg = draft.usesMetric ? $0 : BodyUnits.kg(fromPounds: Int($0.rounded())) }
        )
    }

    private var weightRange: ClosedRange<Double> {
        let range = BodyMetrics.weightRangeKg
        guard !draft.usesMetric else { return range }
        return (range.lowerBound * BodyUnits.poundsPerKg).rounded()...(range.upperBound * BodyUnits.poundsPerKg).rounded()
    }

    private var weightText: String {
        draft.usesMetric
            ? String(format: "%.1f kg", draft.weightKg)
            : "\(BodyUnits.pounds(fromKg: draft.weightKg)) lb"
    }

    private var paceText: String {
        draft.usesMetric
            ? String(format: "%.1f kg", draft.paceKgPerWeek)
            : String(format: "%.1f lb", draft.paceKgPerWeek * BodyUnits.poundsPerKg)
    }
}
