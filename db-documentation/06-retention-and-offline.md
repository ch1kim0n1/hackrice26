# 06 — Retention, deletion, and offline behavior

## Three different lifetimes

1. **Gameplay validity:** a buff can expire or a battle can finish while its record still exists.
2. **Cloud history:** useful evidence, summaries and ownership survive longer than temporary raw detail.
3. **Device cache:** disposable downloaded copies have independent age/size limits. A queued unsent action is not a cache entry.

The default battle-detail window is **72 hours after terminal completion/cancellation**, not three calendar dates and not three days after match creation. Active battles, pending settlement, unresolved upload commands and permanent progression cannot be deleted under that rule.

## Cloud retention defaults

These are implementation defaults proposed for review, not claims that jobs already run. Account deletion overrides ordinary history retention, subject to the documented backup lifecycle.

| Data | Default logical retention | Why / cleanup owner |
|---|---|---|
| Raw battle events | Available through `ended_at + 72 hours` | Enough for playback, reconnect and recent debugging; guarded chunk job every 15 minutes |
| Battle input snapshots, compact results and grant receipts | Account lifetime | Explain outcomes, prevent duplicate rewards and preserve progression; not the full animation log |
| Detailed dungeon turn/floor playback | Same 72-hour window as associated completed battle/run | Compact floor results and best-floor progression remain |
| Raw health samples and activity observations | 7 days | Accommodates normal delayed HealthKit synchronization and correction; summaries exported before cleanup |
| Hot `health_hourly` continuous aggregate | 6 days | Its source remains available for corrections/privacy refresh; configure 1-day materialization chunks, verify supported API |
| `app.health_hourly_history` | 365 days | Compact owner-deletable historical readings summary; finalized/corrected from complete hourly buckets |
| Canonical meals, revisions and nutrition deltas | Account lifetime, until the user deletes that intake/history | A nutrition app should not forget meals after three days; these low-volume records support corrections and longer trends |
| `nutrition_hourly` continuous aggregate | Follows retained nutrition source | Source remains available to recompute corrections/deletions |
| Completed workout summaries | 365 days | Preserve workout history without retaining every sensor point; daily activity/gameplay summaries remain separately |
| Battle metrics | 365 days | Cross-battle performance/time analysis, independent of short-lived event streams |
| Hot `battle_hourly` aggregate | 30 days | Source lasts much longer; older trends can query bounded metrics or durable daily history |
| Accepted gameplay events | 30 days | Recent user activity and diagnostics; ownership and grant evidence live elsewhere |
| Hot `gameplay_hourly` aggregate | 7 days | Recent trend acceleration; daily/lifetime history preserved independently |
| Daily history, collection, progression, rankings and season outcomes | Account lifetime | Permanent user value; archive formats/indexes can change without deleting entitlement evidence |
| Wallet ledger, crate verification receipts, acquisition/fusion/claim receipts | Account lifetime | Reconciliation, fair-roll verification, anti-duplication and ownership lineage |
| Pending photo drafts | 24 hours after last edit, if not queued for confirmation | UI warns before expiry; confirmed meal persists independently |
| Gym/photo-analysis images | Delete within 72 hours of final verification/confirmation, or draft expiry | Retain decision/confirmed nutrients; storing the photo longer needs an explicit product need/consent |
| Successfully delivered outbox payloads | 7 days | Dispatch diagnosis; durable domain result is elsewhere |
| Failed jobs/outbox | Up to 30 days with alerts and controlled resolution | Never auto-drop unresolved settlement or pending deletion work; dead-letter instead |
| Full command response cache | 7 days | Compact permanent command receipt remains after response body expiry |
| Ingest dedup keys/tombstones | 30 days | Longer than admissible raw event age; stale replay rejected after keys expire |
| Player sync changes/tombstones | 30 days | Expired client cursor requires full resync; it does not receive an incomplete delta |
| Read/expired notifications | 30 days | Relevant result remains available through its feature endpoint |
| Revoked/expired sessions | Remove after a 7-day diagnostic window | Retain minimal redacted authentication audit separately if needed |
| Administrative audit | 90 days initially | Operational diagnosis; exclude health payloads, tokens and photographs |

