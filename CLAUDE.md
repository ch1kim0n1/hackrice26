# Working in this repo

Orientation for AI assistants (and humans in a hurry). Read this before
touching anything; it is mostly the things that are expensive to discover by
trial and error.

Product docs live in [`docs/`](docs/README.md). This file is about *how to
work here*, not what the game is.

---

## The shape of the repo

| Path | What it is |
|---|---|
| `backend/` | Express + TypeScript API. Runs today, on SQLite. |
| `backend/migrations/` | Postgres schema for TigerData (Tiger Cloud). Migrations + RLS + rule enforcement. |
| `ios/` | SwiftUI app. SPM packages `NutriQuest`, `NutriQuestUI` (design system), `BattleKit` (deterministic battle engine). |
| `docs/` | Canonical design + schema documentation. |
| `design/` | `.dc.html` mockups and hand-drawn character SVGs. |

### There are two databases, and they are not the same thing

This trips everyone up.

- **SQLite** (`backend/src/db.ts`, `backend/src/db/migrations/*.ts`) is what the
  running backend uses *right now*. Per-player state: lootbox sessions,
  inventory, cauldron rounds.
- **TigerData** (`backend/migrations/*.sql`) is the Postgres/TimescaleDB target
  on Tiger Cloud: players, profiles, characters, battles, ledgers, RLS, plus the
  `telemetry` hypertables and `analytics` continuous aggregates. Today the app
  writes it as a mirror; SQLite is still the source of truth.

Those two are the whole story. There is no third store.

They model overlapping concepts with different table shapes. A change to one is
usually **not** automatically a change to the other. Work out which one the task
means before writing anything.

---

## Running things

```bash
# Backend
cd backend && npm install          # do this after every pull; deps move
npm test                           # vitest, must be green
npx tsc --noEmit -p .              # must be clean
npm run dev                        # :4000

# Database schema (needs Docker, and `npm run build` first)
docker run -d --name nq-db -p 55444:5432 -e POSTGRES_PASSWORD=ci -e POSTGRES_DB=nq timescale/timescaledb-ha:pg17
export DATABASE_URL=postgres://postgres:ci@localhost:55444/nq
node dist/db/migrate-pg.js          # apply every migration, exactly once each
node scripts/check-pg-schema.js     # shape: ledger parity, RLS, grants, ladders
node scripts/apply-sql-dir.js seed  # fixtures
node scripts/run-db-invariants.js   # the game's rules, asserted for real
                                    # Those four ARE the CI gate
                                    # (.github/workflows/tigerdata-db.yml).
                                    # Run them after any migration change.

# iOS
cd ios && xcodegen generate        # REQUIRED after adding/removing any source
                                   # file — the .xcodeproj is generated from
                                   # project.yml and is not checked in
./scripts/test-ios.sh              # note: pipes through `tail -40`, so use
                                   # xcodebuild directly if you need full output
```

To see the app actually running, use the `run` skill. The simulator app reads
its backend URL from `UserDefaults` (`config.backendBaseURL`); point it at
`http://localhost:4000` to test against local changes, and remember the App
Store build points at Railway, which will not have your new endpoints.

**QA launch arguments** (existing convention, for screenshots without tapping):
`-uiTab <tab>`, `-uiSection <casino|battle>`, `-uiGame cauldron`.

---

## Rules that are not negotiable

From [`docs/CONVENTIONS.md`](docs/CONVENTIONS.md), plus what CI enforces:

- **iOS builds with zero warnings.** Not "no errors" — zero warnings.
- **Design system only.** Screens consume `NQTheme` / `NQText` / `nqPadding` /
  `nqElevation` / `@Environment(\.nqAccent)`. A raw hex colour or a magic
  padding number in feature code is a review reject.
- **Deployment target is iOS 16.0.** `scrollBounceBehavior`, `.topBarTrailing`
  and friends are newer — the compiler will tell you, but check before reaching
  for a modern modifier.
- **Zod-validate every request body.** No `any` in TypeScript.
- **Game maths is pure and deterministic.** No `Date()` or `Double.random`
  inside `BattleKit` — seeded RNG only, because the server replays the same
  fight.
- **Migrations are append-only.** Never edit an applied migration; correct it
  with a new one. Databases in the field will not re-run the old one.

---

## Traps

**New Postgres tables need their own RLS.** `0011_rls_policies.sql` swept every
table with a `player_id` that existed *at the time it ran*. Anything created
later must `enable row level security` and add its own `player_isolation` policy
— 0012 forgot, and `app.cauldron_rounds` and `telemetry.body_metrics` went
unprotected until `0017`. `scripts/check-pg-schema.js` now fails the build on
this, so you will hear about it, but write it into the migration in the first
place. Columnstore hypertables are the one exemption: Timescale does not support
RLS there, which is why `telemetry.battle_metrics` and
`telemetry.nutrition_deltas` are skipped.

**A revoke needs its re-grant.** `0015` revoked the inherited table grant on
`app.mines_rounds` to hide the mine `layout` behind a column grant, and never
restored INSERT/UPDATE — so the mirror could not write at all, silently, because
it only `console.warn`s. If you narrow a grant, re-grant what the app still
needs and add it to `check-pg-schema.js`.

**`backend/data/` is gitignored.** It holds the SQLite file. Source data files
put there silently never get committed — `backend/src/data/` is where authored
data belongs (see `characters.json`).

**One economy ladder.** `backend/src/game/rarityBands.ts` is the single source
of truth for what a monster is worth and which rarity a value maps to. Cauldron
Crash used to have its own parallel table; it was deleted for a reason. Do not
add a second one — see [`docs/NET-WORTH.md`](docs/NET-WORTH.md).

**Star levels are 1-based (1–5).** Every monster has at least ★1. The old
`fusion_tier` was 0-based; `0011_star_levels.sql` renamed and rebased it.

**The canonical stat set is four stats**: `power / guard / vitality / tempo`.
Adding a fifth means changing the zod schema, the SQL functions, BattleKit,
every stored `base_stats` blob and every battle replay. It is a migration, not
an edit.

**Asset catalogue names collide.** Xcode derives Swift symbols from imageset
names, so `broccoli-bud` and `BroccoliBud` both become `broccoliBud` and you
get a warning plus an arbitrary winner. Check before adding an imageset whose
name matches an existing one in another case.

**Cauldron Crash is server-authoritative.** The crash point is drawn server-side
and is never sent to the client while a round is live. If you find yourself
adding it to a live payload, stop.

---

## Conventions for commits and PRs

- Branch per feature off `main`. PR into `main` with a summary and a test plan.
- Imperative commit subject, ≤60 chars. The body explains **why**, not what.
- **No AI attribution.** No `Co-Authored-By` trailer, no "Generated with" line,
  in commits or PR descriptions. This is a standing preference — respect it
  without being asked.

## Before you say you are done

Run the gates for whatever you touched, and report what actually happened:

| Changed | Run |
|---|---|
| `backend/` | `npm test` + `npx tsc --noEmit -p .` |
| `backend/migrations/`, `backend/seed/` | the four DB commands above (migrate \| check \| seed \| invariants) |
| `ios/` | `xcodegen generate` + build (zero warnings) + `./scripts/test-ios.sh` |

If a change spans the economy, the schema and the app, run all three. They
catch different things, and this repo has had all three break independently.
