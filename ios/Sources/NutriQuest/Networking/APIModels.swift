import Foundation
import BattleKit

// MARK: - Battle (POST /battle/simulate)

/// Squad member payload the battle route expects: `{ id, name, rarity?, star? }`.
/// The server resolves combat stats and authored moves from its own catalog —
/// the client only identifies which instances it's fielding (final-dev-doc §4).
struct BattleSquadMember: Codable, Sendable {
    let id: String
    let name: String
    let rarity: String
    let star: Int
}

/// Shared battle-result shape (schemas/battle-result.json).
/// Winner "A" = your squad. Events decode straight into BattleKit's
/// `BattleEvent` — the wire shape is the engine's own event schema.
struct ServerBattleResult: Decodable, Sendable {
    let winner: String
    /// Total side-turns played (the engine's `turns`; the field name predates
    /// the turn-based engine and stays for compatibility).
    let rounds: Int
    let events: [BattleEvent]
    /// End-of-battle HP as fractions of effective max HP, in squad order.
    let hpLeftA: [Double]
    let hpLeftB: [Double]
    /// Units that ended at 0 HP — the faint-persistence list.
    let faintedA: [String]
    let faintedB: [String]

    var winnerSide: Int { winner == "A" ? 0 : 1 }
}

/// One member of an opponent's stored squad snapshot, as echoed by
/// /battle/friendly and /battle/ranked. The combat bases travel with it so
/// the replay can draw real HP/mana bars instead of placeholder 100s.
struct ResolvedSquadMember: Decodable, Sendable {
    let id: String
    let name: String
    let star: Int
    let rarity: String
    let baseHealth: Int?
    let baseAttack: Int?
    let baseMana: Int?
}

/// POST /battle/friendly — result vs a friend's stored snapshot, with the
/// snapshot echoed so the client can render the replay.
struct FriendlyBattleResponse: Decodable, Sendable {
    let winner: String
    let rounds: Int
    let events: [BattleEvent]
    let hpLeftA: [Double]
    let hpLeftB: [Double]
    let faintedA: [String]
    let faintedB: [String]
    let opponentId: String
    let opponentSquad: [ResolvedSquadMember]
}

/// POST /battle/ranked — SBMM-resolved match: the authoritative result plus
/// the RR movement, any rank-odds Case the win granted, and the opponent's
/// snapshot squad for replay rendering.
struct RankedBattleResponse: Decodable, Sendable {
    let winner: String
    let rounds: Int
    let events: [BattleEvent]
    let hpLeftA: [Double]
    let hpLeftB: [Double]
    let faintedA: [String]
    let faintedB: [String]
    let rank: RankResultDTO
    /// Rank-odds Case granted by a win; nil on a loss.
    let caseReward: CaseRewardDTO?
    let opponent: RankedOpponentDTO
    let opponentSquad: [ResolvedSquadMember]

    var winnerSide: Int { winner == "A" ? 0 : 1 }
}

struct RankResultDTO: Decodable, Sendable {
    let rr: Int
    /// Signed RR movement this match applied (+ on win, − on loss).
    let delta: Int
    let rank: String
    let rankLabel: String
    let promoted: Bool
    let record: RankedRecordDTO
}

struct RankedRecordDTO: Decodable, Sendable {
    let rankedWins: Int
    let rankedLosses: Int
}

struct CaseRewardDTO: Decodable, Sendable {
    let rarity: String
}

struct RankedOpponentDTO: Decodable, Sendable {
    /// True when the queue was empty and a rank-calibrated bot fought.
    let bot: Bool
    let playerId: String?
}

// MARK: - Interactive battles (begin / commit)
//
// Two-phase spec §4 flow: begin parks the server-resolved matchup and hands
// back the seed + full specs so the client runs the identical deterministic
// engine locally; commit submits the decisions the player made and the
// server replays them — the outcome is what the rules produce.

/// A fully resolved unit as `/battle/*/begin` returns it. `rarity` travels
/// as the tier name; `moves` is the authored moveset the server will replay.
struct BattleUnitSpecDTO: Decodable, Sendable {
    let id: String
    let name: String
    let baseHealth: Double
    let baseAttack: Double
    let star: Int
    let rarity: String
    let baseMana: Double?
    let moves: [BattleMoveSpec]

    /// Engine-ready spec — identical values on both sides of the wire.
    var spec: BattleUnitSpec {
        BattleUnitSpec(
            id: id, name: name, baseHealth: baseHealth, baseAttack: baseAttack,
            rarity: (Rarity(rawValue: rarity) ?? .common).battleRarity,
            star: star, moves: moves, baseMana: baseMana
        )
    }
}

/// POST /battle/ranked/begin and /battle/friendly/begin share this shape.
struct BattleBeginResponse: Decodable, Sendable {
    let matchId: String
    /// Decimal string — JSON can't carry a full UInt64.
    let seed: String
    /// Ranked only: who the SBMM queue found.
    let opponent: RankedOpponentDTO?
    /// Friendly only: the snapshot owner.
    let opponentId: String?
    let yourSquad: [BattleUnitSpecDTO]
    let opponentSquad: [BattleUnitSpecDTO]
}

