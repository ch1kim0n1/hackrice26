import Foundation

// MARK: - Battle (POST /battle/simulate)

/// Squad member payload the battle route expects:
/// `{ id, name, statType, rarity }`.
///
/// `rarity` was previously omitted, so the server scaled every unit as common
/// and a Legendary fought identically to a Common. Since the server is
/// authoritative for outcomes (docs/BATTLE-SYSTEM.md §5), that silently
/// discarded rarity from combat entirely.
struct BattleSquadMember: Codable, Sendable {
    let id: String
    let name: String
    let statType: String
    let rarity: String
}

struct BattleSimulateRequest: Encodable {
    let yourSquad: [BattleSquadMember]
    let opponentSquad: [BattleSquadMember]
    let seed: UInt64
}

/// One event from the server's authoritative replay. Mirrors the objects
/// emitted by backend/src/routes/battle.ts `simulate()`.
enum ServerBattleEvent: Decodable, Sendable {
    case battleStart(seed: UInt64)
    case roundStart(round: Int)
    case attack(attackerID: String, defenderID: String, damage: Int, crit: Bool, move: String?, typeMod: Double?)
    case miss(attackerID: String, defenderID: String?)
    case faint(unitID: String)
    case roundEnd(round: Int)
    case victory(winnerSide: Int, rounds: Int)

    private enum Keys: String, CodingKey {
        case event, seed, round, attacker, defender, damage, crit, unit, winner, rounds, move, typeMod
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        switch try c.decode(String.self, forKey: .event) {
        case "battleStart":
            let seedString = try c.decode(String.self, forKey: .seed)
            self = .battleStart(seed: UInt64(seedString) ?? 0)
        case "roundStart":
            self = .roundStart(round: try c.decode(Int.self, forKey: .round))
        case "attack":
            self = .attack(
                attackerID: try c.decode(String.self, forKey: .attacker),
                defenderID: try c.decode(String.self, forKey: .defender),
                damage: try c.decode(Int.self, forKey: .damage),
                crit: try c.decode(Bool.self, forKey: .crit),
                // Presentational parity fields (QA B-004); absent from older
                // server builds, so optional.
                move: try? c.decode(String.self, forKey: .move),
                typeMod: try? c.decode(Double.self, forKey: .typeMod)
            )
        case "miss":
            self = .miss(
                attackerID: try c.decode(String.self, forKey: .attacker),
                defenderID: try? c.decode(String.self, forKey: .defender)
            )
        case "faint":
            self = .faint(unitID: try c.decode(String.self, forKey: .unit))
        case "roundEnd":
            self = .roundEnd(round: try c.decode(Int.self, forKey: .round))
        case "victory":
            let winner = try c.decode(String.self, forKey: .winner)
            self = .victory(winnerSide: winner == "A" ? 0 : 1, rounds: try c.decode(Int.self, forKey: .rounds))
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .event, in: c, debugDescription: "Unknown battle event '\(other)'")
        }
    }
}

/// Server response from `POST /battle/simulate`. Winner "A" = your squad.
struct ServerBattleResult: Decodable, Sendable {
    let winner: String
    let rounds: Int
    let events: [ServerBattleEvent]

    var winnerSide: Int { winner == "A" ? 0 : 1 }
}

/// POST /battle/async/challenge — result vs a friend's stored snapshot, with
/// the snapshot echoed so the client can rebuild the replay.
struct AsyncChallengeResponse: Decodable, Sendable {
    let winner: String
    let rounds: Int
    let events: [ServerBattleEvent]
    let opponentId: String
    let opponentSquad: [BattleSquadMember]
}

/// One "your squad was challenged" feed item (GET /battle/async/notices).
struct AsyncNoticeDTO: Decodable, Sendable {
    let challengerId: String
    let challengerName: String
    /// true = your stored squad defended successfully.
    let defendedWin: Bool
    let rounds: Int
    let at: String
}

struct AsyncNoticesResponse: Decodable, Sendable {
    let notices: [AsyncNoticeDTO]
}

// MARK: - Infinite dungeon (backend/src/routes/battle.ts dungeon section)

/// One floor's outcome in a dungeon run feed.
struct DungeonFloorDTO: Decodable, Sendable {
    let floor: Int
    let boss: Bool
    let won: Bool
    let rounds: Int
    let enemies: [String]
}

