import SwiftUI
import BattleKit
import NutriQuestUI

/// The daily nutrition targets derived from the onboarding questionnaire
/// (Mifflin-St Jeor, goal-adjusted, 40/30/30 macro split). Persisted so the
/// home screen keeps showing the user's plan across launches.
struct DailyPlan: Codable, Equatable {
    var calories: Int
    var proteinG: Int
    var carbsG: Int
    var fatsG: Int

    /// UserDefaults key the encoded plan is stored under.
    static let storageKey = "plan.daily"

    /// Fallback used before onboarding has produced a real plan.
    static let `default` = DailyPlan(calories: 2000, proteinG: 150, carbsG: 200, fatsG: 67)

    /// Loads the persisted plan, or the default when none was saved yet.
    static func load() -> DailyPlan {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let plan = try? JSONDecoder().decode(DailyPlan.self, from: data) else {
            return .default
        }
        return plan
    }

    /// Persists this plan to UserDefaults.
    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }
}

/// Shared observable game state: scanned characters, squad selection,
/// and the last server-authoritative battle replay.
@MainActor
final class GameState: ObservableObject {
    @Published var scannedCharacters: [Character] = []
    /// Characters pulled from loot crates (issue #21) — merged into the
    /// collection alongside scans and the starter roster.
    @Published var crateCharacters: [Character] = []
    /// Battle-ready snapshots keyed by card id — minted monsters keep their
    /// server-rolled combat bases here for squad/dungeon calls.
    @Published var battleCharacters: [String: BattleUnitSpec] = [:]
    @Published var lastReplay: BattleReplay?
    /// Unit ids in a replay are already the squad ids sent to the server —
    /// no UUID mapping needed (the legacy engine's UUID-keyed events are gone).
    @Published var recentScans: [String] = []
    @Published var lastMultiplier: Double = 1.0
    /// Present the crate opening sheet (Home button, QA launch arg).
    @Published var showCrates = false

    // Backend-backed state. nil profile means "not loaded yet"; screens
    // should fall back to cached/sample values while loading.
    @Published var profile: UserProfileDTO?
    @Published var coinBalance: Int = 0
    @Published var lastCrateDrop: CrateOpenResponse?
    @Published var crateInventory: InventoryResponse?
    @Published var fairness: FairnessResponse?
    /// Granted Cases waiting to be opened — ranked wins, promos (spec §5).
    @Published var pendingCases: [PendingCaseDTO] = []

    /// Last backend error, surfaced through the existing Banner/NQBanner
    /// components by the screens. Cleared on the next successful call.
    @Published var backendError: String?
    /// Player tapped Connect on the Watch screen. Persisted so Profile
    /// doesn't keep saying "Not Connected" after a successful link.
    @Published var watchLinked: Bool = UserDefaults.standard.bool(forKey: "watch.linked")

    func setWatchLinked(_ value: Bool) {
        watchLinked = value
        UserDefaults.standard.set(value, forKey: "watch.linked")
    }

    /// True while a HealthKit read + upload is in flight; screens use it to
    /// disable the Sync button rather than queue duplicate uploads.
    @Published private(set) var isSyncingHealth = false
    /// When the phone last uploaded a HealthKit snapshot. Persisted so the
    /// Profile row can say "Synced 3m ago" across launches.
    @Published private(set) var lastHealthSyncAt: Date? = {
        let t = UserDefaults.standard.double(forKey: "watch.lastSyncAt")
        return t > 0 ? Date(timeIntervalSince1970: t) : nil
    }()

    /// Foreground re-syncs closer together than this are skipped: HealthKit
    /// only gets fresh watch data every few minutes, and the backend rate
    /// limits /vitals at 60/min per player.
    private let healthSyncMinInterval: TimeInterval = 60

    /// Connect flow behind Profile › Connected devices and the onboarding
    /// Apple Health step: show the system Health sheet (first time only),
    /// upload today's snapshot, then mark the watch linked. Throws when
    /// Health data is unavailable, the sheet failed, or the upload failed —
    /// the caller shows the failure state. "HealthKit had no data" is *not*
    /// a failure: the link succeeds and the screen shows dashes until the
    /// first real reading.
    func connectAppleWatch() async throws {
        isSyncingHealth = true
        defer { isSyncingHealth = false }
        let uploaded = try await HealthSyncService.shared.sync(requestAuthorizationIfNeeded: true)
        setWatchLinked(true)
        if uploaded { markHealthSynced() }
        await refreshVitals()
    }

    /// Silent foreground sync (launch, scene became active, Sync now). Does
    /// nothing until the player has connected; never re-prompts for
    /// permission. Transport/5xx errors surface via `backendError` like every
    /// other call; a HealthKit read problem is swallowed because it looks
    /// identical to "no data" from the phone's side.
    func syncHealthIfLinked(force: Bool = false) async {
        guard watchLinked, HealthSyncService.shared.hasRequestedAuthorization, !isSyncingHealth else { return }
        if !force, let last = lastHealthSyncAt, Date().timeIntervalSince(last) < healthSyncMinInterval { return }
        isSyncingHealth = true
        defer { isSyncingHealth = false }
        do {
            if try await HealthSyncService.shared.sync(requestAuthorizationIfNeeded: false) {
                markHealthSynced()
            }
            await refreshVitals()
        } catch let error as APIError {
            backendError = error.localizedDescription
        } catch {
            // HealthKit unavailable / read failed: nothing to upload this time.
        }
    }

    private func markHealthSynced() {
        let now = Date()
        lastHealthSyncAt = now
        UserDefaults.standard.set(now.timeIntervalSince1970, forKey: "watch.lastSyncAt")
    }

    /// Gym photo logged until this date. +5% on the daily multiplier while live.
    @Published var gymCheckUntil: Date? = {
        let t = UserDefaults.standard.double(forKey: "gym.checkUntil")
        guard t > Date().timeIntervalSince1970 else { return nil }
        return Date(timeIntervalSince1970: t)
    }()

    var gymBonus: Double {
        guard let until = gymCheckUntil, until > Date() else { return 0 }
        return 0.05
    }

    func logGymCheck() {
        let until = Date().addingTimeInterval(24 * 60 * 60)
        gymCheckUntil = until
        UserDefaults.standard.set(until.timeIntervalSince1970, forKey: "gym.checkUntil")
        recomputeMultiplier()
    }

    // Battle resolution is `BattleEngine.simulate` (static, deterministic) —
    // no engine instance to hold.
    private let multiplierCalc = DailyMultiplierCalculator()
    private let api = APIClient.shared

    /// Height, weight, age, sex, activity and goal — the inputs every
    /// nutrition number is derived from. Set by onboarding, editable later in
    /// Profile > Body & goals. Falls back to an average-adult placeholder
    /// until the player supplies their own.
    @Published private(set) var bodyMetrics: BodyMetrics = (BodyMetrics.load() ?? .default).normalized()

    /// BattleKit's view of the player, scoring the daily party multiplier
    /// against personal targets. Derived, so editing the metrics moves it.
    var nutritionProfile: PlayerProfile { bodyMetrics.playerProfile }

    // MARK: - Daily plan (onboarding-derived targets)

    /// Calorie + macro targets derived from `bodyMetrics`. Persisted so the
    /// home screen renders the plan before anything is recomputed.
    @Published var dailyPlan: DailyPlan = DailyPlan.load()

    /// Daily calorie target, and the macro targets behind the dashboard rings.
    var calorieTarget: Double { Double(dailyPlan.calories) }
    var proteinTarget: Double { Double(dailyPlan.proteinG) }
    /// 25 g per 2000 kcal, off the plan's calories so every displayed target
    /// stays internally consistent even before the metrics are re-saved.
    var fiberTarget: Double { 25 * (calorieTarget / 2000) }

    /// Stores a plan directly and persists it.
    func applyPlan(_ plan: DailyPlan) {
        dailyPlan = plan
        plan.save()
    }

