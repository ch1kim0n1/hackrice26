-- 0002_nutrition_activity.sql
-- Nutrition, activity, and verification (ordinary tables).
-- Source: db-documentation/03-relational-model.md (Nutrition, activity, and verification).

-- app.products : shared lookup cache (Open Food Facts etc.), not a player's intake.
create table if not exists app.products (
  barcode          text primary key,
  provider         text not null default 'openfoodfacts',
  name             text,
  brand            text,
  food_group       text,
  declared_unit    text not null default 'per_100g',
  nutrition        jsonb not null default '{}'::jsonb,  -- normalized per declared unit
  source_hash      text,
  fetched_at       timestamptz,
  freshness        text,
  created_at       timestamptz not null default now()
);

-- app.product_enrichment : optional planned price/scarcity enrichment.
create table if not exists app.product_enrichment (
  barcode      text not null references app.products(barcode) on delete cascade,
  provider     text not null,
  region       text not null default 'global',
  price_inputs jsonb not null default '{}'::jsonb,
  fetched_at   timestamptz,
  primary key (barcode, provider, region)
);

-- app.meals : durable current intake record; creation is idempotent via a receipt.
create table if not exists app.meals (
  id             uuid primary key default gen_random_uuid(),
  player_id      text not null references app.players(id) on delete cascade,
  current_revision integer not null default 1,
  consumed_at    timestamptz not null,
  game_day_id    uuid references app.game_days(id),
  source_kind    text not null default 'scan' check (source_kind in ('scan','manual','recipe','import')),
  status         text not null default 'confirmed' check (status in ('confirmed','deleted')),
  created_at     timestamptz not null default now()
);
create index if not exists meals_player_time_idx on app.meals(player_id, consumed_at desc);
create index if not exists meals_game_day_idx on app.meals(game_day_id);

-- app.meal_revisions : immutable revision; corrections append, never erase provenance.
create table if not exists app.meal_revisions (
  meal_id         uuid not null references app.meals(id) on delete cascade,
  revision        integer not null,
  correction_reason text,
  totals          jsonb not null default '{}'::jsonb,   -- calories/macros/sodium/micros
  source_confidence numeric,
  recorded_at     timestamptz not null default now(),
  primary key (meal_id, revision)
);

-- app.meal_items : confirmed edited items (not just model output).
create table if not exists app.meal_items (
  meal_id       uuid not null,
  revision      integer not null,
  item_id       uuid not null default gen_random_uuid(),
  barcode       text references app.products(barcode),
  label         text,
  portion_g     numeric,
  food_group    text,
  calories      numeric,
  protein_g     numeric,
  carbs_g       numeric,
  fat_g         numeric,
  sodium_mg     numeric,
  micronutrients jsonb not null default '{}'::jsonb,     -- six tracked micros
  missing_flags jsonb not null default '{}'::jsonb,
  primary key (meal_id, revision, item_id),
  foreign key (meal_id, revision) references app.meal_revisions(meal_id, revision) on delete cascade
);

-- app.meal_drafts : editable, unconfirmed analysis; no rewards before confirmation.
create table if not exists app.meal_drafts (
  id             uuid primary key default gen_random_uuid(),
  player_id      text not null references app.players(id) on delete cascade,
  media_ref      uuid,   -- FK to media_objects added below
  analysis_status text not null default 'pending'
                   check (analysis_status in ('pending','analyzing','ready','failed')),
  model_version  text,
  expires_at     timestamptz not null,
  created_at     timestamptz not null default now()
);
create index if not exists meal_drafts_player_idx on app.meal_drafts(player_id);

-- app.scan_claims : barcode/day eligibility for grant credit (distinct from intake logging).
create table if not exists app.scan_claims (
  id            uuid primary key default gen_random_uuid(),
  player_id     text not null references app.players(id) on delete cascade,
  game_day_id   uuid not null references app.game_days(id),
  barcode       text not null,
  entitlement   text not null default 'daily_barcode',
  rules_version text not null,
  claimed_at    timestamptz not null default now(),
  -- one barcode credit per player per game day
  unique (player_id, game_day_id, barcode)
);

-- app.daily_activity : consolidated canonical totals, not a sum of cumulative snapshots.
create table if not exists app.daily_activity (
  player_id        text not null references app.players(id) on delete cascade,
  game_day_id      uuid not null references app.game_days(id),
  source_revision  integer not null default 1,
  steps            integer not null default 0,
  active_energy_kcal numeric not null default 0,
  exercise_minutes numeric not null default 0,
  stand_hours      numeric not null default 0,
  coverage         jsonb not null default '{}'::jsonb,
  latest_measured_at timestamptz,
  updated_at       timestamptz not null default now(),
  primary key (player_id, game_day_id)
);

-- app.workouts : completed workout summaries (separate from raw sensor samples).
create table if not exists app.workouts (
  id               uuid primary key default gen_random_uuid(),
  player_id        text not null references app.players(id) on delete cascade,
  source_system    text not null default 'healthkit',
  source_workout_id text not null,
  workout_type     text,
  started_at       timestamptz not null,
  ended_at         timestamptz,
  duration_s       integer,
  energy_kcal      numeric,
  revision         integer not null default 1,
  deleted          boolean not null default false,
  created_at       timestamptz not null default now(),
  unique (player_id, source_system, source_workout_id)
);
create index if not exists workouts_player_time_idx on app.workouts(player_id, started_at desc);

-- app.media_objects : private photo/art metadata; signed access, no public permanent URL.
create table if not exists app.media_objects (
  id          uuid primary key default gen_random_uuid(),
  player_id   text not null references app.players(id) on delete cascade,
  object_key  text not null,
  purpose     text not null check (purpose in ('meal_photo','gym_photo','generated_art','other')),
  status      text not null default 'active',
  expires_at  timestamptz,
  hash        text,
  created_at  timestamptz not null default now()
);
create index if not exists media_objects_player_idx on app.media_objects(player_id);

-- app.gym_checks : unique successful entitlement per player/day.
create table if not exists app.gym_checks (
  id            uuid primary key default gen_random_uuid(),
  player_id     text not null references app.players(id) on delete cascade,
  game_day_id   uuid not null references app.game_days(id),
  object_ref    uuid references app.media_objects(id),
  verification_status text not null default 'pending'
                  check (verification_status in ('pending','verified','rejected')),
  result_version text,
  created_at    timestamptz not null default now()
);
-- at most one verified gym check per player per day
create unique index if not exists gym_checks_verified_day_uq
  on app.gym_checks(player_id, game_day_id)
  where verification_status = 'verified';

-- app.training_buffs : explicit combat/reward scope for a time window.
create table if not exists app.training_buffs (
  id            uuid primary key default gen_random_uuid(),
  player_id     text not null references app.players(id) on delete cascade,
  source_kind   text not null check (source_kind in ('gym_check','workout')),
  source_ref    uuid,
  kind          text not null,
  starts_at     timestamptz not null,
  ends_at       timestamptz not null,
  rules_version text not null,
  created_at    timestamptz not null default now()
);
create index if not exists training_buffs_player_idx on app.training_buffs(player_id, ends_at desc);

-- deferred FKs now that media_objects exists
alter table app.meal_drafts
  add constraint meal_drafts_media_fk
  foreign key (media_ref) references app.media_objects(id) on delete set null;
