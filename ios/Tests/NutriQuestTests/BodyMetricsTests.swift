import XCTest
@testable import NutriQuest

// ============================================================================
// Body metrics -> daily targets.
//
// BodyMetrics is the single input to every nutrition number the app shows:
// the home calorie gauge, the health dashboard rings and the BattleKit profile
// behind the daily multiplier. These tests pin the Mifflin-St Jeor chain
// (BMR -> maintenance -> goal-adjusted target -> macros) so an edit to the
// settings screen can't quietly move the maths.
// ============================================================================

final class BodyMetricsTests: XCTestCase {

    /// Metrics for a player of a known age, built from a birthdate so the
    /// age-in-years derivation is exercised too.
    private func metrics(
        sex: BodySex = .male,
        heightCm: Double = 180,
        weightKg: Double = 80,
        age: Int = 34,
        activity: ActivityLevel = .light,
        goal: WeightGoal = .maintain,
        pace: Double = 0
    ) -> BodyMetrics {
        let birthdate = Calendar.current.date(byAdding: .day, value: -1, to:
            Calendar.current.date(byAdding: .year, value: -age, to: Date()) ?? Date()) ?? Date()
        return BodyMetrics(
            sex: sex,
            heightCm: heightCm,
            weightKg: weightKg,
            birthdate: birthdate,
            activity: activity,
            goal: goal,
            paceKgPerWeek: pace,
            usesMetric: true
        )
    }

    func testBMRMatchesMifflinStJeor() {
        // 10*80 + 6.25*180 - 5*34 + 5 = 1760
        XCTAssertEqual(metrics().bmr, 1760, accuracy: 0.001)
        // 10*62 + 6.25*168 - 5*28 - 161 = 1369
        let female = metrics(sex: .female, heightCm: 168, weightKg: 62, age: 28)
        XCTAssertEqual(female.bmr, 1369, accuracy: 0.001)
    }

    func testOtherSexTakesTheMidpointConstant() {
        let other = metrics(sex: .other)
        XCTAssertEqual(other.bmr, metrics(sex: .male).bmr - 83, accuracy: 0.001)
        XCTAssertEqual(other.bmr, metrics(sex: .female).bmr + 83, accuracy: 0.001)
    }

    func testMaintenanceScalesBMRByActivity() {
        XCTAssertEqual(metrics(activity: .sedentary).maintenanceCalories, 1760 * 1.2, accuracy: 0.001)
        XCTAssertEqual(metrics(activity: .active).maintenanceCalories, 1760 * 1.725, accuracy: 0.001)
    }

    func testMaintainGoalTargetsMaintenanceCalories() {
        let m = metrics(goal: .maintain, pace: 0)
        XCTAssertEqual(m.calorieDelta, 0)
        XCTAssertEqual(m.calorieTarget, m.maintenanceCalories, accuracy: 0.001)
    }

    func testLosingSubtractsThePaceDeficit() {
        let m = metrics(goal: .lose, pace: 0.5)
        // 0.5 kg/week * 7700 kcal/kg / 7 days = 550 kcal/day
        XCTAssertEqual(m.calorieDelta, -550, accuracy: 0.001)
        XCTAssertEqual(m.calorieTarget, m.maintenanceCalories - 550, accuracy: 0.001)
    }

    func testGainingAddsThePaceSurplus() {
        let m = metrics(goal: .gain, pace: 0.5)
        XCTAssertEqual(m.calorieTarget, m.maintenanceCalories + 550, accuracy: 0.001)
    }

    func testAggressiveCutIsFlooredAtASafeIntake() {
        let m = metrics(heightCm: 150, weightKg: 45, age: 60, activity: .sedentary, goal: .lose, pace: 1.5)
        XCTAssertLessThan(m.maintenanceCalories + m.calorieDelta, 1200)
        XCTAssertEqual(m.calorieTarget, 1200, accuracy: 0.001)
    }

    func testMacrosSplitThirtyFortyThirty() {
        let m = metrics()
        let plan = m.targets
        let calories = m.calorieTarget
        XCTAssertEqual(plan.calories, Int(calories.rounded()))
        XCTAssertEqual(plan.proteinG, Int((calories * 0.30 / 4).rounded()))
        XCTAssertEqual(plan.carbsG, Int((calories * 0.40 / 4).rounded()))
        XCTAssertEqual(plan.fatsG, Int((calories * 0.30 / 9).rounded()))
    }

    func testCutSplitsThirtyFiveThirtyFiveThirty() {
        let m = metrics(goal: .lose, pace: 0.5)
        let plan = m.targets
        let calories = m.calorieTarget
        XCTAssertEqual(plan.proteinG, Int((calories * 0.35 / 4).rounded()))
        XCTAssertEqual(plan.carbsG, Int((calories * 0.35 / 4).rounded()))
        XCTAssertEqual(plan.fatsG, Int((calories * 0.30 / 9).rounded()))
    }

    func testFibreScalesWithCalories() {
        let m = metrics()
        XCTAssertEqual(m.fiberTargetG, 25 * (m.calorieTarget / 2000), accuracy: 0.001)
    }

    func testEditingAMetricMovesTheTarget() {
        var m = metrics(goal: .maintain)
        let before = m.targets.calories
        m.weightKg += 10
        XCTAssertEqual(m.targets.calories - before, Int((100 * m.activity.factor).rounded()))
    }

    func testPlayerProfileMirrorsTheMetrics() {
        let m = metrics(sex: .female, goal: .lose, pace: 0.5)
        let profile = m.playerProfile
        XCTAssertEqual(profile.age, m.ageYears)
        XCTAssertEqual(profile.sex, .female)
        XCTAssertEqual(profile.heightCm, m.heightCm)
        XCTAssertEqual(profile.weightKg, m.weightKg)
        XCTAssertEqual(profile.activity, m.activity.battleKitActivity)
        XCTAssertEqual(profile.goal, .cut)
    }

    func testNormalizeClampsOutOfRangeValuesAndClearsPaceWhenMaintaining() {
        var m = metrics(heightCm: 400, weightKg: 900, goal: .maintain, pace: 1.2)
        m.birthdate = Date().addingTimeInterval(60 * 60 * 24 * 365)
        let clean = m.normalized()
        XCTAssertEqual(clean.heightCm, BodyMetrics.heightRangeCm.upperBound)
        XCTAssertEqual(clean.weightKg, BodyMetrics.weightRangeKg.upperBound)
        XCTAssertEqual(clean.paceKgPerWeek, 0)
        XCTAssertLessThanOrEqual(clean.birthdate, Date())
    }

    func testUnitConversionsRoundTrip() {
        let imperial = BodyUnits.feetInches(fromCm: 180)
        XCTAssertEqual(imperial.feet, 5)
        XCTAssertEqual(imperial.inches, 11)
        XCTAssertEqual(BodyUnits.cm(fromFeet: 5, inches: 11), 180.34, accuracy: 0.001)
        XCTAssertEqual(BodyUnits.pounds(fromKg: 80), 176)
        XCTAssertEqual(BodyUnits.kg(fromPounds: 176), 79.83, accuracy: 0.01)
    }
}
