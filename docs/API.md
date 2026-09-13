# API Contracts

Base: `https://<railway-app>.up.railway.app` (no `/api/v1` prefix yet)
Auth: **not implemented yet.** Player identification today is the `X-Player-Id` header (see below); Sign in with Apple replaces it post-hackathon.
Errors: `{ "error": string }` on most routes (newer routes use `{ "error": { "code", "message" } }`). Codes seen today: `PLAYER_ID_REQUIRED`, `PLAYER_ID_INVALID`, `VALIDATION`, `NOT_FOUND`.

## Player identification (implemented)

Every stateful route requires `X-Player-Id: <id>` — a UUID the client generates once and persists (UserDefaults). The backend scopes all in-memory state (lootbox keys/seeds/inventory, vitals history, profiles) by this id.

- Missing header → `400 { error: { code: "PLAYER_ID_REQUIRED", ... } }`
- Malformed (not 6-64 chars of `[A-Za-z0-9_-]`) → `400 { error: { code: "PLAYER_ID_INVALID", ... } }`
- State is in-memory: a backend restart resets keys, inventory, vitals history, and profiles to defaults.

## Implemented routes (current code)

| Route | Notes |
|---|---|
| `GET /health` | liveness |
| `GET /characters` | sample characters |
| `POST /scan` | real OFF lookup; body `{barcode, playerId?}`; barcode must be 6-20 digits; 1 barcode/day/player; returns derived stats + summoned character |
| `GET /scan/collection/:playerId` | characters minted from scans |
| `GET /user/:id` | per-player profile (created on first access) |
| `PUT /user/:id` | partial profile update (displayName, level, streakDays, battlesWon, activeCharacterId, colorMode) — validated |
| `PATCH /user/:id` | full nutrition profile write (`age`, `sex`, `heightCm`, `weightKg`, `activity`, `goal`) — Zod-validated; mirrors to TigerData `telemetry.body_metrics` |
| `POST /battle/simulate` | deterministic sim; squads 1-3 units, statType validated, seed optional |
| `GET /lootbox/*` | crates, rarities, fairness — requires X-Player-Id |
| `POST /lootbox/crates/:id/open` | provably-fair open; clientSeed 6-128 chars optional; returns the stored drop (`id`, `stars`, `value`) |
| `GET /lootbox/shop-cases` | coin-shop cases: one per rarity floor, EV-priced with 15% house margin |
| `POST /lootbox/shop-cases/:id/open` | paid in coins (ledger reason `case_open`); no keys, no pity; returns stored drop + `coinBalance` |
| `GET /lootbox/inventory?limit=` | limit 1-200; includes starter-roster, scan, and dish drops — every character the player owns is a real drop |
| `POST /lootbox/keys/grant` | amount int 1-1000 |
| `POST /lootbox/fairness/*`, `/reset` | per-player seed management |
| `GET /characters/catalog` | authored roster with bios |
| `GET /characters/coins` | coin balance |
| `POST /characters/sell` | `dropIds[]` → coins credited at net worth |
| `POST /characters/merge` | `dropIds[3]` same character + same rarity + same ★ → one ★+1 drop (keeps source crateId) |
| `POST /vitals` | HealthKit snapshot (validated); scoped per player. Producer: the iOS app's `Health/HealthSyncService` (Profile › Connected devices, onboarding, and every foreground) |
| `GET /vitals/latest`, `/vitals/recent?limit=` | per-player history; limit 1-MAX |
| `POST /vitals/reset` | clears caller's history only |

## Planned routes (not yet built)

The following are specified but have no implementation. Do not wire the iOS app against them.

