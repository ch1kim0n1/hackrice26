# Resume context

Updated: September 11, 2026, America/Chicago.

## User request and authorization

Design NutriQuest's complete new data architecture around Tiger Data / Tiger Cloud / TimescaleDB, ordinary PostgreSQL, and device SQLite. Include all identified implemented and planned features. Create exact branch `dev-db` from main and document the plan thoroughly enough for another model to continue.

**Current authorization is design and documentation only.** Do not implement runtime changes, execute migrations, connect using downloaded cloud credentials, reset an existing database, deploy, push, or merge unless the user subsequently asks.

User accepts cloud dependence, shared compute, ongoing costs, and Timescale-specific design. User reports an existing development service and approximately $1,000 trial credit; account balance, expiry, service size, and available extensions have NOT been inspected. Offline use should rely on cached/bundled data. Battle detail should remain useful for roughly three days; other features must not lose data they depend on.

## Repository state

- Workspace: `C:\hackrice26-precode`.
- Branch: `dev-db`.
- Branch base: `f7a9e4ed2d98ec96753c132196478bfb9b568d49`, fetched `origin/main`.
- Local `main` was behind; the branch was deliberately created from the fetched remote main, not the stale local pointer.
- Branch creation command already succeeded: `git switch --no-track -c dev-db origin/main`.
- No upstream was set and nothing was pushed.
- Pre-existing working changes were preserved: `docs/README.md` and untracked `docs/TIGERDATA-MIGRATION.md`. They belong to the earlier analysis turn. Do not discard or accidentally stage them with this folder.
- `origin/dev` at the inspected `ab5d1a0` revision contains LAN PvP/tournament source not present in the main baseline. It was inspected read-only; it was NOT merged.
- Other database-oriented branches exist. Do not merge or cherry-pick them simply because their names sound related; this is a fresh design on main.

## Work completed

- Reviewed backend routes/services/game rules, iOS screens/state/networking, the HealthKit companion, pure battle logic, product plans, SQL design files, tests, and relevant LAN work on `origin/dev`.
- Verified core platform behavior against Tiger Data, PostgreSQL, node-postgres, and SQLite primary documentation. Sources and service-specific checks are in [09](09-decisions-and-sources.md).
- Produced the architecture package indexed in [README](README.md).
- No runtime implementation or cloud access occurred.

## Main decisions to preserve

- A single hosted PostgreSQL database contains both ordinary tables and Timescale hypertables.
- Six proposed hypertables: `health_samples`, `activity_observations`, `nutrition_deltas`, `battle_events`, `battle_metrics`, `gameplay_events`, all in `telemetry`.
- Ordinary PostgreSQL is authoritative for current state and durable receipts. Timescale `battle_events` is the authoritative retained event stream, not a substitute for permanent settlement records.
- Battle playback uses the backend event stream and local animation. Automatic battles can be fully simulated and persisted before playback. No database write for each rendered frame.
- Battle event access lasts 72 hours after the terminal outcome. Guarded whole-chunk cleanup protects active/unsettled battles and may retain physical bytes slightly longer.
- SQLite is a device cache plus protected outbox, not a second backend authority. Raw cache and replay expiry is 72 hours; pending user work is not silently discarded.
- Transactional daily state decides gameplay immediately. Continuous aggregates serve trends; delayed refresh must never block battle rewards or change an already-started battle.
- Use the live seven-tier loot/battle behavior as the parity baseline, not an older four-tier schema.
- Do not reimplement game formulas independently in SQL. Database constraints enforce invariants; shared versioned TypeScript game code calculates outcomes.

## Conflicts resolved or isolated

Old product plans and live behavior differ on gym buffs, duplicate scans, currencies, and some combat rules. The design supports them without silently changing balance:

- Persist `rules_version` and explicit reward/buff policies.
- Initial integration preserves tested live behavior.
- Planned capsule currency is distinct from keys; there is no automatic conversion.
- Fusion, ranked, arena, and gym verification activate only with explicit versioned product rules and their acceptance tests.
- LAN remains casual/unranked; imported offline results cannot mint online rewards or rating.

## Validation status

- Documentation checks: pending final local verification; record completion in CHANGELOG before handing off.
- Database/schema integration tests: NOT RUN; there are no new executable migrations yet.
- Cloud compatibility/performance/security checks: NOT RUN.
- Prior analysis baseline, not a test of this design: backend build passed; an earlier test run had 188 passing test cases but a Windows temporary SQLite cleanup failure (`EPERM`), so its process exit was nonzero. Re-run relevant tests during implementation and do not claim that historical result validates PostgreSQL behavior.

## Current phase: wiring features to TigerData (2026-09-12)

Schema is fully deployed on `db-19576` and up to date with `main` (incl. casino/coins/ranks/body/stars via `0012`). Feature wiring is underway using an **additive best-effort mirror** (SQLite stays source of truth). 5 features wired, ~9 remain, 6 of 7 hypertables fed by live features. **To continue, follow [12 wiring runbook](12-wiring-runbook.md)** — it has the exact recipe, status table, and next order. Reference repos: `backend/src/db/repositories/`.

## Next action for another model

1. Read this file, [README](README.md), and the decision log.
2. Check `git status` and inspect changes since this documented base. Preserve unrelated edits.
3. If the user still wants only design, review/update the documents; stop before implementation.
4. Once implementation is authorized, start phase 0 in [08](08-implementation-and-validation.md): inspect the actual service version and capabilities using server-side secrets without printing credentials.
5. Implement numbered slices in dependency order; update the checklist, decision log, and changelog after each slice.
6. Validate the whole authoritative user journey and concurrency/security/retention gates before proposing a merge to main.

When blocked, record the exact failed check, non-secret error, attempted safe alternatives, and the smallest next action. Do not label a design proposal as implemented because the corresponding documentation exists.
