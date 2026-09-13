-- 0005_battles_seasons.sql
-- Battles, dungeon, ranked, arena, seasons, LAN, notifications (ordinary tables).
-- Source: db-documentation/03-relational-model.md (Battles, dungeon, ranked, arena, seasons, LAN).

-- app.battle_requests
create table if not exists app.battle_requests (
  id             uuid primary key default gen_random_uuid(),
  requester_id   text not null references app.players(id) on delete cascade,
  challenged_id  text references app.players(id) on delete set null,
  matchmaking_ref text,
  status         text not null default 'pending'
                 check (status in ('pending','accepted','declined','expired')),
  expires_at     timestamptz,
  created_at     timestamptz not null default now()
);

-- app.battles : UQ (id, stream_started_at) is the anchor telemetry.battle_events references.
create table if not exists app.battles (
  id                uuid not null default gen_random_uuid(),
  stream_started_at timestamptz not null default now(),   -- immutable stream anchor
  mode              text not null,
  rules_version     text not null,
  seed              text,
  status            text not null default 'created'
                    check (status in ('created','running','completed','settled','abandoned')),
  version           bigint not null default 1,
  last_event_sequence bigint not null default 0,
  checkpoint        jsonb,
  ended_at          timestamptz,
  settlement_state  text not null default 'unsettled'
                    check (settlement_state in ('unsettled','settled','refunded')),
  primary key (id),
  unique (id, stream_started_at),
  -- terminal states require an end time
  check ((status in ('completed','settled') and ended_at is not null)
         or status in ('created','running','abandoned'))
);
create index if not exists battles_status_idx on app.battles(status);

-- app.battle_participants : immutable snapshot sufficient to explain the battle later.
create table if not exists app.battle_participants (
  battle_id     uuid not null references app.battles(id) on delete cascade,
  slot          integer not null,
  player_id     text references app.players(id) on delete set null,   -- null for NPC
  is_npc        boolean not null default false,
  profile_version_id uuid references app.profile_versions(id),
  game_day_id   uuid references app.game_days(id),
  unit_snapshot jsonb not null default '{}'::jsonb,
  target_snapshot jsonb not null default '{}'::jsonb,
  multiplier    numeric not null default 1.0,
  buff_snapshot jsonb not null default '{}'::jsonb,
  primary key (battle_id, slot)
);
-- a participating player appears at most once per battle
create unique index if not exists battle_participants_player_uq
  on app.battle_participants(battle_id, player_id)
  where player_id is not null;

-- app.battle_results : durable result after replay-event expiry.
create table if not exists app.battle_results (
  battle_id       uuid primary key references app.battles(id) on delete cascade,
  winner_slot     integer,
  is_draw         boolean not null default false,
  compact_outcome jsonb not null default '{}'::jsonb,
  rounds          integer,
  final_hp        jsonb not null default '{}'::jsonb,
  replay_hash     text,
  settlement_receipt uuid references app.claim_receipts(id),
  algorithm_version text not null,
  created_at      timestamptz not null default now()
);

-- app.dungeon_runs / app.dungeon_floor_results
create table if not exists app.dungeon_runs (
  id            uuid primary key default gen_random_uuid(),
  player_id     text not null references app.players(id) on delete cascade,
  seed          text,
  rules_version text not null,
  squad_snapshot jsonb not null default '{}'::jsonb,
  carry_hp      jsonb not null default '{}'::jsonb,
  best_floor    integer not null default 0,
  status        text not null default 'active',
  created_at    timestamptz not null default now()
);

create table if not exists app.dungeon_floor_results (
  run_id        uuid not null references app.dungeon_runs(id) on delete cascade,
  floor         integer not null,
  battle_id     uuid references app.battles(id),
  compact_outcome jsonb not null default '{}'::jsonb,
  primary key (run_id, floor)
);

-- app.dungeon_state : settle accrual at old rate before rate change.
create table if not exists app.dungeon_state (
  player_id       text primary key references app.players(id) on delete cascade,
  best_floor      integer not null default 0,
  accrual_boundary timestamptz not null default now(),
  fractional_remainder numeric not null default 0,
  current_rate    numeric not null default 0,
  version         bigint not null default 1
);

-- app.matchmaking_entries : one active entry per mode.
create table if not exists app.matchmaking_entries (
  player_id     text not null references app.players(id) on delete cascade,
  mode          text not null,
  rating        integer,
  season_id     uuid,
  squad_version bigint,
  expires_at    timestamptz,
  lease         timestamptz,
  primary key (player_id, mode)
);