/// One decision in the commit script — the discriminated-union shape
/// `battleActionSchema` expects on the backend.
enum BattleActionDTO: Encodable, Sendable {
    /// Use moves[moveIndex] of the active unit (consumes the turn).
    case move(Int)
    /// Voluntary switch to squad slot (consumes the turn).
    case switchTo(Int)
    /// Free faint-replacement pick (no turn, no RNG draw).
    case choose(Int)

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .move(let i):
            try c.encode("move", forKey: .type)
            try c.encode(i, forKey: .moveIndex)
        case .switchTo(let i):
            try c.encode("switch", forKey: .type)
            try c.encode(i, forKey: .unitIndex)
        case .choose(let i):
            try c.encode("choose", forKey: .type)
            try c.encode(i, forKey: .unitIndex)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case type, moveIndex, unitIndex
    }
}


// MARK: - Infinite dungeon (backend/src/routes/battle.ts dungeon section)

/// One floor's outcome in a dungeon run feed.
struct DungeonFloorDTO: Decodable, Sendable {
    let floor: Int
    let boss: Bool
    let won: Bool
    let rounds: Int
    let enemies: [String]
    /// Coins paid for clearing this floor (0 when lost).
    let reward: Int
}

struct DungeonRunResponse: Decodable, Sendable {
    let runSeed: String
    let floorsCleared: Int
    let bestFloor: Int
    /// Coins banked this run — kept even on wipe (spec §5).
    let coinsEarned: Int
    /// Wallet balance after the run.
    let coins: Int
    let feed: [DungeonFloorDTO]
}

struct DungeonStateResponse: Decodable, Sendable {
    let bestFloor: Int
    let lastRunAt: String?
}

// MARK: - User (GET /user/:id)

struct UserProfileDTO: Decodable, Sendable {
    let id: String
    let displayName: String
    /// Inert legacy fields — the spec has no XP/levels; kept so older
    /// payloads still decode.
    let level: Int?
    let xp: Int?
    let streakDays: Int?
    let battlesWon: Int?
    var activeCharacterId: String?
    let colorMode: String
    /// Ranked Rating (spec §5).
    let rr: Int?
    let rankedWins: Int?
    let rankedLosses: Int?
    /// Nutrition streak + stored Cookbook Boosts (spec §6).
    let nutritionStreakDays: Int?
    let cookbookBoosts: Int?
}

/// `GET /user/:id` wraps the profile plus its derived rank, record, streak,
/// faint list and today's tasks: `{ "profile": {...}, "rank": {...}, ... }`.
struct UserResponse: Decodable, Sendable {
    let profile: UserProfileDTO
    let rank: RankBlockDTO?
    let record: RecordDTO?
    let streak: StreakDTO?
    /// Character ids currently fainted (recover on daily reset or a
    /// nutrition-task revive).
    let fainted: [String]?
    let tasks: [TaskDTO]?
}

/// Public rank block from the server: RR, derived rank, distance to promote.
struct RankBlockDTO: Decodable, Sendable {
    let rr: Int
    let rank: String
    let rankLabel: String
    /// RR needed to reach the next rank; nil at Diamond.
    let rrToNextRank: Int?
}

struct RecordDTO: Decodable, Sendable {
    let rankedWins: Int
    let rankedLosses: Int
    let winRate: Double
}

struct StreakDTO: Decodable, Sendable {
    let days: Int
    let boosts: Int
    let nextBoostIn: Int
}

// MARK: - Daily tasks (GET /user/tasks/today, POST /user/tasks/:id/claim)

/// One of today's three tasks — one nutrition, one battle, one flex.
struct TaskDTO: Decodable, Sendable, Identifiable {
    let id: String
    let category: String
    let label: String
    /// Whether claiming awards task RR (+5, capped +10/day, never promotes).
    let rrEligible: Bool
    /// True on tasks that only exist when the player opted into watch data —
    /// non-watch players never see them (the server substitutes instead).
    let watchOnly: Bool?
    /// Server-verified completion flag.
    let done: Bool
    let claimed: Bool
}

struct TasksResponse: Decodable, Sendable {
    let day: String
    let tasks: [TaskDTO]
}

/// POST /user/tasks/:taskId/claim result.
struct TaskClaimResult: Decodable, Sendable {
    let taskId: String
    let coins: Int
    let bonusCoins: Int
    let allDone: Bool
    /// Task RR actually applied — 0 for flex tasks, at the daily cap, or at
    /// the top of the current rank.
    let rrApplied: Int
    let rr: Int
    let rank: String
    /// Fainted character revived by a nutrition-task claim, if any.
    let revived: String?
    let streakDays: Int?
    let boostEarned: Bool?
}

// MARK: - Battle history (GET /user/:id/history)

struct BattleHistoryEntry: Decodable, Sendable, Identifiable {
    let id: Int
    let mode: String
    let result: String
    let opponent: String?
    let rrDelta: Int
    let squad: [BattleHistorySquadMember]
    /// Free-form per-mode detail (rounds, floors cleared, coins earned…).
    /// All fields optional — the shape varies by mode.
    let detail: BattleHistoryDetail?
    let at: String
}

struct BattleHistoryDetail: Decodable, Sendable {
    let rounds: Int?
    let floorsCleared: Int?
    let bestFloor: Int?
    let coinsEarned: Int?
    let defended: Bool?
    let caseReward: String?

