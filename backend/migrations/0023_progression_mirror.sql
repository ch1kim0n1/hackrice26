-- 0023_progression_mirror.sql — progression tables the SQLite source of truth
-- gained in the spec migration (final-dev-doc §5/§6), mirrored for TigerData.
--
-- app.pending_cases    — granted fixed-rarity Cases (ranked wins, promos)
--                        waiting to be opened. One row per unopened case;
--                        the open consumes it (DELETE), which is why the grant
--                        includes delete — an open that cannot delete the row
--                        would double-mint.
--
-- app.fainted_monsters — 0-HP monsters that stay fainted until the daily
--                        reset or a nutrition-task revive. Day-stamped;
--                        recovery deletes the row.
--
-- Player-owned rows -> player_isolation policy, same convention as the other
-- app.* tables (0011/0017/0022). check-pg-schema fails the build on any
-- player_id table missing RLS or a policy.

create table if not exists app.pending_cases (
  case_id    uuid        not null,
  player_id  uuid        not null,
  rarity     text        not null check (rarity in
             ('common','uncommon','rare','epic','legendary','mythic','secret')),
  source     text        not null,           -- e.g. 'ranked:gold', 'promo:XYZ'
  created_at timestamptz not null default now(),
  primary key (case_id)
);

create index if not exists pending_cases_player_idx
  on app.pending_cases(player_id, created_at);

alter table app.pending_cases enable row level security;
drop policy if exists player_isolation on app.pending_cases;
create policy player_isolation on app.pending_cases for all
  using (player_id = current_setting('app.current_player', true)::uuid)
  with check (player_id = current_setting('app.current_player', true)::uuid);

grant select, insert, delete on app.pending_cases to nutriquest_app;

create table if not exists app.fainted_monsters (
  player_id   uuid        not null,
  char_id     text        not null,
  day         date        not null,
  fainted_at  timestamptz not null default now(),
  primary key (player_id, char_id)
);

create index if not exists fainted_monsters_player_day_idx
  on app.fainted_monsters(player_id, day);

alter table app.fainted_monsters enable row level security;
drop policy if exists player_isolation on app.fainted_monsters;
create policy player_isolation on app.fainted_monsters for all
  using (player_id = current_setting('app.current_player', true)::uuid)
  with check (player_id = current_setting('app.current_player', true)::uuid);

grant select, insert, delete on app.fainted_monsters to nutriquest_app;
