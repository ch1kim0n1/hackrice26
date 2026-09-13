-- 0011_rls_policies.sql
-- Row-level security as DEFENSE IN DEPTH (backend authorization is still the primary boundary).
-- The app connects as a restricted, non-owner role and sets a per-transaction player context:
--     SET LOCAL app.current_player = '<player id>';
-- RLS then confines every player-owned row to that player. No secrets here.

-- ---- Restricted runtime role (NOLOGIN here; a human adds LOGIN + password out-of-band) ----
do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'nutriquest_app') then
    create role nutriquest_app nologin;
  end if;
end $$;

grant usage on schema app, telemetry, analytics to nutriquest_app;
grant select, insert, update, delete on all tables in schema app       to nutriquest_app;
grant select, insert, update, delete on all tables in schema telemetry to nutriquest_app;
grant select                          on all tables in schema analytics to nutriquest_app;
grant usage, select on all sequences in schema app to nutriquest_app;
grant usage, select on all sequences in schema ops to nutriquest_app;
grant usage on schema ops to nutriquest_app;
grant select, insert, update, delete on all tables in schema ops to nutriquest_app;

-- future tables inherit the same grants
alter default privileges in schema app       grant select, insert, update, delete on tables to nutriquest_app;
alter default privileges in schema telemetry  grant select, insert, update, delete on tables to nutriquest_app;
alter default privileges in schema ops         grant select, insert, update, delete on tables to nutriquest_app;

-- ---- Enable RLS + a uniform player-isolation policy on every player-owned table ----
do $$
declare r record;
begin
  for r in
    select c.table_schema, c.table_name
    from information_schema.columns c
    join information_schema.tables t
      on t.table_schema = c.table_schema and t.table_name = c.table_name
    where c.column_name = 'player_id'
      and c.table_schema in ('app','telemetry')
      and t.table_type = 'BASE TABLE'
  loop
    -- RLS is not supported on hypertables with columnstore enabled; skip those.
    -- (telemetry.nutrition_deltas, telemetry.battle_metrics — see 0010). The app
    -- still filters these by player_id, and the restricted role limits access.
    if exists (
      select 1 from timescaledb_information.hypertables h
      where h.hypertable_schema = r.table_schema
        and h.hypertable_name   = r.table_name
        and h.compression_enabled
    ) then
      continue;
    end if;
    execute format('alter table %I.%I enable row level security', r.table_schema, r.table_name);
    execute format('drop policy if exists player_isolation on %I.%I', r.table_schema, r.table_name);
    execute format(
      $f$create policy player_isolation on %I.%I for all
         using (player_id = current_setting('app.current_player', true))
         with check (player_id = current_setting('app.current_player', true))$f$,
      r.table_schema, r.table_name);
  end loop;
end $$;

-- Allow the owner to SET ROLE nutriquest_app, so RLS can be exercised/tested as
-- the app sees it. `tsdbadmin` is Tiger Cloud's superuser and does not exist on
-- a plain Postgres, so an unguarded grant here aborts the whole migration and no
-- database can ever be built from empty -- which is exactly what happened: this
-- file has only ever been applied to the provisioned service, and the CI job
-- that would have caught it never ran (billing). Guarded, and extended to
-- whichever role is actually migrating, so this applies anywhere.
do $$
begin
  if exists (select 1 from pg_roles where rolname = 'tsdbadmin') then
    execute 'grant nutriquest_app to tsdbadmin';
  end if;
  if current_user <> 'tsdbadmin' then
    execute format('grant nutriquest_app to %I', current_user);
  end if;
end $$;

-- Notes:
-- * Table owner (tsdbadmin) BYPASSES RLS unless FORCE is set; the app must connect as
--   nutriquest_app for policies to apply. We do NOT force RLS on the owner so migrations/ops work.
-- * Continuous aggregates (analytics.*) are materialized views and are NOT covered by RLS;
--   the backend must filter them by player_id in the query.
-- * currency_entries / battle_participants have nullable player_id (system/NPC rows); those rows
--   are simply invisible to the player-scoped role, which is the intended behavior.