    enum CodingKeys: String, CodingKey {
        case rounds, floorsCleared, bestFloor, coinsEarned, defended
        case caseReward = "case"
    }
}

struct BattleHistorySquadMember: Decodable, Sendable {
    let id: String
    let name: String
}

struct BattleHistoryResponse: Decodable, Sendable {
    let battles: [BattleHistoryEntry]
}

// MARK: - Vitals (backend/src/vitals — HealthKit snapshots from the watch)

/// One HealthKit snapshot as stored by the backend. All metrics optional —
/// the watch sends whatever HealthKit had at sync time. Numbers arrive as
/// JSON numbers that may carry a fraction, so they decode as Double.
struct VitalsSnapshotDTO: Decodable, Sendable {
    let timestamp: String?
    let heartRateBpm: Double?
    let restingHeartRateBpm: Double?
    let hrvMs: Double?
    let stepsToday: Double?
    let activeCaloriesToday: Double?
    let exerciseMinutesToday: Double?
    let standHoursToday: Double?
}

/// `GET /vitals/latest` — the store entry: when it arrived, the raw snapshot,
/// and the backend's descriptive analysis strings.
struct VitalsLatestResponse: Decodable, Sendable {
    let receivedAt: String?
    let snapshot: VitalsSnapshotDTO
    let analysis: [String: String]?
}

/// `POST /vitals` — acknowledgement plus the same analysis strings.
struct VitalsUploadResponse: Decodable, Sendable {
    let success: Bool
    let message: String?
    let analysis: [String: String]?
}

// MARK: - Loot crates (commit-reveal fairness)

/// Character as returned by the lootbox routes' `characterPayload`:
/// the source-neutral combat shape (Health/Attack, Mana on Epic+) plus
/// presentational extras. Rarity belongs to the instance, never the design.
struct LootCharacterDTO: Decodable, Sendable {
    let id: String
    let name: String
    let colorHex: String
    let rarity: String
    let imageKey: String?
    let tagline: String?
    let baseHealth: Double?
    let baseAttack: Double?
    /// Present only on Epic-and-higher instances.
    let baseMana: Double?
    let isLocked: Bool?
    let rarityLabel: String?
    let rarityColorHex: String?
    let flavor: String?
    let bio: String?
}

/// The mint-time roll units the server records for a drop (anti-cheat
/// audit). `mintSegment` is the 55/27/13/4/1 band-segment pick;
/// `mintPosition` the position inside it. All optional: drops minted before
/// the fields existed, or budget-priced casino rewards, carry -1/none.
struct DropRollsDTO: Decodable, Sendable {
    let rarity: Double?
    let character: Double?
    let mintSegment: Double?
    let mintPosition: Double?
}

struct FairnessDTO: Decodable, Sendable {
    let serverSeedHash: String
    let clientSeed: String
    let nonce: Int
}

/// One resolved drop. `reel`/`reelWinnerIndex` are animation data returned
/// only by the open route.
struct CrateOpenResponse: Decodable, Sendable {
    /// The real, unique server-side drop instance id this pull just minted —
    /// what `/characters/sell` actually wants. Optional only so decoding
    /// never breaks against an older server; every current build sends it.
    let id: String?
    /// Which source produced the mint: a cookbook id, "case:<rarity>",
    /// "scan", "starter-roster", "merge", ...
    let crateId: String
    let character: LootCharacterDTO
    /// The ★1 value rolled at mint — permanent; fusion keeps the max.
    let baseMintValue: Int?
    /// Current net worth: baseMintValue + star bonus.
    let value: Int
    /// Mastery of the minted drop — always 1 on a fresh pull.
    let stars: Int?
    /// Rarity of the Case that produced this mint, when opened via a case.
    let caseRarity: String?
    let rolls: DropRollsDTO?
    let fairness: FairnessDTO?
    let openedAt: String
    let reel: [LootCharacterDTO]?
    let reelWinnerIndex: Int?
    /// Coin balance after the open — cookbook opens are coin-paid.
    let coinBalance: Int?
    /// True when the mint overflowed a full inventory into the mailbox.
    let overflowed: Bool?
    /// True when a Cookbook Boost (×1.15 Rare+ odds) was consumed on this open.
    let boostApplied: Bool?
}

struct CrateOddsDTO: Decodable, Sendable {
    let rarity: String
    let label: String
    let colorHex: String
    let tierChance: Double
    let oneIn: Int
    let characterCount: Int?
    let perCharacterChance: Double?
}

/// `GET /lootbox/cookbooks` — the Cookbooks, the only purchasable loot
/// containers (spec §3). `price` is in coins; `contents` is included by the
/// single-cookbook endpoint (rarity is rolled per mint).
struct CookbookDTO: Decodable, Sendable, Identifiable {
    let id: String
    let name: String
    let description: String
    let price: Int
    let odds: [CrateOddsDTO]
    let contents: [LootCharacterDTO]?
}

struct CookbooksResponse: Decodable, Sendable {
    let cookbooks: [CookbookDTO]
}