struct DungeonRunResponse: Decodable, Sendable {
    let runSeed: String
    let floorsCleared: Int
    let bestFloor: Int
    let keysEarned: Int
    let keys: Int
    let pendingIdleKeys: Int
    let feed: [DungeonFloorDTO]
}

struct DungeonStateResponse: Decodable, Sendable {
    let bestFloor: Int
    let lastRunAt: String?
    let pendingIdleKeys: Int
}

struct DungeonClaimResponse: Decodable, Sendable {
    let claimed: Int
    let keys: Int
}

// MARK: - User (GET /user/:id)

struct UserProfileDTO: Decodable, Sendable {
    let id: String
    let displayName: String
    let level: Int
    let xp: Int?
    let streakDays: Int
    let battlesWon: Int
    var activeCharacterId: String?
    let colorMode: String
}

/// `GET /user/:id` wraps the profile: `{ "profile": {...} }`.
struct UserResponse: Decodable, Sendable {
    let profile: UserProfileDTO
    let progression: XPProgression?
    /// Present once the player touches their profile — comeback crate status.
    let comeback: ComebackDTO?
}

struct ComebackDTO: Decodable, Sendable {
    /// A welcome-back crate is pending and claimable.
    let eligible: Bool
    let daysAway: Int
}

/// Server-derived XP state — level, progress into the current level, and
/// the cost of the next one. All derived from lifetime xp server-side.
struct XPProgression: Decodable, Sendable {
    let level: Int
    let xp: Int
    let xpIntoLevel: Int
    let xpForLevel: Int
    let progress: Double   // 0...1
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

// MARK: - Loot crates (commit-reveal fairness)

/// Character as returned by the lootbox routes' `characterPayload`:
/// the core fields plus presentational extras.
struct LootCharacterDTO: Decodable, Sendable {
    let id: String
    let name: String
    let colorHex: String
    let rarity: String
    let statType: String
    let isLocked: Bool?
    let rarityLabel: String?
    let rarityColorHex: String?
    let flavor: String?
    /// Set for dish-photo characters — drives the procedural artwork so a
    /// salad and a steak don't render as the same silhouette.
    let foodGroup: String?
}

struct DropRollsDTO: Decodable, Sendable {
    let rarity: Double
    let character: Double
    let power: Double
    let shiny: Double
}

struct FairnessDTO: Decodable, Sendable {
    let serverSeedHash: String
    let clientSeed: String
    let nonce: Int
}

/// One resolved drop. `reel`/`reelWinnerIndex` are animation data returned
/// only by the open route.
/// Pity counters — opens since the last Epic+/Legendary+ pull, and how many
/// opens remain until each guarantee forces a drop.
struct PityDTO: Decodable, Sendable {
    let sinceEpic: Int
    let sinceLegendary: Int
    let epicIn: Int
    let legendaryIn: Int
}

struct CrateOpenResponse: Decodable, Sendable {
    /// The real, unique server-side drop instance id this pull just minted —
    /// what `/characters/sell` actually wants. Optional only so decoding
    /// never breaks against an older server; every current build sends it.
    let id: String?
    let crateId: String
    let character: LootCharacterDTO
    let power: Double
    let powerLabel: String
    let shiny: Bool
    let value: Int
    let rolls: DropRollsDTO?
    /// Set when the pity guarantee lifted the rolled tier.
    let pityForced: String?
    let fairness: FairnessDTO
    let openedAt: String
    let reel: [LootCharacterDTO]?
    let reelWinnerIndex: Int?
    /// Absent on a shop-case open (POST /lootbox/shop-cases/:id/open) — that
    /// route is paid in coins and never touches keys.
    let keysRemaining: Int?
    /// Set only on a coin-paid open.
    let coinsSpent: Int?
    let coinBalance: Int?
    /// Mastery of the minted drop — always 1 on a fresh pull; optional so
    /// decoding never breaks against an older server.
    let stars: Int?
    let pity: PityDTO?
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

struct CrateSummaryDTO: Decodable, Sendable {
    let id: String
    let name: String
    let description: String
    let keyCost: Int
    let characterCount: Int
    let odds: [CrateOddsDTO]
    let pity: PityDTO?
}

struct CratesResponse: Decodable, Sendable {
    let crates: [CrateSummaryDTO]
}

/// One daily quest with server-verified progress (GET /user/quests/today).
struct DailyQuestDTO: Decodable, Sendable {
    let id: String
    let label: String
    let kind: String
    let target: Int
    let reward: Int
    let progress: Int
    let done: Bool
    let claimed: Bool
}

struct DailyQuestsResponse: Decodable, Sendable {
    let day: String
    let quests: [DailyQuestDTO]
}

struct ClaimQuestResponse: Decodable, Sendable {
    let keys: Int
}

struct InventoryItemDTO: Decodable, Sendable, Identifiable {
    let id: String
    let crateId: String
    let character: LootCharacterDTO
    let power: Double
    let powerLabel: String
    let shiny: Bool
    let value: Int
    let stars: Int?
    let lockedBy: String?
    let fairness: FairnessDTO
    let openedAt: String

