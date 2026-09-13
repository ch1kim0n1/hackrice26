# NutriQuest database architecture

Status: **schema implemented and seeded on Tiger Cloud DEV service `db-19576`; application not yet wired.** See [08](08-implementation-and-validation.md) and [CHANGELOG](CHANGELOG.md).

Working branch: `dev-db`, created from freshly fetched `origin/main` at `f7a9e4ed2d98ec96753c132196478bfb9b568d49` on September 11, 2026 (America/Chicago).

## The decision in plain English

Use **one Tiger Cloud PostgreSQL database with the TimescaleDB extension** as NutriQuest's server database. Use regular PostgreSQL tables for accounts, ownership, currency, progression, and other records that must stay correct. Use TimescaleDB hypertables for health readings, activity observations, nutrition changes, battle event streams, and gameplay history. Keep SQLite on the device for useful offline data and pending uploads.

Tiger Data is the provider, Tiger Cloud is the hosted service, and TimescaleDB is an extension running inside PostgreSQL. These are not three databases that need to synchronize with each other. The same SQL connection can query ordinary tables and hypertables together. See [architecture](01-architecture.md) for the cost and query implications.

**Three days applies to temporary battle details and device caches, not to a player's collection, balance, meals, achievements, or battle results.** A completed battle keeps its event replay available for at least 72 hours. Permanent compact records preserve outcomes, reward receipts, and the inputs needed to explain them.

The meaningful Tiger Data use is an end-to-end loop: timestamped health and nutrition evidence -> authoritative daily gameplay state -> durable battle events -> battle and health trends -> safe automatic cleanup. Hypertables support real product behavior, not just an unrelated monitoring chart.

## Read this folder in this order

| Document | Purpose |
|---|---|
| [CONTEXT](CONTEXT.md) | Start here when resuming in another task/model; scope, state, next action. |
| [01 Architecture](01-architecture.md) | Components, responsibilities, costs, and decisions responding to the requested tradeoffs. |
| [02 Feature map](02-feature-map.md) | Every identified implemented or planned feature and its data ownership. |
| [03 Relational model](03-relational-model.md) | Ordinary PostgreSQL tables, keys, constraints, and durable records. |
| [04 Timescale design](04-timescale-design.md) | Hypertables, time semantics, continuous aggregates, SQL query patterns. |
| [05 Transactions and live battles](05-transactions-and-live-battles.md) | Command handling, replay delivery, concurrency, retries, and failure recovery. |
| [06 Retention and offline](06-retention-and-offline.md) | Exact retention defaults, deletion guards, device budgets, and offline behavior. |
| [07 API, security, and operations](07-api-security-operations.md) | Backend integration, authentication, connection limits, jobs, and privacy. |
| [08 Implementation and validation](08-implementation-and-validation.md) | What is deployed, validation run, dependency-ordered wiring slices, and merge-to-main safety. |
| [09 Decisions and sources](09-decisions-and-sources.md) | Accepted direction, proposed defaults, what was verified on the live service, source references. |
| [10 Schema parity audit](10-schema-parity-audit.md) | Whole-repo/multi-branch feature→table coverage; confirms all features have a data home. |
| [11 Planned-feature wiring plan](11-planned-features-wiring-plan.md) | Build order and transaction design for features that are schema-covered but not yet implemented (fusion, ranked, arena, seasons, gym verification, lore, LAN). |
| [12 Wiring runbook](12-wiring-runbook.md) | Exact repeatable recipe + status table for connecting each feature to TigerData (best-effort mirror). Start here to continue the wiring. |
| [CHANGELOG](CHANGELOG.md) | Changes to this plan; update alongside implementation. |

## Scope and authority

This folder is the proposed target data architecture. It supersedes `docs/TIGERDATA-MIGRATION.md` for new database design. Older product documents remain evidence of feature intent, not executable schema specifications. The current code and tests establish gameplay parity where those older documents disagree.

No credentials are included. No service has been provisioned, queried, or modified for this design. The user's downloaded development credentials must remain outside Git and outside the mobile app.

No SQL migrations, runtime database adapters, app changes, or new dependencies are implemented in this documentation change. Table names and schedules below are contracts for future implementation. Optional features are mapped now but need not all ship in the first integration.

## Non-negotiable rules

1. Server-authoritative ownership, rewards, battle outcomes, and ranked eligibility.
2. One transaction for each economy/progression operation and its durable receipt.
3. Replay delivery and background jobs can retry; rewards cannot be issued twice.
4. Never add up cumulative step/ring snapshots as if they were separate activity.
5. Preserve measurement time, ingestion time, source identity, units, and missing values.
6. Preserve the rules, targets, and squad snapshot used by a battle.
7. No deletion of active battles, unsent user work, permanent ownership, or unsettled money-like game currency records under a cache policy.
8. No client database credentials and no trusting client-submitted player IDs or combat stats.
9. All cloud feature/version claims must be checked against the actual development service before executable migrations are written.
