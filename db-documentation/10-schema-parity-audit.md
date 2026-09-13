# 10 — Schema parity audit

Purpose: confirm the deployed TigerData schema accounts for **every** feature in the product, across the whole repo and its branches — not only LAN and food-photo scanning. Performed 2026-09-12 against the schema deployed on `db-19576`.

**Verdict: all features are covered.** Three minor, non-blocking nuances are recorded at the end for a future migration. No feature is missing a data home.

## Sources cross-checked

| Source | What it establishes | Location |
|---|---|---|
| Live SQLite runtime schema (17 tables) | What the app actually persists today | `feat/db-alignment: backend/src/db/migrations/001_initial.ts`, `002_integrity.ts` |
| Earlier relational design (20 tables + RPCs) | Fullest intended feature set | design evidence for this audit; superseded by `backend/migrations/` and since removed |
| Backend endpoints | Live API surface | `backend/src/routes/*`, `auth/*`, `vitals/*`, `nutrition/*`, `game/*`, `services/*` |
| iOS/Watch screens + state | Client-owned + server-backed features | `ios/Sources/**`, `GameState.swift`, HealthKit companion |
| LAN branch | Local PvP/tournaments | `origin/dev: ios/Sources/NutriQuest/LAN/*` (iOS-only, no backend) |
| Design docs | Intended target model | `db-documentation/02`, `03`, `04`; `docs/DATA-MODELS.md`, `ERD.md`, `BATTLE-SYSTEM.md` |

## Live SQLite runtime → deployed TigerData tables

Every one of the 17 live tables has a home:

| Live SQLite table | Deployed target |
|---|---|
| `account` | `app.players` + `app.credentials` |
| `session` | `app.sessions` |
| `lootbox_session` (keys, seed, nonce, since_epic, since_legendary) | `app.fairness_seeds` + `app.pity_state` + `app.wallets` |
| `lootbox_retired` | `app.fairness_seeds` (state `retired`/`revealed`) |
| `lootbox_drop` | `app.crate_opens` + `app.character_acquisitions` + `telemetry.gameplay_events` |
| `user_profile` | `app.profile_versions` + `app.player_settings` |
| `scan_seen` (per-day dedupe via `date(seen_at)=date('now')`) | `app.scan_claims` (`player_id, game_day_id, barcode`) |
| `scan_character` | `app.owned_characters` + `app.character_acquisitions` |
| `vitals_snapshot` | `telemetry.health_samples` + `telemetry.activity_observations` + `app.daily_activity` |
| `dish_analysis` | `app.meal_drafts` → `app.meals`/`meal_revisions`/`meal_items` |
| `quest_claim` | `app.quest_claims` (+ `app.daily_quests`) |
| `player_seen` (last_seen, comeback pending/claimed) | `app.comeback_claims` (**+ presence gap, below**) |
| `friend_squad` | `app.squads` + `app.squad_members` |
| `async_battle` (winner_side, rounds, seen_by_defender) | `app.battles` + `battle_participants` + `battle_results` + `telemetry.battle_metrics` + `app.notifications` |
| `dungeon_state` | `app.dungeon_state` (+ `dungeon_runs`/`dungeon_floor_results`) |
| `promo_code` | `app.promo_codes` |
| `promo_redeem` | `app.promo_redemptions` |

## Earlier relational design → deployed TigerData tables

All 20 covered: `players`→`players`; `profiles`→`profile_versions`/`player_settings`; `products`→`products`; `characters`→`owned_characters`+`character_definitions`; `characters_battle_snapshot`→`battle_participants.unit_snapshot`; `character_lore`→`character_content`; `fusion_events`→`fusion_operations`+`fusion_inputs`; `day_logs`→`meals`/`meal_items`+`daily_history`; `daily_state`→`daily_state`; `gym_checks`→`gym_checks`; `training_buffs`→`training_buffs`; `battles`→`battles`; `arena_matches`→`arena_escrows`(+`battles`); `rankings`→`rankings`; `seasons`→`seasons`; `fatigue`→`fatigue`; `capsule_ledger`→`currency_entries`; `capsule_opens`→`crate_opens`; `capsule_pity`→`pity_state`; `audit_log`→`ops.admin_audit`.

