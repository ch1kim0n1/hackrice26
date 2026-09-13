-- 0018_game_rule_enforcement.sql -- the game's rules, enforced by the database.
--
-- Until now the only DB-level enforcement of game rules lived in a parallel
-- Postgres schema that was never provisioned and never ran anywhere but CI.
-- This file moves the rules worth enforcing onto the schema the app actually
-- uses, against the shapes it actually has.
--
-- The rules are deliberately split three ways, by their nature:
--
--   Pure maths        -> TypeScript, seeded and deterministic. game/rarityBands.ts,
--                        game/rankTiers.ts, BattleKit. The server replays fights,
--                        so this cannot live in SQL.
--   Structural truth  -> here. The things that must hold no matter which code
--                        path writes: an append-only ledger stays append-only,
--                        a locked monster cannot move or vanish, a derived
--                        column is always derived.
--   Live runtime      -> SQLite CHECKs plus one chokepoint (consumeDrops), which
--                        already exist.
--
-- Rules NOT brought across, because the model they described is gone:
--   * rarity from scarcity/price -- superseded by the net-worth ladder, already
--     enforced by 0014's owned_character_rarity_from_worth trigger.
--   * fusing three same-barcode copies into a star -- superseded; merging raises
--     stars and value, never rarity.
--   * Elo ratings and a Diamond tier -- the consistency ladder is
--     bronze/silver/gold/plat from rank points; Elo stays in BattleKit.
--   * a three-monster pot -- no such table exists; every casino game wagers one
--     monster per round.

-- ---------------------------------------------------------------------------
-- 1. The coin/key ledger is append-only.
--
-- A balance is SUM(amount) over these rows, so a row that can be edited after
-- the fact is a balance that cannot be explained. Blocking the owner too is the
-- point: a correction is a new compensating row, not a rewrite.
--
-- The one legal mutation is the FK's own doing. player_id is
-- `on delete set null` so a deleted player's ledger survives anonymised for
-- accounting; that arrives here as an UPDATE and must be let through, but only
-- when it changes nothing else.
-- ---------------------------------------------------------------------------
create or replace function app.reject_ledger_mutation()
returns trigger language plpgsql as $fn$
begin
  if tg_op = 'UPDATE'
     and old.player_id is not null and new.player_id is null
     and new.id           =  old.id
     and new.operation_id =  old.operation_id
     and new.entry_index  =  old.entry_index
     and new.account      =  old.account
     and new.currency     =  old.currency
     and new.amount       =  old.amount
     and new.reason       =  old.reason
     and new.created_at   =  old.created_at
     and new.ref is not distinct from old.ref
  then
    return new;  -- privacy anonymisation via ON DELETE SET NULL
  end if;
  raise exception
    'app.currency_entries is append-only; % rejected (correct with a compensating entry)', tg_op
    using errcode = '23514';
end
$fn$;

drop trigger if exists currency_entries_append_only on app.currency_entries;
create trigger currency_entries_append_only
before update or delete on app.currency_entries
for each row execute function app.reject_ledger_mutation();

-- Structural shape of a ledger row. `reason` is deliberately left open text: the
-- vocabulary still grows with each game mode, and 0016 already had to widen one
-- CHECK for exactly that reason. Non-empty is the part worth asserting.
alter table app.currency_entries drop constraint if exists currency_entries_amount_check;
alter table app.currency_entries add constraint currency_entries_amount_check
  check (amount <> 0);
alter table app.currency_entries drop constraint if exists currency_entries_currency_check;
alter table app.currency_entries add constraint currency_entries_currency_check
  check (currency in ('keys','capsules','coins'));
alter table app.currency_entries drop constraint if exists currency_entries_reason_check;
alter table app.currency_entries add constraint currency_entries_reason_check
  check (btrim(reason) <> '');

-- ---------------------------------------------------------------------------
-- 2. A locked monster names its holder, and cannot move or vanish.
--
-- 0012 gave owned_characters a bare `locked` boolean and 0014 tied it to
-- status. A flag cannot say WHICH battle or round is holding a monster, so
-- releasing one afterwards is guesswork -- the same problem the SQLite schema
-- hit at 004 and fixed at 007 with locked_by. Same fix, same authority:
-- locked_by is the truth and `locked`/`status` are kept in step with it.
-- ---------------------------------------------------------------------------
alter table app.owned_characters add column if not exists locked_by text;
create index if not exists owned_characters_locked_by_idx
  on app.owned_characters(locked_by) where locked_by is not null;

-- Anything already flagged is held by something nobody recorded. Name it, using
-- the same sentinel the SQLite migration chose, so the columns agree from here.
update app.owned_characters set locked_by = 'legacy'
 where locked_by is null and (locked or status = 'locked');

