-- 0012_main_feature_alignment.sql
-- Brings the TigerData schema up to the features merged into main after 0011:
--   * casino "Cauldron Crash"   -> app.cauldron_rounds  (SQLite cauldron_round)
--   * coin economy              -> 'coins' currency on wallets + currency_entries
--   * rank points / tiers       -> app.rankings.rank_points, rank_tier
--   * body metrics (weigh-ins)  -> telemetry.body_metrics hypertable + profile body_type
--   * star levels               -> app.owned_characters.star_level (1..5)
-- Idempotent where possible.

-- ---- coins currency ------------------------------------------------------
alter table app.wallets drop constraint if exists wallets_currency_check;
alter table app.wallets add constraint wallets_currency_check
  check (currency in ('keys','capsules','coins'));

-- ---- rank points / tier --------------------------------------------------
alter table app.rankings add column if not exists rank_points integer not null default 0
  check (rank_points >= 0);
alter table app.rankings add column if not exists rank_tier text not null default 'bronze';
do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'rankings_rank_tier_check') then
    alter table app.rankings add constraint rankings_rank_tier_check
      check (rank_tier in ('bronze','silver','gold','plat'));
  end if;
end $$;
create index if not exists rankings_tier_idx on app.rankings(season_id, rank_tier);

-- ---- star levels (character progression) ---------------------------------
-- fusion_tier stays for lineage; star_level is the 1..5 display/rule level.
alter table app.owned_characters add column if not exists star_level integer not null default 1
  check (star_level between 1 and 5);
create index if not exists owned_characters_star_idx on app.owned_characters(player_id, star_level);

-- ---- body type on profile versions --------------------------------------
alter table app.profile_versions add column if not exists body_type text;
do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'profile_versions_body_type_check') then
    alter table app.profile_versions add constraint profile_versions_body_type_check
      check (body_type is null or body_type in ('ectomorph','mesomorph','endomorph'));
  end if;
end $$;

-- ---- casino: Cauldron Crash rounds --------------------------------------
-- Mutable during an ACTIVE round (cash-out updates), terminal afterwards, so an
-- ordinary table (not a hypertable). Fairness/wager/reward kept as jsonb snapshots.
create table if not exists app.cauldron_rounds (
  round_id            uuid primary key default gen_random_uuid(),
  player_id           text not null references app.players(id) on delete cascade,
  wager               jsonb not null,
  starting_net_worth  integer not null check (starting_net_worth >= 0),
  crash_multiplier    double precision not null check (crash_multiplier >= 1),
  status              text not null check (status in ('ACTIVE','CASHED_OUT','CRASHED')),
  started_at          timestamptz not null default now(),
  cash_out_at         timestamptz,
  cash_out_multiplier double precision,
  final_net_worth     integer,
  reward              jsonb,
  fairness            jsonb not null,
  completed_at        timestamptz
);
create index if not exists cauldron_rounds_player_idx on app.cauldron_rounds(player_id, started_at desc);

-- ---- body metrics weigh-in time series (hypertable) ----------------------
create table if not exists telemetry.body_metrics (
  player_id     text not null references app.players(id) on delete cascade,
  logged_at     timestamptz not null,
  received_at   timestamptz not null default now(),
  weight_kg     numeric(5,1) not null check (weight_kg between 25 and 400),
  body_fat_pct  numeric(4,1) check (body_fat_pct is null or body_fat_pct between 2 and 70),
  source        text not null default 'manual' check (source in ('manual','healthkit','onboarding')),
  primary key (player_id, logged_at)
);
select create_hypertable('telemetry.body_metrics', 'logged_at',
       chunk_time_interval => interval '30 days', if_not_exists => true);
create index if not exists body_metrics_player_idx on telemetry.body_metrics(player_id, logged_at desc);

-- ---- record in the migration ledger --------------------------------------
insert into ops.schema_migrations(version, name)
values ('0012','0012_main_feature_alignment.sql')
on conflict do nothing;
