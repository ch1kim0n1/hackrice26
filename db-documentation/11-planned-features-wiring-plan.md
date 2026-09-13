# 11 — Planned-feature wiring plan (not on `main`)

Purpose: for every feature that is **schema-covered but not yet implemented in application code** — either because it's marked "planned" in [02](02-feature-map.md), or because it lives only on a branch other than `main` (`origin/dev`'s LAN work) — say exactly what needs to be built and in what order. This is a plan, not an implementation: no route, service, or migration in this document has been written. It assumes the `main`-branch wiring in [08](08-implementation-and-validation.md) (slices 1–5) lands first, because every planned feature below reuses `db/pg.ts`, `withPlayer`, the command-receipt pattern, and the event tables it introduces.

Every deployed table these features need already exists (migrations `0001`–`0006`; confirmed in the [10](10-schema-parity-audit.md) parity audit). Nothing here requires a new migration except where explicitly called out.

## Ordering and why

These do not compete with each other for schema, but they do compete for review/test attention. Suggested order, each gated on the previous reaching its acceptance gate:

1. Character lore/art content (lowest risk — additive content, no economy impact)
2. Fusion (touches ownership/inventory but is single-player, no matchmaking)
3. Gym-photo verification + training buffs (single-player, but needs an object-storage decision first)
4. LAN casual PvP + tournament persistence (isolated — explicitly non-ranked, can't corrupt economy)
5. Ranked matchmaking, Elo, fatigue (introduces cross-player matching)
6. Arena stakes (depends on ranked/rating existing, and moves currency between players)
7. Seasons (depends on rankings and battle_metrics history existing to roll up)

## 1. Character lore / art content

- **State today:** `character_definitions` and `character_content` tables exist; `services/artPrompt.ts` builds prompts but nothing persists a result against a character.
- **Build:** a `lore` service that calls the configured provider (Groq per `.env.example`'s `GROQ_API_KEY`), writes `character_content` rows keyed by `(character_definition_id, content_type, rules_version)`, and records provider/model/status per row (07's "replaceable integrations with recorded version and status"). Serve from `routes/characters.ts` with a cache — this is read-heavy, write-once content, not a hot path.
- **No new tables.** No transactional concurrency concerns — it's an upsert-if-absent, not a player-facing mutation.
- **Gate:** provider failures degrade to "lore unavailable," never a blocked screen.

## 2. Fusion

- **Target tables:** `fusion_operations`, `fusion_inputs` (from [03](03-relational-model.md)); reads/writes `owned_characters`.
- **Build:** `game/fusion.ts` — pure, versioned rules (which rarity/element combinations fuse, what the result is) mirroring the existing `game/rarity.ts` / `game/baseStats.ts` pattern. A `routes/fusion.ts` command handler follows the doc-05 transaction contract exactly: lock the *sorted* set of input `owned_characters` ids, verify all are unconsumed and owned by the caller, mark them consumed, insert `fusion_operations` + `fusion_inputs` (preserving lineage), mint the result via the same acquisition path scans use, append one `gameplay_events` row.
- **Concurrency guard:** unique-consumed-input constraint (a copy can only ever be an input once) plus the sorted-lock rule in [05](05-transactions-and-live-battles.md) — this is the same shape as a crate open, just with N locked inputs instead of a wallet.
- **Activate under `rules_version`.** Do not let a fusion result formula change retroactively explain an old fusion.
- **Test before merge:** concurrent fusion attempts using the same copy twice — one must fail cleanly, not consume the copy twice.

## 3. Gym-photo verification + training buffs

- **Target tables:** `gym_checks`, `training_buffs`, `media_objects`.
- **Blocking decision (Phase-0, still open per [09](09-decisions-and-sources.md)):** pick the object-storage provider for the photo itself. The DB only ever stores a reference/hash/status in `media_objects` — do not park base64 photos in Postgres.
- **Build:** an upload route that gets a private object reference, a verification step (vision-model check per `OPENAI_API_KEY` in `.env.example`) that writes a `gym_checks` row with the model's decision and the rules snapshot used, and — only on a verified check — a `training_buffs` row with an explicit expiry. Battle eligibility reads the buff row, never re-derives "verified" from the photo.
- **Concurrency guard:** one reward-eligibility window per check (doc 05's pattern for promo/quest claims applies directly — unique entitlement, one grant).
- **Privacy:** photo bytes never enter logs; 07's redaction rules apply in full here, this is the feature most likely to leak a private image into a log line if rushed.

## 4. LAN casual PvP + tournaments (`origin/dev`)

- **State today:** iOS-only, on `origin/dev` (`ios/Sources/NutriQuest/LAN/`), inspected read-only for the parity audit, **not merged**. No backend counterpart exists.
- **Target tables (optional, only if online persistence is wanted):** `lan_sessions`, `tournaments`, `tournament_entries`, `tournament_matches`.
- **Non-negotiable boundary (already decided, [05](05-transactions-and-live-battles.md) and [09](09-decisions-and-sources.md)):** LAN stays casual/unranked. Uploaded LAN results are excluded from ranked metrics, economy grants, and anti-cheat evidence — they get provenance-tagged rows, never a path into `rankings` or `wallets`.
- **Build order:**
  1. Merge (or cherry-pick, reviewed) the `origin/dev` iOS LAN source into a feature branch off the *post-wiring* `main`, not directly — it predates the pg cutover and will need its networking layer checked against whatever session/auth shape lands in slice 2.
  2. Decide whether LAN needs backend persistence at all for the hackathon (it can be fully host-authoritative and local, per 05's "Offline and LAN trust boundary" — that's the cheaper path and may be sufficient).
  3. If persistence is wanted: bracket/match state transitions (`bye`, `walkover`, `host disconnect`) are explicit rows, never inferred; a byes/walkover is not a fabricated combat result.
- **Gate:** an integration test that a LAN result cannot mint currency, XP, or a rating change under any code path.

## 5. Ranked matchmaking, Elo, fatigue

- **Target tables:** `matchmaking_entries`, `rankings`, `fatigue`.
- **Depends on:** the async-battle settlement transaction from main-branch slice 4/5 already being pg-backed — ranked settlement is "the same battle-settlement transaction, plus a rating update," not a parallel system.
- **Build:** `game/elo.ts` already exists (pure function, tested) — it's the settlement wiring that's missing. A matchmaking queue table + a lease-based matcher (07's job table pattern: "Battle timeout / matchmaking leases, once per minute"). Settlement extends the doc-05 battle-settlement transaction to also write `rankings` and `fatigue` in the same commit — never a separate follow-up write.
- **Concurrency guard:** "battle version/state and unique settlement operation" from 05's transaction-boundary table applies unchanged; add matchmaking-lease uniqueness so two workers can't pair the same queued player twice.
- **Explicit rule from [09](09-decisions-and-sources.md):** never calculate authoritative Elo from a delayed aggregate — `rankings` is written transactionally at settlement, continuous aggregates are for the trend charts only.

## 6. Arena stakes

- **Target tables:** `arena_escrows`, plus `currency_entries`/`wallets` transfers.
- **Depends on:** ranked/rating existing (arena is framed as a rated-adjacent mode in [02](02-feature-map.md)) and the wallet-lock pattern from crate-open wiring.
- **Build:** create-escrow locks the stake from both wallets in one transaction (sorted player-id lock order, per 05); settle-escrow is a single transaction that either pays the winner or refunds both on a defined cancellation path — "unique settlement/refund" is the guard already specified in 05's transaction table.
- **Non-negotiable:** no real-money system — stakes are earned in-game currency only ([09](09-decisions-and-sources.md)).

## 7. Seasons

- **Target tables:** `seasons`, `season_progress`, `season_reward_claims`.
- **Depends on:** `rankings` and `battle_metrics` history existing (seasons roll those up), so this is last.
- **Build:** a season-close/season-start job following 07's "Season transitions — hourly catch-up against configured boundaries" and 05's "Large season payouts run in small repeat-safe batches... A season remains in `closing` until reconciliation confirms all required batches." Do not hold every player's lock in one transaction.
- **Concurrency guard:** unique season-transition job (idempotent close/start) + per-player repeat-safe reward grant, exactly as specified in [05](05-transactions-and-live-battles.md).

## What this plan deliberately does not cover

- Live/interactive (non-automatic) battle turns — [05](05-transactions-and-live-battles.md) already scopes that as a future flow layered on the same battle transaction once the automatic loop is fully wired; it is not planned-feature-specific.
- Remote push notifications — `notifications`/`ops.outbox` tables exist; wiring is part of main-branch slice 5 (event model), not a standalone planned feature.
- Anything requiring a new schema object: none of the above needs one. If implementation surfaces a genuine gap, add a migration numbered after the current head (`0012+`) and record it here and in [CHANGELOG](CHANGELOG.md), the same way `0009` closed the two gaps found in the [10](10-schema-parity-audit.md) audit.

## Update log

- **2026-09-12** — Initial version, written after the main-branch schema/runtime-foundation slice landed. No implementation started on any item above.
