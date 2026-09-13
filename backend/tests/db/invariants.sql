-- invariants.sql -- the game's rules, asserted against a real database.
--
-- Run by backend/scripts/run-db-invariants.js against a throwaway TimescaleDB
-- that has had backend/migrations/*.sql and backend/seed/*.sql applied. Every
-- assertion is about behaviour, not shape: scripts/check-pg-schema.js already
-- covers shape (ledger parity, RLS coverage, grants, the time-series surface).
--
-- Everything runs inside one transaction that is rolled back at the end, so the
-- fixtures below never persist and the file can be run repeatedly.

begin;

-- ---------------------------------------------------------------------------
-- Harness
-- ---------------------------------------------------------------------------
create or replace function pg_temp.assert(ok boolean, label text)
returns void language plpgsql as $fn$
begin
  if ok then
    raise notice 'ok: %', label;
  else
    raise exception 'FAILED: %', label;
  end if;
end
$fn$;

-- Asserts that a statement is refused, and refused for the stated reason.
--
-- `expect` is a fragment of the error the database must raise -- a constraint
-- name, or wording from a trigger. It is not optional cosmetics: an earlier
-- draft of this file "proved" that an unknown casino mode was rejected, when in
-- fact the insert was failing on an unrelated uuid cast and the mode CHECK was
-- never consulted. Naming the expected reason is what makes the assertion real.
create or replace function pg_temp.assert_raises(stmt text, label text, expect text)
returns void language plpgsql as $fn$
declare got text;
begin
  begin
    execute stmt;
  exception when others then
    got := sqlerrm;
    if position(lower(expect) in lower(got)) = 0 then
      raise exception 'FAILED: % -- refused, but for the wrong reason. expected %, got: %',
        label, expect, got;
    end if;
    raise notice 'ok (refused as expected): %', label;
    return;
  end;
  raise exception 'FAILED: % -- the statement was accepted', label;
end
$fn$;

-- ===========================================================================
-- The ledger explains every wallet it backs.
--
-- Runs first, on the seeded data, before the fixtures below add a deliberately
-- inconsistent wallet of their own. A balance is SUM(amount) over the ledger, so
-- a wallet that does not equal its own entries is a balance nothing can explain
-- -- which is exactly what the demo seed used to ship.
-- ===========================================================================
do $$
declare bad text;
begin
  select string_agg(
           w.player_id || '/' || w.currency ||
           ' (wallet ' || w.balance || ' vs ledger ' || coalesce(l.summed, 0) || ')', ', ')
    into bad
    from app.wallets w
    left join (select player_id, currency, sum(amount) as summed
                 from app.currency_entries
                where player_id is not null
                group by 1, 2) l
      on l.player_id = w.player_id and l.currency = w.currency
   where w.balance <> coalesce(l.summed, 0);
  perform pg_temp.assert(bad is null,
    'every wallet balance equals its ledger sum (off by: ' || coalesce(bad, '-') || ')');
end $$;

-- Seeded badges must already agree with their own point totals.
do $$
declare bad text;
begin
  select string_agg(player_id || ' (' || rank_points || ' -> ' || rank_tier || ')', ', ')
    into bad from app.rankings
   where rank_tier <> app.rank_tier_for_points(rank_points);
  perform pg_temp.assert(bad is null,
    'every seeded rank badge matches its points (off by: ' || coalesce(bad, '-') || ')');
end $$;

-- ---------------------------------------------------------------------------
-- Fixtures. Two players, so "isolated" can mean something.
-- ---------------------------------------------------------------------------
insert into app.players(id, display_name, kind) values
  ('p_inv_one', 'Invariant One', 'registered'),
  ('p_inv_two', 'Invariant Two', 'registered')
on conflict (id) do nothing;

insert into app.owned_characters(id, player_id, net_worth, status)
values ('11111111-0000-0000-0000-000000000001', 'p_inv_one', 2650, 'available'),
       ('11111111-0000-0000-0000-000000000002', 'p_inv_one', 6900, 'available'),
       ('22222222-0000-0000-0000-000000000001', 'p_inv_two', 500,  'available');

-- ===========================================================================
-- The ledger is append-only (0018)
-- ===========================================================================
insert into app.currency_entries(operation_id, entry_index, player_id, currency, amount, reason)
values (gen_random_uuid(), 0, 'p_inv_one', 'coins', 1500, 'grant');

select pg_temp.assert_raises(
  $q$ update app.currency_entries set amount = 999999 where player_id = 'p_inv_one' $q$,
  'ledger UPDATE is rejected', 'append-only');

select pg_temp.assert_raises(
  $q$ delete from app.currency_entries where player_id = 'p_inv_one' $q$,
  'ledger DELETE is rejected', 'append-only');

select pg_temp.assert_raises(
  $q$ insert into app.currency_entries(operation_id, entry_index, player_id, currency, amount, reason)
      values (gen_random_uuid(), 0, 'p_inv_one', 'coins', 0, 'grant') $q$,
  'a zero-amount ledger entry is rejected', 'currency_entries_amount_check');

select pg_temp.assert_raises(
  $q$ insert into app.currency_entries(operation_id, entry_index, player_id, currency, amount, reason)
      values (gen_random_uuid(), 0, 'p_inv_one', 'doubloons', 10, 'grant') $q$,
  'a ledger entry in an unknown currency is rejected', 'currency_entries_currency_check');

select pg_temp.assert_raises(
  $q$ insert into app.currency_entries(operation_id, entry_index, player_id, currency, amount, reason)
      values (gen_random_uuid(), 0, 'p_inv_one', 'coins', 10, '   ') $q$,
  'a ledger entry with no reason is rejected', 'currency_entries_reason_check');

-- A correction is a new row, not a rewrite -- so the ledger must still accept one.
insert into app.currency_entries(operation_id, entry_index, player_id, currency, amount, reason)
values (gen_random_uuid(), 0, 'p_inv_one', 'coins', -500, 'correction');
do $$
begin
  perform pg_temp.assert(
    (select sum(amount) from app.currency_entries
      where player_id = 'p_inv_one' and currency = 'coins') = 1000,
    'a compensating entry is how a balance is corrected');
end $$;

-- ===========================================================================
-- A wallet balance can never go negative (0004's CHECK, still standing)
-- ===========================================================================
insert into app.wallets(player_id, currency, balance) values ('p_inv_one', 'coins', 100)
on conflict (player_id, currency) do update set balance = 100;

select pg_temp.assert_raises(
  $q$ update app.wallets set balance = balance - 500
       where player_id = 'p_inv_one' and currency = 'coins' $q$,
  'overdrawing a wallet is rejected', 'wallets_balance_check');

-- ===========================================================================
-- Locks: a staked monster names its holder and cannot move or vanish (0018)
-- ===========================================================================
update app.owned_characters
   set locked_by = 'battle:abc'
 where id = '11111111-0000-0000-0000-000000000001';

do $$
declare r record;
begin
  select locked, status, locked_by into r from app.owned_characters
   where id = '11111111-0000-0000-0000-000000000001';
  perform pg_temp.assert(r.locked_by = 'battle:abc', 'a locked monster records what holds it');
  perform pg_temp.assert(r.locked, 'locked is derived from locked_by');
  perform pg_temp.assert(r.status = 'locked', 'status is kept in step with the lock');
end $$;

select pg_temp.assert_raises(
  $q$ delete from app.owned_characters where id = '11111111-0000-0000-0000-000000000001' $q$,
  'a locked monster cannot be sold or merged away', 'cannot be removed');

select pg_temp.assert_raises(
  $q$ update app.owned_characters set player_id = 'p_inv_two'
       where id = '11111111-0000-0000-0000-000000000001' $q$,
  'a locked monster cannot change owner mid-battle', 'cannot change owner');

-- Settlement: release and transfer in one statement is the legal path.
update app.owned_characters
   set player_id = 'p_inv_two', locked_by = null
 where id = '11111111-0000-0000-0000-000000000001';

do $$
declare r record;
begin
  select player_id, locked, status into r from app.owned_characters
   where id = '11111111-0000-0000-0000-000000000001';
  perform pg_temp.assert(r.player_id = 'p_inv_two', 'settlement moves the stake to the winner');
  perform pg_temp.assert(not r.locked, 'settlement releases the lock');
  perform pg_temp.assert(r.status = 'available', 'a released monster is available again');
end $$;

-- Once released it can be sold, which is the other half of the rule.
delete from app.owned_characters where id = '11111111-0000-0000-0000-000000000001';
do $$
begin
  perform pg_temp.assert(
    (select count(*) from app.owned_characters
      where id = '11111111-0000-0000-0000-000000000001') = 0,
    'a released monster can be sold');
end $$;

-- Deleting an account must still work even while a stake is live, or the privacy
-- deletion path is blocked by the anti-cheat rule.
update app.owned_characters set locked_by = 'battle:xyz'
 where id = '11111111-0000-0000-0000-000000000002';
delete from app.players where id = 'p_inv_one';
do $$
begin
  perform pg_temp.assert(
    (select count(*) from app.owned_characters where player_id = 'p_inv_one') = 0,
    'deleting a player cascades through a locked monster');
  perform pg_temp.assert(
    (select count(*) from app.currency_entries where player_id = 'p_inv_one') = 0,
    'a deleted player leaves no player-attributed ledger rows');
  perform pg_temp.assert(
    (select count(*) from app.currency_entries where player_id is null and reason = 'correction') >= 1,
    'the ledger survives the deletion, anonymised');
end $$;

-- ===========================================================================
-- Rarity is always derived from net worth (0014)
-- ===========================================================================
do $$
declare got text;
begin
  insert into app.owned_characters(id, player_id, net_worth, rarity)
  values ('22222222-0000-0000-0000-000000000002', 'p_inv_two', 58500, 'common');
  select rarity into got from app.owned_characters
   where id = '22222222-0000-0000-0000-000000000002';
  perform pg_temp.assert(got = 'mythic', 'a claimed rarity is overruled by net worth');

  update app.owned_characters set net_worth = 500
   where id = '22222222-0000-0000-0000-000000000002';
  select rarity into got from app.owned_characters
   where id = '22222222-0000-0000-0000-000000000002';
  perform pg_temp.assert(got = 'common', 'rarity follows net worth back down');
end $$;

select pg_temp.assert_raises(
  $q$ insert into app.owned_characters(player_id, net_worth, star_level)
      values ('p_inv_two', 500, 6) $q$,
  'a star level above 5 is rejected', 'owned_characters_star_level_check');

-- ===========================================================================
-- The consistency ladder: tier is always the point total's tier (0018)
-- ===========================================================================
insert into app.seasons(id, mode, starts_at, ends_at, state)
values ('33333333-0000-0000-0000-000000000001', 'inv-mode',
        now() - interval '1 day', now() + interval '30 days', 'active')
on conflict (id) do nothing;

do $$
declare got text;
begin
  insert into app.rankings(player_id, season_id, rank_points, rank_tier)
  values ('p_inv_two', '33333333-0000-0000-0000-000000000001', 640, 'bronze');
  select rank_tier into got from app.rankings
   where player_id = 'p_inv_two' and season_id = '33333333-0000-0000-0000-000000000001';
  perform pg_temp.assert(got = 'plat', '640 points is plat however the row was written');

  update app.rankings set rank_points = 150
   where player_id = 'p_inv_two' and season_id = '33333333-0000-0000-0000-000000000001';
  select rank_tier into got from app.rankings
   where player_id = 'p_inv_two' and season_id = '33333333-0000-0000-0000-000000000001';
  perform pg_temp.assert(got = 'silver', 'a demotion follows the points down');

  update app.rankings set rank_tier = 'plat'
   where player_id = 'p_inv_two' and season_id = '33333333-0000-0000-0000-000000000001';
  select rank_tier into got from app.rankings
   where player_id = 'p_inv_two' and season_id = '33333333-0000-0000-0000-000000000001';
  perform pg_temp.assert(got = 'silver', 'a badge cannot be set by hand past its points');
end $$;

-- Every band in the ladder must be reachable, and they must tile from zero.
do $$
declare gap text;
begin
  perform pg_temp.assert((select min(min_points) from app.rank_bands) = 0,
    'the bottom rank band starts at zero');
  select string_agg(tier, ', ' order by ordinal) into gap
    from app.rank_bands a
   where app.rank_tier_for_points(a.min_points) <> a.tier;
  perform pg_temp.assert(gap is null,
    'every rank band resolves to itself at its own floor (off by: ' || coalesce(gap, '-') || ')');
end $$;

-- ===========================================================================
-- Onboarding sanity (0018)
-- ===========================================================================
select pg_temp.assert_raises(
  $q$ insert into app.profile_versions(player_id, revision, measurements, formula_version)
      values ('p_inv_two', 900, '{"age": 4}', 'v1') $q$,
  'an age under 10 is rejected', 'profile_versions_age_check');

select pg_temp.assert_raises(
  $q$ insert into app.profile_versions(player_id, revision, measurements, formula_version)
      values ('p_inv_two', 901, '{"age": 999}', 'v1') $q$,
  'an impossible age is rejected', 'profile_versions_age_check');

insert into app.profile_versions(player_id, revision, measurements, formula_version)
values ('p_inv_two', 902, '{"height_cm": 180}', 'v1');
do $$
begin
  perform pg_temp.assert(
    (select count(*) from app.profile_versions where player_id = 'p_inv_two' and revision = 902) = 1,
    'a profile with no age yet is still accepted');
end $$;

-- ===========================================================================
-- The casino cannot pay out a round it did not win (0016)
-- ===========================================================================
select pg_temp.assert_raises(
  $q$ insert into app.portal_wheel_spins
        (player_id, wager, wager_value, pick, section, winning_color, won, multiplier, final_net_worth, fairness)
      values ('p_inv_two', '{}', 500, 'blue', 3, 'red', false, 0, 4000, '{}') $q$,
  'a losing wheel spin cannot pay out', 'portal_wheel_paid_iff_won');

insert into app.portal_wheel_spins
  (player_id, wager, wager_value, pick, section, winning_color, won, multiplier, final_net_worth, fairness)
values ('p_inv_two', '{}', 500, 'blue', 3, 'blue', true, 2, 1000, '{}');
do $$
begin
  perform pg_temp.assert(
    (select count(*) from app.portal_wheel_spins where player_id = 'p_inv_two') = 1,
    'a winning wheel spin is recorded');
end $$;

select pg_temp.assert_raises(
  $q$ insert into telemetry.gamble_events
        (occurred_at, player_id, mode, outcome, wager_value, net_worth_change, ref_id)
      values (now(), 'p_inv_two', 'roulette', 'won', 100, 100, gen_random_uuid()) $q$,
  'an unknown casino mode is rejected', 'gamble_events_mode_check');

-- ===========================================================================
-- Row-level security actually isolates, read as the app's own role
--
-- The owner bypasses RLS (0011 leaves FORCE off so migrations and ops work), so
-- asserting isolation means becoming nutriquest_app -- which is exactly how the
-- backend reaches these tables.
-- ===========================================================================
do $$
declare
  own_rows     int;
  foreign_rows int;
  total_rows   int;
begin
  select count(*) into total_rows from app.owned_characters;
  perform pg_temp.assert(total_rows >= 2, 'RLS fixture: rows exist that could leak');

  set local role nutriquest_app;
  perform set_config('app.current_player', 'p_inv_two', true);

  select count(*) into own_rows from app.owned_characters where player_id = 'p_inv_two';
  select count(*) into foreign_rows from app.owned_characters where player_id <> 'p_inv_two';

  reset role;

  perform pg_temp.assert(foreign_rows = 0,
    'RLS isolates: the app role sees no other player''s monsters');
  perform pg_temp.assert(own_rows > 0,
    'RLS isolates: the app role still sees its own monsters');
end $$;

-- The mine layout is the one column the app role must never read, live or not.
do $$
declare leaked int;
begin
  set local role nutriquest_app;
  perform set_config('app.current_player', 'p_inv_two', true);
  begin
    select count(*) into leaked from app.mines_rounds where layout is not null;
    reset role;
    raise exception 'FAILED: the app role could read app.mines_rounds.layout';
  exception when insufficient_privilege then
    reset role;
    raise notice 'ok (refused as expected): the mine layout is unreadable by the app role';
  end;
end $$;

do $$ begin raise notice 'ALL INVARIANTS HELD'; end $$;

rollback;
