-- 0006_ops.sql
-- Operational tables (idempotency, ingest dedup, outbox, jobs, sync, lifecycle, audit).
-- Source: db-documentation/03-relational-model.md (Operational tables).

-- ops.command_receipts : idempotency for meaningful gameplay mutations.
create table if not exists ops.command_receipts (
  player_id     text not null references app.players(id) on delete cascade,
  command_id    uuid not null,
  command_type  text not null,
  request_hash  text not null,       -- canonical request hash; same key/different hash => conflict
  status        text not null default 'completed',
  result_ref    text,
  created_at    timestamptz not null default now(),
  primary key (player_id, command_id)
);

-- ops.command_responses : optional cached response body, expires after 7 days.
create table if not exists ops.command_responses (
  player_id     text not null,
  command_id    uuid not null,
  response_body jsonb,
  expires_at    timestamptz not null default (now() + interval '7 days'),
  primary key (player_id, command_id),
  foreign key (player_id, command_id)
    references ops.command_receipts(player_id, command_id) on delete cascade
);

-- ops.ingest_keys : 30-day dedup/tombstone window for source-identified ingestion.
create table if not exists ops.ingest_keys (
  player_id     text not null references app.players(id) on delete cascade,
  source_system text not null,
  source_id     text not null,
  revision      integer not null,
  payload_hash  text not null,
  measured_at   timestamptz,          -- canonical measurement time
  applied       boolean not null default true,
  deleted       boolean not null default false,
  created_at    timestamptz not null default now(),
  primary key (player_id, source_system, source_id, revision)
);

-- ops.health_sync_cursors : last acknowledged source cursor per (player, device, data type).
create table if not exists ops.health_sync_cursors (
  player_id     text not null references app.players(id) on delete cascade,
  device_id     uuid not null,
  data_type     text not null,
  last_cursor   text,
  policy_version text,
  updated_at    timestamptz not null default now(),
  primary key (player_id, device_id, data_type)
);

-- ops.outbox : inserted in the same transaction as the domain change.
create table if not exists ops.outbox (
  id            uuid primary key default gen_random_uuid(),
  aggregate_id  text not null,
  aggregate_version bigint not null,
  payload       jsonb not null default '{}'::jsonb,
  status        text not null default 'pending' check (status in ('pending','sent','dead')),
  available_at  timestamptz not null default now(),
  lease         timestamptz,
  attempts      integer not null default 0,
  created_at    timestamptz not null default now()
);
create index if not exists outbox_ready_idx on ops.outbox(status, available_at);

-- ops.jobs : FOR UPDATE SKIP LOCKED leasing, retry-safe.
create table if not exists ops.jobs (
  id            uuid primary key default gen_random_uuid(),
  job_key       text not null unique,
  kind          text not null,
  input_refs    jsonb not null default '{}'::jsonb,
  lease         timestamptz,
  attempts      integer not null default 0,
  next_run_at   timestamptz not null default now(),
  dead_letter_reason text,
  created_at    timestamptz not null default now()
);
create index if not exists jobs_ready_idx on ops.jobs(next_run_at) where dead_letter_reason is null;

-- ops.player_sync_heads / ops.player_changes : per-player ordered sync allocation.
create table if not exists ops.player_sync_heads (
  player_id     text primary key references app.players(id) on delete cascade,
  next_sequence bigint not null default 1
);

create table if not exists ops.player_changes (
  player_id     text not null references app.players(id) on delete cascade,
  sequence      bigint not null,
  entity        text not null,
  entity_version bigint not null,
  tombstone     boolean not null default false,
  created_at    timestamptz not null default now(),
  primary key (player_id, sequence)
);

-- ops.lifecycle_checkpoints : required before destructive cleanup.
create table if not exists ops.lifecycle_checkpoints (
  stream        text not null,
  range_start   timestamptz not null,
  range_end     timestamptz not null,
  task          text not null,
  status        text not null default 'pending'
                check (status in ('pending','refreshed','finalized','deleted','failed')),
  watermark     timestamptz,
  updated_at    timestamptz not null default now(),
  primary key (stream, range_start, range_end, task)
);

-- ops.admin_audit : no credentials or raw health/photo payloads.
create table if not exists ops.admin_audit (
  id            uuid primary key default gen_random_uuid(),
  actor         text not null,
  action        text not null,
  target_refs   jsonb not null default '{}'::jsonb,
  change_summary text,
  created_at    timestamptz not null default now()
);