struct InventoryItemDTO: Decodable, Sendable, Identifiable {
    let id: String
    let crateId: String
    let character: LootCharacterDTO
    /// Current net worth: baseMintValue + star bonus.
    let value: Int
    /// The ★1 value rolled at mint — permanent, inherited by fusion.
    let baseMintValue: Int?
    let stars: Int?
    let lockedBy: String?
    let fairness: FairnessDTO?
    let openedAt: String

    var isStaked: Bool { lockedBy != nil && !(lockedBy ?? "").isEmpty }
}

struct InventoryResponse: Decodable, Sendable {
    let count: Int
    let totalValue: Int
    let items: [InventoryItemDTO]
    let mailbox: MailboxDTO?
    let cases: [PendingCaseDTO]?
}

/// Rewards that arrived while the inventory was full — never silently lost.
struct MailboxDTO: Decodable, Sendable {
    let count: Int
    let items: [InventoryItemDTO]
}

/// A rank-granted Case waiting to be opened (spec §5 ranked rewards).
struct PendingCaseDTO: Decodable, Sendable, Identifiable, Equatable {
    var id: String { caseId }
    let caseId: String
    let rarity: String
    let source: String
    let createdAt: String
}

struct PendingCasesResponse: Decodable, Sendable {
    let cases: [PendingCaseDTO]
}

/// `POST /lootbox/mailbox/claim` — moves overflow drops into the inventory.
struct MailboxClaimResponse: Decodable, Sendable {
    let claimed: [InventoryItemDTO]
    let remaining: Int
    let count: Int
    let mailboxCount: Int
}

/// `POST /characters/merge` — three same-character/rarity/star copies fused
/// into one instance at the next star.
struct MergeResponseDTO: Decodable, Sendable {
    struct From: Decodable, Sendable {
        let star: Int
        let count: Int
    }
    struct To: Decodable, Sendable {
        let star: Int
        let rarity: String
        let value: Int
        /// Preview of the fused unit's Effective Attack (base × rarity × star).
        let attack: Double?
    }
    let merged: InventoryItemDTO
    let consumedIds: [String]
    let from: From
    let to: To
}

/// `GET /characters/catalog` — the 14 authored characters, Pokédex-style.
/// The master record: permanent id, display name, combat bases, the 3
/// authored standard moves + the Mana Special, art reference and lore.
struct CharacterCatalogEntryDTO: Decodable, Sendable {
    let id: String
    let name: String
    let colorHex: String
    let tagline: String
    let bio: String
    let baseHealth: Double
    let baseAttack: Double
    /// The Mana pool the Special draws on — only meaningful at Epic+.
    let baseMana: Double?
    let moves: [CatalogMoveDTO]
    let special: CatalogMoveDTO?
    let image: CatalogImageDTO?

    /// The moveset as the engine consumes it: three standards, Special last.
    var engineMoves: [BattleMoveSpec] {
        moves.map { $0.engineMove(kind: .standard) }
            + (special.map { [$0.engineMove(kind: .special)] } ?? [])
    }
}

/// An authored move as the catalog serves it (backend moveSchema).
struct CatalogMoveDTO: Decodable, Sendable {
    let id: String
    let name: String
    let power: Double
    let accuracy: Double
    let statusEffect: String?
    let statusChance: Double?
    let duration: Int?
    let manaCost: Double
    let description: String?

    /// Same move in the engine's shape — identical fields on the wire.
    func engineMove(kind: BattleMoveSpec.Kind) -> BattleMoveSpec {
        BattleMoveSpec(
            id: id, name: name, kind: kind, power: power, accuracy: accuracy,
            manaCost: manaCost,
            statusEffect: statusEffect.flatMap(StatusEffectID.init(rawValue:)),
            statusChance: statusChance, duration: duration, description: description
        )
    }
}

/// Art resolution from `imageFor()` — a file under /assets when it exists,
/// else the generated-art route.
struct CatalogImageDTO: Decodable, Sendable {
    let imageKey: String
    let file: String?
    let variant: String
    let url: String
}

struct CharacterCatalogResponse: Decodable, Sendable {
    let catalog: [CharacterCatalogEntryDTO]
}

struct CoinsResponse: Decodable, Sendable {
    let balance: Int
}

struct SellResponse: Decodable, Sendable {
    let coins: Int
    let balance: Int
}

// MARK: - Leaderboard (GET /user/leaderboard)

/// One leaderboard row. Server ordering is fixed by spec §6: RR desc, then
/// ranked wins, then win rate — `rank` is the position, `rankLabel` the tier.
struct LeaderboardEntry: Decodable, Sendable, Identifiable {
    let rank: Int
    let id: String
    let displayName: String
    let rr: Int
    let rankLabel: String
    let rankedWins: Int
    let rankedLosses: Int
    let winRate: Double
    let isYou: Bool
}

struct LeaderboardResponse: Decodable, Sendable {
    let entries: [LeaderboardEntry]
}

/// GET /lootbox/fairness — current commit-reveal commitment + retired seeds.
struct FairnessResponse: Decodable, Sendable {
    let current: FairnessSeedDTO
    let retired: [FairnessSeedDTO]
    let howItWorks: String?
}

