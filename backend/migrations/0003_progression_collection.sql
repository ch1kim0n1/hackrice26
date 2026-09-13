-- 0003_progression_collection.sql
-- Progression, daily loop, and collection (ordinary tables).
-- Source: db-documentation/03-relational-model.md (Progression, daily loop, collection).

-- app.daily_state : synchronously updated authoritative gameplay projection.
create table if not exists app.daily_state (
  player_id        text not null references app.players(id) on delete cascade,
  game_day_id      uuid not null references app.game_days(id) on delete cascade,
  nutrient_breakdown jsonb not null default '{}'::jsonb,
  multiplier       numeric not null default 1.0,
  objective_state  jsonb not null default '{}'::jsonb,
  source_revisions jsonb not null default '{}'::jsonb,
  version          bigint not null default 1,
  updated_at       timestamptz not null default now(),
  primary key (player_id, game_day_id)
);

-- app.daily_history : durable compact Journey history.
create table if not exists app.daily_history (
  player_id     text not null references app.players(id) on delete cascade,
  game_day_id   uuid not null references app.game_days(id) on delete cascade,
  summary       jsonb not null default '{}'::jsonb,
  scan_count    integer not null default 0,
  open_count    integer not null default 0,
  battle_count  integer not null default 0,
  nutrition_totals jsonb not null default '{}'::jsonb,
  activity_totals  jsonb not null default '{}'::jsonb,
  targets       jsonb not null default '{}'::jsonb,
  finalized_at  timestamptz,
  revision      integer not null default 1,
  primary key (player_id, game_day_id)
);

-- app.player_progress : transactional counters (durable receipts hold the proof).
create table if not exists app.player_progress (
  player_id       text primary key references app.players(id) on delete cascade,
  xp              bigint not null default 0,
  level           integer not null default 1,
  lifetime_scans  bigint not null default 0,
  lifetime_opens  bigint not null default 0,
  lifetime_wins   bigint not null default 0,
  version         bigint not null default 1,
  updated_at      timestamptz not null default now()
);

-- app.streak_state : server-clock streaks; unique freeze use per day.
create table if not exists app.streak_state (
  player_id           text primary key references app.players(id) on delete cascade,
  last_qualifying_day integer,     -- game_day sequence
  streak              integer not null default 0,
  best_streak         integer not null default 0,
  freeze_inventory    integer not null default 0,
  freezes_used        jsonb not null default '[]'::jsonb,
  updated_at          timestamptz not null default now()
);

-- app.daily_quests : once-persisted selection; retries do not reroll.
create table if not exists app.daily_quests (
  player_id     text not null references app.players(id) on delete cascade,
  game_day_id   uuid not null references app.game_days(id) on delete cascade,
  quest_id      text not null,
  definition_version text not null,
  progress      numeric not null default 0,
  target        numeric not null,
  primary key (player_id, game_day_id, quest_id)
);

-- app.quest_claims : exact entitlement cannot be claimed twice.
create table if not exists app.quest_claims (
  player_id     text not null references app.players(id) on delete cascade,
  game_day_id   uuid not null references app.game_days(id) on delete cascade,
  quest_id      text not null,
  command_ref   uuid,
  result_ref    uuid,
  claimed_at    timestamptz not null default now(),
  primary key (player_id, game_day_id, quest_id)
);

-- app.comeback_claims : one comeback per away interval.
create table if not exists app.comeback_claims (
  id                     uuid primary key default gen_random_uuid(),
  player_id              text not null references app.players(id) on delete cascade,
  eligibility_interval_id text not null,
  claimed_at             timestamptz not null default now(),
  unique (player_id, eligibility_interval_id)
);

-- app.character_definitions : shared catalogue, seven-tier support, versioned snapshots.
create table if not exists app.character_definitions (
  definition_id text not null,
  version       integer not null,
  name          text not null,
  rarity        text not null,          -- seven-tier rarity label
  element       text,
  base_stats    jsonb not null default '{}'::jsonb,
  provenance    jsonb not null default '{}'::jsonb,
  created_at    timestamptz not null default now(),
  primary key (definition_id, version)
);