Retaining a compact battle snapshot is not permission to duplicate raw medical history inside it. Store the numeric game contributions/targets and revision IDs needed to reproduce the rules, not unrelated sensor payloads.

## Battle cleanup: safe 72-hour semantics

`battle_events` is partitioned by the immutable battle `stream_started_at`, with an initial six-hour chunk interval. A generic unconditional `drop_after = 3 days` on that start time is **not** sufficient: it could delete a still-active match or retain less than 72 hours after completion.

Use one guarded lifecycle worker, not a second competing native drop policy:

1. Pick only fully old chunks using actual Timescale chunk metadata; never construct arbitrary table names from a request.
2. Verify every battle represented in a candidate chunk is terminal, ended at least 72 hours ago, has a durable result and complete settlement/refund, and has the required daily/metric projections persisted.
3. Verify no unresolved recovery/verification job requires its raw events. Ordinary undelivered mobile notifications do not block indefinitely once the durable result and expiry contract exist; unresolved domain settlement does.
4. Serialize cleanup against writers with a documented shared/exclusive lifecycle lock protocol. A writer takes the shared lock before creating/appending to a stream; the cleanup worker takes the exclusive lock, rechecks eligibility, and then drops the eligible chunk(s). No writer may create a backdated stream or append to a terminal battle. Verify locking/DDL behavior in integration tests.
5. Record the completed cleanup range/checkpoint. Retrying the job is safe.

The API stops serving replay when the 72-hour contract expires. Physical removal can lag because a chunk contains several battles. With six-hour chunks and a 15-minute job cadence, normal lag is up to roughly one extra chunk plus the job interval after the latest relevant battle becomes eligible; active/held battles and outages can extend it. Monitor holds rather than deleting required data to meet an artificial exact byte deadline.