/// One seed pair (current or retired). `serverSeed` is nil for the current
/// pair (not yet revealed) and non-nil for retired pairs.
struct FairnessSeedDTO: Decodable, Sendable {
    let serverSeedHash: String
    let serverSeed: String?
    let clientSeed: String
    let nonce: Int
    let createdAt: String
    let retiredAt: String?
}

/// POST /lootbox/fairness/rotate — reveals old seed, commits new one.
struct RotateSeedResponse: Decodable, Sendable {
    let revealed: FairnessSeedDTO
    let current: FairnessSeedDTO
}

// MARK: - Journey (GET /user/:id/journey)

struct JourneySummary: Decodable, Sendable {
    let totalScans: Int
    let totalDrops: Int
    let totalCharacters: Int
    let totalLootValue: Int
    let totalVitalsSnapshots: Int
}

struct JourneyBucket: Decodable, Sendable {
    let date: String
    let count: Int
}

struct JourneyDistribution: Decodable, Sendable {
    let rarity: String
    let count: Int
}

struct JourneyVitalsPoint: Decodable, Sendable {
    let date: String
    let steps: Int?
    let activeCalories: Int?
    let heartRate: Double?
}

struct JourneyCollection: Decodable, Sendable {
    let byRarity: [JourneyDistribution]
}

struct JourneyTimeline: Decodable, Sendable {
    let scansByDay: [JourneyBucket]
    let dropsByDay: [JourneyBucket]
}

/// One completed workout as the server stored it from a vitals upload.
/// `start`/`end` stay Strings for the same reason as `CasinoTrendPoint.bucket`.
struct JourneyWorkout: Decodable, Sendable, Identifiable {
    let activityType: String
    let start: String
    let end: String
    let durationMinutes: Double
    let activeCalories: Double?
    let distanceMeters: Double?
    let averageHeartRateBpm: Double?
    let maxHeartRateBpm: Double?

    var id: String { "\(activityType)|\(start)" }
    var startDate: Date? { CasinoTrendPoint.parse(start) }
}

/// One calendar day (`date` is YYYY-MM-DD) of health activity.
struct JourneyActivityDay: Decodable, Sendable, Identifiable {
    let date: String
    let workouts: [JourneyWorkout]
    let workoutMinutes: Int
    let workoutCalories: Int
    let steps: Int?
    let activeCalories: Int?
    let exerciseMinutes: Int?

    var id: String { date }
}

struct JourneyActivity: Decodable, Sendable {
    let byDay: [JourneyActivityDay]
}

struct JourneyResponse: Decodable, Sendable {
    let profile: UserProfileDTO
    let summary: JourneySummary
    let collection: JourneyCollection
    let timeline: JourneyTimeline
    let recentDrops: [InventoryItemDTO]
    let vitals: [JourneyVitalsPoint]
    /// Absent from servers that predate the Journey calendar.
    let activity: JourneyActivity?
}

// MARK: - Promo codes

struct PromoRedeemResponse: Decodable, Sendable {
    let result: PromoReward
}

struct PromoReward: Decodable, Sendable {
    /// "coins:<n>" or "case:<rarity>" — the reward descriptor that redeemed.
    let reward: String
    /// Present on coin rewards: the wallet after crediting.
    let coinBalance: Int?
    /// Present on case rewards: the Case now pending in the inventory.
    let grantedCase: PendingCaseDTO?

    private enum CodingKeys: String, CodingKey {
        case reward, coinBalance
        case grantedCase = "case"
    }
}

// MARK: - Barcode scan (the only mint path)
//
//   POST /scan  { barcode } -> ScanResultDTO
//
// The server fetches nutrition from Open Food Facts itself (the client only
// sends the digits), scores it holistically, and — the FIRST time this user
// ever scans that barcode — mints a ★1 catalog monster. Re-scans log the
// meal and count for tasks but never mint again; `duplicate` tells the UI
// which case it's looking at.

/// The per-100g nutrition snapshot the mint was generated from — also the
/// anti-cheat record the server persists in scan_mint.
struct ScanNutritionDTO: Decodable, Sendable {
    let calories: Double?
    let proteinG: Double?
    let carbsG: Double?
    let fatG: Double?
    let fiberG: Double?
    let sugarG: Double?
    let sodiumMg: Double?
    let satFatG: Double?
}

/// Proof a monster was minted this scan — absent on `duplicate` responses.
struct ScanMintDTO: Decodable, Sendable {
    let dropId: String
    let netWorth: Int
    let stars: Int
}

/// `POST /scan` — barcode → nutrition → (once ever) a monster.
struct ScanResultDTO: Decodable, Sendable {
    let barcode: String
    let foodName: String
    /// 0–100 holistic NutritionScore; tilts the rarity roll.
    let nutritionScore: Double?
    /// The minted catalog instance — present only on the first-ever scan.
    let summonedCharacter: LootCharacterDTO?
    let nutrition: ScanNutritionDTO?
    /// True on every scan after the first for this barcode.
    let duplicate: Bool
    let mealId: String
    let mint: ScanMintDTO?
}

struct ScanResponseEnvelope: Decodable, Sendable {
    let result: ScanResultDTO
}

// MARK: - Dish photo scan (no barcode)
//
// Two steps, mirroring backend/src/routes/scan.ts:
//   POST /scan/photo/analyze  -> DishAnalysisDTO (a draft, nothing minted)
//   POST /scan/photo/confirm  -> DishConfirmResult (a meal log, nothing minted)
// The user reviews and corrects the draft in between. A photographed plate
// can NEVER mint a monster — barcode is the only food path that can.

