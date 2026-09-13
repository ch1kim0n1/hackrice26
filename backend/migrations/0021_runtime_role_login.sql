-- 0021_runtime_role_login.sql -- let the restricted role actually connect.
--
-- 0011 created nutriquest_app NOLOGIN and wrote every RLS policy in the schema
-- against it, with a note that "a human adds LOGIN + password out-of-band".
-- That never happened, so for the whole life of this database every policy in
-- 0011, 0014, 0015, 0016, 0017 and 0018 has been enforced against a role that
-- cannot open a connection. The app has only ever connected as the table owner,
-- which bypasses RLS entirely.
--
-- This grants LOGIN. It deliberately does NOT set a password: a migration is a
-- file in git, and a credential in git is a credential you have to rotate. The
-- password is set once, out of band:
--
--   alter role nutriquest_app password 'REDACTED';
--
-- and handed to the app as DATABASE_URL. The owner connection string moves to
-- DATABASE_URL_ADMIN, which the migration runner and the CI checks use --
-- see backend/src/db/pg.ts.
--
-- After this, RLS is real: the app connects as a non-owner, so every
-- player_isolation policy binds, and app.mines_rounds.layout stops being
-- readable by the process that serves the game.

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'nutriquest_app') then
    -- LOGIN alone opens no door: Tiger Cloud requires password auth, and this
    -- role has no password until someone sets one.
    alter role nutriquest_app login;
  end if;
end $$;

-- The restricted role needs to see its own schemas to resolve unqualified
-- names and to let the pool's startup queries work.
grant usage on schema app, telemetry, analytics, ops to nutriquest_app;

-- 0011 granted table privileges at the time it ran and set default privileges
-- for tables created afterwards *by the role that ran 0011*. Re-assert across
-- everything currently present so a table created by a different admin session
-- (or restored from a dump) is not silently unreachable.
grant select, insert, update, delete on all tables in schema app       to nutriquest_app;
grant select, insert, update, delete on all tables in schema telemetry to nutriquest_app;
grant select, insert, update, delete on all tables in schema ops       to nutriquest_app;
grant select                          on all tables in schema analytics to nutriquest_app;
grant usage, select on all sequences in schema app to nutriquest_app;
grant usage, select on all sequences in schema ops to nutriquest_app;

-- Re-apply the two deliberate narrowings the blanket grant above just undid.
-- 0015 hides the Kitchen Mines board from the app role; 0014 and 0020 keep the
-- catalogue tables read-only. Order matters: these must come after the sweep.
revoke all on app.mines_rounds from nutriquest_app;
grant select (round_id, player_id, wager, wager_value, mines, revealed, status,
              started_at, cash_out_multiplier, final_net_worth, reward, completed_at, fairness)
  on app.mines_rounds to nutriquest_app;
grant insert on app.mines_rounds to nutriquest_app;
grant update (revealed, status, cash_out_multiplier, final_net_worth, reward, completed_at)
  on app.mines_rounds to nutriquest_app;

revoke insert, update, delete on app.character_definitions, app.rarity_bands,
  app.attacks, app.character_attacks, app.character_images, app.rank_bands
  from nutriquest_app;

-- No ledger row is written here: the runner (backend/src/db/migrate-pg.ts)
-- records every file it applies, in the same transaction.