create or replace function app.sync_owned_character_lock()
returns trigger language plpgsql as $fn$
begin
  new.locked := new.locked_by is not null;
  -- Keep 0014's locked = (status = 'locked') invariant true from either
  -- direction, so callers can set whichever one they mean.
  if new.locked and new.status <> 'locked' then
    new.status := 'locked';
  elsif not new.locked and new.status = 'locked' then
    new.status := 'available';
  end if;
  return new;
end
$fn$;

drop trigger if exists owned_character_lock_sync on app.owned_characters;
create trigger owned_character_lock_sync
before insert or update on app.owned_characters
for each row execute function app.sync_owned_character_lock();

-- A staked monster cannot be sold, merged away, or handed to someone else while
-- the stake is live. Settlement is still allowed, because it releases the lock
-- and changes the owner in the same statement.
--
-- The players-row check is what keeps "delete my account" working: player_id is
-- `on delete cascade`, and by the time that cascade reaches this row the parent
-- is already gone, so a privacy deletion is not mistaken for a sale.
create or replace function app.guard_locked_character()
returns trigger language plpgsql as $fn$
begin
  if tg_op = 'DELETE' then
    if old.locked_by is not null
       and exists (select 1 from app.players where id = old.player_id) then
      raise exception 'character % is locked by % and cannot be removed',
        old.id, old.locked_by using errcode = '23514';
    end if;
    return old;
  end if;

  if old.locked_by is not null
     and new.player_id <> old.player_id
     and new.locked_by is not null then
    raise exception 'character % cannot change owner while locked by %',
      old.id, old.locked_by using errcode = '23514';
  end if;
  return new;
end
$fn$;

drop trigger if exists owned_character_lock_guard on app.owned_characters;
create trigger owned_character_lock_guard
before delete or update on app.owned_characters
for each row execute function app.guard_locked_character();

-- ---------------------------------------------------------------------------
-- 3. The consistency ladder, as data rather than as a literal.
--
-- game/rankTiers.ts owns points -> tier. Writing those floors inline here would
-- make a second ladder, which is the mistake CLAUDE.md calls out for net worth.
-- A table instead, checked against the TypeScript by
-- backend/scripts/check-pg-schema.js, the same way app.rarity_bands is.
-- ---------------------------------------------------------------------------
create table if not exists app.rank_bands (
  tier       text primary key,
  ordinal    smallint not null unique check (ordinal between 0 and 3),
  min_points integer not null unique check (min_points >= 0)
);

insert into app.rank_bands(tier, ordinal, min_points) values
  ('bronze', 0, 0), ('silver', 1, 100), ('gold', 2, 300), ('plat', 3, 600)
on conflict (tier) do update set
  ordinal = excluded.ordinal, min_points = excluded.min_points;

create or replace function app.rank_tier_for_points(p_points integer)
returns text language sql stable strict as $fn$
  select coalesce(
    (select tier from app.rank_bands
      where min_points <= greatest(p_points, 0)
      order by min_points desc limit 1),
    'bronze')
$fn$;

-- The seed wrote tiers that disagree with their own point totals (it used Elo
-- ratings, which are the other ladder entirely -- see rankTiers.ts). Put every
-- badge back in step with the number that produced it before enforcing it.
update app.rankings
   set rank_tier = app.rank_tier_for_points(rank_points)
 where rank_tier <> app.rank_tier_for_points(rank_points);

create or replace function app.derive_rank_tier()
returns trigger language plpgsql as $fn$
begin
  new.rank_tier := app.rank_tier_for_points(new.rank_points);
  return new;
end
$fn$;

drop trigger if exists rankings_tier_from_points on app.rankings;
create trigger rankings_tier_from_points
before insert or update of rank_points, rank_tier on app.rankings
for each row execute function app.derive_rank_tier();

-- Catalogue table: world-readable to the runtime role, never writable by it.
-- Same treatment 0014 gave app.rarity_bands.
alter table app.rank_bands enable row level security;
drop policy if exists catalog_read on app.rank_bands;
create policy catalog_read on app.rank_bands for select to nutriquest_app using (true);
revoke insert, update, delete on app.rank_bands from nutriquest_app;
grant select on app.rank_bands to nutriquest_app;
grant execute on function app.rank_tier_for_points(integer) to nutriquest_app;

-- ---------------------------------------------------------------------------
-- 4. An onboarding age that could not be a person.
--
-- measurements is jsonb, so this is the CHECK the old column-typed schema got
-- for free. Absent stays legal -- onboarding is progressive.
-- ---------------------------------------------------------------------------
alter table app.profile_versions drop constraint if exists profile_versions_age_check;
alter table app.profile_versions add constraint profile_versions_age_check
  check (
    measurements->>'age' is null
    or ((measurements->>'age') ~ '^[0-9]+$'
        and (measurements->>'age')::integer between 10 and 120)
  );

-- No ledger row is written here: the runner (backend/src/db/migrate-pg.ts)
-- records every file it applies, in the same transaction.
