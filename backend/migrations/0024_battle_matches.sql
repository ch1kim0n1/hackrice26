-- 0024_battle_matches.sql — pending interactive battles (spec §4/§5).
--
-- Ranked/friendly play is two-phase: begin parks the server-resolved squads
-- and the drawn seed here; commit replays the player's action script against
-- that locked snapshot. The row is what makes the seed un-rollable and the
-- match single-use (consumed_at).
--
-- Player-owned row -> player_isolation policy, same convention as the other
-- app.* tables (0011/0017/0022).

create table if not exists app.battle_matches (
  id           uuid        not null default gen_random_uuid(),
  player_id    uuid        not null,
  mode         text        not null check (mode in ('ranked','friendly')),
  own_squad    jsonb       not null,
  opp_squad    jsonb       not null,
  opponent_id  uuid,
  is_bot       boolean     not null default false,
  meta         jsonb,
  seed         text        not null,
  consumed_at  timestamptz,
  expires_at   timestamptz not null,
  created_at   timestamptz not null default now(),
  primary key (id, player_id)
);

create index if not exists battle_matches_player_time_idx
  on app.battle_matches(player_id, created_at desc);

alter table app.battle_matches enable row level security;
drop policy if exists player_isolation on app.battle_matches;
create policy player_isolation on app.battle_matches for all
  using (player_id = current_setting('app.current_player', true)::uuid)
  with check (player_id = current_setting('app.current_player', true)::uuid);
