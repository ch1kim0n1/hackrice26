import Foundation
import BattleKit

/// Biological sex, as the Mifflin-St Jeor equation uses it.
///
/// The equation only defines a male and a female constant; `other` takes the
/// midpoint so the plan stays usable without forcing a choice.
enum BodySex: String, Codable, CaseIterable, Identifiable {
    case male, female, other

    var id: String { rawValue }

    /// Display title for option cards and chips.
    var title: String {
        switch self {
        case .male: return "Male"
        case .female: return "Female"
        case .other: return "Other"
        }
    }

    /// Constant term added to the Mifflin-St Jeor BMR.
    var bmrOffset: Double {
        switch self {
        case .male: return 5
        case .female: return -161
        case .other: return -78
        }
    }

    /// BattleKit's `PlayerProfile` only models male/female, so `other` folds
    /// into the lower constant rather than inventing a third case there.
    var battleKitSex: PlayerProfile.Sex {
        self == .male ? .male : .female
    }
}

/// How much the player moves on a normal day — the TDEE multiplier.
enum ActivityLevel: String, Codable, CaseIterable, Identifiable {
    case sedentary, light, moderate, active

    var id: String { rawValue }

    /// Display title for option cards and chips.
    var title: String {
        switch self {
        case .sedentary: return "Sedentary"
        case .light: return "Light"
        case .moderate: return "Moderate"
        case .active: return "Active"
        }
    }

    /// One-line explanation of what the level means in practice.
    var detail: String {
        switch self {
        case .sedentary: return "Desk job, little exercise"
        case .light: return "Exercise 1-3 days a week"
        case .moderate: return "Exercise 3-5 days a week"
        case .active: return "Exercise 6-7 days a week"
        }
    }

    /// Multiplier applied to BMR to get maintenance calories.
    var factor: Double {
        switch self {
        case .sedentary: return 1.2
        case .light: return 1.375
        case .moderate: return 1.55
        case .active: return 1.725
        }
    }

    /// The matching BattleKit activity case (same factors).
    var battleKitActivity: PlayerProfile.Activity {
        switch self {
        case .sedentary: return .sedentary
        case .light: return .light
        case .moderate: return .moderate
        case .active: return .active
        }
    }
}

/// Weight goal driving the calorie deficit or surplus.
enum WeightGoal: String, Codable, CaseIterable, Identifiable {
    case lose, maintain, gain

    var id: String { rawValue }

    /// Display title for the option card.
    var title: String {
        switch self {
        case .lose: return "Lose weight"
        case .maintain: return "Maintain"
        case .gain: return "Gain weight"
        }
    }

    /// Sign applied to the pace-derived calorie adjustment.
    var calorieDirection: Double {
        switch self {
        case .lose: return -1
        case .maintain: return 0
        case .gain: return 1
        }
    }

    /// The matching BattleKit goal, which drives its protein-per-kg figure.
    var battleKitGoal: PlayerProfile.Goal {
        switch self {
        case .lose: return .cut
        case .maintain: return .maintain
        case .gain: return .bulk
        }
    }
}

/// The player's body and goal inputs — the single source of truth for every
/// derived nutrition number in the app.
///
/// Onboarding writes this once; the Profile > Body & goals screen edits it
/// afterwards. Both paths go through `GameState.applyBodyMetrics`, which
/// re-derives the daily plan so the home gauge, the health dashboard and the
/// daily multiplier all move together.
struct BodyMetrics: Codable, Equatable {
    var sex: BodySex
    var heightCm: Double
    var weightKg: Double
    var birthdate: Date
    var activity: ActivityLevel
    var goal: WeightGoal
    /// Intended rate of change in kg per week. Ignored when maintaining.
    var paceKgPerWeek: Double
    /// Whether the player entered metric units, so the editor reopens in the
    /// units they last used.
    var usesMetric: Bool

    /// UserDefaults key the encoded metrics are stored under.
    static let storageKey = "profile.bodyMetrics"

    /// Accepted input ranges, shared by the onboarding pickers and the editor.
    static let heightRangeCm: ClosedRange<Double> = 120...220
    static let weightRangeKg: ClosedRange<Double> = 35...200
    static let paceRangeKgPerWeek: ClosedRange<Double> = 0.1...1.5

    /// Calories stored in a kilogram of body mass, spread over a week.
    private static let kcalPerKg: Double = 7700

    /// Floor on a cutting target, so an aggressive pace can't prescribe a
    /// dangerous intake.
    private static let minimumCutCalories: Double = 1200

