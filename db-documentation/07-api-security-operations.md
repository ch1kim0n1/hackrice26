# 07 — API, security, and operations

## Backend and mobile boundary

Use a standard PostgreSQL driver (`pg` is the proposed TypeScript choice) with a small shared pool per process. Introduce repositories and a transaction/unit-of-work helper; domain code must not casually open independent connections mid-command.

Preserve useful public DTOs and route behavior during the first integration. Add explicit versioned contracts where authority changes: `commandId`, `expectedVersion`, owned instance IDs, source sample metadata, `asOf`, server time, sync cursor and replay expiry. Mobile types must be updated with the backend; storing SQL IDs as JSON strings avoids numeric precision loss.

Logical API capabilities:

| Area | Required contracts |
|---|---|
| Auth/account | Register/login/logout, server-derived identity, profile/settings version, device link/revoke |
| Nutrition | Barcode confirm, photo draft/analyze/review/confirm, intake revisions/deletion, current daily state/history |
| Collection/economy | Catalogue/owned inventory, squads, open/verify/rotate seeds, promo/quest claims, later fusion |
| Battles | Authorized create/accept, result/checkpoint, paginated events/SSE, later interactive action and ranked/arena entry |
| Health | Bounded source-aware sample batches, corrections/deletions, day-total and workout revision sync, latest/history reads |
| Sync | Consistent snapshot + cursor, ordered changes, per-command result lookup, explicit cursor expiry |
| Operations | Liveness without DB dependency, readiness with safe DB check, separate protected administration |

Integration must audit every route, store and helper for synchronous/database assumptions. Express 4 async handlers require an explicit error-forwarding wrapper or equivalent middleware; returning a rejected promise must not strand the request. Release transactions/connections on every exception and client disconnect. Remove import-time DDL in favor of a dedicated migration command.

Production backend state comes from Tiger Cloud, not a per-process map or a fallback SQLite file. Small process caches are optional and version/TTL bounded. A failed cloud connection returns a retryable service error, not a silent alternate authoritative database.

## Authentication and access control

- App -> backend authentication only. The mobile app never receives the Tiger Cloud connection string, service owner password, or migration role.
- Derive the player from a verified session/token. Do not use a client `X-Player-Id` header as authority. If guests are required, issue server-authenticated guest identities with limited privileges.
- Retain hashed password and hashed opaque session-token semantics for the initial integration; do not build an unrelated identity-provider migration as a side effect. Email/OAuth recovery can be added deliberately later.
- Session TTL initially 30 days, with logout/device revocation and server enforcement. Keychain stores the bearer token. Rate-limit registration/login and expensive scan/vision endpoints.
- Every query carries owner or participant scope. A player cannot read another player's health, photos, intake or session data through a public leaderboard or battle snapshot.
- Public catalogue/leaderboard DTOs are explicit sanitized projections, not `SELECT *` from private tables.

Database roles:

| Role | Purpose |
|---|---|
| `nq_migrator` | Schema/extension/policy setup; not used by runtime requests |
| `nq_api` | Narrow ordinary gameplay DML/read grants and required telemetry writes; no DDL, job-policy mutation or credential-table enumeration |
| `nq_auth` | Narrow credential/session operations used by authentication code; never shared with mobile |
| `nq_worker` | Approved job/outbox/aggregate/export operations; no unrestricted human administrative API |
| `nq_retention` | Narrow controlled lifecycle/deletion operations; no user-facing route |
| `nq_readonly` | Redacted operational/analysis views; no health access unless explicitly authorized |

Use ordinary-table row-level security for owner-scoped sensitive data where practical, with transaction-local request identity and fail-closed missing context. Review policies for participants/public projections separately. Runtime roles must not be table owners or have `BYPASSRLS` accidentally.

**Do not assume continuous aggregates inherit source-table RLS.** Version-specific compatibility with RLS on source hypertables must be tested. Initial private telemetry/analytics access is backend-only with explicit owner-bound query methods, least-privilege roles and cross-player integration tests. There are no direct SQL credentials for end users. If the service cannot safely combine a proposed CAGG with source RLS, keep that analytical surface private under this model; do not disable all application authorization to make an aggregate compile.

## Privacy and trusted inputs

Source metadata improves deduplication and provenance; it does not prove that an arbitrary client health upload is medically genuine. Apply plausible-value/rate checks, trust labels, and bounded gameplay effects. Do not claim anti-cheat attestation from a database row alone.

Raw health values/photos never enter general logs, public replay payloads, `NOTIFY` messages, analytics error dumps, or crash-report breadcrumbs. Log request/event IDs, counts, durations and redacted error codes. Limit photo size/content type and store it privately. Provider/model choices for vision/lore/art remain replaceable integrations with recorded version and status.