Timescale retention removes whole chunks, not individual rows at an exact birthday. This is an important distinction between logical expiry and actual storage reclamation. [Chunk-size and retention behavior](https://www.tigerdata.com/blog/timescale-cloud-tips-testing-your-chunk-size)

## Summary-safe cleanup and privacy

For health, first refresh complete hourly ranges, upsert `app.health_hourly_history` with its source revision/coverage, update `daily_history`, and record a checkpoint. Then expire old hot aggregate chunks, and only then allow eligible raw source chunks to drop. Source cleanup pauses if export/refresh failed or a late-data correction is outstanding.

Long-lived health summaries deliberately live in a normal owner-keyed table. This avoids retaining old private health data only inside a continuous aggregate whose raw source has already disappeared and can no longer be recomputed for selective deletion. Do not directly edit Timescale internal materialization tables.

Automatic CAGG refresh windows must not overlap dropped raw ranges. The aggregate windows/retention above are deliberately shorter than their expiring raw sources, except nutrition whose source is retained. Configure and verify materialization chunk intervals where the safety margin is small. A recovery job after downtime explicitly processes surviving ranges before deleting anything; an old global watermark is not evidence that newly arrived historical data was summarized.

Account/health deletion is separate from “drop old chunks”:

- Disable access and queue a deletion workflow with an owner ID and stable job ID.
- Delete the owner's source facts, direct summary rows, drafts/photos, sessions/device credentials and personal domain rows in controlled batches, respecting permanent-reference anonymization rules for other players' match results.
- Refresh affected still-retained aggregate buckets from the remaining source, and verify the deleted player no longer appears. The retention design keeps those hot sources available; nutrition source history also remains available for recomputation until this deletion.
- Erase/anonymize the player's battle participant snapshots and analytics dimensions as appropriate without corrupting the opponent's result or ledger balance. Preserve a non-identifying result receipt only where needed for the other account's consistency; do not retain the deleted user's health snapshot.
- Invalidate sync cursors and issue device cache deletion on next connection. A device that never reconnects cannot be remotely guaranteed wiped; local protection/logout handling is required.
- Record backup expiry policy after inspecting the service. Do not promise immediate physical erasure from provider backups; a restore runbook must reapply the deletion ledger before serving traffic.

## Device SQLite layout and budgets

Use a per-account cache namespace/database. Never reuse one account's cached snapshots under another login.

| Local data | Policy |
|---|---|
| `cached_snapshots` | Server projections with entity version, fetched time and expiry; temporary account snapshots are evictable after 72 hours without refresh |
| `cached_battle_events` | Active replay protected; completed replay expires 72 hours after server end time, or earlier if safely evicted for space |
| `cached_health_detail` | Maximum 72 hours of downloaded raw readings; keep only what visible/offline features use |
| `cached_history_pages` | Bounded pages of summaries; TTL applies to the cached copy, not the age of the historical facts inside it |
| `pending_commands` | Stable command ID, payload hash, dependency order, retry status; protected from cache eviction |
| `pending_health_uploads` | Batched source IDs/revisions/cursor; ack per item; never silently drop because a cache sweep ran |
| `local_drafts` | User-created offline meal input and file references; show expiry/storage state explicitly; not a downloaded cache |
| `sync_state` | Last committed server cursor, account/endpoint identity, schema version, last successful sync |

Initial storage targets, to be measured on real devices:

- SQLite **evictable cache**: 32 MiB soft target, 64 MiB hard admission target.
- Protected commands/draft metadata/upload queue: separate 16 MiB admission quota. Pending photos are separate protected files with an initial 40 MiB quota and upload compression.
- Disposable image/download cache: 100 MiB LRU limit; bundled assets are not part of it.
- These are application-managed budgets, not a promise that the SQLite file or total app footprint can never temporarily exceed their sum. WAL, indexes, active transactions, file-system overhead and protected data need headroom.
- On pressure, evict expired then least-recently-used disposable content. Never erase pending work to make a chart cache fit. At a protected quota, stop accepting additional offline uploads/drafts, explain the limit, and offer sync/export/user-confirmed discard.
- After 7 days pending, mark a command as needing attention and check its feature admission window. Do not quietly delete or award stale competitive credit. Durable command receipts still prevent re-execution after the cached response expires.

Cleanup runs on launch/foreground, after a successful sync, after battle completion, on storage pressure, and at a best-effort daily background opportunity. iOS does not guarantee a background deletion task runs at an exact time. Expired data is hidden on reads even before physical cleanup runs.

Enable SQLite foreign keys. Use a serialized writer and short transactions. Configure incremental auto-vacuum at database creation if chosen, reclaim pages incrementally, and checkpoint WAL when safe; a `DELETE` alone need not shrink the file. Do not run a disruptive full `VACUUM` after every sample. Verify real file/WAL sizes in cache tests. [SQLite PRAGMA documentation](https://www.sqlite.org/pragma.html)

Store tokens in Keychain, not SQLite. Apply iOS file protection and appropriate backup exclusions to cache/health data; optional database encryption must be evaluated rather than assumed to exist in plain SQLite.

## Offline permissions and conflict rules

| Action offline | User-visible behavior | Reconnection behavior |
|---|---|---|
| View cached collection/profile/history | Show “last synced” and stale state; bundled assets remain available | Revalidate versions and fetch bounded changes |
| Capture a meal or edit an unsubmitted draft | Save pending input if quota permits | Validate source/time and confirm server-side; do not promise prior-day game rewards |
| Upload HealthKit data | Queue source-aware batches within quota | Per-item ack; raw older than 7 days becomes an explicit stale result, with supported summary sync handled separately |
| Practice/LAN casual battle | Local, clearly unranked/unverified | Optional history only; never automatic online reward/rating settlement |
| Spend, fuse, claim contested rewards, enter ranked/arena | Requires connection; do not show final spendable changes | Submit only after current state/eligibility is validated |
| Read account balance/active buffs | Cached estimate and server expiry, not a new entitlement | Server state wins; expired buffs stay expired |

Use optimistic local UI only for reversible drafts/preferences. Ownership/currency changes remain pending until a receipt arrives. Historical meal intake can be retained without backdating game rewards. Conflicting revisions return `409` plus the latest version; do not apply last-writer-wins to balances or ownership.

If a sync cursor is older than the 30-day change log, the API returns `RESYNC_REQUIRED`. Replace evictable projections with a fresh consistent snapshot, retain pending commands, then replay those commands with their original IDs. Snapshot and cursor must be obtained consistently under the per-player sync protocol.
