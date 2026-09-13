# NutriQuest Data Schemas

Every piece of user-wise data collected and analyzed by the backend.

All entities are **per-player** (keyed by `X-Player-Id` header, pattern `^[A-Za-z0-9_-]{6,64}$`).
All persisted state lives in SQLite (`data/nutriquest.db`, override with `NUTRIQUEST_DB`).
Schemas are JSON Schema (draft 2020-12). `$ref` links resolve relative to this directory.

## Entity map

| Schema | Table | Persisted | Cap | Description |
|---|---|---|---|---|
| [user-profile.json](user-profile.json) | `user_profile` | ✓ | 1/player | Display name, level, streak, battles won, active character, color mode |
| [scan-seen.json](scan-seen.json) | `scan_seen` | ✓ | ∞ | Daily barcode scan log. Enforces one-barcode-per-day. Resets daily (UTC) |
| [scan-character.json](scan-character.json) | `scan_character` | ✓ | ∞ | Characters minted from food scans. Composite PK (player_id, char_id) |
| [character-payload.json](character-payload.json) | (embedded) | ✓ | — | Character object embedded in scan_character.payload and lootbox_drop.payload |
| [lootbox-session.json](lootbox-session.json) | `lootbox_session` | ✓ | 1/player | Active fairness seed pair, key balance, nonce |
| [lootbox-retired.json](lootbox-retired.json) | `lootbox_retired` | ✓ | ∞ | Retired seed pairs (server seed revealed for verification) |
| [lootbox-drop.json](lootbox-drop.json) | `lootbox_drop` | ✓ | 200/player | Crate open history with full roll + fairness inputs |
| [loot-drop-payload.json](loot-drop-payload.json) | (embedded) | ✓ | — | Full drop result embedded in lootbox_drop.payload |
| [vitals-snapshot.json](vitals-snapshot.json) | `vitals_snapshot` | ✓ | 100/player | Apple Watch health data. Per-player isolated history |
| [stored-snapshot-payload.json](stored-snapshot-payload.json) | (embedded) | ✓ | — | Snapshot + server analysis embedded in vitals_snapshot.payload |
| [health-snapshot.json](health-snapshot.json) | (embedded) | ✓ | — | Raw HealthKit reading. All metrics optional (null) |
| [workout-summary.json](workout-summary.json) | (embedded) | ✓ | 50/snapshot | One workout from HealthKit recentWorkouts[] |
| [battle-result.json](battle-result.json) | `battle_result` | ✗ **PROPOSED** | — | Battle outcomes. NOT YET PERSISTED. See file for proposed schema |
| [battle-outcome-payload.json](battle-outcome-payload.json) | (embedded) | ✗ **PROPOSED** | — | Full battle result with event stream for replay |
| [battle-sim-unit.json](battle-sim-unit.json) | (embedded) | ✗ **PROPOSED** | — | Rarity/fusion-scaled unit in a battle |
| [battle-event.json](battle-event.json) | (embedded) | ✗ **PROPOSED** | — | One event in the replay stream (7 event types) |

## Data flow

```
iOS app
  │
  ├─ POST /scan { barcode }
  │   → scan_seen (daily log)
  │   → scan_character (minted character, if new)
  │
  ├─ POST /battle/simulate { yourSquad, opponentSquad, seed }
  │   → battle_result (PROPOSED — currently ephemeral)
  │
  ├─ POST /lootbox/crates/:id/open
  │   → lootbox_session (keys--, nonce++)
  │   → lootbox_drop (full drop record)
  │
  ├─ POST /lootbox/fairness/rotate
  │   → lootbox_session (new seed pair)
  │   → lootbox_retired (old pair, seed revealed)
  │
  ├─ PUT /user/:id { displayName, level, ... }
  │   → user_profile (upserted)
  │
  └─ POST /vitals { timestamp, heartRateBpm, ... }
      → vitals_snapshot (capped at 100/player)
```

## Privacy

- `player_id` is a client-generated opaque string (`^[A-Za-z0-9_-]{6,64}$`). Not a name, email, or account id.
- `testerId` in vitals is a random project-local id. Never a name or account identifier.
- Health metric **values** are never logged. Only metric **names** are logged (e.g. "received snapshot with metrics: stepsToday, heartRateBpm").
- All health data stays in the local SQLite file. Never sent to a third party.

## Gaps

1. **Battle results not persisted.** `POST /battle/simulate` returns the outcome but does not save it. Match history, win/loss tracking, and replay review require `battle_result` table. Schema defined in [battle-result.json](battle-result.json) — ready to implement.
2. **No scan metadata.** `scan_character` stores the minted character but not the food name, nutriments, or NOVA group from Open Food Facts. If analytics need food-level data, add a `scan_log` table.
3. **No lootbox grant audit.** `POST /lootbox/keys/grant` updates `lootbox_session.keys` but does not record who granted what, when, or why. If economy auditing is needed, add a `key_grant_log` table.
