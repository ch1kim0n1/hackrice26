# 03 — Ordinary PostgreSQL model

These are proposed schema contracts, not executable DDL. All tables in this document are ordinary PostgreSQL tables, even when they have timestamps. The point is stable identity, relations, and transactional updates. Time facts are defined separately in [04](04-timescale-design.md).

## Conventions

- Schemas: `app` for domain data, `telemetry` for hypertables, `analytics` for read models, `ops` for jobs/sync. No dependency on provider-specific authentication or object-storage schemas.
- `players.id` is an opaque server-generated text ID (retain the API's string ID contract). New domain object IDs and client command IDs are UUIDs. Never derive a player ID from a username or accept one as authentication.
- Use `timestamptz` for real instants, UTC in transport, a stored IANA zone for a game day, and a `date` for its display label. Use server timestamps for rewards and expiry.
- Store seeds/large nonces without JavaScript precision loss: database integer/byte representation plus decimal or hex strings in JSON. Currency is integer units, never floating point. API values must be explicitly range-checked.
- Every mutable aggregate root has a monotonically increasing `version`. Every important derived record names its `rules_version` and input revision(s).
- Foreign-key columns are indexed where joins/deletes need them. Standard timestamps such as `created_at`/`updated_at` are omitted from the inventory for readability but required where meaningful.
- `PK` means primary key; `UQ` means a required uniqueness constraint. All owned rows carry `player_id`; owner-consistent composite references or transactional checks prevent linking another player's objects.
- JSONB holds versioned snapshots and provider metadata, not fields routinely filtered/sorted such as player, mode, time, rarity, calories, status, or balances.

## Identity, configuration, and daily boundaries

| Table | Key / important columns | Required behavior |
|---|---|---|
| `app.players` | PK `id`; display name, account status, `version` | Server-controlled identity; soft-disable immediately during deletion. |
| `app.credentials` | PK/FK `player_id`; UQ normalized username; password hash and parameters | Retain a suitable password KDF; no plaintext passwords or public grants to this table. |
| `app.sessions` | PK token hash; player, device, expiry, revoked time | Store hash, not raw bearer token; expiry/revocation checked server-side. |
| `app.devices` | PK `id`; owner, platform, linked/revoked time, push-token reference | Device membership does not grant authority for a different player. |
| `app.player_settings` | PK player; theme, active-character reference, preferred squad, game timezone, notification preferences | Ownership-validate references; device permission state itself stays on device. |
| `app.profile_versions` | PK `id`; UQ `(player_id, revision)`; measurements, activity/goal, calculated targets, formula version | New version on meaningful change; privacy-sensitive; past battle snapshots never rewritten. |
| `app.rule_sets` | PK version string; immutable config/checksum, activation time | Loot, combat, eligibility, target, buff, and reward configuration with code/algorithm version. |
| `app.game_days` | PK `id`; UQ `(player_id, sequence)` and `(player_id, starts_at)`; display date, timezone, start/end, profile/rule versions | One non-overlapping active interval per player, created under player lock; a day can be 23/25 hours across DST. |

Daily queries use `game_day_id`, not a bare server `CURRENT_DATE`. Onboarding selects a timezone. A timezone change takes effect only after the current day ends, at most once per seven days initially. New intervals continue from the prior end and end at the next midnight in the selected zone; do not give an immediate extra reward reset. Labels may repeat during travel, so they are not the identity key. The backend creates days lazily and a worker finalizes ended days; a single worldwide midnight reset is not appropriate.

## Nutrition, activity, and verification

| Table | Key / important columns | Required behavior |
|---|---|---|
| `app.products` | PK barcode; provider, normalized nutrition per declared unit, name/brand, food group, freshness, source payload hash | Shared lookup cache, not a player's intake. Explicit units and unknown values. |
| `app.product_enrichment` | PK `(barcode, provider, region)`; observed price/scarcity inputs, fetched time | Optional planned enrichment; not a promise that an external API is configured. |
| `app.meal_drafts` | PK `id`; player, media reference, analysis status, expiry, model version | Editable, unconfirmed data; no rewards or intake before confirmation. |
| `app.meals` | PK `id`; player, current revision, consumed time, game day, source kind, consumed/deleted status | Durable current intake record; creation command unique through receipt. |
| `app.meal_revisions` | PK `(meal_id, revision)`; correction reason, totals, source confidence, recorded time | Immutable revision. Corrections append a revision; do not erase provenance. |
| `app.meal_items` | PK `(meal_id, revision, item_id)`; product/reference, portion g, label, food group, normalized nutrient fields, missing-value flags | Store confirmed edits, not just image/model output. Support calories, macro nutrients, sodium and six tracked micronutrients. |
| `app.scan_claims` | PK `id`; player, game day, barcode/confirmation identity, entitlement, rules version | UQ eligibility key for the selected rule (barcode/day for barcode credit); distinguish intake logging from grant eligibility. |
| `app.daily_activity` | PK `(player_id, game_day_id)`; source revision, steps/energy/exercise/stand totals, coverage, latest measured time | Canonical consolidated totals, not the sum of cumulative snapshots from several devices. |
| `app.workouts` | PK `id`; UQ `(player_id, source_system, source_workout_id)`; type, start/end, duration, energy, revision, deletion state | Keep completed workout summaries separately from short-lived raw sensor samples. |
| `app.gym_checks` | PK `id`; player/day, object reference, verification status, result/version | Unique successful entitlement per player/day; failed attempts rate-limited without permitting duplicate grants. |
| `app.training_buffs` | PK `id`; player, gym-check/workout source, kind, start/end, rule version | Explicit combat/reward scope; no implicitly stacked conflicting gym rules. |
| `app.media_objects` | PK `id`; owner, object key, purpose, status, expiry, hash | Private photos require signed access; store no public permanent photo URL. |

Nutrition totals use the actual consumed quantities, not the number of scans. A corrected item emits negative old and positive new values to `nutrition_deltas` within the same transaction. Daily game eligibility and rewards follow the pinned game rules; a historical correction does not reopen a settled battle or recreate a claimed reward.

## Progression, daily loop, collection

| Table | Key / important columns | Required behavior |
|---|---|---|
| `app.daily_state` | PK `(player_id, game_day_id)`; nutrient breakdown, multiplier, objective state, source revisions, version | Synchronously updated authoritative gameplay projection. Do not calculate it from a delayed continuous aggregate. |
| `app.daily_history` | Same PK; day summary, scan/open/battle counts, nutrition/activity totals, targets, finalization/revision | Durable compact Journey history; can accept labeled historical nutrition corrections without changing awarded progress. |
| `app.player_progress` | PK player; XP, level, lifetime scan/open/win counters, version | Transactional counters plus durable reward receipts; periodic reconciliation. |
| `app.streak_state` | PK player; last qualifying day sequence, streak/best streak, freeze inventory/use | Unique freeze use per day; server clock, not arbitrary client date resets. |
| `app.daily_quests` | PK `(player_id, game_day_id, quest_id)`; chosen definition/version, progress/target | Deterministic or once-persisted selection; retries do not reroll. |
| `app.quest_claims` | PK `(player_id, game_day_id, quest_id)`; command/result references | Exact entitlement cannot be claimed twice. |
| `app.comeback_claims` | PK `id`; UQ `(player_id, eligibility_interval_id)` | Determine away interval under lock; repeat requests cannot generate another comeback. |
| `app.achievement_unlocks` | PK `(player_id, achievement_id, definition_version)`; achieved time, evidence reference | Survives disposal of contributing event detail. Version migration must not regrant unintentionally. |
| `app.claim_receipts` | PK `id`; UQ `(player_id, entitlement_type, entitlement_key)`; XP/currency/ownership effect references | Common permanent proof for objective, milestone, battle and season grants. |
| `app.character_definitions` | PK `(definition_id, version)`; name, rarity, element, base stats, provenance | Shared catalogue with seven-tier support; snapshots retain older definitions. |
| `app.owned_characters` | PK `id`; player, definition/version or generated snapshot, fusion tier, status, acquisition ID | One row per actual copy. Do NOT use player/barcode/tier as a uniqueness constraint that destroys duplicates. |
| `app.character_acquisitions` | PK `id`; player, source kind/ref, immutable acquired character snapshot | Permanent acquisition evidence; independent of replay retention. |
| `app.character_content` | PK `(content_identity, content_version)`; lore, art reference, generator status/version | Shared or instance-specific as appropriate; retries reuse a stable request identity. |
| `app.squads` / `app.squad_members` | PK squad; members PK `(squad_id, slot)`, UQ character per squad | Slot limits from mode rules; only owned, available copies; no trust in client-submitted stats. |
| `app.fusion_operations` / `app.fusion_inputs` | PK operation; input PK `(operation_id, character_id)`, UQ consumed character | Lock eligible copies, consume exactly five under the activated rule, create result in one transaction. Consumed copies keep lineage and are excluded from available collection. |

“Permanent collection” means ownership is never removed by a temporary cache/history policy. Fusion explicitly changes ownership availability; account deletion still removes personal data. A UI inventory display cap must not delete earned acquisition receipts or silently destroy owned copies.

## Economy and fairness

| Table | Key / important columns | Required behavior |
|---|---|---|
| `app.wallets` | PK `(player_id, currency)`; available balance, version | Balance nonnegative; keys and optional earned capsules are distinct currencies. |
| `app.currency_entries` | PK `id`; UQ `(operation_id, entry_index)`; player/system account, currency, signed integer amount, reason/ref | Append-only durable transfer/issuance/burn ledger; corrections use compensating entries. |
| `app.crate_definitions` | PK `(crate_id, rules_version)`; cost, pool, rarity weights, pity policy | Pin on each open; validate pool/weight consistency before activation. |
| `app.pity_state` | PK `(player_id, pity_scope)`; counters, version | Scope matches the activated crate policy; no accidental switch to older global/four-tier logic. |
| `app.fairness_seeds` | PK `id`; player, commitment, encrypted/private seed, client seed, next nonce, state/reveal time | Active seed never public; rotation and nonce allocation locked atomically. |
| `app.crate_opens` | PK `id`; UQ `(seed_id, nonce)`; crate/rules, roll inputs, pity before/after, cost, acquired instance, commitment | Compact permanent verification receipt; omit private active seed from public response. |
| `app.promo_codes` / `app.promo_redemptions` | PK code ID; UQ normalized code; redemption UQ `(code_id, player_id)`; caps/expiry/reward | Lock global usage and wallet; validate authorization of administrative code changes. |

Wallet rows are the fast read model; the ledger explains/reconciles them. Both change in one transaction. Issuance and burns have explicit system-account/reason semantics; arena transfers cannot create currency except an explicitly authorized issuance. A SQL `CHECK` can protect an individual nonnegative balance, but it cannot enforce multi-row accounting by itself: locked transactions and reconciliation are required.

## Battles, dungeon, ranked, arena, seasons, LAN

| Table | Key / important columns | Required behavior |
|---|---|---|
| `app.battle_requests` | PK `id`; requester, challenged player/matchmaking ref, expiry, status | Authorize both participants; deterministic accept/decline/expiry transitions. |
| `app.battles` | PK `id`; UQ `(id, stream_started_at)`; mode, rules, seed, status, version, last event sequence, checkpoint, end time, settlement state | `stream_started_at` immutable; terminal states require an end time. Valid state machine and optimistic/row locking. |
| `app.battle_participants` | PK `(battle_id, slot)`; player or NPC identity, profile/day IDs, immutable unit/target/multiplier/buff snapshot | UQ participating player per battle where applicable. Snapshot is sufficient to explain the battle after original health detail expires. |
| `app.battle_results` | PK battle; winner/draw, compact outcome, rounds, final HP, replay hash, settlement receipt, algorithm version | Durable result after event expiry; reward/grant state cannot be reconstructed solely from expired events. |
| `app.dungeon_runs` / `app.dungeon_floor_results` | PK run; floor PK `(run_id, floor)`; seed/rules, squad/carry HP, best floor, compact outcomes | Optional detailed floor replay links to battles; retain compact completed-run result. |
| `app.dungeon_state` | PK player; best floor, accrual boundary, fractional remainder, current rate, version | On rate change first settle accrual at the old rate; claims use server time and one locked boundary. |
| `app.matchmaking_entries` | PK player/mode slot; rating/season, squad version, expiry, lease | One active entry per mode; acquire compatible players transactionally, handle abandonment. |
| `app.fatigue` | PK scope (player or owned character, as pinned rules specify); until, source battle, cleared-by receipt | Recovery must be a verified eligible action; TTL checked at request time. |
| `app.seasons` | PK `id`; unique configured interval; rules, start/end, state | Idempotent open/close; no duplicate active intervals for a mode. |
| `app.rankings` | PK `(season_id, player_id)`; rating, tier, wins/losses, version | Index `(season_id, rating DESC, player_id)`; tie ordering explicit. |
| `app.season_progress` / `app.season_reward_claims` | PK progress `(season_id, player_id)`; claim includes reward ID | Daily score caps and once-only reward tiers. Closing season pins standings before payout. |
| `app.arena_escrows` | PK battle; participant stakes, currency, status, settlement operation | Funds reserved before start; exactly one settle OR refund; explicit integer burn rounding. |
| `app.lan_sessions` | PK session; authenticated uploader, protocol version, trust=`unverified_local`, summary hash | Optional history synchronization, never proof of online authority. |
| `app.tournaments` / `app.tournament_entries` / `app.tournament_matches` | PK tournament; entrant UQ tournament/player; match UQ tournament/round/slot | Bracket revision, byes, walkovers, host/trust mode; retain online-authoritative and local-casual outcomes distinctly. |
| `app.notifications` | PK `id`; player, type, related object, read/status/expiry | Sanitized user-facing payload; push is a delivery hint, not the only copy of a battle result. |

Automatic battles initially need a compact terminal checkpoint, not a long-lived match actor. Future interactive matches use the same state/event model with per-turn version checks. Do not introduce a distributed game server solely to animate an already-computed replay.

## Operational tables

| Table | Key / required behavior |
|---|---|
| `ops.command_receipts` | PK `(player_id, command_id)`; command type, canonical request hash, status, result reference. Compact receipt retained with the account for meaningful gameplay mutations. Same key/different request -> conflict. |
| `ops.command_responses` | Same key; optional cached response body, expires after 7 days. Expiry does not remove the permanent receipt or authorize re-execution. Never cache image bytes/secrets here. |
| `ops.ingest_keys` | PK `(player_id, source_system, source_id, revision)`; payload hash, canonical measurement time, applied/deleted state. Thirty-day dedup/tombstone window plus explicit admissible event-age checks. |
| `ops.health_sync_cursors` | PK `(player_id, device_id, data_type)`; last acknowledged source cursor/anchor and policy version. Revocation resets access, not another device's data. |
| `ops.outbox` | PK event UUID; aggregate ID/version, minimal payload/ref, status, available time, lease, attempts. Inserted in the same transaction as the domain change. |
| `ops.jobs` | PK job ID; unique job key, kind, input refs, lease, attempts, next run, dead-letter reason. `FOR UPDATE SKIP LOCKED` leasing and retry-safe handlers. |
| `ops.player_sync_heads` / `ops.player_changes` | Head PK player with next sequence; change PK `(player_id, sequence)` with entity/version/tombstone. Allocate under per-player lock so committed order is safe for cursor sync. |
| `ops.lifecycle_checkpoints` | PK `(stream, range_start, range_end, task)`; refresh/finalization/deletion status and validated watermark. Required before destructive cleanup. |
| `ops.admin_audit` | PK ID; actor, action, target refs, redacted change summary/time. No credentials or raw health/photo payloads. |

Do not use a plain global sequence as proof that every earlier change committed: concurrent transactions can commit out of order. Per-player ordered sync allocation or an equivalent proven protocol is required.
