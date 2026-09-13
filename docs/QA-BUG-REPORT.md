# NutriQuest — Backend QA Report

**Branch audited:** `main` @ `6f9cbda`
**Date:** 2026-09-06
**Scope:** Backend only (`backend/`). Routes, services, middleware, persistence, per-player isolation, input validation, error handling. 168 live HTTP probes + 40 unit tests.

**Test summary:**
```
tsc --noEmit:                     clean
npm test (vitest):                34 passed, 6 failed
  src/routes/battle.test.ts:      7 passed, 5 failed  (parity)
  src/routes/scan.test.ts:        6 passed, 0 failed
  src/services/persistence.test.ts: 4 passed, 0 failed
  src/services/lootbox.test.ts:   17 passed, 1 failed (spendKeys)
```

**Live probes:** 168 curl checks across every endpoint. Auth, validation boundaries, per-player isolation, persistence across restart, error paths, type coercion, injection attempts.

---

## BLOCKERS

### B-001 — `spendKeys(0)` and `spendKeys(-n)` succeed; negative grants keys
**File:** `backend/src/services/lootboxState.ts:184-189`
**Repro:**
```ts
state.keys = 25;
state.spendKeys(0);   // true, keys=25 (no-op but "succeeds")
state.spendKeys(-5);  // true, keys=30 (GRANTS 5 keys)
```
The guard is `if (this.keys < amount) return false`. For `amount=0`, `25 < 0` is false → proceeds, subtracts 0. For `amount=-5`, `25 < -5` is false → proceeds, subtracts -5 → **increases** balance. A caller can mint unbounded keys by passing negative amounts.
**Exposure:** `/lootbox/keys/grant` validates `amount >= 1` (lootbox.ts:149), so the route itself is safe. But `spendKeys` is also called from `/crates/:id/open` with `crate.keyCost` (data-driven, currently always positive). The engine API is unsafe — any future caller, or a crate with `keyCost=0`, would expose the bug.
**Fix:** Add `if (!Number.isInteger(amount) || amount <= 0) return false;` at the top of `spendKeys`.
**Test:** `lootbox.test.ts:158-167` documents this and fails.

### B-002 — Battle parity drift persists for seeds 1, 42, 9999
**File:** `backend/src/routes/battle.ts:116-217`
The battle port was refactored to add squad bonus, 50/50 move selection, `move`/`typeMod` event fields, insertion-sort turn order, and hpShare timeout — all mirroring Swift. Despite this, 3 of 5 canonical seeds still mismatch:
| Seed | Expected (Swift) | Actual (TS) |
|---|---|---|
| `0xDEADBEEFCAFEBABE` | A, 3 | A, 3 ✓ |
| `42` | A, 6 | A, **5** |
| `1` | B, 6 | B, **?** (rounds differ) |
| `100` | A, 4 | A, 4 ✓ |
| `9999` | B, 7 | B, **?** (rounds differ) |
The two passing seeds suggest the core loop is close but a subtle RNG draw sequence or sort-comparator difference remains. The insertion sort comparator at `battle.ts:153` uses `l > r` (descending) with `a.index < b.index` tiebreak — Swift's `BattleEngine.swift` uses `sort(by:)` which is not guaranteed insertion sort for small arrays in Swift, and the tiebreak direction may differ. This is the most likely remaining drift source.
**Fix:** Verify Swift's sort is stable insertion sort with the same comparator direction. If Swift uses `Array.sort(by: >)` the tiebreak for equal keys is insertion-order preserved (Swift's sort is guaranteed stable since Swift 5.0), but the JS `swiftInsertionSort` implementation at `battle.ts:94-114` must produce the exact same element swaps. Diff the per-draw RNG sequence between Swift and TS for seed 42 to isolate the first divergence.
**Test:** `battle.test.ts:82-99` (5 parity tests, 3 failing).