Use parameterized SQL and explicitly allowlisted sort/identifier choices. Require verified TLS using the provider's supported certificate configuration; do not “fix” TLS by turning verification off. Never print the downloaded connection string during setup or failure reporting.

Implement deletion/export from the lifecycle design, including summaries, files, device state and backups. Health access and deletion tests are release gates, not optional cleanup.

## Connection and query budgets

Initial process defaults, subject to actual service limits:

- API pool maximum 10, worker pool maximum 3, one dedicated listener connection per streaming API instance.
- Total budget = `API instances * (pool max + listener) + worker instances * worker pool + migration/admin reserve`.
- Inspect `max_connections` and provider-reserved capacity; keep the application budget below the usable limit, initially targeting at most 70% to leave headroom. Reduce defaults if the service is smaller. Autoscaling must account for multiplied pools.
- Initial statement timeout: 5 seconds for normal requests; explicitly scoped jobs may use up to 30 seconds. Initial lock timeout: 2 seconds. Idle-in-transaction timeout: 15 seconds. Benchmark and override by job class rather than globally removing limits.
- Health batches: initially up to 500 normalized records and 1 MiB request body, returning per-record acceptance. Photos use a separate capped upload route/object upload and never ride a sample batch.
- Typical list page: 50, maximum 200; battle event page maximum 500 small events. Reject oversized event payloads; no entire-history JSON response.
- Use a finite time range in every time-series read. Initial raw history API maximum is 7 days; longer health requests read stored summaries. Do not accidentally make “all players, all time” the default.
- Keep CPU-intensive image/model requests out of DB transactions. Coalesce identical product/art requests; use TTLs and stable job keys.

These are operating defaults, not measured SLOs. Query plans and device/backend load tests may change them before release.

## Worker and job schedule

| Job | Initial cadence | Correctness rule |
|---|---|---|
| Outbox dispatch | Event wake-up plus short bounded polling while active | Durable domain transaction precedes delivery; retries safe |
| Health aggregate refresh | 10 minutes | Complete buckets, late-range jobs, guarded export/drop |
| Battle aggregate refresh | 5 minutes | Analytics only; settlement never waits on it |
| Nutrition/gameplay aggregate refresh | 15 minutes | Signed correction-aware nutrition, finite windows |
| Hourly health-history export | Hourly plus late-correction jobs | Upsert finalized sum/count/coverage; never average averages |
| Game-day finalize / expired buff housekeeping | Hourly catch-up; validity also checked on requests | Respect per-player intervals; do not delete permanent collection |
| Battle timeout / matchmaking leases | Once per minute while needed | Persist terminal/refund transition before any retention eligibility |
| Battle retention | Every 15 minutes | Terminal+settled+72-hour guards and lifecycle writer lock |
| Other raw retention / summary expiry | Hourly | Only after dependent rollups/checkpoints; one owner per policy |
| Photo/draft/session/outbox cleanup | Hourly | Per-data expiry; unresolved user/domain work protected |
| Season transitions | Hourly catch-up against configured boundaries | Idempotent close/start and batched unique rewards |
| Ledger/progress reconciliation | Daily, plus after deployment/test incidents | Alert on mismatch; never auto-invent compensating game grants |

Use Timescale's native scheduled policies for straightforward CAGG refresh/columnstore where supported. Use the application lifecycle worker for dependent/guarded deletion and exports. Never install a native drop policy that races the guard worker. Document each installed job's owner, config and version in migrations.

## Observability, resilience, and cost

Measure connection saturation, transaction/lock duration, API p95 latency, query counts, chunk/index sizes, slow queries, ingest rejects, duplicate suppression, SSE reconnect gaps, outbox lag, CAGG freshness, export/deletion lag, orphan photos, device pending queue age and cache/WAL size.

Alert on unapplied settlements, negative/mismatched balances, unauthorized access attempts, stale lifecycle watermarks, an outbox oldest-ready age over 60 seconds during active play, or an aggregate lag greater than two scheduled refresh intervals beyond its documented raw-tail behavior. Alert thresholds are initial operations settings to tune.

Optimize in order: correct bounded indexed SQL -> batched ingestion -> shared summaries -> avoid needless polling -> prune temporary data -> columnstore measured retained facts -> right-size compute. Add replicas/extra services only after a demonstrated bottleneck. No unsupported promise about cost per battle or the user's trial balance.

Use separate development/test and production services/secrets. Verify service backup/PITR/HA availability and retention before production; “managed database” is not proof that a specific plan has every resilience feature. Establish a tested restore and deletion-replay runbook. Initial production target proposal: recovery point within one hour and recovery within four hours, pending actual plan capability and restore measurements; this is not an achieved guarantee.
