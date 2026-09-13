-- 0025_fix_player_id_columns.sql — fix a uuid/text player_id mismatch in
-- 0022-0024, plus the one missing explicit grant among them.
--
-- app.scan_mints, app.pending_cases, app.fainted_monsters and app.battle_matches
-- all declared `player_id uuid`, and their player_isolation policies cast
-- `current_setting('app.current_player', true)::uuid` to match. But real
-- player ids are not guaranteed to be UUIDs: registered accounts get
-- crypto.randomUUID() (backend/src/auth/store.ts), but the legacy
-- X-Player-Id header path (backend/src/middleware/player.ts) accepts any
-- string matching /^[A-Za-z0-9_-]{6,64}$/, and non-UUID ids are already in
-- use (tests, headless/pre-auth clients). Any such player hitting these four
-- tables gets `invalid input syntax for type uuid` on every RLS check —
-- reads included, since the policy applies to `for all`.
--
-- Fix: retype player_id to text on all four tables and rebuild each policy to
-- match the standard convention used everywhere else in this schema
-- (`player_id = current_setting('app.current_player', true)`, no cast). The
-- policy has to be dropped BEFORE the column type changes — Postgres refuses
-- to alter a column a policy still references.
--
-- Also: every sibling table (0022, 0023) has an explicit grant to
-- nutriquest_app; 0024 (battle_matches) never got one. The commit path
-- (`consumed_at`) needs update, not just insert.

drop policy if exists player_isolation on app.scan_mints;
alter table app.scan_mints alter column player_id type text using player_id::text;
create policy player_isolation on app.scan_mints for all
  using (player_id = current_setting('app.current_player', true))
  with check (player_id = current_setting('app.current_player', true));

drop policy if exists player_isolation on app.pending_cases;
alter table app.pending_cases alter column player_id type text using player_id::text;
create policy player_isolation on app.pending_cases for all
  using (player_id = current_setting('app.current_player', true))
  with check (player_id = current_setting('app.current_player', true));

drop policy if exists player_isolation on app.fainted_monsters;
alter table app.fainted_monsters alter column player_id type text using player_id::text;
create policy player_isolation on app.fainted_monsters for all
  using (player_id = current_setting('app.current_player', true))
  with check (player_id = current_setting('app.current_player', true));

drop policy if exists player_isolation on app.battle_matches;
alter table app.battle_matches alter column player_id type text using player_id::text;
-- opponent_id has the identical problem: it holds another player's id, drawn
-- from the same non-UUID-guaranteed domain, not a foreign identifier of its
-- own type.
alter table app.battle_matches alter column opponent_id type text using opponent_id::text;
create policy player_isolation on app.battle_matches for all
  using (player_id = current_setting('app.current_player', true))
  with check (player_id = current_setting('app.current_player', true));

grant select, insert, update on app.battle_matches to nutriquest_app;
