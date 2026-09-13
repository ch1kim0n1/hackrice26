# Data Models

Domain schema. Postgres. `snake_case` in DB, `camelCase` in Swift/TS.

> **Status.** The design model, not the deployed one. The implemented schema is
> `backend/migrations/` (schemas `app`, `telemetry`, `analytics`, `ops`), described
> in [`db-documentation/03-relational-model.md`](../db-documentation/03-relational-model.md);
> the time-series design is in
> [`db-documentation/04-timescale-design.md`](../db-documentation/04-timescale-design.md).
> Names here map onto that rather than matching it exactly.

> **New-vision delta** (issues #67–#81): ranks, BMI/BMR dynamic goals, 14-character roster,
> stars via merging (supersedes fusion), net worth → rarity, coins, pot gambling,
> Monster Crash, attacks, per-rarity art.

## Identity

```sql
players (
  id            uuid PK,               -- = auth.users.id
  display_name  text NOT NULL,
  created_at    timestamptz DEFAULT now(),
  last_seen_at  timestamptz,
  device_hash   text                   -- anti-multiaccount (demo)
)

profiles (
  player_id     uuid PK REFERENCES players,
  age           int CHECK (age BETWEEN 10 AND 100),
  sex           text CHECK (sex IN ('male','female')),
  height_cm     numeric(5,1),
  weight_kg     numeric(5,1),
  body_type     text,                  -- NEW: ectomorph/mesomorph/endomorph (#88)
  activity      text CHECK (activity IN ('sedentary','light','moderate','active')),
  goal          text CHECK (goal IN ('cut','maintain','bulk')),
  calorie_target int,                  -- derived server-side (Mifflin-St Jeor)
  protein_target int,
  fiber_target  int,
  updated_at    timestamptz
)

body_metric_log (                      -- NEW (#88): append-only weight history
  id           uuid PK DEFAULT gen_random_uuid(),
  player_id    uuid REFERENCES players,
  weight_kg    numeric(5,1) NOT NULL,
  body_fat_pct numeric(4,1),           -- optional, when the client has it
  source       text CHECK (source IN ('manual','healthkit','onboarding')),
  logged_at    timestamptz DEFAULT now()
  -- append-only (block_mutation); newest row syncs profiles.weight_kg
  -- every insert triggers BMI/BMR + target + goal recompute (#89/#90)
)
```

## Products & characters

```sql
products (                             -- OFF cache, shared across players
  barcode      text PK,
  name         text,
  brand        text,
  nutriments   jsonb,                  -- raw OFF nutriments object
  nova_group   int,
  unique_scans int,                    -- OFF scarcity signal
  price_tier   numeric,                -- from Open Prices (per country)
  micro_score  numeric,                -- 0..1 computed
  food_group   text,                   -- produce/grain/dairy/protein/other
  fetched_at   timestamptz
)

character_catalog (                    -- NEW (#94): established roster, Pokédex side
  id           int PK,
  slug         text UNIQUE,            -- stable key
  name         text,
  bio          text,
  base_stats   jsonb,
  base_rarity  text,
  element      text
  -- seeded with the 14 MVP characters (#92/#93)
)

characters (                           -- player-owned instances
  id           uuid PK DEFAULT gen_random_uuid(),
  player_id    uuid REFERENCES players,
  barcode      text REFERENCES products,
  catalog_id   int REFERENCES character_catalog,  -- NEW: null for generated
  name         text,
  element      text CHECK (element IN ('protein','fiber','vitamin','hydration')),
  rarity       text CHECK (rarity IN ('common','uncommon','rare','epic','legendary')),
  star_level   int DEFAULT 1 CHECK (star_level BETWEEN 1 AND 5),   -- NEW: replaces fusion_tier (#110); 1-based, every monster is at least ★1
  net_worth    int NOT NULL DEFAULT 0,  -- NEW (#118): coins; rarity derives from this (#119)
  base_stats   jsonb,                  -- advanced stat block (#101), nutrition-derived (#104)
  locked       boolean DEFAULT false,  -- NEW: staked / in-pot → no sell/merge (#133)
  art_url      text,
  created_at   timestamptz DEFAULT now(),
  UNIQUE (player_id, barcode, star_level)         -- dupes tracked for merging
)

character_images (                     -- NEW (#97): per-rarity art variants
  character_key text,                  -- catalog slug or generated key
  rarity        text,
  image_key     text,
  PRIMARY KEY (character_key, rarity)
)

merge_events (                         -- NEW (#110/#111): supersedes fusion_events
  id           uuid PK,
  player_id    uuid,
  result_id    uuid REFERENCES characters,
  consumed_ids uuid[] CHECK (array_length(consumed_ids,1) = 3),  -- 3 same char, same ★
  created_at   timestamptz DEFAULT now()
  -- legacy: fusion_events consumed 5; reconcile per #110
)

attacks (                              -- NEW (#106)
  id           int PK,
  name         text,
  kind         text,                   -- basic|signature|special
  power        numeric,
  effect       jsonb,
  min_rarity   text                    -- special attacks gated by rarity (#108)
)

character_attacks (                    -- NEW (#106): catalog moveset
  character_key text,
  attack_id     int REFERENCES attacks,
  PRIMARY KEY (character_key, attack_id)
)
```

### Character stats — the canonical set (#101)

**Four stats, not five.** `power / guard / vitality / tempo` is the set the
whole game already runs on, and there is exactly one definition of it:

| Layer | Where |
|---|---|
| Schema + validation | `backend/src/schemas/gameSchemas.ts` (`baseStatsSchema`, `STAT_KEYS`) |
| Derivation from nutrition | `backend/src/game/baseStats.ts` and `public.compute_base_stats()` |
| Combat | `BattleStats` in `ios/Sources/BattleKit/BattleModels.swift`, mirrored in `routes/battle.ts` |
| Storage | `characters.base_stats jsonb` |

```
power     offence           20 + protein_g × 4
guard     defence           20 + fiber_g   × 5
vitality  effective HP      20 + microScore × 45
tempo     turn order        20 + (protein_g / max(sugar_g,1)) × 10 + (50 − sugar_g) × 0.6
```

Every stat is an integer clamped to **10..100**. The floor stops a
zero-protein snack from being unplayable; the ceiling is what rarity and star
multipliers scale *from*, never to — a stat above 100 means a bug upstream,
not a strong monster.

**Element is derived, never stored independently.** A character's element is
whichever stat is highest: `power→protein`, `guard→fiber`, `vitality→vitamin`,
`tempo→hydration` (`element_from_stats()` in SQL, `STAT_ELEMENT` in TS). The
roster loader enforces the same rule at boot, so a Pokédex entry can never
claim an element its own stat line contradicts.

Adding a fifth stat means changing all four layers above plus every stored
`base_stats` blob and every battle replay — it is a migration, not an edit.

## Daily loop

```sql
day_logs (                             -- one scanned food, one day
  id           uuid PK,
  player_id    uuid,
  barcode      text,
  log_date     date NOT NULL DEFAULT current_date,
  calories     numeric,
  protein_g    numeric,
  fiber_g      numeric,
  sugar_g      numeric,
  micro_score  numeric,
  food_group   text,
  counts_toward_multiplier boolean DEFAULT true,
  logged_at    timestamptz DEFAULT now(),
  UNIQUE (player_id, barcode, log_date)
)

daily_state (                          -- materialized multiplier per day
  player_id        uuid,
  log_date         date,
  multiplier       numeric CHECK (multiplier BETWEEN 0.8 AND 1.5),
  breakdown        jsonb,
  objectives       jsonb,              -- NOW dynamic: recomputed from BMI/BMR band (#90)
  capsules_earned  int DEFAULT 0,
  scan_xp          int DEFAULT 0,
  rank_points      int DEFAULT 0,      -- NEW (#83): daily consistency points
  PRIMARY KEY (player_id, log_date)
)

training_buffs (
  player_id    uuid,
  granted_at   timestamptz,
  expires_at   timestamptz,
  verified     boolean DEFAULT true,
  photo_path   text,
  PRIMARY KEY (player_id, granted_at)
)
```

## Battles & ranked

```sql
characters_battle_snapshot (
  id           uuid PK,
  battle_id    uuid,
  player_id    uuid,
  units        jsonb                   -- [{characterId, fullStats, element, mult, attacks}] (#103)
)

battles (
  id           uuid PK,
  mode         text CHECK (mode IN ('expedition','ranked','arena')),
  seed         bigint NOT NULL,
  player_a     uuid,
  player_b     uuid,                   -- null for expedition/bot
  is_bot_b     boolean DEFAULT false,  -- NEW (#85): bot fallback at same rank
  squad_a      jsonb,
  squad_b      jsonb,
  replay       jsonb,
  winner       uuid,
  rounds       int,
  created_at   timestamptz DEFAULT now()
)

rankings (
  player_id    uuid,
  season_id    int,
  rating       int DEFAULT 1000,       -- Elo (battle skill), moved by apply_ranked_result()
  tier         text DEFAULT 'Bronze',  -- Elo tier, derived from rating via tier_for()
  rank_points  int DEFAULT 0,          -- NEW (#82/#83): consistency-driven progression
  rank_tier    text DEFAULT 'bronze' CHECK (rank_tier IN ('bronze','silver','gold','plat')),  -- NEW (#82): badge source
  -- TWO LADDERS: `rating`/`tier` is how well you fight; `rank_points`/`rank_tier`
  -- is how well you eat. Thresholds + promotion/demotion are #84.
  -- Per-season by primary key, so a season reset is a new row, not a wipe.
  wins         int,
  losses       int,
  PRIMARY KEY (player_id, season_id)
)

seasons (
  id           int PK,                 -- weekly
  starts_at    date,
  ends_at      date,
  status       text CHECK (status IN ('active','ended'))
)

fatigue (
  player_id    uuid PK,
  fatigued_until timestamptz,
  recovery_quest text
)
```

## Economy

```sql
capsule_ledger (                       -- pull currency, append-only
  id           uuid PK,
  player_id    uuid,
  amount       int CHECK (amount != 0),
  reason       text CHECK (reason IN ('scan','objective','gym','ranked_win','arena_win','arena_stake','arena_refund','season_reward','burn')),
  ref_id       uuid,
  created_at   timestamptz DEFAULT now()
)

coin_ledger (                          -- NEW (#114): soft currency for character trade
  id           uuid PK,
  player_id    uuid,
  amount       int CHECK (amount != 0),
  reason       text CHECK (reason IN ('sell','gamble_stake','gamble_win','gamble_loss','battle_stake','battle_win','battle_refund','crash_cashout','grant')),
  ref_id       uuid,                   -- session/sale/battle id
  created_at   timestamptz DEFAULT now()
)

capsule_opens (
  id           uuid PK,
  player_id    uuid,
  rarity       text,
  character_id uuid REFERENCES characters,
  pity_counter int,
  created_at   timestamptz DEFAULT now()
  -- odds scale with player rank tier (#86)
)

arena_matches (
  battle_id    uuid PK REFERENCES battles,
  stake        int,                    -- capsule stake
  char_stake_a uuid REFERENCES characters,   -- NEW (#116): optional character stake
  char_stake_b uuid REFERENCES characters,
  escrow_a     int,
  escrow_b     int,
  settled      boolean DEFAULT false
)

gamble_sessions (                      -- NEW (#123)
  id           uuid PK,
  player_id    uuid,
  mode         text CHECK (mode IN ('pot','crash')),
  status       text CHECK (status IN ('active','won','lost','cashed_out')),
  pot_value    int,                    -- summed net worth of entries
  seed_commit  text,                   -- HMAC hash committed pre-round (provably fair)
  result       jsonb,
  created_at   timestamptz DEFAULT now()
)

gamble_pot_entries (                   -- NEW (#123): 1–3 characters per pot
  session_id   uuid REFERENCES gamble_sessions,
  character_id uuid REFERENCES characters,
  PRIMARY KEY (session_id, character_id)
  -- enforced: 1–3 entries per session; entries locked while active
)

crash_sessions (                       -- NEW (#126): Monster Crash state
  session_id   uuid PK REFERENCES gamble_sessions,
  crash_point  numeric,                -- server-chosen, HMAC-derived
  cashout_mult numeric,                -- null = crashed
  payout_character_id uuid REFERENCES characters
)

rarity_bands (                         -- NEW (#121): exponential net worth → rarity
  rarity       text PK,
  min_net_worth int NOT NULL           -- band edges grow exponentially
)
```

## Lore & verification

```sql
character_lore (
  character_id uuid PK REFERENCES characters,
  name         text,
  lore         text,
  catchphrase  text,
  personality  text,
  generated_at timestamptz
)

gym_checks (
  id           uuid PK,
  player_id    uuid,
  photo_path   text,
  vision_result jsonb,
  passed       boolean,
  checked_at   timestamptz,
  UNIQUE (player_id, date(checked_at))
)
```

## Invariants (enforced by DB + backend)

1. `capsule_ledger` and `coin_ledger` balances per player never negative (trigger).
2. Battle insert requires: squad size 3, all units scanned today, no fatigue (ranked), none locked.
3. `day_logs` unique (player, barcode, date) — one barcode per day.
4. Merge consumes exactly **3** same-character, same-star characters (`merge_events_validate`).
5. Arena settle is a single transaction: pot transfer + ledger entries + lock release.
6. Every table has RLS: player rows owner-only; `products`, `seasons`, `character_catalog`, `attacks`, `rarity_bands` world-readable.
7. `characters.rarity` is always consistent with `net_worth` via `rarity_bands` — revaluation on every mutation (#120).
8. `gamble_pot_entries` per session ∈ [1,3]; entries and staked characters carry `locked=true` until session/settlement closes.
9. All gamble outcomes derive from a committed seed (hash stored pre-round) — never client input.
10. Rank points award once per (player, day) — idempotent.
