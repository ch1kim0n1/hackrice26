-- 0016_portal_wheel.sql — Portal Wheel on TigerData
--
-- The fourth casino game (SQLite: 008_portal_wheel). One monster, one colour,
-- one spin — so like Plinko this is an immutable row per round with no active
-- state, and unlike Kitchen Mines there is nothing to withhold: the winning
-- section is public the moment it is drawn, because the client needs it to
-- stop the wheel on the right wedge.
--
-- 0015 fixed telemetry.gamble_events to three modes. A fourth game means that
-- CHECK has to widen, which is done here rather than by editing 0015: the
-- migration ledger is append-only (ops.schema_migrations), and a file that has
-- already run on the live store is history.
--
-- `multiplier` is the price the chosen colour was quoted at, frozen at spin
-- time. The section layout in backend/src/data/portalWheel.ts is tunable, so a
-- rebalanced wheel must not silently restate what an old spin paid.

-- ---------------------------------------------------------------------------
-- Portal Wheel — one immutable row per spin.
-- ---------------------------------------------------------------------------
create table if not exists app.portal_wheel_spins (
  spin_id         uuid primary key default gen_random_uuid(),
  player_id       text not null references app.players(id) on delete cascade,
  wager           jsonb not null,
  wager_value     bigint not null check (wager_value >= 0),
  pick            text not null check (pick in ('blue','red','yellow','green')),
  -- Which of the wheel's equal sections the pointer stopped on. Kept alongside
  -- the colour because the colour is derivable from the section and not the
  -- reverse, and the section is what a disputed spin is replayed against.
  section         integer not null check (section >= 0),
  winning_color   text not null check (winning_color in ('blue','red','yellow','green')),
  won             boolean not null,
  multiplier      numeric not null check (multiplier >= 0),
  final_net_worth bigint not null default 0,          -- 0 on a wrong colour
  reward          jsonb,                              -- null on a wrong colour
  created_at      timestamptz not null default now(),
  fairness        jsonb not null,
  -- A win pays and a loss does not. The one exception is a worthless wager,
  -- which can win and still floor to nothing.
  constraint portal_wheel_paid_iff_won
    check (won = (final_net_worth > 0) or wager_value = 0)
);
create index if not exists portal_wheel_spins_player_idx
  on app.portal_wheel_spins(player_id, created_at desc);

alter table app.portal_wheel_spins enable row level security;
drop policy if exists player_isolation on app.portal_wheel_spins;
create policy player_isolation on app.portal_wheel_spins for all
  using (player_id = current_setting('app.current_player', true))
  with check (player_id = current_setting('app.current_player', true));
grant select, insert on app.portal_wheel_spins to nutriquest_app;

-- ---------------------------------------------------------------------------
-- telemetry.gamble_events — admit the fourth mode.
--
-- Dropping and re-adding the CHECK rather than adding a second one: two
-- overlapping constraints on the same column would both have to be consulted
-- to know what a legal mode is, and the next game would inherit the confusion.
-- analytics.gamble_hourly groups by mode, so it picks the new game up with no
-- change of its own. Wheel spins record outcome 'won' or 'lost', alongside the
-- served/burnt/cashed_out/crashed/dropped/busted values 0015 listed.
-- ---------------------------------------------------------------------------
alter table telemetry.gamble_events
  drop constraint if exists gamble_events_mode_check;
alter table telemetry.gamble_events
  add constraint gamble_events_mode_check
  check (mode in ('crash','mines','plinko','wheel'));

-- No ledger row is written here on purpose. The runner
-- (backend/src/db/migrate-pg.ts) records every file it applies, in the same
-- transaction; a file that also records itself makes the runner's insert a
-- duplicate-key failure, which is why 0012 and 0015 cannot apply to an empty
-- database. Recording the ledger is the runner's job, not a migration's.