- `POST /auth/sync` — session sync placeholder (no real auth in code yet)
- `PUT /me/profile` — targets derivation endpoint (targets currently computed client-side in BattleKit `PlayerProfile`)
- `GET /daily` — materialized daily multiplier/objectives endpoint (computed client-side in BattleKit `DailyMultiplierCalculator`)
- `POST /gym-check` — OpenAI Vision verification (no Vision integration)
- `POST /characters/merge` — implemented above (3 same-character same-rarity same-★ drops → ★+1)
- `POST /characters/sell` — implemented above (drops → coins at net worth)
- `GET /characters/catalog` — implemented above (authored roster + bios)
- `GET /characters/:id/lore` — Groq proxy (no Groq integration)
- `POST /battles/ranked`, `/battles/arena` — exact-tier matchmaking w/ bot fallback, capsule/character escrow (#85/#116)
- `GET /rankings/*`, `GET /capsules`, `POST /capsules/open`, `GET /objectives` — economy endpoints (capsule ledger unimplemented; the lootbox routes above are the current stand-in)
- `POST /metrics/weight` — log weight, triggers BMI/BMR + target recompute (#88–#90)
- `POST /gamble/pot` — stake 1–3 characters on summed net worth (#124)
- `POST /crash/start`, `GET /crash/:id/tick`, `POST /crash/:id/cashout` — Monster Crash (#126–#128)
- `GET /coins` — coin ledger balance + history (#114)
 API Contracts

Base: `https://<railway-app>.up.railway.app` (no `/api/v1` prefix yet)
Auth: **not implemented yet.** Player identification today is the `X-Player-Id` header (see below); Sign in with Apple replaces it post-hackathon.
Errors: `{ "error": string }` on most routes (newer routes use `{ "error": { "code", "message" } }`). Codes seen today: `PLAYER_ID_REQUIRED`, `PLAYER_ID_INVALID`, `VALIDATION`, `NOT_FOUND`.

## Player identification (implemented)

Every stateful route requires `X-Player-Id: <id>` — a UUID the client generates once and persists (UserDefaults). The backend scopes all in-memory state (lootbox keys/seeds/inventory, vitals history, profiles) by this id.

- Missing header → `400 { error: { code: "PLAYER_ID_REQUIRED", ... } }`
- Malformed (not 6-64 chars of `[A-Za-z0-9_-]`) → `400 { error: { code: "PLAYER_ID_INVALID", ... } }`
- State is in-memory: a backend restart resets keys, inventory, vitals history, and profiles to defaults.

## Implemented routes (current code)

| Route | Notes |
|---|---|
| `GET /health` | liveness |
| `GET /characters` | sample characters |
| `POST /scan` | real OFF lookup; body `{barcode, playerId?}`; barcode must be 6-20 digits; 1 barcode/day/player; returns derived stats + summoned character |
| `GET /scan/collection/:playerId` | characters minted from scans |
| `GET /user/:id` | per-player profile (created on first access) |
| `PUT /user/:id` | partial profile update (displayName, level, streakDays, battlesWon, activeCharacterId, colorMode) — validated |
| `PATCH /user/:id` | full nutrition profile write (`age`, `sex`, `heightCm`, `weightKg`, `activity`, `goal`) — Zod-validated; mirrors to TigerData `telemetry.body_metrics` |
| `POST /battle/simulate` | deterministic sim; squads 1-3 units, statType validated, seed optional |
| `GET /lootbox/*` | crates, rarities, fairness — requires X-Player-Id |
| `POST /lootbox/crates/:id/open` | provably-fair open; clientSeed 6-128 chars optional; returns the stored drop (`id`, `stars`, `value`) |
| `GET /lootbox/shop-cases` | coin-shop cases: one per rarity floor, EV-priced with 15% house margin |
| `POST /lootbox/shop-cases/:id/open` | paid in coins (ledger reason `case_open`); no keys, no pity; returns stored drop + `coinBalance` |
| `GET /lootbox/inventory?limit=` | limit 1-200; includes starter-roster, scan, and dish drops — every character the player owns is a real drop |
| `POST /lootbox/keys/grant` | amount int 1-1000 |
| `POST /lootbox/fairness/*`, `/reset` | per-player seed management |
| `GET /characters/catalog` | authored roster with bios |
| `GET /characters/coins` | coin balance |
| `POST /characters/sell` | `dropIds[]` → coins credited at net worth |
| `POST /characters/merge` | `dropIds[3]` same character + same rarity + same ★ → one ★+1 drop (keeps source crateId) |
| `POST /vitals` | HealthKit snapshot (validated); scoped per player. Producer: the iOS app's `Health/HealthSyncService` (Profile › Connected devices, onboarding, and every foreground) |
| `GET /vitals/latest`, `/vitals/recent?limit=` | per-player history; limit 1-MAX |
| `POST /vitals/reset` | clears caller's history only |

## Auth
| Method | Path | Notes |
|---|---|---|
| POST | `/auth/sync` | Validate the session token, upsert player, return profile |

## Profile
| Method | Path | Body | Returns |
|---|---|---|---|
| GET | `/me` | — | player + profile + targets (calorie/protein/fiber) |
| PUT | `/me/profile` | age, sex, heightCm, weightKg, bodyType, activity, goal | recomputed targets |
| POST | `/metrics/weight` | weightKg | new BMI/BMR + recomputed targets + new objectives (#88–#90) |

## Scanning & daily loop
| Method | Path | Body | Returns |
|---|---|---|---|
| GET | `/products/:barcode` | — | product (OFF cache; fetches on miss) |
| POST | `/scan` | barcode | character created (or fusion dupe count), day-log entry, updated multiplier breakdown |
| GET | `/daily` | — | day log, multiplier breakdown, objectives, capsules today, training buff status |
| POST | `/gym-check` | multipart photo | pass/fail + buff expiry (1/day, Vision + EXIF server-side) |

## Characters
| Method | Path | Body | Returns |
|---|---|---|---|
| GET | `/characters` | — | full collection: stats, ★, netWorth, rarity, locks |
| GET | `/characters/catalog` | — | 14 established characters: name/bio/stats/rarity/art (#95) |
| POST | `/characters/merge` | consumedIds[3] | new ★+1 character (#111) |
| POST | `/characters/sell` | characterId | coins credited at net worth (#115); 409 if locked |
| GET | `/characters/:id/lore` | — | Groq lore (cached) |

## Battles
| Method | Path | Body | Returns |
|---|---|---|---|
| POST | `/battles/expedition` | unitIds[3] | replay + rewards |
| POST | `/battles/ranked` | unitIds[3] | replay + RP delta + rewards; 409 FATIGUED; exact-tier match, bot fallback flagged |
| POST | `/battles/arena` | unitIds[3], stake, charStakeId? | battle id, escrowed; opponent resolved async (#116) |
| GET | `/battles/:id` | — | authoritative replay |
| GET | `/rankings/me` | — | rating, rankPoints, tier, badge, W/L |
| GET | `/rankings/leaderboard` | ?season= | top 100 |

## Economy
| Method | Path | Body | Returns |
|---|---|---|---|
| GET | `/capsules` | — | balance + today's earn breakdown |
| POST | `/capsules/open` | — | rarity + character (pity + rank-scaled odds, #86) |
| GET | `/objectives` | — | today's objectives + progress (BMI/BMR-dynamic, #90) |
| GET | `/coins` | — | coin balance + ledger history (#114) |
| POST | `/gamble/pot` | characterIds[1-3] | session: seedCommit, potValue; resolves server-side (#124) |
| POST | `/crash/start` | characterIds[1-3] | session + seedCommit; pot locked (#126) |
| GET | `/crash/:id/tick` | — | current multiplier / crashed (#127) |
| POST | `/crash/:id/cashout` | — | payout character at mult×pot or 409 if crashed (#127/#128) |

## Server rules (implemented today)

1. **Per-player scoping**: lootbox state, vitals history, and profiles are keyed by `X-Player-Id` — one client never sees another's state.
2. **Anti-gaming caps in POST /scan**: 1 barcode/day per player; 3 items/hour cap is client-side only for now.
3. **Battle simulation is deterministic**: seed in → same replay out. The production HMAC(matchId, SERVER_SECRET) seeding is planned, not wired.
4. **Input validation**: barcode format, squad shape/statTypes, seed, clientSeed, key amounts, inventory limits all return 400s.

## Server rules (planned — see SECURITY.md)

- Append-only capsule ledger, never-negative balance trigger
- Rate limits per player
- JWT ownership checks + RLS backstop