-- app.owned_characters : one row per actual copy (no dedup-destroying uniqueness).
create table if not exists app.owned_characters (
  id                uuid primary key default gen_random_uuid(),
  player_id         text not null references app.players(id) on delete cascade,
  definition_id     text,
  definition_version integer,
  generated_snapshot jsonb,             -- for scan/dish/fusion generated units
  fusion_tier       integer not null default 0,
  status            text not null default 'available'
                    check (status in ('available','in_squad','consumed','locked')),
  acquisition_id    uuid,
  created_at        timestamptz not null default now(),
  foreign key (definition_id, definition_version)
    references app.character_definitions(definition_id, version)
);
create index if not exists owned_characters_player_idx on app.owned_characters(player_id, status);

-- app.character_acquisitions : permanent acquisition evidence.
create table if not exists app.character_acquisitions (
  id             uuid primary key default gen_random_uuid(),
  player_id      text not null references app.players(id) on delete cascade,
  source_kind    text not null check (source_kind in ('scan','dish','lootbox','fusion','promo','reward')),
  source_ref     text,
  character_snapshot jsonb not null,
  acquired_at    timestamptz not null default now()
);
create index if not exists character_acquisitions_player_idx on app.character_acquisitions(player_id, acquired_at desc);

-- app.character_content : lore/art; retries reuse a stable request identity.
create table if not exists app.character_content (
  content_identity text not null,
  content_version  integer not null,
  lore             text,
  art_ref          uuid references app.media_objects(id),
  generator_status text not null default 'pending',
  generator_version text,
  created_at       timestamptz not null default now(),
  primary key (content_identity, content_version)
);

-- app.squads / app.squad_members
create table if not exists app.squads (
  id          uuid primary key default gen_random_uuid(),
  player_id   text not null references app.players(id) on delete cascade,
  name        text,
  mode        text not null default 'default',
  version     bigint not null default 1,
  created_at  timestamptz not null default now()
);
create index if not exists squads_player_idx on app.squads(player_id);

create table if not exists app.squad_members (
  squad_id      uuid not null references app.squads(id) on delete cascade,
  slot          integer not null,
  character_id  uuid not null references app.owned_characters(id),
  primary key (squad_id, slot),
  unique (squad_id, character_id)     -- a character occupies at most one slot per squad
);

-- app.fusion_operations / app.fusion_inputs : consume exactly five, create result atomically.
create table if not exists app.fusion_operations (
  id            uuid primary key default gen_random_uuid(),
  player_id     text not null references app.players(id) on delete cascade,
  rules_version text not null,
  result_character_id uuid references app.owned_characters(id),
  status        text not null default 'completed',
  created_at    timestamptz not null default now()
);

create table if not exists app.fusion_inputs (
  operation_id  uuid not null references app.fusion_operations(id) on delete cascade,
  character_id  uuid not null references app.owned_characters(id),
  primary key (operation_id, character_id),
  unique (character_id)               -- a copy can be consumed by only one fusion
);

-- app.achievement_unlocks : survives disposal of contributing event detail.
create table if not exists app.achievement_unlocks (
  player_id          text not null references app.players(id) on delete cascade,
  achievement_id     text not null,
  definition_version integer not null,
  achieved_at        timestamptz not null default now(),
  evidence_ref       text,
  primary key (player_id, achievement_id, definition_version)
);

-- app.claim_receipts : common permanent proof for objective/milestone/battle/season grants.
create table if not exists app.claim_receipts (
  id               uuid primary key default gen_random_uuid(),
  player_id        text not null references app.players(id) on delete cascade,
  entitlement_type text not null,
  entitlement_key  text not null,
  xp_effect        bigint not null default 0,
  currency_effect  jsonb not null default '{}'::jsonb,
  ownership_effect jsonb not null default '{}'::jsonb,
  created_at       timestamptz not null default now(),
  unique (player_id, entitlement_type, entitlement_key)
);

-- deferred FKs on player_settings now that owned_characters + squads exist
alter table app.player_settings
  add constraint player_settings_active_char_fk
  foreign key (active_character_id) references app.owned_characters(id) on delete set null;
alter table app.player_settings
  add constraint player_settings_squad_fk
  foreign key (preferred_squad_id) references app.squads(id) on delete set null;

-- acquisition backreference
alter table app.owned_characters
  add constraint owned_characters_acquisition_fk
  foreign key (acquisition_id) references app.character_acquisitions(id) on delete set null;