    /// Saves edited body metrics and re-derives everything that depends on
    /// them: the daily calorie/macro plan, the multiplier breakdown scored
    /// against today's log, and the backend's copy of the nutrition profile.
    func applyBodyMetrics(_ metrics: BodyMetrics) {
        let clean = metrics.normalized()
        bodyMetrics = clean
        clean.save()
        applyPlan(clean.targets)
        rescoreDayLog()
        Task { await syncBodyMetrics() }
    }

    /// Re-runs the multiplier over today's log after the targets moved, so the
    /// squad boost reflects the new plan without waiting for the next scan.
    private func rescoreDayLog() {
        guard !dayLog.isEmpty else { return }
        Task { [weak self] in
            guard let self else { return }
            let breakdown = await self.multiplierCalc.calculate(entries: self.dayLog, profile: self.nutritionProfile)
            await MainActor.run {
                self.lastBreakdown = breakdown
                self.recomputeMultiplier()
            }
        }
    }

    /// Best-effort mirror of the nutrition profile (PATCH /user/:id).
    /// The local copy is authoritative for targets, so a failure here is
    /// silent rather than an offline banner on the Profile tab.
    private func syncBodyMetrics() async {
        _ = try? await api.updateBodyMetrics(
            id: AppConfig.playerID,
            age: bodyMetrics.ageYears,
            sex: bodyMetrics.sex.battleKitSex.rawValue,
            heightCm: bodyMetrics.heightCm,
            weightKg: bodyMetrics.weightKg,
            activity: bodyMetrics.activity.rawValue,
            goal: bodyMetrics.goal.battleKitGoal.rawValue
        )
    }

    /// Registers the backend's answer to `POST /scan`. The server owns the
    /// mint: the FIRST time this player ever scans a barcode the result
    /// carries the ★1 monster it created; every re-scan comes back with
    /// `duplicate` set and is nutrition-only. Either way the plate lands on
    /// the day log — re-scans still count for tasks.
    ///
    /// Returns the minted character for the summon animation, or nil when the
    /// scan was a duplicate. `product` is the best-effort local OFF lookup —
    /// it only enriches the day log (food group, micro score); the monster
    /// and its stats always come from the server.
    @discardableResult
    func registerScanResult(_ result: ScanResultDTO, product: FoodProduct? = nil) -> Character? {
        var minted: Character?
        if let dto = result.summonedCharacter, let mint = result.mint {
            var character = Character(
                id: dto.id,
                name: dto.name,
                colorHex: dto.colorHex,
                imageKey: dto.imageKey,
                rarity: Rarity(rawValue: dto.rarity) ?? .common,
                baseHealth: dto.baseHealth ?? 100,
                baseAttack: dto.baseAttack ?? 50,
                baseMana: dto.baseMana,
                starLevel: mint.stars,
                bio: dto.bio ?? dto.flavor,
                dropIDs: [mint.dropId],
                netWorth: mint.netWorth
            )
            character.dropMeta[mint.dropId] = DropMeta(stars: mint.stars, rarity: dto.rarity, locked: false)
            scannedCharacters.append(character)
            battleCharacters[dto.id] = unitSpec(for: character)
            minted = character
        }

        if recentScans.count < 8 { recentScans.insert(result.foodName, at: 0) }
        markScannedToday()
        bumpCounter("stats.totalScans")

        // Recompute the daily party multiplier from the day's scans. The
        // snapshot the server scored is per-100g, same as the product feed.
        let n = result.nutrition
        let entry = DayLogEntry(
            barcode: result.barcode,
            name: result.foodName,
            calories: n?.calories ?? 0,
            protein: n?.proteinG ?? 0,
            carbs: n?.carbsG ?? 0,
            fat: n?.fatG ?? 0,
            fiber: n?.fiberG ?? 0,
            sugar: n?.sugarG ?? 0,
            microScore: product?.microScore ?? 0.3,
            foodGroup: product.map { Self.foodGroup(for: $0) } ?? .other
        )
        appendDayLog(entry)
        checkAchievements()
        return minted
    }

    /// Registers a confirmed dish-photo plate: a meal-log entry, never a
    /// monster — the barcode path is the only food scan that can mint.
    ///
    /// The day log gets real plate totals here (actual grams eaten) rather
    /// than the per-100g figures a barcode product carries.
    func registerDishLog(result: DishConfirmResult) {
        if recentScans.count < 8 { recentScans.insert(result.foodName, at: 0) }
        markScannedToday()
        bumpCounter("stats.totalScans")

        let totals = result.nutrition
        appendDayLog(DayLogEntry(
            barcode: result.mealId,
            name: result.foodName,
            calories: totals.calories,
            protein: totals.proteinG,
            carbs: totals.carbsG,
            fat: totals.fatG,
            fiber: totals.fiberG,
            sugar: totals.sugarG,
            microScore: totals.microScore,
            foodGroup: FoodGroup(rawValue: totals.dominantFoodGroup) ?? .other
        ))
        checkAchievements()
    }

    /// Appends an entry and rescores the multiplier against the new day log.
    private func appendDayLog(_ entry: DayLogEntry) {
        // Synchronous append — the log is observable state callers may read
        // right after registering a scan/meal. Only the multiplier recompute
        // is deferred (it awaits the async calculator).
        dayLog.append(entry)
        persistTodayCalories()
        Task { [weak self] in
            guard let self else { return }
            let breakdown = await self.multiplierCalc.calculate(entries: self.dayLog, profile: self.nutritionProfile)
            await MainActor.run {
                self.lastBreakdown = breakdown
                self.recomputeMultiplier()
            }
        }
    }

    /// Every scan this session, oldest first. Not yet persisted across
    /// relaunches (matches the known scan-persistence gap) — the health
    /// dashboard reflects the current session's real logged nutrition.
    @Published private(set) var dayLog: [DayLogEntry] = []

    /// Today's entries only, for the health dashboard.
    var todayEntries: [DayLogEntry] {
        dayLog.filter { Calendar.current.isDateInToday($0.loggedAt) }
    }

    var todayCalories: Double { todayEntries.reduce(0) { $0 + $1.calories } }
    var todayProtein: Double { todayEntries.reduce(0) { $0 + $1.protein } }
    var todayCarbs: Double { todayEntries.reduce(0) { $0 + $1.carbs } }
    var todayFat: Double { todayEntries.reduce(0) { $0 + $1.fat } }
    var todayFiber: Double { todayEntries.reduce(0) { $0 + $1.fiber } }
    var todaySugar: Double { todayEntries.reduce(0) { $0 + $1.sugar } }
    var todayFoodGroups: Int { Set(todayEntries.map(\.foodGroup)).count }
    var todayQualityScore: Double {
        guard !todayEntries.isEmpty else { return 0 }
        return todayEntries.map(\.microScore).reduce(0, +) / Double(todayEntries.count)
    }

    /// 0...1 progress toward each personal target, for progress bars/rings.
    var todayCalorieProgress: Double { min(todayCalories / max(nutritionProfile.calorieTarget, 1), 1) }
    var todayProteinProgress: Double { min(todayProtein / max(nutritionProfile.proteinTarget, 1), 1) }
    var todayFiberProgress: Double { min(todayFiber / max(nutritionProfile.fiberTarget, 1), 1) }

    // MARK: - Per-day calorie history (home week strip)

    /// Writes today's running calorie total under "cal.day.yyyy-MM-dd".
    /// The full day log is session-only; this lightweight total is what lets
    /// the home screen's week strip show past days after a relaunch.
    private func persistTodayCalories() {
        UserDefaults.standard.set(todayCalories, forKey: "cal.day.\(todayKey())")
    }

    /// Calories logged on a given day. Today reads the live session total;
    /// other days read the persisted per-day total (0 when nothing logged).
    func calories(on date: Date) -> Double {
        if Calendar.current.isDateInToday(date) { return todayCalories }
        return UserDefaults.standard.double(forKey: "cal.day.\(key(for: date))")
    }