### B-003 — `PLAYER_CAPACITY` throws → 500 HTML with stack trace, no JSON error
**File:** `backend/src/services/lootboxState.ts:250-253` + `backend/src/routes/lootbox.ts` (every route)
**Repro:** `MAX_PLAYERS=1`, two players hit `/lootbox/inventory`:
```
player 1: 200
player 2: 500  (HTML, not JSON)
  Error: PLAYER_CAPACITY
    at stateFor (.../lootboxState.ts:253:13)
    at .../lootbox.ts:136:25
    ...full stack trace...
```
`stateFor()` throws `new Error("PLAYER_CAPACITY")` when `sessions.size >= MAX_PLAYERS`. No route wraps this in try/catch, no express error handler exists in `index.ts`. Express's default handler returns `text/html` with the full stack trace — information leak + non-JSON response breaks iOS client.
**Fix:** Either (a) add an express error handler in `index.ts` that returns `{ error: { code: err.message } }` as JSON, or (b) catch `PLAYER_CAPACITY` in each lootbox route and return `503 { error: { code: "PLAYER_CAPACITY" } }`. Option (a) is the general fix.

---

## MAJOR

### M-001 — `/battle/simulate` and `/battle/:userId` do not require `X-Player-Id`
**File:** `backend/src/routes/battle.ts:222` (no `requirePlayerId` on `battleRouter`)
**Repro:**
```
POST /battle/simulate  (no header)  → 200  (should be 400)
GET  /battle/anything  (no header)  → 200  (should be 400)
```
Every other player-scoped router (`scanRouter`, `userRouter`, `lootboxRouter`, `vitalsRouter`) calls `router.use(requirePlayerId)`. `battleRouter` does not. `/simulate` currently ignores `playerId` (hard-coded `multA=1.2`, `multB=1.0`), so the auth gap doesn't leak data today — but it's inconsistent with the rest of the API and will leak the moment per-player multipliers are wired in (the documented design per `docs/BATTLE-SYSTEM.md §3`).
**Fix:** Add `battleRouter.use(requirePlayerId);` at the top of `battle.ts`. The iOS client already sends the header on every request (#17), so this is transparent.

### M-002 — `clientSeed` validation in `/crates/:id/open` is contradictory
**File:** `backend/src/routes/lootbox.ts:84-92`
Two sequential checks that contradict:
```ts
// Check 1 (line 84): rejects if length < 6 OR length > 128
if (clientSeed !== undefined && (typeof clientSeed !== "string" || clientSeed.length < 6 || clientSeed.length > 128))
// Check 2 (line 88): rejects if length > 64
if (typeof clientSeed === "string" && clientSeed.length > 64)
```
A 100-char `clientSeed` passes check 1 (≤128) but fails check 2 (>64). The error messages conflict: check 1 says "6-128 characters", check 2 says "64 characters or fewer". The effective limit is 64, but the first error message lies.
**Fix:** Delete check 2. Change check 1's upper bound to 64 and its message to "6-64 characters". Match `/fairness/client-seed` (lootbox.ts:184) which already enforces 1-64.

### M-003 — Duplicate validation block in `/keys/grant`
**File:** `backend/src/routes/lootbox.ts:149-154`
```ts
if (!Number.isInteger(amount) || amount < 1 || amount > 1000) {
  return res.status(400).json({ error: "amount must be an integer between 1 and 1000." });
}
if (!Number.isInteger(amount) || amount < 1 || amount > 1000) {  // ← identical
  return res.status(400).json({ error: "amount must be an integer between 1 and 1000." });
}
```
The second block is dead code — same condition, same error. Likely a copy-paste leftover.
**Fix:** Delete the second `if` block (lines 152-154).

### M-004 — `PUT /user/:id` accepts non-object body (array) as silent no-op
**File:** `backend/src/routes/user.ts:85`
**Repro:**
```
PUT /user/player-alpha  body=[1,2,3]  → 200  (returns profile, no update)
```
`const body = (req.body ?? {}) as Record<string, unknown>;` — if `req.body` is `[1,2,3]`, the cast lies. None of the field checks (`body.displayName !== undefined` etc.) match array indices, so it's a silent no-op returning 200. Should be 400.
**Fix:** Add `if (!isObject(body)) return res.status(400).json({ error: { code: "VALIDATION", message: "body must be a JSON object" } });` before the field checks. Mirror `validateSnapshot.ts:112-114`.

### M-005 — `seed: null` rejected with 400 on `/battle/simulate`
**File:** `backend/src/routes/battle.ts:268`
**Repro:**
```
POST /battle/simulate  body={"seed":null}  → 400  "seed must be a non-negative finite number"
```
The check is `if (seed !== undefined && (!Number.isFinite(seed) || seed < 0))`. `null !== undefined` is true, so it enters the check; `Number.isFinite(null)` is false → 400. But `null` should mean "not provided" (defaults to `Date.now()`), same as omitting the field. The iOS client sends `null` for optional fields by convention.
**Fix:** Change to `if (seed !== undefined && seed !== null && (!Number.isFinite(seed) || seed < 0))`.

### M-006 — `seed` precision loss for integers > `Number.MAX_SAFE_INTEGER`
**File:** `backend/src/routes/battle.ts:268, 300`
**Repro:**
```
POST /battle/simulate  body={"seed":9007199254740993}  → seed="9007199254740992" (lost precision)
POST /battle/simulate  body={"seed":18446744073709551616}  → seed="18446744073709551616" (happens to round-trip)
```
`seed` is typed as `number`. JSON parses large integers as IEEE-754 doubles, losing precision before `BigInt(seed)` ever sees them. `9007199254740993` becomes `9007199254740992`. The determinism contract requires exact seed reproduction. `Number.isFinite(1e21)` is true so the validation passes, but the seed is already wrong.
**Fix:** Accept `seed` as a string when it exceeds `Number.MAX_SAFE_INTEGER`, or document that seeds are limited to 53-bit integers. The Swift engine uses `UInt64` — the TS port can't accept full `UInt64` seeds via JSON without a string escape.

---

## MINOR

### m-001 — `/battle/:userId` returns static state, ignores `:userId`
**File:** `backend/src/routes/battle.ts:305-320`
**Repro:**
```
GET /battle/anything      → { state: { turn: "you", fatigued: false, moves: [4] } }
GET /battle/anything-else → { state: { turn: "you", fatigued: false, moves: [4] } }  (identical)
```
The `:userId` param is read but never used — `sampleCharacters.slice(0,3)` and `slice(3,6)` are hard-coded. This is a stub endpoint, but it should either be removed or scoped to the caller's `X-Player-Id` (once M-001 is fixed).

### m-002 — `/lootbox/fairness/client-seed` error message says "1-64" but rejects empty string
**File:** `backend/src/routes/lootbox.ts:184-186`
```ts
if (clientSeed !== undefined && (... length < 6 || length > 128))  // check 1: "6-128"
if (typeof clientSeed !== "string" || !clientSeed.length || ... > 64)  // check 2: "1-64"
```
Same contradiction as M-002 but on a different route. Empty string `""` passes check 1 (`undefined` skip) but fails check 2 (`!length`). Error says "1-64 characters" but the real minimum is 6 (from check 1 for non-empty strings). The two routes (`/crates/:id/open` and `/fairness/client-seed`) should agree on the same `clientSeed` policy.

### m-003 — `node:sqlite` experimental warning on every startup
**File:** `backend/src/db.ts:13`
```
(node:NNNNN) ExperimentalWarning: SQLite is an experimental feature and might change at any time
```
Printed on every `npm run dev` startup. Not a bug, but noisy. `node:sqlite` is stable enough for a hackathon demo but may change in future Node versions. Pin Node version in `package.json` `engines` or document the required Node >= 22.5.

### m-004 — `npm audit` not run (devDeps not audited)
**File:** `backend/package-lock.json`
Did not run `npm audit` this pass. Previous report (m-010) noted 3 moderate vulnerabilities in devDeps. Worth a `npm audit --audit-level=moderate` check.

### m-005 — `charactersRouter` has no `requirePlayerId` (intentional, but undocumented)
**File:** `backend/src/routes/characters.ts`
`/characters` and `/characters/:id` return static catalog data (no player-scoped state). No `requirePlayerId` middleware — correct, but the inconsistency with other routers should be documented or the router should accept optional `X-Player-Id` for future per-player catalog filtering.

### m-006 — `scan_seen` table has no TTL; "one barcode per day" is actually "one barcode forever"
**File:** `backend/src/db.ts:51-55` + `backend/src/routes/scan.ts:37-42, 140-141`
The comment at `scan.ts:118` says "one barcode per day per player" but `seenBarcode`/`markSeen` use `scan_seen` with no timestamp column. Once a barcode is marked seen, it's seen forever — a player can never re-scan the same barcode on a new day. The original in-memory `dayLogs` was reset on restart (implicitly daily-ish); the SQLite version is permanent.
**Fix:** Add a `seen_at TEXT NOT NULL` column to `scan_seen` and filter on `date(seen_at) = date('now')`, or accept the behavior change and update the comment.

### m-007 — `vitalsStoreFor` constructs a new `VitalsStore` on every call
**File:** `backend/src/vitals/vitalsStore.ts:59-61`
```ts
export function vitalsStoreFor(playerId: string): VitalsStore {
  return new VitalsStore(playerId);
}
```
Unlike `stateFor` (lootbox) which caches `GameState` in a `Map`, `vitalsStoreFor` allocates a fresh object every request. The class is stateless (all state is in SQLite), so this is correct but wasteful — every `/vitals/*` call allocates + GCs a `VitalsStore`. Not a bug, just an inconsistency with the lootbox pattern.

---

## Per-player isolation — verification matrix

| Router | `requirePlayerId` | URL `:id` vs header check | Per-player store | Verified |
|---|---|---|---|---|
| `/scan` | ✓ (scan.ts:32) | ✓ `requireOwnId` (scan.ts:105) | ✓ SQLite keyed by `player_id` | ✓ live: player-beta cannot read player-alpha's collection (403) |
| `/user` | ✓ (user.ts:7) | ✓ `requireOwnId` (user.ts:61) | ✓ SQLite keyed by `player_id` | ✓ live: mismatch → 403; profile isolation verified |
| `/lootbox` | ✓ (lootbox.ts:18) | n/a (no `:id` param) | ✓ `stateFor(playerId)` + SQLite | ✓ live: alpha opens crate, beta keys unchanged; beta inventory empty |
| `/vitals` | ✓ (vitalsRoutes.ts:11) | n/a | ✓ `vitalsStoreFor(playerId)` + SQLite | ✓ live: alpha posts snapshot, beta `/latest` → 404, beta `/recent` count=0 |
| `/battle` | ✗ **M-001** | n/a | n/a (no per-player state yet) | ✗ no auth, no per-player scoping |
| `/characters` | ✗ (intentional, m-005) | n/a | n/a (static catalog) | n/a |

## Persistence — verification

| Store | Survives restart | Verified |
|---|---|---|
| lootbox (keys, seeds, inventory) | ✓ SQLite (`lootbox_session`, `lootbox_retired`, `lootbox_drop`) | ✓ live: keys=24, profile, vitals all survived `pkill` + restart |
| user profile | ✓ SQLite (`user_profile`) | ✓ live: `displayName=PersistedTrainer` survived restart |
| scan collection | ✓ SQLite (`scan_seen`, `scan_character`) | ✓ unit: `scan.test.ts` + `persistence.test.ts` |
| vitals | ✓ SQLite (`vitals_snapshot`) | ✓ live: count=1 survived restart |
| In-memory (`NUTRIQUEST_DB=memory`) | ✗ resets on restart | ✓ verified: all stores reset to defaults |

## Input validation — boundary checks passed

| Endpoint | Boundaries tested | Result |
|---|---|---|
| `POST /scan` | barcode 5/6/20/21 digits, non-string, null, body=array/string | ✓ all correct |
| `POST /battle/simulate` | squad size 0/1/3/4, id/name 0/1/64/65 chars, statType valid/invalid/missing, seed 0/neg/non-finite/null/huge | ✓ except M-005 (null) and M-006 (precision) |
| `PUT /user/:id` | displayName 1/2/32/33 chars + trim, level 0/1/999/1000, streakDays -1/0/3650/3651/1.5, battlesWon -1/0/1.5, activeCharacterId 64/65/null/number, colorMode valid/invalid, body=array | ✓ except M-004 (array body) |
| `POST /lootbox/crates/:id/open` | clientSeed 5/6/64/65/100/128/129 chars, non-string, null | ✓ but contradictory errors (M-002) |
| `POST /lootbox/keys/grant` | amount 0/1/1000/1001/-5/1.5/NaN/1e10 | ✓ (M-003 is dead code, not a validation gap) |
| `POST /lootbox/verify` | crateId bad, serverSeed/clientSeed empty/non-string, nonce -1/0/1.5/string | ✓ all correct |
| `POST /vitals` | body=array, timestamp missing, testerId with slash, 50/51 workouts, HR 20/250/300, steps -1/0/200000/200001/Infinity/null, recentWorkouts string/null, workout missing fields | ✓ all correct |

---

## Prioritization

| Priority | IDs | Theme |
|---|---|---|
| **Blocker** | B-001, B-002, B-003 | spendKeys negative-input, battle parity drift, PLAYER_CAPACITY 500 HTML |
| **Major** | M-001..M-006 | battle missing auth, clientSeed contradiction, dead code, array body, seed=null, seed precision |
| **Minor** | m-001..m-007 | static battle endpoint, clientSeed message, sqlite warning, audit, characters auth, scan_seen TTL, vitalsStore alloc |

**Recommended fix order:** B-001 (one-line guard) → B-003 (express error handler) → M-001 (add `requirePlayerId` to battleRouter) → M-005 (seed=null) → M-002 + M-003 (lootbox validation cleanup) → M-004 (array body) → B-002 (battle parity — needs Swift/TS RNG diff, hardest) → m-006 (scan_seen TTL) → rest.

---

## Addendum — QA pass 2026-09-06 (`fix/crates-sheet-qa` @ 1cc0010)

Re-ran the full suite after #32–#42 landed. Status of this report's findings:

**Fixed this pass:**
- B-001/B-003/B-004/B-005 — TS battle port now matches the Swift engine
  event-for-event (verified against all 5 canonical seeds: identical moves,
  damage, crits, typeMods). Rarity/fusion scaling accepted on the request
  body; 50/50 move pick; squad bonus; HP-share timeout winner.
- M-001/L-001 — `spendKeys` rejects zero/negative/non-integer amounts.
- B-004 (client half) — `ServerBattleEvent` decodes `move`/`typeMod`;
  `BattleReplayMapper` passes them through to replays.
- New: `NQBanner` renders caller markdown (was showing literal `**`).

**Test status after fixes:**
```
Swift (BattleKitTests + ScanPipelineTests):  16 passed, 0 failed
TS   (all suites):                           40 passed, 0 failed  ← was 34/6
```

**Still open (unchanged):**
- B-008 — `/battle/simulate` party multipliers still hard-coded 1.2/1.0;
  needs server-side day-log state.
- M-002 — empty `clientSeed` policy differs between `/crates/:id/open` and
  `/fairness/client-seed`.
- m-010 — 3 moderate dev-dep vulnerabilities (`npm audit fix`).
- Visual-drift items M-003..M-009 as applicable post-#35.

**Verified live (simulator + running backend):**
- Home renders hand-drawn character art (#26 fix confirmed in a real run).
- Crate sheet: 25 keys, both crates, tier chips; error + empty states render
  when backend is down.
- Vitals pipeline: 404 before first sync (treated as no-data), per-player
  isolation, snapshot round-trip.
- Key-grant route rejects 0/negative amounts.
