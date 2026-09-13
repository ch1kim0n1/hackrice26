import Foundation

// MARK: - Player profile -> personal targets

public struct PlayerProfile: Sendable, Equatable {
    public enum Sex: String, Sendable { case male, female }
    public enum Activity: Double, CaseIterable, Sendable {
        case sedentary = 1.2
        case light = 1.375
        case moderate = 1.55
        case active = 1.725
    }
    public enum Goal: String, Sendable {
        case cut, maintain, bulk

        var calorieAdjustment: Double {
            switch self {
            case .cut: return -0.15
            case .maintain: return 0
            case .bulk: return 0.10
            }
        }

        var proteinPerKg: Double {
            switch self {
            case .maintain: return 1.2
            case .cut, .bulk: return 1.8
            }
        }
    }

    public let age: Int
    public let sex: Sex
    public let heightCm: Double
    public let weightKg: Double
    public let activity: Activity
    public let goal: Goal

    public init(age: Int, sex: Sex, heightCm: Double, weightKg: Double, activity: Activity, goal: Goal) {
        self.age = age
        self.sex = sex
        self.heightCm = heightCm
        self.weightKg = weightKg
        self.activity = activity
        self.goal = goal
    }

    /// Mifflin-St Jeor BMR.
    public var bmr: Double {
        let base = 10 * weightKg + 6.25 * heightCm - 5 * Double(age)
        return sex == .male ? base + 5 : base - 161
    }

    /// Daily calorie target: TDEE adjusted by goal.
    public var calorieTarget: Double {
        bmr * activity.rawValue * (1 + goal.calorieAdjustment)
    }

    /// Daily protein target in grams.
    public var proteinTarget: Double {
        weightKg * goal.proteinPerKg
    }

    /// Daily fiber target (25 g per 2000 kcal).
    public var fiberTarget: Double {
        25 * (calorieTarget / 2000)
    }
}

// MARK: - Day log

/// One scanned food's contribution to the daily log.
public struct DayLogEntry: Sendable, Equatable, Identifiable {
    public var id: String { barcode }
    public let barcode: String
    public let name: String
    public let calories: Double
    public let protein: Double
    /// Carbohydrates in grams. Defaults to 0 for callers that predate
    /// macro tracking on the home screen.
    public let carbs: Double
    /// Fat in grams. Defaults to 0 for callers that predate macro tracking.
    public let fat: Double
    public let fiber: Double
    public let sugar: Double
    public let microScore: Double        // 0...1
    public let foodGroup: FoodGroup
    public let loggedAt: Date

    public init(
        barcode: String,
        name: String = "",
        calories: Double,
        protein: Double,
        carbs: Double = 0,
        fat: Double = 0,
        fiber: Double,
        sugar: Double,
        microScore: Double,
        foodGroup: FoodGroup,
        loggedAt: Date = Date()
    ) {
        self.barcode = barcode
        self.name = name
        self.calories = calories
        self.protein = protein
        self.carbs = carbs
        self.fat = fat
        self.fiber = fiber
        self.sugar = sugar
        self.microScore = microScore
        self.foodGroup = foodGroup
        self.loggedAt = loggedAt
    }
}

public enum FoodGroup: String, CaseIterable, Sendable {
    case produce, grain, dairy, protein, other
}

// MARK: - Multiplier breakdown

/// Field-by-field result, rendered as the "Daily Expedition" UI card.
public struct DailyMultiplierBreakdown: Sendable, Equatable {
    public let protein: Double
    public let fiber: Double
    public let micronutrients: Double
    public let diversity: Double
    public let calorie: Double
    public let sugarPenalty: Double
    public let total: Double

    public init(protein: Double, fiber: Double, micronutrients: Double, diversity: Double, calorie: Double, sugarPenalty: Double, total: Double) {
        self.protein = protein
        self.fiber = fiber
        self.micronutrients = micronutrients
        self.diversity = diversity
        self.calorie = calorie
        self.sugarPenalty = sugarPenalty
        self.total = total
    }

    public static let neutral = DailyMultiplierBreakdown(
        protein: 0, fiber: 0, micronutrients: 0, diversity: 0, calorie: 0, sugarPenalty: 0, total: 1.0
    )
}

// MARK: - Calculator

/// Computes the Daily Party Multiplier (clamp 0.80...1.50) from the day's
/// scanned foods and the player's personal targets. See docs/BATTLE-SYSTEM.md §3-4.
public actor DailyMultiplierCalculator {

    public init() {}

    public func calculate(entries: [DayLogEntry], profile: PlayerProfile) -> DailyMultiplierBreakdown {
        // Anti-gaming: one barcode per day, max 3 items per hour.
        var seen = Set<String>()
        var filtered: [DayLogEntry] = []
        var hourWindow: [Date] = []

        for entry in entries.sorted(by: { $0.loggedAt < $1.loggedAt }) {
            // A barcode counts at most once per day, period — even if it was
            // dropped by the hourly cap.
            guard !seen.contains(entry.barcode) else { continue }
            seen.insert(entry.barcode)
            hourWindow = hourWindow.filter { entry.loggedAt.timeIntervalSince($0) < 3600 }
            if hourWindow.count >= 3 { continue }
            hourWindow.append(entry.loggedAt)
            filtered.append(entry)
        }

        guard !filtered.isEmpty else { return .neutral }

        let calories = filtered.reduce(0.0) { $0 + $1.calories }
        let protein = filtered.reduce(0.0) { $0 + $1.protein }
        let fiber = filtered.reduce(0.0) { $0 + $1.fiber }
        let sugar = filtered.reduce(0.0) { $0 + $1.sugar }
        let microAvg = filtered.map(\.microScore).reduce(0, +) / Double(filtered.count)
        let groups = Set(filtered.map(\.foodGroup))

        // Protein: scaled 0.8x -> 1.3x target window.
        let pRatio = protein / max(profile.proteinTarget, 1)
        let proteinBonus = pRatio >= 0.8
            ? min((pRatio - 0.8) / 0.5, 1) * 0.12
            : 0

        // Fiber: 0 -> target.
        let fiberBonus = min(fiber / max(profile.fiberTarget, 1), 1) * 0.12

        // Diversity: distinct food groups, cap 3.
        let diversityBonus = Double(min(groups.count, 3)) * 0.04

        // Micronutrients: day average microScore.
        let microBonus = min(microAvg / 0.5, 1) * 0.12

        // Calories: ±10% full bonus, ±20% half — but scaled by food quality.
        // Empty calories (microScore ~0) earn almost nothing from the window.
        let calDelta = abs(calories - profile.calorieTarget) / max(profile.calorieTarget, 1)
        let calorieBase: Double = calDelta <= 0.10 ? 0.20 : (calDelta <= 0.20 ? 0.10 : 0)
        let calorieBonus = calorieBase * min(microAvg / 0.4, 1)

        // Sugar penalty.
        let sugarPenalty: Double = sugar > 75 ? -0.15 : (sugar > 50 ? -0.08 : 0)

        // Nutrient-poor day penalty: micronutrient average below 0.2.
        let poorNutritionPenalty: Double = microAvg < 0.2 ? -0.10 : 0

        let total = min(1.5, max(0.8, 1.0 + proteinBonus + fiberBonus + diversityBonus + microBonus + calorieBonus + sugarPenalty + poorNutritionPenalty))

        return DailyMultiplierBreakdown(
            protein: proteinBonus,
            fiber: fiberBonus,
            micronutrients: microBonus,
            diversity: diversityBonus,
            calorie: calorieBonus,
            sugarPenalty: sugarPenalty + poorNutritionPenalty,
            total: total
        )
    }
}