    /// Best-effort food group from Open Food Facts category text — powers
    /// the diversity bonus (§3 of docs/BATTLE-SYSTEM.md) and the dashboard's
    /// group chips. Falls back to `.other` when nothing matches.
    static func foodGroup(for product: FoodProduct) -> FoodGroup {
        let haystack = [product.categories, product.genericName, product.productNameEn, product.productName]
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")
        func matches(_ keywords: [String]) -> Bool { keywords.contains { haystack.contains($0) } }

        if matches(["fruit", "vegetable", "legume", "salad", "produce"]) { return .produce }
        if matches(["bread", "cereal", "rice", "pasta", "grain", "oat", "wheat"]) { return .grain }
        if matches(["milk", "cheese", "yogurt", "yoghurt", "dairy", "cream"]) { return .dairy }
        if matches(["meat", "fish", "egg", "poultry", "chicken", "beef", "pork", "tofu", "nut", "seed", "protein"]) { return .protein }
        return .other
    }

    // MARK: - Streak (loss-aversion mechanic)

    private enum StreakKeys {
        static let lastScanDay = "streak.lastScanDay"   // yyyy-MM-dd
        static let freezes = "streak.freezes"
        static let localCount = "streak.localCount"
        static let celebrated = "streak.celebratedMilestones"
    }

    /// Local streak state. The backend's streakDays stays the source of truth
    /// for the number; this layer adds the *loss* half of the mechanic:
    /// at-risk detection, freeze items, and break handling.
    @Published var streakFreezes: Int
    /// yyyy-MM-dd of the last successful scan, or nil if never scanned.
    @Published private(set) var lastScanDay: String?

    /// True after 17:00 local time when nothing has been scanned today —
    /// the window where loss framing ("your streak is in danger") applies.
    var streakAtRisk: Bool {
        guard lastScanDay != todayKey() else { return false }
        guard Calendar.current.component(.hour, from: Date()) >= 17 else { return false }
        return true
    }

    /// Days missed since the last scan (0 = scanned today).
    private var missedDays: Int {
        guard let last = lastScanDay, let lastDate = dateFromKey(last) else { return 0 }
        return Calendar.current.dateComponents([.day], from: lastDate, to: Calendar.current.startOfDay(for: Date())).day ?? 0
    }

    init() {
        let d = UserDefaults.standard
        _lastScanDay = Published(initialValue: d.string(forKey: StreakKeys.lastScanDay))
        _streakFreezes = Published(initialValue: d.integer(forKey: StreakKeys.freezes))
        reconcileStreak()
    }

    /// Called at launch: if a day was missed, spend a freeze to save the
    /// streak; otherwise the streak breaks (backend streakDays resets on the
    /// server's own daily rollover — this keeps the local narrative honest).
    private func reconcileStreak() {
        guard missedDays >= 1, lastScanDay != nil else { return }
        if missedDays == 1, streakFreezes > 0 {
            streakFreezes -= 1
            UserDefaults.standard.set(streakFreezes, forKey: StreakKeys.freezes)
        }
        // A break is reflected server-side; locally we just clear the day
        // marker so at-risk logic starts fresh.
        if missedDays >= 2 {
            lastScanDay = nil
            UserDefaults.standard.set(nil, forKey: StreakKeys.lastScanDay)
        }
    }

    private func markScannedToday() {
        let previous = lastScanDay
        lastScanDay = todayKey()
        UserDefaults.standard.set(lastScanDay, forKey: StreakKeys.lastScanDay)
        NQNotifications.cancelStreakRiskForToday()
        evaluateStreakMilestone(previousDay: previous)
    }

    // MARK: - Streak milestone celebration (goal-gradient ladder)

    /// Milestone hit by today's scan, awaiting celebration. nil = nothing
    /// pending. The RootTabView overlay consumes and clears it.
    @Published var streakMilestone: Int?

    /// Escalating celebration tiers — the goal-gradient effect: the closer
    /// to a big milestone, the bigger the payoff. Day 3 = flicker, 7 = burst,
    /// 30 = confetti, 100 = full-screen shareable moment.
    static let streakMilestones: [Int] = [3, 7, 14, 30, 100]

    private func evaluateStreakMilestone(previousDay: String?) {
        let d = UserDefaults.standard
        var count = d.integer(forKey: StreakKeys.localCount)

        if previousDay == nil {
            count = 1
        } else if previousDay == yesterdayKey() {
            count += 1
        } else if previousDay != todayKey() {
            count = 1   // gap — streak broke, start over
        } else {
            return      // already scanned today; no new milestone
        }
        d.set(count, forKey: StreakKeys.localCount)

        guard Self.streakMilestones.contains(count) else { return }
        var celebrated = Set(d.stringArray(forKey: StreakKeys.celebrated) ?? [])
        guard !celebrated.contains("\(count)") else { return }
        celebrated.insert("\(count)")
        d.set(Array(celebrated), forKey: StreakKeys.celebrated)
        streakMilestone = count
    }

