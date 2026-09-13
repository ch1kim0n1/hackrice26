import Foundation

enum APIError: LocalizedError {
    case invalidURL(String)
    case transport(Error)
    case badStatus(Int, String?)
    case decodingFailed

    var errorDescription: String? {
        switch self {
        case .invalidURL(let string):
            return "Backend URL is not valid: \(string)"
        case .transport(let error):
            return "Could not reach the backend: \(error.localizedDescription)"
        case .badStatus(let code, let body):
            return Self.userFacingStatus(code, body: body)
        case .decodingFailed:
            return "Backend response was not in the expected format."
        }
    }

    /// One-line copy for `NQBanner`. HTML and multi-line bodies are dropped
    /// so a missing route cannot dump an nginx 404 page onto the casino floor.
    static func userFacingStatus(_ code: Int, body: String?) -> String {
        let fallback = "Couldn't reach the server (HTTP \(code))."
        guard let body else { return fallback }
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return fallback }
        let looksHTML = trimmed.hasPrefix("<")
            || trimmed.range(of: "<html", options: .caseInsensitive) != nil
            || trimmed.range(of: "<!doctype", options: .caseInsensitive) != nil
        if looksHTML { return fallback }
        if trimmed.contains(where: \.isNewline) || trimmed.count > 80 { return fallback }
        return "Couldn't reach the server (HTTP \(code)): \(trimmed)"
    }

    /// Network and 5xx problems are worth a retry; a 4xx means our payload is wrong.
    var isRetryable: Bool {
        switch self {
        case .transport: return true
        case .badStatus(let code, _): return code >= 500
        case .invalidURL, .decodingFailed: return false
        }
    }
}

/// Typed client for the NutriQuest backend (backend/src/routes). All routes
/// are mounted at the root: /battle, /user, /lootbox, /scan, /characters.
///
/// Every request carries `X-Player-ID` (see AppConfig.playerID) so the
/// backend can scope state per player once that lands server-side.
final class APIClient {

    static let shared = APIClient()

    private let session: URLSession

    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private let decoder = JSONDecoder()

    init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: - Dish photo scan (no barcode needed)
    //
    // Two steps: analyze produces a breakdown the user reviews, confirm turns
    // the corrected plate into a character. Nothing is minted until confirm.

    private struct DishAnalyzeEnvelope: Decodable {
        let analysis: DishAnalysisDTO
    }

    private struct DishConfirmEnvelope: Decodable {
        let result: DishConfirmResult
    }

    private struct DishAnalyzeBody: Encodable {
        let image: String
    }

    private struct DishConfirmBody: Encodable {
        let analysisId: String
        let edits: [DishItemEdit]
    }

    /// POST /scan/photo/analyze — identifies each food on the plate and
    /// estimates its portion. A vision call, so it gets a longer timeout than
    /// the default request budget.
    func analyzeDishPhoto(jpegBase64: String) async throws -> DishAnalysisDTO {
        let envelope = try await request(
            DishAnalyzeEnvelope.self,
            method: "POST",
            path: "scan/photo/analyze",
            body: DishAnalyzeBody(image: jpegBase64),
            timeout: 60
        )
        return envelope.analysis
    }

    /// POST /scan/photo/confirm — applies the user's corrections server-side
    /// and mints the character from the confirmed plate.
    func confirmDishPhoto(analysisId: String, edits: [DishItemEdit]) async throws -> DishConfirmResult {
        let envelope = try await request(
            DishConfirmEnvelope.self,
            method: "POST",
            path: "scan/photo/confirm",
            body: DishConfirmBody(analysisId: analysisId, edits: edits)
        )
        return envelope.result
    }

    // MARK: - Core request

    // MARK: - Auth

    struct AuthResponse: Decodable {
        let playerId: String
        let token: String
        let account: AuthAccount
    }
    struct AuthAccount: Decodable {
        let username: String
        let displayName: String
        let createdAt: String
    }
    struct AuthMeResponse: Decodable {
        let playerId: String
        let account: AuthAccount
    }

