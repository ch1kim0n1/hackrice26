-- 0022_scan_mints.sql — barcode-mint anti-cheat provenance (spec §1 checklist).
--
-- Every barcode mint persists the barcode, the exact nutrition snapshot the
-- monster was generated from, the nutrition data source, and the timestamp.
-- (player_id, barcode) is the primary key: one barcode mints once per user,
-- ever — a repeat insert fails instead of double-minting. Re-scans still log
-- meals (app.meals) and count for tasks; they just never write here again.
--
-- Player-owned row -> player_isolation policy, same convention as the other
-- app.* tables (0011/0017).

create table if not exists app.scan_mints (
  player_id    uuid        not null,
  barcode      text        not null,
  monster_id   uuid        not null,
  character_id text        not null,
  nutrition    jsonb       not null,
  source       text        not null,
  minted_at    timestamptz not null default now(),
  primary key (player_id, barcode)
);

create index if not exists scan_mints_player_time_idx
  on app.scan_mints(player_id, minted_at desc);

alter table app.scan_mints enable row level security;
drop policy if exists player_isolation on app.scan_mints;
create policy player_isolation on app.scan_mints for all
  using (player_id = current_setting('app.current_player', true)::uuid)
  with check (player_id = current_setting('app.current_player', true)::uuid);

grant select, insert on app.scan_mints to nutriquest_app;