    private func yesterdayKey() -> String {
        guard let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date()) else { return "" }
        return key(for: yesterday)
    }

    /// Grants a streak freeze — wired to crate rewards (rare+ pulls).
    func grantStreakFreeze() {
        streakFreezes += 1
        UserDefaults.standard.set(streakFreezes, forKey: StreakKeys.freezes)
    }

    private func todayKey() -> String {
        key(for: Date())
    }

    // MARK: - Per-day goal completion (streak calendar)

    /// Current nutrition streak in days. The backend's streak block is the
    /// source of truth once the profile has loaded; before that (or offline)
    /// the locally tracked count keeps the number honest.
    var streakCount: Int {
        streak?.days ?? profile?.nutritionStreakDays ?? UserDefaults.standard.integer(forKey: StreakKeys.localCount)
    }

    /// Marks today as "all goals achieved" once every daily task is done.
    /// Persisted under "goals.day.yyyy-MM-dd" so the profile's streak
    /// calendar can still mark past days after a relaunch.
    private func persistGoalCompletionIfEarned() {
        guard !dailyTasks.isEmpty, dailyTasks.allSatisfy(\.done) else { return }
        UserDefaults.standard.set(true, forKey: "goals.day.\(todayKey())")
    }

    /// True when every daily goal was completed on the given day. Today also
    /// checks the live task list so the calendar lights up the moment the
    /// last goal lands; past days read the persisted per-day flag.
    func allGoalsAchieved(on date: Date) -> Bool {
        if Calendar.current.isDateInToday(date),
           !dailyTasks.isEmpty, dailyTasks.allSatisfy(\.done) {
            return true
        }
        return UserDefaults.standard.bool(forKey: "goals.day.\(key(for: date))")
    }

    // MARK: - Achievements

    /// One-shot celebration for a newly unlocked achievement.
    @Published var achievement: Achievement?

    @discardableResult
    private func bumpCounter(_ key: String, by amount: Int = 1) -> Int {
        let v = UserDefaults.standard.integer(forKey: key) + amount
        UserDefaults.standard.set(v, forKey: key)
        return v
    }

    /// Re-evaluates milestones after any progression event.
    func checkAchievements() {
        let stats = Achievements.Stats(
            totalScans: UserDefaults.standard.integer(forKey: "stats.totalScans"),
            uniqueCharacters: collection.filter { !$0.isLocked }.count,
            rarePlusPulls: UserDefaults.standard.integer(forKey: "stats.rarePlusPulls"),
            legendaries: UserDefaults.standard.integer(forKey: "stats.legendaries"),
            battlesWon: record?.rankedWins ?? profile?.battlesWon ?? 0
        )
        if let unlocked = Achievements.evaluate(stats: stats).first {
            achievement = unlocked
            NQJuice.reveal()
        }
    }

    private func dateFromKey(_ key: String) -> Date? {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: key)
    }

    private func key(for date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    // MARK: - Vitals → gameplay (issue #27)

    /// The watch's latest HealthKit activity, and the bonus it contributes to
    /// the Daily Party Multiplier. nil activity = no snapshot synced yet.
    @Published var vitalsActivity: VitalsActivity?
    @Published var vitalsBonus: Double = 0

    /// Last food-only multiplier breakdown; the vitals bonus is added on top
    /// so a new snapshot or a new scan both recompute the same way. Exposed
    /// (not private) so the health dashboard can show the same real numbers.
    @Published private(set) var lastBreakdown: DailyMultiplierBreakdown = .neutral

    private func recomputeMultiplier() {
        lastMultiplier = min(1.5, max(0.8, lastBreakdown.total + vitalsBonus + gymBonus))
    }

    /// GET /vitals/latest — pulls the watch's snapshot and folds its activity
    /// into the Daily Party Multiplier (capped +0.10, see VitalsActivity).
    /// A 404 means no snapshot has synced yet — normal before pairing, so it
    /// quietly keeps the bonus at 0; only transport/5xx errors surface in
    /// `backendError`.
    func refreshVitals() async {
        do {
            let latest = try await api.fetchLatestVitals()
            backendError = nil
            let snapshot = latest.snapshot
            let activity = VitalsActivity(
                stepsToday: snapshot.stepsToday.map(Int.init),
                exerciseMinutesToday: snapshot.exerciseMinutesToday.map(Int.init),
                standHoursToday: snapshot.standHoursToday.map(Int.init),
                activeCaloriesToday: snapshot.activeCaloriesToday.map(Int.init)
            )
            vitalsActivity = activity
            vitalsBonus = activity.bonus
            recomputeMultiplier()
        } catch APIError.badStatus(404, _) {
            vitalsActivity = nil
            vitalsBonus = 0
            recomputeMultiplier()
        } catch {
            backendError = error.localizedDescription
        }
    }

    /// Resolves a battle on the backend (POST /battle/simulate) and maps the
    /// server's authoritative event stream into a BattleReplay for animation.
    ///
    /// The local BattleEngine is never used to decide the outcome — the server
    /// result is the source of truth. Returns nil (and sets `backendError`)
    /// when the backend is unreachable instead of silently resolving locally.
    /// The squad payload sent to the server: identity + progression only.
    /// Combat stats and authored moves resolve server-side from the catalog,
    /// so a stale local snapshot can never skew a match.
    private func squadMember(_ c: Character) -> BattleSquadMember {
        BattleSquadMember(id: c.id, name: c.name, rarity: c.rarity.rawValue, star: c.starLevel)
    }

    /// A deterministic seed derived from the matchup, so the same squads
    /// replay identically on rewatch. Sent as a decimal string — JSON can't
    /// carry a full UInt64.
    private func battleSeed(for yourSquad: [Character], versus opponentSquad: [Character], salt: String = "") -> UInt64 {
        let seedString = (yourSquad + opponentSquad).map(\.id).joined() + "|" + salt
        return seedString.utf8.reduce(UInt64(31)) { ($0 &+ UInt64($1) &+ 31) &* 0x100000001b3 }
    }

    @discardableResult
    func resolveBattle(yourSquad: [Character], opponentSquad: [Character], chosenMove: String? = nil) async -> BattleReplay? {
        let seed = battleSeed(for: yourSquad, versus: opponentSquad, salt: chosenMove ?? "")

        do {
            let result = try await api.simulateBattle(BattleSimulateRequest(
                yourSquad: yourSquad.map(squadMember),
                opponentSquad: opponentSquad.map(squadMember),
                seed: String(seed)
            ))
            let replay = try BattleReplayMapper.replay(from: result)
            lastReplay = replay
            backendError = nil
            return replay
        } catch {
            backendError = error.localizedDescription
            return nil
        }
    }

    /// Friendly battle against a friend's stored squad snapshot. The server
    /// resolves and records it in both players' battle history — no RR moves.
    /// Returns the replay plus the snapshot squad so the caller can animate it.
    func challengeFriend(opponentId: String) async -> (replay: BattleReplay, opponentSquad: [Character])? {
        let yourChars = Array(collection.filter { !$0.isLocked }.prefix(3))
        guard yourChars.count == 3 else { return nil }

        do {
            let result = try await api.challengeFriend(opponentId: opponentId, squad: yourChars.map(squadMember))
            // Snapshot units become displayable characters for the replay.
            let opponentChars = result.opponentSquad.map { m in
                Character(
                    id: m.id,
                    name: m.name,
                    colorHex: "#9C978F",
                    rarity: Rarity(rawValue: m.rarity) ?? .common,
                    starLevel: m.star
                )
            }
            let replay = try BattleReplayMapper.replay(
                from: ServerBattleResult(
                    winner: result.winner, rounds: result.rounds, events: result.events,
                    hpLeftA: result.hpLeftA, hpLeftB: result.hpLeftB,
                    faintedA: result.faintedA, faintedB: result.faintedB
                )
            )
            lastReplay = replay
            backendError = nil
            return (replay, opponentChars)
        } catch {
            backendError = error.localizedDescription
            return nil
        }
    }

    /// Endless dungeon — personal best + last run feed (spec §5).
    @Published var dungeonState: DungeonStateResponse?
    @Published var lastDungeonRun: DungeonRunResponse?

    func refreshDungeon() async {
        do {
            dungeonState = try await api.fetchDungeonState()
        } catch {
            backendError = error.localizedDescription
        }
    }

    /// POST /battle/dungeon/run — exactly 3 unlocked characters descend.
    /// Floors pay coins on clear and earnings survive a wipe.
    @discardableResult
    func runDungeon() async -> DungeonRunResponse? {
        let squad = collection.filter { !$0.isLocked }.prefix(3).map(squadMember)
        guard squad.count == 3 else { return nil }
        do {
            let run = try await api.runDungeon(squad: squad)
            lastDungeonRun = run
            coinBalance = run.coins
            await refreshDungeon()
            backendError = nil
            return run
        } catch {
            backendError = error.localizedDescription
            return nil
        }
    }

    /// Local deterministic simulation. Kept for replaying/animating a result
    /// the server already produced (same squads + seed = same replay) and for
    /// practice mode; never used to decide a ranked outcome on its own.
    func simulateLocally(yourSquad: [Character], opponentSquad: [Character]) -> BattleReplay {
        let a = yourSquad.map { battleStats(for: $0) }
        let b = opponentSquad.map { battleStats(for: $0) }
        let seed = battleSeed(for: yourSquad, versus: opponentSquad)
        let replay = BattleEngine.simulate(squadA: a, squadB: b, seed: seed)
        lastReplay = replay
        return replay
    }

    // MARK: - Collection (single source of truth)

    /// The full roster: starter characters + every scanned food + every crate
    /// pull, deduplicated by id. Collection, Battle squad selection, and
    /// Profile counts all read this — scanning and playing are one system.
    var collection: [Character] {
        // Later sources win on a shared id, not the first: the starter
        // roster is a real server-owned drop from the moment the account
        // exists (services/lootboxState.ts seedStarterRoster), so once
        // inventory has synced, `crateCharacters` holds the same six ids
        // with their real dropIds/net worth attached — that copy is what
        // should render, not the inert placeholder SampleData started as.
        // Display order still follows first appearance, so the grid doesn't
        // reshuffle the moment a card becomes sellable.
        var order: [String] = []
        var byID: [String: Character] = [:]
        for character in SampleData.characters + scannedCharacters + crateCharacters {
            if byID[character.id] == nil { order.append(character.id) }
            byID[character.id] = character
        }
        return order.compactMap { byID[$0] }
    }

    /// Adds a backend loot drop to the collection. Returns the app Character.
    ///
    /// Rarity now decodes directly: `Rarity` carries the same seven tiers the
    /// backend does, so a Mythic or Secret pull keeps its identity instead of
    /// being flattened into Legendary on the way in.
    @discardableResult
    func addCrateCharacter(drop: CrateOpenResponse) -> Character {
        let loot = drop.character
        let rarity = Rarity(rawValue: loot.rarity) ?? .common

        var character = Character(
            id: "crate-\(loot.id)",
            name: loot.name,
            colorHex: loot.colorHex,
            imageKey: loot.imageKey,
            rarity: rarity,
            baseHealth: loot.baseHealth ?? 100,
            baseAttack: loot.baseAttack ?? 50,
            baseMana: loot.baseMana,
            starLevel: drop.stars ?? 1,
            bio: loot.bio ?? loot.flavor,
            dropIDs: drop.id.map { [$0] } ?? [],
            netWorth: drop.value
        )
        if let dropID = drop.id {
            character.dropMeta[dropID] = DropMeta(stars: drop.stars ?? 1, rarity: loot.rarity, locked: false)
        }
        // Dedupe by id — a re-pull folds into the existing card rather than
        // adding a second card with the same grid identity.
        if let idx = crateCharacters.firstIndex(where: { $0.id == character.id }) {
            if let dropID = drop.id {
                crateCharacters[idx].dropIDs.append(dropID)
                crateCharacters[idx].dropMeta[dropID] = DropMeta(stars: drop.stars ?? 1, rarity: loot.rarity, locked: false)
            }
            crateCharacters[idx].netWorth += drop.value
            crateCharacters[idx].starLevel = max(crateCharacters[idx].starLevel, drop.stars ?? 1)
        } else {
            crateCharacters.append(character)
        }
        // Rare+ pulls award a streak freeze — loss-aversion item earned
        // through the variable-reward loop.
        // Compared by rank rather than a list of tier names, so an eighth tier
        // would not silently stop counting as a rare-or-better pull.
        if rarity >= .rare {
            grantStreakFreeze()
            bumpCounter("stats.rarePlusPulls")
        }
        if rarity >= .legendary {
            bumpCounter("stats.legendaries")
        }
        checkAchievements()
        return character
    }

    // MARK: - Backend: profile

    /// True only while the first profile fetch is in flight. Screens use this
    /// (not `profile == nil`) so a failed request never leaves skeletons up.
    @Published var profileLoading = false

    /// GET /user/:id for this install's player ID. On failure the previous
    /// profile (if any) stays and `backendError` is set. The response also
    /// carries the derived rank block, record, streak, faints and today's
    /// tasks — all synced here so screens read one place.
    func loadProfile() async {
        profileLoading = true
        defer { profileLoading = false }
        do {
            let result = try await api.fetchUserProfile(id: AppConfig.playerID)
            profile = result.profile
            rank = result.rank
            record = result.record
            streak = result.streak
            faintedIds = Set(result.fainted ?? [])
            if let tasks = result.tasks { dailyTasks = tasks }
            backendError = nil
        } catch {
            backendError = error.localizedDescription
        }
    }

    // MARK: - Progression state (spec §5/§6)

    /// Derived rank block — RR, rank label, distance to promote.
    @Published var rank: RankBlockDTO?
    /// Ranked record — wins, losses, win rate.
    @Published var record: RecordDTO?
    /// Nutrition streak + unspent Cookbook Boosts.
    @Published var streak: StreakDTO?
    /// Character ids currently fainted — cannot be fielded until the daily
    /// reset or a nutrition-task revive.
    @Published var faintedIds: Set<String> = []
    /// Today's three tasks (nutrition / battle / flex).
    @Published var dailyTasks: [TaskDTO] = []
    /// Completed battles, newest first (profile history).
    @Published var battleHistory: [BattleHistoryEntry] = []

    /// GET /user/tasks/today — refresh verified task progress.
    func refreshTasks() async {
        do {
            dailyTasks = try await api.fetchTasks().tasks
            persistGoalCompletionIfEarned()
            backendError = nil
        } catch {
            backendError = error.localizedDescription
        }
    }

    /// POST /user/tasks/:id/claim — server verifies completion, pays coins
    /// (+500 on the trio), applies task RR and may revive a faint.
    @discardableResult
    func claimTask(_ taskId: String) async -> TaskClaimResult? {
        do {
            let result = try await api.claimTask(taskId)
            coinBalance += result.coins + result.bonusCoins
            if let i = dailyTasks.firstIndex(where: { $0.id == taskId }) {
                dailyTasks[i] = TaskDTO(
                    id: dailyTasks[i].id,
                    category: dailyTasks[i].category,
                    label: dailyTasks[i].label,
                    rrEligible: dailyTasks[i].rrEligible,
                    done: true,
                    claimed: true
                )
            }
            if let revived = result.revived { faintedIds.remove(revived) }
            if var r = rank { r = RankBlockDTO(rr: result.rr, rank: result.rank, rankLabel: r.rankLabel, rrToNextRank: r.rrToNextRank); rank = r }
            persistGoalCompletionIfEarned()
            if let days = result.streakDays, var s = streak {
                s = StreakDTO(days: days, boosts: s.boosts + (result.boostEarned == true ? 1 : 0), nextBoostIn: s.nextBoostIn)
                streak = s
            }
            backendError = nil
            return result
        } catch {
            backendError = error.localizedDescription
            return nil
        }
    }

    /// GET /user/:id/history — refresh the battle log.
    func refreshBattleHistory() async {
        do {
            battleHistory = try await api.fetchBattleHistory(id: AppConfig.playerID).battles
            backendError = nil
        } catch {
            backendError = error.localizedDescription
        }
    }

    /// PUT /user/:id — showcase a character on the Profile screen. Optimistic:
    /// the profile updates immediately so the pfp swaps without a flash of
    /// the old character, and rolls back if the server rejects it.
    @discardableResult
    func setDisplayCharacter(_ characterID: String) async -> Bool {
        let previous = profile?.activeCharacterId
        profile?.activeCharacterId = characterID
        do {
            let result = try await api.updateProfile(id: AppConfig.playerID, activeCharacterId: characterID)
            profile = result.profile
            backendError = nil
            return true
        } catch {
            profile?.activeCharacterId = previous
            backendError = error.localizedDescription
            return false
        }
    }

    /// GET /user/:id/journey — all numbers + timelines for the Journey view.
    @Published var journey: JourneyResponse?
    func loadJourney() async {
        do {
            journey = try await api.fetchJourney(id: AppConfig.playerID)
            backendError = nil
        } catch {
            backendError = error.localizedDescription
        }
    }

    // MARK: - Backend: cookbooks & cases (commit-reveal fairness)

    /// POST /lootbox/cases/:id/open — consume a granted Case; the server
    /// resolves the drop (commit-reveal); the client never rolls outcomes.
    @discardableResult
    func openPendingCase(caseID: String, clientSeed: String? = nil) async -> CrateOpenResponse? {
        do {
            let drop = try await api.openPendingCase(caseId: caseID, clientSeed: clientSeed)
            lastCrateDrop = drop
            backendError = nil
            return drop
        } catch {
            backendError = error.localizedDescription
            return nil
        }
    }

    /// GET /lootbox/inventory — pulls, mailbox and pending cases for this player.
    func refreshInventory(limit: Int = 50) async {
        do {
            let inventory = try await api.fetchInventory(limit: limit)
            crateInventory = inventory
            pendingCases = inventory.cases ?? pendingCases
            // A full listing is authoritative about what is still owned —
            // Cauldron Crash destroys instances, so cards have to be able to
            // leave the collection, not only join it. A truncated page says
            // nothing about the drops it did not include, so it never prunes.
            if inventory.items.count >= inventory.count {
                syncCrateCharacters(with: inventory.items)
            }
            backendError = nil
        } catch {
            backendError = error.localizedDescription
        }
    }

    func refreshCoins() async {
        do {
            coinBalance = try await api.fetchCoins().balance
        } catch {
            backendError = error.localizedDescription
        }
    }

    /// GET /lootbox/cookbooks — the four Cookbooks, cheapest first.
    func refreshCookbooks() async -> [CookbookDTO] {
        do {
            let books = try await api.fetchCookbooks()
            backendError = nil
            return books
        } catch {
            backendError = error.localizedDescription
            return []
        }
    }

    /// POST /lootbox/cookbooks/:id/open — paid in coins. Only the coin
    /// balance comes back to sync; the mint itself is added by the caller.
    @discardableResult
    func openCookbook(cookbookID: String, clientSeed: String? = nil) async -> CrateOpenResponse? {
        do {
            let drop = try await api.openCookbook(id: cookbookID, clientSeed: clientSeed)
            lastCrateDrop = drop
            if let balance = drop.coinBalance { coinBalance = balance }
            backendError = nil
            return drop
        } catch {
            backendError = error.localizedDescription
            return nil
        }
    }

    /// POST /lootbox/mailbox/claim — move overflow drops into the inventory.
    @discardableResult
    func claimMailbox(dropIDs: [String]) async -> Bool {
        do {
            _ = try await api.claimMailbox(dropIDs: dropIDs)
            await refreshInventory(limit: 200)
            backendError = nil
            return true
        } catch {
            backendError = error.localizedDescription
            return false
        }
    }

    /// A sale is in flight — sell UI disables rather than letting a second
    /// tap race the first.
    @Published var sellBusy = false

    /// GET /characters/coins — non-fatal: the shop still works with no
    /// balance shown while this is still in flight or unreachable.
    func loadCoinBalance() async {
        coinBalance = (try? await api.fetchCoins().balance) ?? coinBalance
    }

    /// POST /characters/sell — converts monsters to coins at full net worth.
    /// Same "the wager pool loses the instance immediately" pattern the
    /// casino games use, since selling draws from that same pool of real,
    /// server-tracked drops (see `cauldronWagerable`).
    @discardableResult
    func sellCharacters(_ dropIDs: [String]) async -> Int? {
        guard !sellBusy, !dropIDs.isEmpty else { return nil }
        sellBusy = true
        defer { sellBusy = false }
        do {
            let result = try await api.sellMonsters(dropIDs: dropIDs)
            cauldronWagerable.removeAll { dropIDs.contains($0.id) }
            minesWagerable.removeAll { dropIDs.contains($0.id) }
            plinkoWagerable.removeAll { dropIDs.contains($0.id) }
            portalWheelWagerable.removeAll { dropIDs.contains($0.id) }
            // Every crate/reward card carries the real dropIds behind it —
            // strip the sold ones, and drop the card entirely once every
            // instance it stood for is gone.
            for index in crateCharacters.indices {
                crateCharacters[index].dropIDs.removeAll { dropIDs.contains($0) }
                crateCharacters[index].dropMeta = crateCharacters[index].dropMeta.filter { !dropIDs.contains($0.key) }
            }
            crateCharacters.removeAll { $0.dropIDs.isEmpty }
            coinBalance = result.balance
            backendError = nil
            return result.coins
        } catch {
            backendError = error.localizedDescription
            return nil
        }
    }

    /// POST /characters/sell — single-monster convenience wrapper.
    @discardableResult
    func sellMonster(dropID: String) async -> Int? {
        await sellCharacters([dropID])
    }

    /// Rebuilds the crate half of the collection from a complete inventory
    /// listing. Scans and the starter roster keep their cards — their drops
    /// land on the same card the collection already shows.
    ///
    /// Several pulls of the same character still show as one card (grouped
    /// by character type, as before), but that card now remembers every real
    /// instance's dropId and net worth behind it — that's what lets the
    /// collection sell it for real instead of merely displaying it.
    private func syncCrateCharacters(with items: [InventoryItemDTO]) {
        var rebuilt: [Character] = []
        var indexByID: [String: Int] = [:]
        for item in items {
            // Characters minted outside a crate — the starter six, barcode
            // scans, dish photos — carry the character's own bare id, so the
            // drop lands on the same card `collection` already shows and
            // upgrades it in place instead of adding a shadow card.
            let nonCrate = item.crateId == "starter-roster" || item.crateId == "scan" || item.crateId == "dish" || item.crateId == "merge"
            let id = nonCrate ? item.character.id : "crate-\(item.character.id)"
            let meta = DropMeta(
                stars: item.stars ?? 1,
                rarity: item.character.rarity,
                locked: item.lockedBy != nil
            )
            if let index = indexByID[id] {
                rebuilt[index].dropIDs.append(item.id)
                rebuilt[index].dropMeta[item.id] = meta
                rebuilt[index].netWorth += item.value
                rebuilt[index].starLevel = max(rebuilt[index].starLevel, item.stars ?? 1)
                continue
            }
            indexByID[id] = rebuilt.count
            var card = Character(
                id: id,
                name: item.character.name,
                colorHex: item.character.colorHex,
                imageKey: item.character.imageKey,
                rarity: Rarity(rawValue: item.character.rarity) ?? .common,
                baseHealth: item.character.baseHealth ?? 100,
                baseAttack: item.character.baseAttack ?? 50,
                baseMana: item.character.baseMana,
                starLevel: item.stars ?? 1,
                bio: item.character.bio ?? item.character.flavor,
                dropIDs: [item.id],
                netWorth: item.value
            )
            card.dropMeta[item.id] = meta
            rebuilt.append(card)
        }
        crateCharacters = rebuilt
    }

    /// Authored bios from GET /characters/catalog, keyed by roster id. Empty
    /// until the fetch lands, and empty forever offline — `CharacterBios`
    /// falls back rather than leaving a sheet blank.
    @Published var characterCatalogBios: [String: String] = [:]

    /// GET /characters/catalog. Bios are static content, so this runs once per
    /// launch and a failure is not surfaced as a backend error: the sheet has
    /// a local fallback and nothing else depends on it.
    func loadCharacterCatalog() async {
        guard characterCatalogBios.isEmpty else { return }
        do {
            let catalog = try await api.fetchCharacterCatalog()
            characterCatalogBios = Dictionary(
                catalog.map { ($0.id, $0.bio) },
                uniquingKeysWith: { first, _ in first }
            )
        } catch {
            // Left empty on purpose — see the doc comment.
        }
    }

    /// The bio for a character's sheet: authored catalog entry, then whatever
    /// the drop carried, then the local starter-roster copy.
    func bio(for character: Character) -> String? {
        CharacterBios.bio(for: character, catalog: characterCatalogBios)
    }

    // MARK: - Merge

    /// A fusion is in flight — merge UI disables rather than letting a second
    /// tap race the first.
    @Published var mergeBusy = false

    /// POST /characters/merge — fuses the three copies in `dropIDs` into one
    /// instance a star up. The inventory is the authority on what the player
    /// now owns, so a refresh rebuilds the collection rather than trying to
    /// patch it locally.
    @discardableResult
    func mergeCharacters(_ dropIDs: [String]) async -> MergeResponseDTO? {
        guard !mergeBusy, dropIDs.count == 3 else { return nil }
        mergeBusy = true
        defer { mergeBusy = false }
        do {
            let result = try await api.mergeCharacters(dropIDs: dropIDs)
            await refreshInventory(limit: 200)
            backendError = nil
            return result
        } catch {
            backendError = error.localizedDescription
            return nil
        }
    }

    /// POST /lootbox/promos/:code/redeem — one-time reward (coins or a Case).
    @discardableResult
    func redeemPromo(code: String) async -> PromoRedeemResponse? {
        do {
            let response = try await api.redeemPromo(code: code)
            if let balance = response.result.coinBalance { coinBalance = balance }
            if let granted = response.result.grantedCase { pendingCases.append(granted) }
            backendError = nil
            return response
        } catch {
            backendError = error.localizedDescription
            return nil
        }
    }

    /// GET /lootbox/cases — Cases this player can still open.
    @discardableResult
    func refreshPendingCases() async -> [PendingCaseDTO] {
        do {
            let cases = try await api.fetchPendingCases()
            pendingCases = cases
            backendError = nil
            return cases
        } catch {
            backendError = error.localizedDescription
            return pendingCases
        }
    }

    /// GET /lootbox/fairness — current seed commitment + retired seeds.
    func refreshFairness() async {
        do {
            fairness = try await api.fetchFairness()
            backendError = nil
        } catch {
            backendError = error.localizedDescription
        }
    }

    /// POST /lootbox/fairness/rotate — retire current seed (revealing it),
    /// commit a new one. Used by the fairness verifier sheet.
    func rotateSeed() async {
        do {
            let response = try await api.rotateSeed()
            fairness = FairnessResponse(
                current: response.current,
                retired: ([response.revealed] + (fairness?.retired ?? [])).prefix(10).map { $0 },
                howItWorks: fairness?.howItWorks
            )
            backendError = nil
        } catch {
            backendError = error.localizedDescription
        }
    }

    /// The battle stats behind a collection card — the card's own combat
    /// bases (baseHealth/baseAttack/baseMana from the mint or catalog) plus
    /// its instance rarity and stars. Powers the character detail sheet as
    /// well as squad selection.
    func battleStats(for character: Character) -> BattleUnitSpec {
        battleCharacters[character.id] ?? unitSpec(for: character)
    }

    /// A character card expressed as the engine's squad snapshot. The card
    /// carries everything the spec needs; authored moves resolve on the
    /// server, so the local fallback fights with Strike.
    private func unitSpec(for c: Character) -> BattleUnitSpec {
        BattleUnitSpec(
            id: c.id,
            name: c.name,
            baseHealth: c.baseHealth,
            baseAttack: c.baseAttack,
            rarity: c.rarity.battleRarity,
            star: c.starLevel,
            moves: [strikeMove],
            baseMana: c.baseMana
        )
    }

    // MARK: - Monster Casino: Cauldron Crash

    /// The round currently bubbling, if any. Server-owned: the client never
    /// decides that a round is over.
    @Published var cauldronRound: CauldronRoundDTO?
    /// The last finished round, so a player returning from the background
    /// still finds out how it ended.
    @Published var cauldronLastRound: CauldronRoundDTO?
    /// Monsters this player can put in the pot, newest first.
    @Published var cauldronWagerable: [CauldronMonsterDTO] = []
    /// Published rules (edge, brackets, odds). Fetched once.
    @Published var cauldronConfig: CauldronConfigResponse?
    /// A wager or cash-out is in flight — the UI disables its buttons rather
    /// than letting a second request race the first.
    @Published var cauldronBusy = false

    /// GET /cauldron/config — the published odds. Idempotent; safe to call
    /// on every appearance.
    func loadCauldronConfig() async {
        guard cauldronConfig == nil else { return }
        cauldronConfig = try? await api.fetchCauldronConfig()
    }

    /// GET /cauldron/state — live round, last result, and the wagerable bank.
    ///
    /// This is also how a crash is discovered: the crash point lives on the
    /// server, so the client learns the cauldron blew up by asking.
    @discardableResult
    func refreshCauldron() async -> CauldronRoundDTO? {
        do {
            let state = try await api.fetchCauldronState()
            cauldronRound = state.round
            cauldronLastRound = state.lastRound
            cauldronWagerable = state.wagerable
            backendError = nil
            return state.round
        } catch {
            backendError = error.localizedDescription
            return nil
        }
    }

    /// POST /cauldron/rounds — lock the wager in. Returns the started round,
    /// or nil if the server refused it (already bubbling, monster gone).
    func startCauldronRound(dropIDs: [String]) async -> CauldronRoundDTO? {
        guard !cauldronBusy else { return nil }
        cauldronBusy = true
        defer { cauldronBusy = false }
        do {
            let round = try await api.startCauldronRound(dropIDs: dropIDs)
            cauldronRound = round.isActive ? round : nil
            if !round.isActive { cauldronLastRound = round }
            // The wagered monsters are gone from the bank the moment the
            // round starts — reflect that without waiting for a refresh.
            cauldronWagerable.removeAll { dropIDs.contains($0.id) }
            backendError = nil
            return round
        } catch {
            backendError = error.localizedDescription
            await refreshCauldron()
            return nil
        }
    }

    /// POST /cauldron/rounds/:id/cashout — take the multiplier, if it is
    /// still there. The returned round says what actually happened.
    func cashOutCauldron(roundID: String) async -> CauldronRoundDTO? {
        guard !cauldronBusy else { return nil }
        cauldronBusy = true
        defer { cauldronBusy = false }
        do {
            let posted = try await api.cashOutCauldronRound(roundID: roundID)
            backendError = nil
            return terminalRound(
                CauldronCashOut.resolve(
                    roundId: roundID,
                    posted: posted,
                    liveRound: cauldronRound,
                    lastRound: cauldronLastRound
                )
            )
        } catch {
            // A dropped POST that actually landed is recovered from a fresh
            // state snapshot — the server, not the response, is the verdict.
            let snapshot = await peekCauldronState()
            if let verdict = terminalRound(
                CauldronCashOut.resolve(
                    roundId: roundID,
                    posted: nil,
                    liveRound: snapshot?.round ?? cauldronRound,
                    lastRound: snapshot?.lastRound ?? cauldronLastRound
                )
            ) {
                backendError = nil
                return verdict
            }
            if let snapshot {
                cauldronWagerable = snapshot.wagerable
                if let live = snapshot.round { cauldronRound = live }
                cauldronLastRound = snapshot.lastRound
            }
            backendError = error.localizedDescription
            return nil
        }
    }

    /// GET /cauldron/state without publishing a nil live round, so a pending
    /// cash-out is not swapped for the wager table mid-tap.
    private func peekCauldronState() async -> CauldronStateResponse? {
        try? await api.fetchCauldronState()
    }

    /// Unwraps a terminal cash-out verdict; `stillLive` / `unknown` stay nil
    /// so the view can unfreeze and let the player tap again.
    private func terminalRound(_ verdict: CauldronCashOutVerdict) -> CauldronRoundDTO? {
        switch verdict {
        case .cashedOut(let round), .crashed(let round):
            return round
        case .stillLive, .unknown:
            return nil
        }
    }

    /// Fold a finished round back into the app: the round stops being live,
    /// a won monster joins the collection, and the bank is re-read from the
    /// server rather than guessed at.
    func applyCauldronResult(_ round: CauldronRoundDTO) {
        guard !round.isActive else {
            cauldronRound = round
            return
        }
        cauldronRound = nil
        cauldronLastRound = round
        if round.didCashOut, let reward = round.reward {
            addCauldronReward(reward)
            bumpCounter("stats.cauldronWins")
        } else {
            bumpCounter("stats.cauldronLosses")
        }
        Task { [weak self] in
            await self?.refreshCauldron()
            // The wager destroyed inventory instances, so the Squad tab has
            // to be rebuilt from the server rather than patched locally.
            await self?.refreshInventory(limit: 200)
        }
    }

    /// Adds a monster won from the cauldron to the collection.
    @discardableResult
    func addCauldronReward(_ reward: CauldronMonsterDTO) -> Character {
        let meta = DropMeta(stars: reward.stars, rarity: reward.character.rarity, locked: false)
        var character = Character(
            id: "crate-\(reward.character.id)",
            name: reward.character.name,
            colorHex: reward.character.colorHex,
            imageKey: reward.character.imageKey,
            rarity: Rarity(rawValue: reward.character.rarity) ?? .common,
            baseHealth: reward.character.baseHealth ?? 100,
            baseAttack: reward.character.baseAttack ?? 50,
            baseMana: reward.character.baseMana,
            starLevel: reward.stars,
            bio: reward.character.bio ?? reward.character.flavor,
            dropIDs: [reward.id],
            netWorth: reward.netWorth
        )
        character.dropMeta[reward.id] = meta
        if let index = crateCharacters.firstIndex(where: { $0.id == character.id }) {
            crateCharacters[index].dropIDs.append(reward.id)
            crateCharacters[index].dropMeta[reward.id] = meta
            crateCharacters[index].netWorth += reward.netWorth
            crateCharacters[index].starLevel = max(crateCharacters[index].starLevel, reward.stars)
        } else {
            crateCharacters.append(character)
        }
        if character.rarity >= .rare { grantStreakFreeze() }
        checkAchievements()
        return character
    }


    // MARK: - Monster Casino: Kitchen Mines

    /// The board currently in play, if any. Server-owned.
    @Published var minesRound: MinesRoundDTO?
    /// The last finished board, so a player returning finds out how it went.
    @Published var minesLastRound: MinesRoundDTO?
    /// Monsters that can be wagered, newest first.
    @Published var minesWagerable: [CasinoMonsterDTO] = []
    /// Published board rules. Fetched once.
    @Published var minesConfig: MinesConfigResponse?
    /// A reveal or cash-out is in flight — the UI disables the board rather
    /// than letting a second tap race the first.
    @Published var minesBusy = false

    func loadMinesConfig() async {
        guard minesConfig == nil else { return }
        minesConfig = try? await api.fetchMinesConfig()
    }

    /// GET /mines/state — live board, last result, wagerable bank.
    @discardableResult
    func refreshMines() async -> MinesRoundDTO? {
        do {
            let state = try await api.fetchMinesState()
            minesRound = state.round
            minesLastRound = state.lastRound
            minesWagerable = state.wagerable
            backendError = nil
            return state.round
        } catch {
            backendError = error.localizedDescription
            return nil
        }
    }

    /// POST /mines/rounds — commit the monster and lay the board.
    func startMinesRound(dropID: String, mines: Int) async -> MinesRoundDTO? {
        guard !minesBusy else { return nil }
        minesBusy = true
        defer { minesBusy = false }
        do {
            let round = try await api.startMinesRound(dropID: dropID, mines: mines)
            minesRound = round.isActive ? round : nil
            if !round.isActive { minesLastRound = round }
            // The wager is gone the moment the board is laid.
            minesWagerable.removeAll { $0.id == dropID }
            backendError = nil
            return round
        } catch {
            backendError = error.localizedDescription
            await refreshMines()
            return nil
        }
    }

    /// POST /mines/rounds/:id/reveal — lift one dish.
    func revealMinesTile(roundID: String, tile: Int) async -> MinesRevealResponse? {
        guard !minesBusy else { return nil }
        minesBusy = true
        defer { minesBusy = false }
        do {
            let result = try await api.revealMinesTile(roundID: roundID, tile: tile)
            if result.round.isActive {
                minesRound = result.round
            } else {
                applyMinesResult(result.round)
            }
            backendError = nil
            return result
        } catch {
            backendError = error.localizedDescription
            return nil
        }
    }

    /// POST /mines/rounds/:id/cashout — serve it.
    func cashOutMines(roundID: String) async -> MinesRoundDTO? {
        guard !minesBusy else { return nil }
        minesBusy = true
        defer { minesBusy = false }
        do {
            let round = try await api.cashOutMinesRound(roundID: roundID)
            applyMinesResult(round)
            backendError = nil
            return round
        } catch {
            backendError = error.localizedDescription
            return nil
        }
    }

    /// Fold a finished board back into the app: the round stops being live, a
    /// won monster joins the collection, and the bank is re-read rather than
    /// guessed at.
    func applyMinesResult(_ round: MinesRoundDTO) {
        guard !round.isActive else {
            minesRound = round
            return
        }
        minesRound = nil
        minesLastRound = round
        if round.didServe, let reward = round.reward {
            addCauldronReward(reward)
            bumpCounter("stats.minesWins")
        } else {
            bumpCounter("stats.minesLosses")
        }
        Task { [weak self] in
            await self?.refreshMines()
            // The wager destroyed an inventory instance, so the Squad tab has
            // to be rebuilt from the server rather than patched locally.
            await self?.refreshInventory(limit: 200)
        }
    }


    // MARK: - Monster Casino: Plinko

    /// Monsters that can be dropped, newest first.
    @Published var plinkoWagerable: [CasinoMonsterDTO] = []
    /// The most recent resolved drop.
    @Published var plinkoLastDrop: PlinkoDropDTO?
    /// Recent landings, for the history strip.
    @Published var plinkoRecent: [PlinkoHistoryEntryDTO] = []
    /// Board shape, payout table and published odds. Fetched once.
    @Published var plinkoConfig: PlinkoConfigResponse?
    /// A drop is in flight. Plinko has no mid-round decisions, so this is the
    /// whole of the repeat-input guard: one orb at a time.
    @Published var plinkoBusy = false

    func loadPlinkoConfig() async {
        guard plinkoConfig == nil else { return }
        plinkoConfig = try? await api.fetchPlinkoConfig()
    }

    /// GET /plinko/state — bank plus recent landings.
    func refreshPlinko() async {
        do {
            let state = try await api.fetchPlinkoState()
            plinkoWagerable = state.wagerable
            plinkoRecent = state.recent
            backendError = nil
        } catch {
            backendError = error.localizedDescription
        }
    }

    /// POST /plinko/drops — spend the monster and resolve the drop.
    ///
    /// The result is known the moment this returns; the caller animates it and
    /// only then folds it into the collection, so the reward does not appear
    /// in the squad before the orb has landed.
    func dropPlinko(dropID: String) async -> PlinkoDropDTO? {
        guard !plinkoBusy else { return nil }
        plinkoBusy = true
        defer { plinkoBusy = false }
        do {
            let resolved = try await api.dropPlinko(dropID: dropID)
            // The wager is spent whatever the orb does.
            plinkoWagerable.removeAll { $0.id == dropID }
            backendError = nil
            return resolved
        } catch {
            backendError = error.localizedDescription
            await refreshPlinko()
            return nil
        }
    }

    /// Fold a landed drop into the app, once the animation has finished.
    func applyPlinkoResult(_ resolved: PlinkoDropDTO) {
        plinkoLastDrop = resolved
        if let reward = resolved.reward {
            addCauldronReward(reward)
            bumpCounter("stats.plinkoWins")
        } else {
            bumpCounter("stats.plinkoBusts")
        }
        Task { [weak self] in
            await self?.refreshPlinko()
            // The wager destroyed an inventory instance, so the Squad tab is
            // rebuilt from the server rather than patched locally.
            await self?.refreshInventory(limit: 200)
        }
    }

    // MARK: - Monster Casino: Portal Wheel

    /// Monsters that can be wagered on the wheel, newest first.
    @Published var portalWheelWagerable: [CasinoMonsterDTO] = []
    /// The most recent resolved spin.
    @Published var portalWheelLastSpin: PortalWheelSpinDTO?
    /// Recent spins, for the history strip.
    @Published var portalWheelRecent: [PortalWheelHistoryEntryDTO] = []
    /// The wheel's section layout, published odds and payouts. Fetched once.
    @Published var portalWheelConfig: PortalWheelConfigResponse?
    /// A spin is in flight. The wheel has no mid-round decisions, so this is
    /// the whole of the repeat-input guard: one spin at a time.
    @Published var portalWheelBusy = false

    func loadPortalWheelConfig() async {
        guard portalWheelConfig == nil else { return }
        portalWheelConfig = try? await api.fetchPortalWheelConfig()
    }

    /// GET /portal-wheel/state — bank plus recent spins.
    func refreshPortalWheel() async {
        do {
            let state = try await api.fetchPortalWheelState()
            portalWheelWagerable = state.wagerable
            portalWheelRecent = state.recent
            backendError = nil
        } catch {
            backendError = error.localizedDescription
        }
    }

    /// POST /portal-wheel/spins — commit the monster to a colour and resolve.
    ///
    /// The result is known the moment this returns; the caller spins the wheel
    /// to the section that came back and only then folds the reward in, so a
    /// new monster never appears in the squad before the pointer has stopped.
    func spinPortalWheel(dropID: String, color: String) async -> PortalWheelSpinDTO? {
        guard !portalWheelBusy else { return nil }
        portalWheelBusy = true
        defer { portalWheelBusy = false }
        do {
            let resolved = try await api.spinPortalWheel(dropID: dropID, color: color)
            // The wager is spent whichever colour wins.
            portalWheelWagerable.removeAll { $0.id == dropID }
            backendError = nil
            return resolved
        } catch {
            backendError = error.localizedDescription
            await refreshPortalWheel()
            return nil
        }
    }

    /// Fold a resolved spin into the app, once the animation has finished.
    func applyPortalWheelResult(_ resolved: PortalWheelSpinDTO) {
        portalWheelLastSpin = resolved
        if let reward = resolved.reward {
            addCauldronReward(reward)
            bumpCounter("stats.portalWheelWins")
        } else {
            bumpCounter("stats.portalWheelLosses")
        }
        Task { [weak self] in
            await self?.refreshPortalWheel()
            // The wager destroyed an inventory instance, so the Squad tab is
            // rebuilt from the server rather than patched locally.
            await self?.refreshInventory(limit: 200)
        }
    }

}