The PL/pgSQL RPCs (`derive_targets`, `compute_base_stats`, `assign_rarity`, `do_fusion`, `recalc_multiplier`, `close_day`, `apply_ranked_result`, `start/close_season`, `grant/open_capsule`, `create/settle_arena`, `apply_daily_caps`) are **behaviors**, implemented in versioned TS at wiring time; every one operates on tables that already exist.

## Feature families → coverage (whole product)

| Feature | Deployed home | Status |
|---|---|---|
| Auth: register/login/logout/sessions/devices | `players`, `credentials`, `sessions`, `devices` | ✅ |
| Onboarding, profile, goals, targets, game days | `profile_versions`, `game_days`, `player_settings` | ✅ |
| Barcode scan + product lookup + daily credit | `products`, `scan_claims`, `owned_characters`, `gameplay_events` | ✅ |
| Food-photo analysis + editable dish review | `meal_drafts`, `meals`, `meal_revisions`, `meal_items` | ✅ |
| Nutrition intake vs collectible eligibility | `nutrition_deltas` (signed), `scan_claims` | ✅ |
| Daily home, objectives, multiplier, activity bonus | `daily_state`, `daily_activity`, `claim_receipts` | ✅ |
| Quests, comeback rewards | `daily_quests`, `quest_claims`, `comeback_claims` | ✅ |
| XP, levels, streaks, freezes, achievements | `player_progress`, `streak_state`, `achievement_unlocks` | ✅ |
| Character catalogue/collection/lore/art | `character_definitions`, `owned_characters`, `character_acquisitions`, `character_content` | ✅ |
| Fusion | `fusion_operations`, `fusion_inputs` | ✅ |
| Crate shop, opening, pity, keys, capsules | `wallets`, `currency_entries`, `crate_definitions`, `pity_state`, `crate_opens` | ✅ |
| Provably-fair seeds | `fairness_seeds`, `crate_opens` | ✅ |
| Promo codes | `promo_codes`, `promo_redemptions` | ✅ |
| Battles, friend challenges, replays | `battle_requests`, `battles`, `battle_participants`, `battle_results`, `telemetry.battle_events`/`battle_metrics` | ✅ |
| Infinite dungeon + idle income | `dungeon_runs`, `dungeon_floor_results`, `dungeon_state` | ✅ |
| Ranked matchmaking, Elo, fatigue | `matchmaking_entries`, `rankings`, `fatigue` | ✅ |
| Arena stakes | `arena_escrows`, `currency_entries` | ✅ |
| Seasons + season track/rewards | `seasons`, `season_progress`, `season_reward_claims` | ✅ |
| Leaderboards, challenge inbox, notifications | `rankings`, `notifications` | ✅ |
| HR/HRV/resting/steps/rings/workouts | `health_samples`, `activity_observations`, `daily_activity`, `workouts` | ✅ |
| Gym-photo verification + buff | `gym_checks`, `training_buffs`, `media_objects` | ✅ |
| Journey history | `daily_history`, `character_acquisitions`, aggregates | ✅ |
| Notifications/reminders | `notifications`, `ops.outbox` | ✅ |
| LAN casual PvP + tournaments | `lan_sessions`, `tournaments`, `tournament_entries`, `tournament_matches` (optional persistence) | ✅ |
| Privacy: export/delete | cascade FKs + deletion job (`ops`) | ✅ |
| Idempotency, ingest dedup, sync, audit, lifecycle | `ops.command_receipts`, `ingest_keys`, `player_changes`, `admin_audit`, `lifecycle_checkpoints` | ✅ |

## Minor gaps

1. **Presence / pending-comeback state.** Live `player_seen` tracks `last_seen_at` and `comeback_pending_at`; `app.comeback_claims` records only *claimed* comebacks. → **Resolved** in `0009_presence_account_kind.sql` (`app.players.last_seen_at`, `comeback_pending_at`).
2. **Guest / portable accounts.** Live `players.is_portable` distinguishes header-based demo/guest users from registered accounts. → **Resolved** in `0009` (`app.players.kind` = `guest`/`registered`).
3. **Object-storage provider.** `app.media_objects` stores metadata/refs and access status, but the bucket itself (gym-photos owner-only, character-art public) is an external service still to be chosen (Phase-0 open decision). **Not a schema gap** — no migration; decide the provider at wiring time.

All feature-parity items are now addressed; item 3 is an external infrastructure choice.
