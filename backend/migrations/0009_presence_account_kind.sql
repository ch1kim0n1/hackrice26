-- 0009_presence_account_kind.sql
-- Parity cleanup from db-documentation/10-schema-parity-audit.md (gaps 1 & 2).
-- Idempotent: ADD COLUMN IF NOT EXISTS.
-- (Gap 3, object-storage provider, is an external decision, not a schema change.)

-- Gap 1: presence + pending-comeback state (live `player_seen` had these; app.comeback_claims
-- only records CLAIMED comebacks). Home them on the player row.
alter table app.players add column if not exists last_seen_at        timestamptz;
alter table app.players add column if not exists comeback_pending_at  timestamptz;

-- Gap 2: guest / portable accounts (live `players.is_portable`). A guest is a
-- header-based demo identity with no credentials row; a registered player has one.
alter table app.players add column if not exists kind text not null default 'registered';

do $$
begin
  if not exists (
    select 1 from pg_constraint where conname = 'players_kind_chk'
  ) then
    alter table app.players
      add constraint players_kind_chk check (kind in ('guest','registered'));
  end if;
end $$;

create index if not exists players_last_seen_idx on app.players(last_seen_at desc);