/// One food identified on the plate, with its own portion and nutrients.
/// Nutrient figures are absolute for `portionG` grams — not per 100 g.
struct DishItemDTO: Decodable, Sendable, Identifiable, Equatable {
    let id: String
    let name: String
    let portionG: Double
    let portionLabel: String
    let calories: Double
    let proteinG: Double
    let carbsG: Double
    let fatG: Double
    let fiberG: Double
    let sugarG: Double
    let sodiumMg: Double
    let micronutrients: [String]
    let foodGroup: String
    /// 0...1 — how sure the analysis is about this item.
    let confidence: Double
}

/// Plate-level sums. Always recomputed server-side.
struct DishTotalsDTO: Decodable, Sendable, Equatable {
    let portionG: Double
    let calories: Double
    let proteinG: Double
    let carbsG: Double
    let fatG: Double
    let fiberG: Double
    let sugarG: Double
    let sodiumMg: Double
    let micronutrients: [String]
    /// Share of the six tracked micronutrients present, 0...1.
    let microScore: Double
    let foodGroups: [String]
    let dominantFoodGroup: String
}

/// A draft breakdown awaiting the user's confirmation.
struct DishAnalysisDTO: Decodable, Sendable, Equatable, Identifiable {
    var id: String { analysisId }
    let analysisId: String
    let dishName: String
    let colorHex: String
    let nova: Int
    let items: [DishItemDTO]
    let totals: DishTotalsDTO
    let confidence: Double
    /// True when the estimate is shaky enough to warrant a careful look.
    let lowConfidence: Bool
}

/// What `POST /scan/photo/confirm` returns once the plate is locked in:
/// a meal log entry — never a monster. `flagged` means the estimate was
/// low-confidence or the confirmed totals were implausible; the app can
/// surface it as "estimate — worth a second look" on the log.
struct DishConfirmResult: Decodable, Sendable {
    let source: String?
    let foodName: String
    let mealId: String
    let items: [DishItemDTO]
    let nutrition: DishTotalsDTO
    let lowConfidence: Bool?
    let implausible: Bool?
    let flagged: Bool?
}

/// A single correction from the review screen. The server only honours
/// rename / re-portion / remove — nutrient density always comes from its own
/// analysis, so a client can never post arbitrary macros.
struct DishItemEdit: Encodable, Sendable {
    let id: String
    var name: String?
    var portionG: Double?
    var removed: Bool?
}

// MARK: - Cauldron Crash (GET/POST /cauldron)

/// One owned monster, as the casino sees it: an instance you can wager, with
/// the net worth it contributes to the pot. Shared by every game at the
/// table — the shape is the same whether it goes in a cauldron or on a board.
struct CasinoMonsterDTO: Decodable, Sendable, Identifiable, Equatable {
    let id: String
    let character: LootCharacterDTO
    /// The ★1 value rolled at mint — permanent, inherited by fusion.
    let baseMintValue: Int?
    let stars: Int
    let netWorth: Int
    let acquiredAt: String
    /// Present on a reward: the cash-out budget it was bought with.
    let budget: Int?

    static func == (lhs: CasinoMonsterDTO, rhs: CasinoMonsterDTO) -> Bool { lhs.id == rhs.id }
}

/// Cauldron Crash's name for the same payload.
typealias CauldronMonsterDTO = CasinoMonsterDTO

/// A round. `crashMultiplier` is absent while the round is live — the server
/// does not send it until the cauldron has already blown up or been emptied.
struct CauldronRoundDTO: Decodable, Sendable, Equatable {
    let roundId: String
    let status: String
    let startedAt: String
    let serverTime: String
    let wager: [CauldronMonsterDTO]
    let startingNetWorth: Int
    let startingRarity: String
    let multiplier: Double
    let netWorth: Int
    let rarity: String
    let intensity: String
    let growthRate: Double
    let crashMultiplier: Double?
    let cashOutMultiplier: Double?
    let finalNetWorth: Int?
    let lostNetWorth: Int?
    let reward: CauldronMonsterDTO?
    let completedAt: String?

    var isActive: Bool { status == "ACTIVE" }
    var didCashOut: Bool { status == "CASHED_OUT" }
    var didCrash: Bool { status == "CRASHED" }

    static func == (lhs: CauldronRoundDTO, rhs: CauldronRoundDTO) -> Bool {
        lhs.roundId == rhs.roundId && lhs.status == rhs.status
    }
}

struct CauldronStateResponse: Decodable, Sendable {
    let round: CauldronRoundDTO?
    let lastRound: CauldronRoundDTO?
    let wagerable: [CauldronMonsterDTO]
    let serverTime: String
}

struct CauldronRoundResponse: Decodable, Sendable {
    let round: CauldronRoundDTO
}

struct CauldronRarityRangeDTO: Decodable, Sendable, Identifiable {
    let rarity: String
    let label: String
    let colorHex: String
    let min: Int
    /// nil for the open-ended top bracket.
    let max: Int?

    var id: String { rarity }
}

