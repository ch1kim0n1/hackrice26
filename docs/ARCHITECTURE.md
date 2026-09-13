# Architecture

## Split (as actually implemented)

```
┌─────────────────────┐        ┌──────────────────────────┐
│  iOS app (SwiftUI)  │  HTTP  │  Backend (Express+TS)    │
│                     ├───────►│  :4000, in-memory state  │
│  - VisionKit scan   │        │                          │
│  - BattleKit replay │        │  ├─► Open Food Facts API │
│  - GameState        │        │  └─► (no DB, no auth yet)│
│  - NutriQuestUI kit │        │                          │
└─────────────────────┘        └──────────────────────────┘
┌─────────────────────┐
│  Apple Watch        │   HealthKit snapshots POSTed to /vitals
└─────────────────────┘
```

**Rule: Swift for the app, TypeScript for the backend.** Do not write backend logic in Swift for this project.

## Responsibilities

### iOS (SwiftUI)
- **Scanning**: VisionKit `DataScannerViewController`, all symbologies; Open Food Facts v2 lookup via URLSession (no key, no quota).
- **Character generation**: deterministic procedural core (barcode seed → parts/stats) + AI card art (Pollinations flux, seeded by barcode, version-salted).
- **BattleKit**: pure deterministic battle simulation (Swift actor, SplitMix64 seeded). Runs replays locally; the backend runs the same formula authoritatively.
- **GameState**: day log, party multiplier recalcs, squad state (ObservableObject shared across screens).
- **NutriQuestUI**: design system (white-first, dynamic character accent), animation kit, chibi mascots.

### Backend (Express + TypeScript)
- **Per-player scoping**: `X-Player-Id` header (client-generated UUID) scopes lootbox state, vitals history, and profiles into in-memory Maps. Missing/malformed header → 400.
- **Real OFF lookups**: `POST /scan` fetches Open Food Facts, derives battle stats server-side (same formulas as BattleKit `CharacterFactory`), enforces 1-barcode-per-day per player.
- **Deterministic battles**: `POST /battle/simulate` runs the BattleKit formula port (SplitMix64, type triangle, crit/miss/variance). Seed in → same replay out.
- **Provably-fair loot crates**: HMAC seed pairs per player, hash commitment before rolls, 7-tier rarity, per-roll breakdown.
- **Vitals pipeline**: validated HealthKit snapshots, analysis, per-player history.
- **Input validation**: 400s on malformed barcodes, squads, seeds, client seeds, amounts, limits.

## Data flow: scan → battle

```
1. Scan barcode (on-device VisionKit)
2. GET OFF product (fetched live; caching planned in `app.product_enrichment`)
3. Create FoodCharacter (stats from nutrition via CharacterFactory)
4. Append DayLogEntry (anti-gaming caps: 1 barcode/day; 3/hour client-side)
5. DailyMultiplierCalculator recomputes party multiplier (client-side today)
6. Player selects squad → POST /battle/simulate
7. Backend simulates (seeded), returns replay
8. Client replays events with animation kit
```

## Daily reset

- **Not implemented.** No cron exists. In-memory daily state resets on backend restart. The client resets local UI at local midnight.
- Planned: Railway cron `0 0 * * *` (UTC) expiring day-logs, training buffs, objectives; server state as source of truth.

## Environments

| Env | Backend | Notes |
|---|---|---|
| local | localhost:4000 | in-memory, restart wipes state |
| prod | Railway | same code, no separate staging yet |

Secrets live in Railway env vars + Xcode xcconfig (never committed). See SETUP.md.

## Planned / not yet built

These appear in earlier design docs but have **no implementation**. Do not assume they exist; do not wire the iOS app against them.

- **TigerData** (Tiger Cloud Postgres + TimescaleDB) — schema in `backend/migrations/`, applied to the provisioned service. The app writes it as a mirror; SQLite remains the source of truth.
- **Auth** — no JWT. `X-Player-Id` is client-supplied and unauthenticated; anyone can send any id.
- **Groq** (character lore/dialogue) — no integration.
- **OpenAI Vision** (gym photo verification) — no integration; the GymCheck screen is UI-only.
- **Elo matchmaking / ranked / arena** — design only. `/battle/simulate` resolves a single request; no matchmaking, no RP, no capsule escrow.
- **Railway cron daily reset** — no cron job exists.
- **APNs notifications** — none.
- **Capsule ledger economy** — the lootbox key balance is the current stand-in; the append-only ledger from DATA-MODELS.md is unbuilt.
- **Fastify/Hono** — backend is Express today; migration is optional post-hackathon.