-- app.fatigue : recovery must be a verified eligible action.
create table if not exists app.fatigue (
  scope         text not null,      -- player id or owned-character id per pinned rules
  scope_kind    text not null check (scope_kind in ('player','character')),
  until         timestamptz not null,
  source_battle uuid references app.battles(id) on delete set null,
  cleared_by    uuid references app.claim_receipts(id),
  primary key (scope, scope_kind)
);

-- app.seasons : idempotent open/close; no duplicate active interval per mode.
create table if not exists app.seasons (
  id          uuid primary key default gen_random_uuid(),
  mode        text not null,
  rules       jsonb not null default '{}'::jsonb,
  starts_at   timestamptz not null,
  ends_at     timestamptz not null,
  state       text not null default 'upcoming' check (state in ('upcoming','active','closed')),
  created_at  timestamptz not null default now(),
  unique (mode, starts_at)
);

-- app.rankings
create table if not exists app.rankings (
  season_id   uuid not null references app.seasons(id) on delete cascade,
  player_id   text not null references app.players(id) on delete cascade,
  rating      integer not null default 1000,
  tier        text,
  wins        integer not null default 0,
  losses      integer not null default 0,
  version     bigint not null default 1,
  primary key (season_id, player_id)
);
create index if not exists rankings_leaderboard_idx on app.rankings(season_id, rating desc, player_id);

-- app.season_progress / app.season_reward_claims
create table if not exists app.season_progress (
  season_id   uuid not null references app.seasons(id) on delete cascade,
  player_id   text not null references app.players(id) on delete cascade,
  score       integer not null default 0,
  daily_caps  jsonb not null default '{}'::jsonb,
  primary key (season_id, player_id)
);

create table if not exists app.season_reward_claims (
  season_id   uuid not null references app.seasons(id) on delete cascade,
  player_id   text not null references app.players(id) on delete cascade,
  reward_id   text not null,
  claimed_at  timestamptz not null default now(),
  primary key (season_id, player_id, reward_id)
);

-- app.arena_escrows : funds reserved before start; exactly one settle OR refund.
create table if not exists app.arena_escrows (
  battle_id   uuid primary key references app.battles(id) on delete cascade,
  stakes      jsonb not null default '{}'::jsonb,
  currency    text not null default 'keys',
  status      text not null default 'reserved' check (status in ('reserved','settled','refunded')),
  settlement_operation uuid,
  created_at  timestamptz not null default now()
);

-- app.lan_sessions : casual/unverified; never proof of online authority.
create table if not exists app.lan_sessions (
  id             uuid primary key default gen_random_uuid(),
  uploader_id    text not null references app.players(id) on delete cascade,
  protocol_version text not null,
  trust          text not null default 'unverified_local' check (trust = 'unverified_local'),
  summary_hash   text,
  created_at     timestamptz not null default now()
);

-- app.tournaments / entries / matches
create table if not exists app.tournaments (
  id            uuid primary key default gen_random_uuid(),
  name          text,
  bracket_revision integer not null default 1,
  host_trust    text not null default 'unverified_local',
  created_at    timestamptz not null default now()
);

create table if not exists app.tournament_entries (
  tournament_id uuid not null references app.tournaments(id) on delete cascade,
  player_id     text not null references app.players(id) on delete cascade,
  seed          integer,
  primary key (tournament_id, player_id)
);

create table if not exists app.tournament_matches (
  tournament_id uuid not null references app.tournaments(id) on delete cascade,
  round         integer not null,
  slot          integer not null,
  battle_id     uuid references app.battles(id),
  outcome       jsonb not null default '{}'::jsonb,
  primary key (tournament_id, round, slot)
);

-- app.notifications : sanitized user-facing payload; push is a hint, not the only copy.
create table if not exists app.notifications (
  id            uuid primary key default gen_random_uuid(),
  player_id     text not null references app.players(id) on delete cascade,
  type          text not null,
  related_object text,
  payload       jsonb not null default '{}'::jsonb,
  status        text not null default 'unread' check (status in ('unread','read','archived')),
  expires_at    timestamptz,
  created_at    timestamptz not null default now()
);
create index if not exists notifications_player_idx on app.notifications(player_id, status, created_at desc);

-- matchmaking season backref
alter table app.matchmaking_entries
  add constraint matchmaking_season_fk
  foreign key (season_id) references app.seasons(id) on delete set null;