struct CauldronOddsDTO: Decodable, Sendable {
    let multiplier: Double
    let chance: Double
}

struct CauldronConfigResponse: Decodable, Sendable {
    let houseEdge: Double
    let minWagerMonsters: Int
    let maxWagerMonsters: Int
    let growthRate: Double
    let rarityRanges: [CauldronRarityRangeDTO]
    let survivalOdds: [CauldronOddsDTO]
    let howItWorks: String
}

// MARK: - Kitchen Mines (GET/POST /mines)

/// What one more safe dish would be worth. Never says which dish.
struct MinesNextDTO: Decodable, Sendable, Equatable {
    let multiplier: Double
    let netWorth: Int
    let rarity: String
    /// Chance the next single pick is safe. Published — it is not a secret.
    let safeChance: Double
}

/// A board. `layout` is absent while the round is live: where the mines are is
/// the one thing the server does not tell you until it no longer matters.
struct MinesRoundDTO: Decodable, Sendable, Equatable, Identifiable {
    let roundId: String
    let status: String
    let startedAt: String
    let serverTime: String
    let wager: CasinoMonsterDTO
    let wagerValue: Int
    let mines: Int
    let safeDishes: Int
    /// Safe tiles turned over, in the order they were picked.
    let revealed: [Int]
    let picks: Int
    let multiplier: Double
    let netWorth: Int
    let rarity: String
    let heat: String
    let cleared: Bool
    let next: MinesNextDTO?
    /// Disclosed only once the round is over.
    let layout: [Int]?
    let cashOutMultiplier: Double?
    let finalNetWorth: Int?
    let lostNetWorth: Int?
    let reward: CasinoMonsterDTO?
    let completedAt: String?

    var id: String { roundId }
    var isActive: Bool { status == "ACTIVE" }
    var didServe: Bool { status == "SERVED" }
    var didBurn: Bool { status == "BURNT" }

    static func == (lhs: MinesRoundDTO, rhs: MinesRoundDTO) -> Bool {
        lhs.roundId == rhs.roundId && lhs.status == rhs.status && lhs.picks == rhs.picks
    }
}

struct MinesStateResponse: Decodable, Sendable {
    let round: MinesRoundDTO?
    let lastRound: MinesRoundDTO?
    let wagerable: [CasinoMonsterDTO]
    let serverTime: String
}

struct MinesRoundResponse: Decodable, Sendable {
    let round: MinesRoundDTO
}

/// The answer to lifting one dish, plus the board it left behind.
struct MinesRevealResponse: Decodable, Sendable {
    let tile: Int
    let safe: Bool
    let round: MinesRoundDTO
}

struct MinesConfigResponse: Decodable, Sendable {
    let houseEdge: Double
    let rows: Int
    let columns: Int
    let tileCount: Int
    let minMines: Int
    let maxMines: Int
    let minePresets: [Int]
    let rarityRanges: [CauldronRarityRangeDTO]
    let howItWorks: String
}

/// One rung of the payout ladder for a chosen mine count.
struct MinesPayoutRungDTO: Decodable, Sendable, Identifiable {
    let picks: Int
    let multiplier: Double
    let survivalChance: Double

    var id: Int { picks }
}

struct MinesPayoutsResponse: Decodable, Sendable {
    let mines: Int
    let safeDishes: Int
    let rungs: [MinesPayoutRungDTO]
}

// MARK: - Plinko (GET/POST /plinko)

/// One landing slot, with the odds behind it.
struct PlinkoSlotDTO: Decodable, Sendable, Identifiable {
    let slot: Int
    let multiplier: Double
    /// Distinct paths into this slot, out of 4096.
    let paths: Int
    let probability: Double
    /// bust | loss | even | win | jackpot
    let tier: String

    var id: Int { slot }
}

/// A resolved drop.
///
/// `path` is the sequence of left/right decisions the server actually rolled,
/// sent so the client can animate the orb along the route that decided the
/// result rather than inventing one that happens to end in the same place.
struct PlinkoDropDTO: Decodable, Sendable, Identifiable, Equatable {
    let dropId: String
    let wager: CasinoMonsterDTO
    let wagerValue: Int
    let path: [Bool]
    let slot: Int
    let multiplier: Double
    let tier: String
    let finalNetWorth: Int
    /// nil when the orb busted — there is no reward band for nothing.
    let rarity: String?
    let busted: Bool
    let reward: CasinoMonsterDTO?
    let createdAt: String

    var id: String { dropId }

    static func == (lhs: PlinkoDropDTO, rhs: PlinkoDropDTO) -> Bool { lhs.dropId == rhs.dropId }
}

/// One line of the history strip.
struct PlinkoHistoryEntryDTO: Decodable, Sendable, Identifiable {
    let dropId: String
    let slot: Int
    let multiplier: Double
    let finalNetWorth: Int
    let createdAt: String

    var id: String { dropId }
}

struct PlinkoStateResponse: Decodable, Sendable {
    let wagerable: [CasinoMonsterDTO]
    let lastDrop: PlinkoDropDTO?
    let recent: [PlinkoHistoryEntryDTO]
    let serverTime: String
}

struct PlinkoDropResponse: Decodable, Sendable {
    let drop: PlinkoDropDTO
}

