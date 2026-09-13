# 05 — Transactions, live battles, and retry safety

## Command contract

Every meaningful mutation has a client-generated UUID `commandId`, authenticated player, validated command type, and canonical request hash. The same command ID is reused on network retries. A different payload with that ID returns a conflict.

1. Validate payload and authorization before slow work. Fetch external food/vision data outside a database transaction, with its own stable job/request identity.
2. Check out ONE PostgreSQL connection, begin a transaction, set request-scoped identity, and reserve/check the command receipt.
3. Lock affected roots in a fixed order: player IDs sorted, then wallet currency, then inventory IDs sorted, then feature state. Use short transactions; no external HTTP or animation waits while locks are held.
4. Revalidate ownership, version, balance, time window and entitlement under the locks. Calculate effects using pinned pure game rules.
5. Write domain rows, ledger/claim receipts, required time facts, ordered sync changes and outbox entries in that same transaction.
6. Commit, then respond or publish. If the response is lost, the next request returns the stored outcome/reference without reapplying effects.
7. Roll back on failure and release the connection in `finally`. Retry known serialization/deadlock failures with a bounded attempt count and jitter; do not blindly rerun arbitrary errors.

PostgreSQL transactions must use one checked-out connection rather than separate `pool.query` calls that may reach different connections. [node-postgres transactions](https://node-postgres.com/features/transactions)

Delivery is **at least once**. Unique receipts plus transactional state make one logical accepted command have at most one committed effect. Do not claim exactly-once networking.

## Domain transaction boundaries

| Operation | Must commit together | Key concurrency guard |
|---|---|---|
| Confirm barcode/photo intake | Meal/revision/items, eligibility claim, acquisition if granted, signed nutrition facts, daily state, XP/quest changes, receipt and outbox | Command ID, eligible barcode/day key, locked daily state |
| Correct/delete intake | New revision/tombstone, reversal/replacement facts, affected daily/history projections, refresh task | Meal revision compare-and-set; no reward replay |
| Health batch | Accepted source revisions/tombstones, canonical samples/observations, daily activity/projection, refresh jobs, per-item acknowledgement | Source ID/revision/hash; owner and freshness validation |
| Crate open | Debit, ledger, locked seed nonce, pity update, roll receipt, owned copy, XP/quest effects, time fact and outbox | Wallet lock, unique seed/nonce, command receipt |
| Promo/quest/objective/comeback claim | Eligibility/usage change, unique grant receipt, wallet/XP effects, event | Unique entitlement plus relevant row locks |
| Fusion | Validate five copies, mark consumed, create result/lineage, update squad validity, event | Sorted ownership locks and unique consumed input |
| Battle settlement | Result, terminal state, XP/wins/rating/fatigue effects, wallet/escrow settlement if any, metric facts, outbox | Battle version/state and unique settlement operation |
| Dungeon run/claim | Run outcomes, best floor, accrued amount/boundary/remainder, reward receipt, wallet/XP | Player/dungeon state lock, no client elapsed time |
| Season close/reward | Immutable closing snapshot, per-player repeat-safe adjustments/grants, successor season state | Unique season transition/job and reward receipt |

Large season payouts run in small repeat-safe batches, not one transaction holding every player lock. A season remains in `closing` until reconciliation confirms all required batches. Leaderboard/reward reads know whether results are provisional or finalized.

## Automatic battle flow: initial integration

1. Authenticate participants and load only eligible owned unit IDs. Select mode, rules/engine version and server seed. Pin daily target/multiplier/activity/gym values and unit stats.
2. Compute the deterministic result using immutable inputs outside a long-held transaction. For small synchronous simulations this may be one request; large dungeon runs can use a worker.
3. In a short transaction, validate that the expected player/squad/day versions and eligibility still hold. If not, retry with fresh snapshots before accepting a battle, or return a version conflict. Write `app.battles`, participant snapshots, all ordered `battle_events`, compact result, grants, metrics, and outbox atomically. Requests waiting for both players use an explicit accepted/running state and pinned snapshots first.
4. Commit before publishing. Both participants receive the same battle ID, seed commitment/reveal policy, rules version, event hash and ordered replay. The client never supplies the winning result or trusted final stats.
5. The device animates the persisted events locally. Damage animation at 60 FPS produces no corresponding 60-Hz database writes.

For a multi-stage asynchronous accepted match, step 3 instead finalizes the previously persisted battle using its pinned immutable inputs. A worker lease and battle version protect against two workers settling it. A crash before commit can retry simulation; a crash after commit reuses the result receipt.

Do not derive a public predictable seed in modes where opponents could exploit it before squad lock-in. Freeze commitments and inputs first; retain the algorithm version and verification material appropriate to the mode. Fair crate seed rotation and battle seed policy are separate concerns.

## Future interactive battle flow

The architecture supports future player-controlled actions without pretending the present automatic loop already has those controls.

- Authenticate action, battle participation, turn/phase, `expectedVersion`, and `commandId`.
- Acquire the battle state lock and relevant player locks in the documented global order; validate action against the persisted checkpoint.
- Calculate the next state, append one or more sequential events, and advance checkpoint/last-sequence/version in one transaction. Only commit-acknowledged actions count.
- On a terminal action, settle all effects in that transaction or transition to a durable `settling` state handled by one repeat-safe settlement worker. Never expose a final spendable reward that has not committed.
- The initial maximum live-match duration is 30 minutes plus an explicit reconnect grace in the pinned mode configuration. A timeout produces a mode-defined terminal cancellation/forfeit and settlement/refund; it does not delete the match. Revisit duration if actual gameplay requires longer sessions.
- Locking and persisted versions are authoritative across API instances. An in-memory actor may optimize delivery but cannot be the only copy of the current turn.

## Durable events and real-time transport

Use HTTPS commands and SSE for committed event delivery initially. `Last-Event-ID` identifies battle ID plus sequence. Reads authorize against participants; friends/spectators need an explicit sanitized permission policy.

The transaction inserts a small `ops.outbox` entry such as “battle X has committed through sequence N.” A dispatcher wakes live subscribers and loads a bounded page. The client deduplicates sequences, acknowledges progress locally, and requests missing pages. A gap is repaired by fetching, not guessed by the animation engine.

For multiple backend instances, PostgreSQL `LISTEN/NOTIFY` can act as a wake-up hint while each instance catches up its local subscribers. Use a dedicated session for `LISTEN`, not a transaction-pooled connection. Send only a non-sensitive event ID/channel hint. Notifications are not a durable queue and are not private row-level messages. Commit ordering, disconnections and payload limits must be respected. [PostgreSQL NOTIFY](https://www.postgresql.org/docs/current/sql-notify.html)

Operational defaults:

- Dispatcher batches up to 100 ready outbox rows with a lease; tune under load.
- While live subscriptions exist, a coalesced catch-up poll (initially once per second per API instance, not per animation/client) repairs missed wake-ups. Back off when idle.
- Backpressure: page events, cap payload sizes, disconnect slow clients with a resumable cursor; do not buffer unlimited history in memory.
- Outbox completion means dispatched, not that every mobile device received it. The retained event stream and compact result provide reconnect recovery.
- If replay has expired, return `410 REPLAY_EXPIRED` plus a result reference and compact summary. The outcome/receipt remains readable. Do not fabricate missing events or rerun reward settlement.

A generic account sync endpoint separately returns ordered `player_changes`; do not use battle sequences as an account-wide sync cursor.

## Offline and LAN trust boundary

Offline practice and LAN host-authoritative tournaments can use cached/bundled squads and local protocol commitments. They are labeled casual/unverified. Local claims of inventory, victory, fitness, or seed fairness alone do not establish server authority.

Optional uploads retain provenance and are excluded from ranked metrics, economy grants and online anti-cheat evidence. If online-authenticated tournaments are added, their server-accepted matches use the normal battle transaction path. Byes, walkovers and host disconnects are explicit bracket state transitions, not invented combat results.

## Failure outcomes to test

- Database unavailable before commit: command remains pending locally; no authoritative reward is shown.
- Commit succeeds, HTTP response disappears: retry returns the original receipt/result.
- Stream disconnects: checkpoint plus missing sequence pages restores playback.
- Two requests spend the last keys: one succeeds, the other sees the updated balance.
- Worker crashes midway through a payout batch: completed grants remain unique; remaining grants resume.
- Late health/meal correction: history changes with provenance, an existing battle does not.
- Retention worker fails: data is held and an alert is raised; it is not prematurely removed to satisfy a disk target.