    /// Register a new account and open a session.
    func register(username: String, password: String, displayName: String? = nil) async throws -> AuthResponse {
        try await request(AuthResponse.self, method: "POST", path: "/auth/register",
                          body: ["username": username, "password": password, "displayName": displayName ?? ""])
    }

    /// Log in and open a session. 401 AUTH_FAILED on bad credentials.
    func login(username: String, password: String) async throws -> AuthResponse {
        try await request(AuthResponse.self, method: "POST", path: "/auth/login",
                          body: ["username": username, "password": password])
    }

    /// Current account for the active session. Throws on 401.
    func authMe() async throws -> AuthMeResponse {
        try await request(AuthMeResponse.self, method: "GET", path: "/auth/me")
    }

    /// Revoke the current session server-side, then clear locally.
    func logout() async {
        struct Ok: Decodable { let ok: Bool }
        _ = try? await request(Ok.self, method: "POST", path: "/auth/logout")
    }

    // MARK: - Meal photo scan (CalAI-style, no barcode needed)
    // MARK: - Core request

    func request<T: Decodable>(
        _ type: T.Type,
        method: String,
        path: String,
        query: [String: String] = [:],
        body: (any Encodable)? = nil,
        timeout: TimeInterval = 15
    ) async throws -> T {
        let url = try Self.buildURL(path: path, query: query)

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // Authenticated sessions send the bearer token; anonymous play keeps
        // the X-Player-ID header so unregistered players still scope state.
        if let token = SessionStore.currentToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        } else {
            request.setValue(AppConfig.playerID, forHTTPHeaderField: "X-Player-ID")
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try encoder.encode(AnyEncodable(body))
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw APIError.transport(error)
        }

        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(statusCode) else {
            throw APIError.badStatus(statusCode, String(data: data, encoding: .utf8))
        }

        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw APIError.decodingFailed
        }
    }

    private static func buildURL(path: String, query: [String: String]) throws -> URL {
        let trimmed = AppConfig.backendBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed), components.scheme != nil else {
            throw APIError.invalidURL(AppConfig.backendBaseURL)
        }
        // NSString's path-joining drops the leading slash when the base path is
        // empty (e.g. "http://localhost:4000" -> path ""), producing "user/x"
        // instead of "/user/x". URLComponents.url returns nil for a non-empty
        // path with no leading slash when a host is present, so every request
        // failed with .invalidURL before this fix -- reachability was never
        // actually the problem, just this string join.
        var joinedPath = (components.path as NSString).appendingPathComponent(path)
        if !joinedPath.hasPrefix("/") { joinedPath = "/" + joinedPath }
        components.path = joinedPath
        if !query.isEmpty {
            components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = components.url else {
            throw APIError.invalidURL(AppConfig.backendBaseURL)
        }
        return url
    }

    // MARK: - Battle (backend/src/routes/battle.ts)

    /// POST /battle/simulate — server-authoritative deterministic resolution.
    /// The seed is generated client-side so the returned replay can be
    /// re-derived/animated locally with the same inputs.
    func simulateBattle(_ body: BattleSimulateRequest) async throws -> ServerBattleResult {
        try await request(ServerBattleResult.self, method: "POST", path: "battle/simulate", body: body)
    }

    /// POST /battle/async/challenge — fight a friend's stored squad snapshot.
    func challengeFriend(opponentId: String, yourSquad: [BattleSquadMember]) async throws -> AsyncChallengeResponse {
        struct ChallengeBody: Encodable { let opponentId: String; let yourSquad: [BattleSquadMember] }
        return try await request(
            AsyncChallengeResponse.self,
            method: "POST",
            path: "battle/async/challenge",
            body: ChallengeBody(opponentId: opponentId, yourSquad: yourSquad)
        )
    }

    /// GET /battle/async/notices — recent challenges against your squad.
    func fetchBattleNotices() async throws -> AsyncNoticesResponse {
        try await request(AsyncNoticesResponse.self, method: "GET", path: "battle/async/notices")
    }

    /// POST /battle/dungeon/run — send the squad down until it wipes.
    func runDungeon(squad: [BattleSquadMember]) async throws -> DungeonRunResponse {
        struct RunBody: Encodable { let squad: [BattleSquadMember] }
        return try await request(DungeonRunResponse.self, method: "POST", path: "battle/dungeon/run", body: RunBody(squad: squad))
    }

    /// GET /battle/dungeon/state — best floor + idle keys waiting.
    func fetchDungeonState() async throws -> DungeonStateResponse {
        try await request(DungeonStateResponse.self, method: "GET", path: "battle/dungeon/state")
    }

    /// POST /battle/dungeon/claim — collect idle keys.
    func claimDungeonIncome() async throws -> DungeonClaimResponse {
        try await request(DungeonClaimResponse.self, method: "POST", path: "battle/dungeon/claim")
    }

    // MARK: - User (backend/src/routes/user.ts)

    /// GET /user/:id — profile plus progression (XP) block and comeback state.
    func fetchUserProfile(id: String) async throws -> UserResponse {
        try await request(UserResponse.self, method: "GET", path: "user/\(id)")
    }

    /// PUT /user/:id — partial update. Only used today to set the showcased
    /// character; pass `nil` for a field to leave it unchanged (the backend
    /// only touches fields present in the body).
    func updateProfile(id: String, activeCharacterId: String?) async throws -> UserResponse {
        struct UpdateBody: Encodable { let activeCharacterId: String? }
        return try await request(
            UserResponse.self,
            method: "PUT",
            path: "user/\(id)",
            body: UpdateBody(activeCharacterId: activeCharacterId)
        )
    }

    /// PATCH /user/:id — writes the full nutrition profile (age, sex, height,
    /// weight, activity, goal) in one shot. The Body & goals editor's save
    /// path; PUT stays the displayName/activeCharacterId route.
    func updateBodyMetrics(
        id: String,
        age: Int,
        sex: String,
        heightCm: Double,
        weightKg: Double,
        activity: String,
        goal: String
    ) async throws -> UserProfileDTO {
        struct Body: Encodable {
            let age: Int
            let sex: String
            let heightCm: Double
            let weightKg: Double
            let activity: String
            let goal: String
        }
        struct Envelope: Decodable {
            let profile: UserProfileDTO
        }
        let envelope = try await request(
            Envelope.self,
            method: "PATCH",
            path: "user/\(id)",
            body: Body(
                age: age,
                sex: sex,
                heightCm: heightCm,
                weightKg: weightKg,
                activity: activity,
                goal: goal
            )
        )
        return envelope.profile
    }

    /// GET /user/:id/journey — profile stats and timelines for the Journey view.
    func fetchJourney(id: String) async throws -> JourneyResponse {
        try await request(JourneyResponse.self, method: "GET", path: "user/\(id)/journey")
    }

    /// GET /user/leaderboard?sort=wins|rank — "wins" (battles won, default)
    /// or "rank" (consistency ladder: points + tier).
    func fetchLeaderboard(sort: LeaderboardSort = .wins) async throws -> LeaderboardResponse {
        try await request(LeaderboardResponse.self, method: "GET", path: "user/leaderboard", query: ["sort": sort.rawValue])
    }

    /// POST /user/comeback/claim — the free welcome-back crate pull.
    func claimComeback() async throws -> CrateOpenResponse {
        try await request(CrateOpenResponse.self, method: "POST", path: "user/comeback/claim")
    }

    // MARK: - Vitals (backend/src/vitals — HealthKit snapshots from the watch)

    /// GET /vitals/latest — the most recent HealthKit snapshot this player's
    /// watch posted. Responds 404 before the first sync; callers should treat
    /// that as "no data yet", not an error.
    func fetchLatestVitals() async throws -> VitalsLatestResponse {
        try await request(VitalsLatestResponse.self, method: "GET", path: "vitals/latest")
    }

    // MARK: - Trends (backend/src/routes/trends.ts)

    /// GET /trends/casino — hourly casino outcomes per mode, straight out of
    /// the `analytics.gamble_hourly` continuous aggregate. Pre-rolled by
    /// TimescaleDB, so the response size is the same after three months of play
    /// as it is on day one.
    ///
    /// Answers `available: false` with no points when the backend is running
    /// without Postgres; callers show an empty state, not an error.
    func fetchCasinoTrend(hours: Int = 72) async throws -> CasinoTrendResponse {
        try await request(
            CasinoTrendResponse.self,
            method: "GET",
            path: "trends/casino",
            query: ["hours": String(hours)]
        )
    }

    // MARK: - Cauldron Crash (backend/src/routes/cauldron.ts)

    /// GET /cauldron/config — the published rules: house edge, wager limits,
    /// rarity brackets, survival odds.
    func fetchCauldronConfig() async throws -> CauldronConfigResponse {
        try await request(CauldronConfigResponse.self, method: "GET", path: "cauldron/config")
    }

    /// GET /cauldron/state — the live round (if the cauldron is still
    /// bubbling), the last finished one, and everything wagerable.
    ///
    /// Also the reconnect path: a round that crashed while the app was in the
    /// background is settled server-side and comes back CRASHED.
    func fetchCauldronState() async throws -> CauldronStateResponse {
        try await request(CauldronStateResponse.self, method: "GET", path: "cauldron/state")
    }

    /// POST /cauldron/rounds — lock 1-3 monsters in and start the multiplier.
    /// The monsters leave the collection immediately; the crash point is fixed
    /// server-side and never sent while the round is live.
    func startCauldronRound(dropIDs: [String]) async throws -> CauldronRoundDTO {
        struct StartBody: Encodable { let dropIds: [String] }
        let response = try await request(
            CauldronRoundResponse.self,
            method: "POST",
            path: "cauldron/rounds",
            body: StartBody(dropIds: dropIDs)
        )
        return response.round
    }

    /// POST /cauldron/rounds/:id/cashout — the server prices the cash-out off
    /// its own clock and decides whether it beat the crash.
    func cashOutCauldronRound(roundID: String) async throws -> CauldronRoundDTO {
        let response = try await request(
            CauldronRoundResponse.self,
            method: "POST",
            path: "cauldron/rounds/\(roundID)/cashout"
        )
        return response.round
    }

    // MARK: - Kitchen Mines (backend/src/routes/mines.ts)

    /// GET /mines/config — board shape, mine limits, the edge, rarity bands.
    func fetchMinesConfig() async throws -> MinesConfigResponse {
        try await request(MinesConfigResponse.self, method: "GET", path: "mines/config")
    }

    /// GET /mines/payouts?mines=N — the whole climb for one board, so the UI
    /// can show what the ladder looks like before committing a monster.
    func fetchMinesPayouts(mines: Int) async throws -> MinesPayoutsResponse {
        try await request(
            MinesPayoutsResponse.self,
            method: "GET",
            path: "mines/payouts",
            query: ["mines": String(mines)]
        )
    }

    /// GET /mines/state — the live board (if any), the last result, the bank.
    func fetchMinesState() async throws -> MinesStateResponse {
        try await request(MinesStateResponse.self, method: "GET", path: "mines/state")
    }

    /// POST /mines/rounds — commit one monster and lay the board. The mine
    /// count is locked from here; the layout is never sent back while live.
    func startMinesRound(dropID: String, mines: Int) async throws -> MinesRoundDTO {
        struct StartBody: Encodable { let dropId: String; let mines: Int }
        let response = try await request(
            MinesRoundResponse.self,
            method: "POST",
            path: "mines/rounds",
            body: StartBody(dropId: dropID, mines: mines)
        )
        return response.round
    }

    /// POST /mines/rounds/:id/reveal — lift one dish. The answer was decided
    /// when the board was laid; this only looks it up.
    func revealMinesTile(roundID: String, tile: Int) async throws -> MinesRevealResponse {
        struct RevealBody: Encodable { let tile: Int }
        return try await request(
            MinesRevealResponse.self,
            method: "POST",
            path: "mines/rounds/\(roundID)/reveal",
            body: RevealBody(tile: tile)
        )
    }

    /// POST /mines/rounds/:id/cashout — serve the dish and take the monster.
    func cashOutMinesRound(roundID: String) async throws -> MinesRoundDTO {
        let response = try await request(
            MinesRoundResponse.self,
            method: "POST",
            path: "mines/rounds/\(roundID)/cashout"
        )
        return response.round
    }

    // MARK: - Plinko (backend/src/routes/plinko.ts)

    /// GET /plinko/config — the board, the payout table and the real odds.
    func fetchPlinkoConfig() async throws -> PlinkoConfigResponse {
        try await request(PlinkoConfigResponse.self, method: "GET", path: "plinko/config")
    }

    /// GET /plinko/state — the bank and recent drops.
    func fetchPlinkoState() async throws -> PlinkoStateResponse {
        try await request(PlinkoStateResponse.self, method: "GET", path: "plinko/state")
    }

    /// POST /plinko/drops — spend one monster and drop the orb. The whole
    /// round resolves server-side before this returns; the client animates
    /// the path that comes back.
    func dropPlinko(dropID: String) async throws -> PlinkoDropDTO {
        struct DropBody: Encodable { let dropId: String }
        let response = try await request(
            PlinkoDropResponse.self,
            method: "POST",
            path: "plinko/drops",
            body: DropBody(dropId: dropID)
        )
        return response.drop
    }

    // MARK: - Portal Wheel (backend/src/routes/portalWheel.ts)

    /// GET /portal-wheel/config — the wheel, the odds and the real edge.
    func fetchPortalWheelConfig() async throws -> PortalWheelConfigResponse {
        try await request(PortalWheelConfigResponse.self, method: "GET", path: "portal-wheel/config")
    }

    /// GET /portal-wheel/state — the bank and recent spins.
    func fetchPortalWheelState() async throws -> PortalWheelStateResponse {
        try await request(PortalWheelStateResponse.self, method: "GET", path: "portal-wheel/state")
    }

    /// POST /portal-wheel/spins — commit one monster to one colour and spin.
    ///
    /// The colour travels with the wager because that is what locks it: there
    /// is no second request that could change the bet once the wheel is turning.
    func spinPortalWheel(dropID: String, color: String) async throws -> PortalWheelSpinDTO {
        struct SpinBody: Encodable {
            let dropId: String
            let color: String
        }
        let response = try await request(
            PortalWheelSpinResponse.self,
            method: "POST",
            path: "portal-wheel/spins",
            body: SpinBody(dropId: dropID, color: color)
        )
        return response.spin
    }

    // MARK: - Loot crates (backend/src/routes/lootbox.ts)

    /// GET /lootbox/crates — every crate with its published drop rates.
    func fetchCrates() async throws -> [CrateSummaryDTO] {
        let response: CratesResponse = try await request(CratesResponse.self, method: "GET", path: "lootbox/crates")
        return response.crates
    }

    /// POST /lootbox/crates/:id/open — spend keys, resolve one drop via the
    /// server's commit-reveal scheme. `clientSeed` is optional player entropy.
    func openCrate(crateID: String, clientSeed: String? = nil) async throws -> CrateOpenResponse {
        struct OpenBody: Encodable { let clientSeed: String? }
        return try await request(
            CrateOpenResponse.self,
            method: "POST",
            path: "lootbox/crates/\(crateID)/open",
            body: OpenBody(clientSeed: clientSeed)
        )
    }

    /// GET /lootbox/shop-cases — the coin shop: one case per rarity, with
    /// its coin price and published odds.
    func fetchShopCases() async throws -> [ShopCaseDTO] {
        try await request(ShopCasesResponse.self, method: "GET", path: "lootbox/shop-cases").cases
    }

    /// POST /lootbox/shop-cases/:id/open — pay the case's coin price and
    /// resolve one drop server-side. No keys, no pity, no rank boost.
    func openShopCase(caseID: String, clientSeed: String? = nil) async throws -> CrateOpenResponse {
        struct OpenBody: Encodable { let clientSeed: String? }
        return try await request(
            CrateOpenResponse.self,
            method: "POST",
            path: "lootbox/shop-cases/\(caseID)/open",
            body: OpenBody(clientSeed: clientSeed)
        )
    }

    /// GET /lootbox/inventory — this player's pulls, newest first.
    func fetchInventory(limit: Int = 50) async throws -> InventoryResponse {
        try await request(
            InventoryResponse.self,
            method: "GET",
            path: "lootbox/inventory",
            query: ["limit": String(limit)]
        )
    }

    /// POST /lootbox/keys/grant — award keys (admin-only).
    func grantKeys(amount: Int, reason: String) async throws -> GrantKeysResponse {
        struct GrantBody: Encodable { let amount: Int; let reason: String }
        return try await request(
            GrantKeysResponse.self,
            method: "POST",
            path: "lootbox/keys/grant",
            body: GrantBody(amount: amount, reason: reason)
        )
    }

    /// GET /lootbox/fairness — current seed commitment + retired (revealed) seeds.
    func fetchFairness() async throws -> FairnessResponse {
        try await request(FairnessResponse.self, method: "GET", path: "lootbox/fairness")
    }

    /// POST /lootbox/fairness/rotate — retire current seed (revealing it), commit new.
    func rotateSeed() async throws -> RotateSeedResponse {
        try await request(RotateSeedResponse.self, method: "POST", path: "lootbox/fairness/rotate")
    }

    /// POST /lootbox/promos/:code/redeem — one-time key/crate reward.
    func redeemPromo(code: String) async throws -> PromoRedeemResponse {
        try await request(PromoRedeemResponse.self, method: "POST", path: "lootbox/promos/\(code)/redeem")
    }

    // MARK: - Daily quests (backend/src/game/quests.ts)

    /// GET /user/quests/today — today's trio with server-verified progress.
    func fetchDailyQuests() async throws -> DailyQuestsResponse {
        try await request(DailyQuestsResponse.self, method: "GET", path: "user/quests/today")
    }

    /// POST /user/quests/:id/claim — verified completion pays keys, once.
    func claimQuest(id: String) async throws -> ClaimQuestResponse {
        try await request(ClaimQuestResponse.self, method: "POST", path: "user/quests/\(id)/claim")
    }

    /// GET /characters/coins — current coin wallet.
    func fetchCoins() async throws -> CoinsResponse {
        try await request(CoinsResponse.self, method: "GET", path: "characters/coins")
    }

    /// GET /characters/catalog — the authored roster, Pokédex-style. Used for
    /// character bios, which are static content and fetched once per launch.
    func fetchCharacterCatalog() async throws -> [CharacterCatalogEntryDTO] {
        let response = try await request(
            CharacterCatalogResponse.self,
            method: "GET",
            path: "characters/catalog"
        )
        return response.catalog
    }

    /// POST /characters/sell — monsters out, coins in at full net worth.
    func sellMonsters(dropIDs: [String]) async throws -> SellResponse {
        struct SellBody: Encodable { let dropIds: [String] }
        return try await request(
            SellResponse.self,
            method: "POST",
            path: "characters/sell",
            body: SellBody(dropIds: dropIDs)
        )
    }

    /// POST /characters/merge — fuses three same-character, same-rarity,
    /// same-star copies into one instance at the next star (max ★5). The
    /// server rejects mismatches, staked copies and ★5s with 409.
    func mergeCharacters(dropIDs: [String]) async throws -> MergeResponseDTO {
        struct MergeBody: Encodable { let dropIds: [String] }
        return try await request(
            MergeResponseDTO.self,
            method: "POST",
            path: "characters/merge",
            body: MergeBody(dropIds: dropIDs)
        )
    }
}

/// Type-erasing box so the generic `request` can take any Encodable body.
private struct AnyEncodable: Encodable {
    private let encodeFunc: (Encoder) throws -> Void

    init(_ wrapped: any Encodable) {
        encodeFunc = wrapped.encode
    }

    func encode(to encoder: Encoder) throws {
        try encodeFunc(encoder)
    }
}