struct PlinkoConfigResponse: Decodable, Sendable {
    let houseEdge: Double
    /// What the payout table actually charges, which should match `houseEdge`.
    let actualHouseEdge: Double
    let expectedMultiplier: Double
    let pegRows: Int
    let slotCount: Int
    let totalPaths: Int
    let multipliers: [Double]
    let slots: [PlinkoSlotDTO]
    let rarityRanges: [CauldronRarityRangeDTO]
    let howItWorks: String
}

// MARK: - Portal Wheel (GET/POST /portal-wheel)

/// One portal colour, with the sections behind it.
///
/// Everything here is derived server-side from the wheel's section layout, so
/// the wedges drawn on screen and the odds printed beside them come from the
/// same source. `sectionIndexes` is what lets the wheel highlight exactly the
/// wedges a bet covers rather than guessing from a count.
struct PortalColorDTO: Decodable, Sendable, Identifiable {
    /// blue | red | yellow | green
    let color: String
    let label: String
    let colorHex: String
    let sections: Int
    let totalSections: Int
    let sectionIndexes: [Int]
    let probability: Double
    let multiplier: Double
    /// What this colour actually charges once its payout is floored.
    let houseEdge: Double

    var id: String { color }
}

/// A resolved spin.
///
/// `section` is the wedge the pointer stopped on, sent so the client can spin
/// the wheel to that exact section. A colour alone would leave the animation
/// free to stop on any wedge of that colour, which is more latitude than a
/// rendering of a result should have.
struct PortalWheelSpinDTO: Decodable, Sendable, Identifiable, Equatable {
    let spinId: String
    let wager: CasinoMonsterDTO
    let wagerValue: Int
    /// The colour that was bet.
    let pick: String
    let section: Int
    let winningColor: String
    let won: Bool
    /// What `pick` was quoted at. Paid only on a win.
    let multiplier: Double
    let finalNetWorth: Int
    /// nil on a wrong colour — there is no reward band for nothing.
    let rarity: String?
    let reward: CasinoMonsterDTO?
    let createdAt: String

    var id: String { spinId }

    static func == (lhs: PortalWheelSpinDTO, rhs: PortalWheelSpinDTO) -> Bool {
        lhs.spinId == rhs.spinId
    }
}

/// One line of the history strip.
struct PortalWheelHistoryEntryDTO: Decodable, Sendable, Identifiable {
    let spinId: String
    let pick: String
    let winningColor: String
    let won: Bool
    let multiplier: Double
    let finalNetWorth: Int
    let createdAt: String

    var id: String { spinId }
}

struct PortalWheelStateResponse: Decodable, Sendable {
    let wagerable: [CasinoMonsterDTO]
    let lastSpin: PortalWheelSpinDTO?
    let recent: [PortalWheelHistoryEntryDTO]
    let serverTime: String
}

struct PortalWheelSpinResponse: Decodable, Sendable {
    let spin: PortalWheelSpinDTO
}

struct PortalWheelConfigResponse: Decodable, Sendable {
    let houseEdge: Double
    /// The worst edge any single colour charges, once payouts are floored.
    let worstHouseEdge: Double
    let totalSections: Int
    let wagerMonsters: Int
    /// The wheel itself, clockwise from the pointer: one colour per section.
    let layout: [String]
    let colors: [PortalColorDTO]
    let rarityRanges: [CauldronRarityRangeDTO]
    let howItWorks: String
}

// MARK: - Trends (backend/src/routes/trends.ts)
//
// Read side of the TimescaleDB continuous aggregates. Every series here is
// pre-rolled hourly or daily by the database, so the payload stays the same
// size whether the player started yesterday or three months ago.

/// Envelope every /trends/* route answers with. `available` is false when the
/// backend has no Postgres configured — an empty chart, not an error.
struct TrendEnvelope<Point: Decodable & Sendable>: Decodable, Sendable {
    let available: Bool
    /// "replica" once a Tiger Cloud read replica is serving analytics, else
    /// "primary", else "none". Useful for a debug overlay; ignored by the UI.
    let source: String
    let points: [Point]
}

/// One hour of casino outcomes for a single game mode.
///
/// `bucket` stays a String rather than a Date on purpose: the shared
/// JSONDecoder uses the default date strategy (numeric), and the backend sends
/// ISO-8601 with fractional seconds, which `.iso8601` also rejects. Parsing
/// here keeps the decoder untouched for every other DTO.
struct CasinoTrendPoint: Decodable, Sendable, Identifiable {
    let bucket: String
    let mode: String
    let plays: Int
    let wagered: Int
    let netChange: Int
    let wins: Int

    var id: String { "\(mode)-\(bucket)" }

    /// Parsed bucket start, tolerant of the fractional seconds Postgres emits.
    var bucketDate: Date? { Self.parse(bucket) }

    private static let withFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let plain = ISO8601DateFormatter()

    static func parse(_ raw: String) -> Date? {
        withFraction.date(from: raw) ?? plain.date(from: raw)
    }

    /// Wins as a share of plays in this bucket, or nil when nothing was played.
    var winRate: Double? {
        plays > 0 ? Double(wins) / Double(plays) : nil
    }
}

typealias CasinoTrendResponse = TrendEnvelope<CasinoTrendPoint>