    /// Placeholder used before onboarding (or the editor) has supplied real
    /// values — an average adult rather than a personalised plan.
    static let `default` = BodyMetrics(
        sex: .male,
        heightCm: 178,
        weightKg: 72,
        birthdate: Calendar.current.date(byAdding: .year, value: -22, to: Date()) ?? Date(),
        activity: .moderate,
        goal: .maintain,
        paceKgPerWeek: 0,
        usesMetric: false
    )

    /// Loads the saved metrics, or nil when the player has never set them.
    static func load() -> BodyMetrics? {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else { return nil }
        return try? JSONDecoder().decode(BodyMetrics.self, from: data)
    }

    /// Persists these metrics to UserDefaults.
    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }

    // MARK: - Derived figures

    /// Age in whole years on today's date.
    var ageYears: Int {
        Calendar.current.dateComponents([.year], from: birthdate, to: Date()).year ?? 22
    }

    /// Body mass index in kg/m².
    var bmi: Double {
        let metres = heightCm / 100
        guard metres > 0 else { return 0 }
        return weightKg / (metres * metres)
    }

    /// Resting burn: Mifflin-St Jeor basal metabolic rate.
    var bmr: Double {
        10 * weightKg + 6.25 * heightCm - 5 * Double(ageYears) + sex.bmrOffset
    }

    /// Maintenance calories — what the player burns on an average day, BMR
    /// scaled by their activity level. Eating this holds weight steady.
    var maintenanceCalories: Double {
        bmr * activity.factor
    }

    /// Signed daily deficit (negative) or surplus (positive) implied by the
    /// goal and pace. Zero when maintaining.
    var calorieDelta: Double {
        goal.calorieDirection * paceKgPerWeek * Self.kcalPerKg / 7
    }

    /// Daily calorie target: maintenance plus the goal adjustment, floored so
    /// a cut never drops below a safe intake.
    var calorieTarget: Double {
        max(goal == .lose ? Self.minimumCutCalories : 0, maintenanceCalories + calorieDelta)
    }

    /// Daily fibre target, 25 g per 2000 kcal — the same scaling BattleKit uses.
    var fiberTargetG: Double {
        25 * (calorieTarget / 2000)
    }

    /// The calorie and macro targets the home screen and dashboard show, split
    /// 30% protein / 40% carbs / 30% fat.
    var targets: DailyPlan {
        let calories = calorieTarget
        return DailyPlan(
            calories: Int(calories.rounded()),
            proteinG: Int((calories * 0.30 / 4).rounded()),
            carbsG: Int((calories * 0.40 / 4).rounded()),
            fatsG: Int((calories * 0.30 / 9).rounded())
        )
    }

    /// BattleKit's view of the same player, used to score the daily party
    /// multiplier against personal targets.
    var playerProfile: PlayerProfile {
        PlayerProfile(
            age: ageYears,
            sex: sex.battleKitSex,
            heightCm: heightCm,
            weightKg: weightKg,
            activity: activity.battleKitActivity,
            goal: goal.battleKitGoal
        )
    }

    /// Clamps every field into its accepted range, so a bad decode or a stale
    /// saved value can't feed nonsense into the equation.
    func normalized() -> BodyMetrics {
        var copy = self
        copy.heightCm = min(max(heightCm, Self.heightRangeCm.lowerBound), Self.heightRangeCm.upperBound)
        copy.weightKg = min(max(weightKg, Self.weightRangeKg.lowerBound), Self.weightRangeKg.upperBound)
        copy.birthdate = min(birthdate, Date())
        copy.paceKgPerWeek = goal == .maintain
            ? 0
            : min(max(paceKgPerWeek, Self.paceRangeKgPerWeek.lowerBound), Self.paceRangeKgPerWeek.upperBound)
        return copy
    }
}

// MARK: - Unit conversion

/// Imperial/metric conversions shared by onboarding and the metrics editor.
enum BodyUnits {
    static let poundsPerKg = 2.20462
    static let cmPerInch = 2.54

    /// Kilograms rendered as whole pounds.
    static func pounds(fromKg kg: Double) -> Int {
        Int((kg * poundsPerKg).rounded())
    }

    /// Whole pounds back to kilograms.
    static func kg(fromPounds pounds: Int) -> Double {
        Double(pounds) / poundsPerKg
    }

    /// Centimetres rendered as feet and whole inches.
    static func feetInches(fromCm cm: Double) -> (feet: Int, inches: Int) {
        let totalInches = Int((cm / cmPerInch).rounded())
        return (totalInches / 12, totalInches % 12)
    }

    /// Feet and inches back to centimetres.
    static func cm(fromFeet feet: Int, inches: Int) -> Double {
        Double(feet * 12 + inches) * cmPerInch
    }
}