    var isStaked: Bool { lockedBy != nil && !(lockedBy ?? "").isEmpty }
}

struct InventoryResponse: Decodable, Sendable {
    let keys: Int
    let count: Int
    let totalValue: Int
    let items: [InventoryItemDTO]
    let pity: PityDTO?
}

struct GrantKeysResponse: Decodable, Sendable {
    let keys: Int
    let reason: String
}

/// `GET /lootbox/shop-cases` — the coin shop: one case per rarity, with the
/// server's derived coin price and its published odds.
struct ShopCaseDTO: Decodable, Sendable, Identifiable {
    let id: String
    let name: String
    let description: String
    let coinCost: Int
    let characterCount: Int
    let odds: [CrateOddsDTO]
}

struct ShopCasesResponse: Decodable, Sendable {
    let cases: [ShopCaseDTO]
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
        let power: Double
    }
    let merged: InventoryItemDTO
    let consumedIds: [String]
    let from: From
    let to: To
}

/// `GET /characters/catalog` — the authored roster, Pokédex-style.
struct CharacterCatalogEntryDTO: Decodable, Sendable {
    let id: String
    let name: String
    let tagline: String
    let bio: String
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

enum LeaderboardSort: String, Sendable {
    case wins
    case rank
}

struct LeaderboardEntry: Decodable, Sendable, Identifiable {
    let rank: Int
    let id: String
    let displayName: String
    let level: Int
    let battlesWon: Int
    let streakDays: Int
    /// Consistency-ladder fields (#67) — present regardless of sort mode.
    let rankPoints: Int
    let rankTier: String
    let isYou: Bool
}

struct LeaderboardResponse: Decodable, Sendable {
    let entries: [LeaderboardEntry]
    let sort: String
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
    let totalCrateOpens: Int
    let totalCharacters: Int
    let currentKeys: Int
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

struct JourneyElementDistribution: Decodable, Sendable {
    let element: String
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
    let byElement: [JourneyElementDistribution]
}

struct JourneyTimeline: Decodable, Sendable {
    let scansByDay: [JourneyBucket]
    let cratesByDay: [JourneyBucket]
}

struct JourneyResponse: Decodable, Sendable {
    let profile: UserProfileDTO
    let summary: JourneySummary
    let collection: JourneyCollection
    let timeline: JourneyTimeline
    let recentDrops: [InventoryItemDTO]
    let vitals: [JourneyVitalsPoint]
}

// MARK: - Promo codes

struct PromoRedeemResponse: Decodable, Sendable {
    let result: PromoReward
}

struct PromoReward: Decodable, Sendable {
    let reward: String
    let keys: Int
    /// Only present for crate rewards. Contains the full open result.
    let drop: CrateOpenResponse?
}

// MARK: - Dish photo scan (no barcode)
//
// Two steps, mirroring backend/src/routes/scan.ts:
//   POST /scan/photo/analyze  -> DishAnalysisDTO (a draft, nothing minted)
//   POST /scan/photo/confirm  -> DishConfirmResult (the character)
// The user reviews and corrects the draft in between.

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

/// Battle stats derived from the confirmed plate.
struct DishStatsDTO: Decodable, Sendable, Equatable {
    let power: Double
    let guardStat: Double
    let vitality: Double
    let tempo: Double

    private enum CodingKeys: String, CodingKey {
        case power, vitality, tempo
        case guardStat = "guard"
    }
}

/// What `POST /scan/photo/confirm` returns once the plate is locked in.
struct DishConfirmResult: Decodable, Sendable {
    let source: String?
    let foodName: String
    let statType: String
    let summonedCharacter: LootCharacterDTO?
    let stats: DishStatsDTO?
    let items: [DishItemDTO]
    let nutrition: DishTotalsDTO
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
    let power: Double
    let powerLabel: String
    let shiny: Bool
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
