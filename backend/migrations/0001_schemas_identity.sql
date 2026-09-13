-- 0001_schemas_identity.sql
-- Schemas + identity/config/daily-boundary tables.
-- Source of truth: db-documentation/03-relational-model.md (Identity, configuration, and daily boundaries).
-- Ordinary PostgreSQL tables. TimescaleDB hypertables live in later migrations.

create schema if not exists app;
create schema if not exists telemetry;
create schema if not exists analytics;
create schema if not exists ops;

-- ---------------------------------------------------------------------------
-- app.players : server-controlled identity (opaque text id, e.g. p_<hex>)
-- ---------------------------------------------------------------------------
create table if not exists app.players (
  id            text primary key,
  display_name  text not null,
  account_status text not null default 'active'
                  check (account_status in ('active','disabled','deleted')),
  version       bigint not null default 1,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

-- app.credentials : one row per player, KDF hash only, never plaintext.
create table if not exists app.credentials (
  player_id       text primary key references app.players(id) on delete cascade,
  username_norm   text not null unique,          -- normalized (lowercased) username
  username_display text not null,
  password_hash   text not null,
  kdf             text not null default 'argon2id',
  kdf_params      jsonb not null default '{}'::jsonb,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);

-- app.sessions : store token HASH, not the raw bearer token.
create table if not exists app.sessions (
  token_hash   bytea primary key,
  player_id    text not null references app.players(id) on delete cascade,
  device_id    uuid,
  issued_at    timestamptz not null default now(),
  expires_at   timestamptz not null,
  revoked_at   timestamptz
);
create index if not exists sessions_player_idx on app.sessions(player_id);

-- app.devices : device membership does not grant cross-player authority.
create table if not exists app.devices (
  id                uuid primary key default gen_random_uuid(),
  player_id         text not null references app.players(id) on delete cascade,
  platform          text not null check (platform in ('ios','watchos','web','other')),
  push_token_ref    text,
  linked_at         timestamptz not null default now(),
  revoked_at        timestamptz
);
create index if not exists devices_player_idx on app.devices(player_id);

-- app.player_settings : per-player preferences; device permission state stays on-device.
create table if not exists app.player_settings (
  player_id            text primary key references app.players(id) on delete cascade,
  theme                text not null default 'system',
  active_character_id  uuid,      -- FK added after owned_characters exists (0003)
  preferred_squad_id   uuid,      -- FK added after squads exists (0003)
  game_timezone        text not null default 'UTC',   -- IANA zone
  notification_prefs   jsonb not null default '{}'::jsonb,
  version              bigint not null default 1,
  updated_at           timestamptz not null default now()
);

-- app.profile_versions : append-only measurement/goal revisions; snapshots never rewritten.
create table if not exists app.profile_versions (
  id                uuid primary key default gen_random_uuid(),
  player_id         text not null references app.players(id) on delete cascade,
  revision          integer not null,
  measurements      jsonb not null default '{}'::jsonb,  -- height/weight/age/etc
  activity_goal     jsonb not null default '{}'::jsonb,
  calculated_targets jsonb not null default '{}'::jsonb,  -- calorie/macro targets
  formula_version   text not null,
  created_at        timestamptz not null default now(),
  unique (player_id, revision)
);

-- app.rule_sets : immutable versioned game configuration (loot/combat/eligibility/reward).
create table if not exists app.rule_sets (
  version       text primary key,
  config        jsonb not null,
  checksum      text not null,
  activated_at  timestamptz,
  created_at    timestamptz not null default now()
);

-- app.game_days : one non-overlapping active interval per player.
create table if not exists app.game_days (
  id                uuid primary key default gen_random_uuid(),
  player_id         text not null references app.players(id) on delete cascade,
  sequence          integer not null,
  display_date      date not null,             -- label only; may repeat while travelling
  timezone          text not null,             -- IANA zone in effect for this day
  starts_at         timestamptz not null,
  ends_at           timestamptz not null,
  profile_version_id uuid references app.profile_versions(id),
  rules_version     text references app.rule_sets(version),
  created_at        timestamptz not null default now(),
  unique (player_id, sequence),
  unique (player_id, starts_at),
  check (ends_at > starts_at)
);
create index if not exists game_days_player_time_idx on app.game_days(player_id, starts_at desc);
