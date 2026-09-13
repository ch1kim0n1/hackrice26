# Backup / recovery rehearsal runbook

Goal: prove we can recover the Tiger Cloud database, so recovery is tested rather than assumed. This is a **human-run** procedure — it needs Tiger Cloud platform write access (fork/restore), which the read-only tooling in this repo cannot perform. Run it once now and after any major schema change.

## Why this is needed
A database is only as safe as its last *tested* restore. Tiger Cloud takes continuous backups automatically, but until we have actually restored one and pointed the app at it, we do not know the restore works or how long it takes. Rehearsing gives us a known recovery time and a known-good procedure for an incident.

## What Tiger Cloud gives us
- Automated continuous backups + point-in-time recovery on the service.
- **Fork**: create a new service from a point in time — the safe way to rehearse without touching production.

## Procedure (fork-based, non-destructive)
1. In Tiger Cloud Console → service `db-19576` → create a **fork** (or `tiger service fork`, once write access is enabled) at "now". Name it `db-restore-drill`.
2. Connect to the fork and verify integrity:
   - `select count(*) from timescaledb_information.hypertables;` → expect 6.
   - `select count(*) from timescaledb_information.continuous_aggregates;` → expect 4.
   - Row-count spot checks vs. production for a few tables (`app.players`, `telemetry.health_samples`).
   - Re-run `backend` readiness logic against the fork's `DATABASE_URL` → expect `ready: true`.
3. Record the **time to first query** on the fork (this is our practical recovery-time estimate).
4. (Optional cutover drill) Point a staging backend at the fork's `DATABASE_URL`, run a smoke test, then revert.
5. **Delete the fork** when done so it stops accruing cost.

## Point-in-time recovery drill (data-loss scenario)
1. Note a timestamp `T`. Make a reversible change (e.g., insert a marker row) after `T`.
2. Fork the service to time `T`.
3. Confirm the marker row is absent on the fork → PITR works.
4. Delete the fork.

## Acceptance
- Fork restores and `ready: true`.
- Hypertable/aggregate counts and spot row counts match production.
- Recovery time recorded in the [CHANGELOG](CHANGELOG.md).

## Status
- [ ] Not yet rehearsed. Blocked on platform write access (read-only tooling can list/inspect services but cannot fork/restore). Assign to a maintainer with Tiger Cloud console access.
