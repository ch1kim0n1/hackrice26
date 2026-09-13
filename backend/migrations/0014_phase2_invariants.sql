-- 0014_phase2_invariants.sql — append-only completion of Phase 2.
-- 0013 reached the DEV service before its session ended. This migration keeps
-- that applied file immutable and adds the missing backfill, RLS, foreign keys,
-- derived-rarity trigger, attack gate, and versioned image lookup.

create table if not exists app.rarity_bands (
  rarity        text primary key,
  ordinal       smallint not null unique check (ordinal between 0 and 6),
  min_net_worth integer not null unique check (min_net_worth >= 0)
);

insert into app.rarity_bands(rarity, ordinal, min_net_worth) values
  ('common', 0, 500), ('uncommon', 1, 1100), ('rare', 2, 2650),
  ('epic', 3, 6900), ('legendary', 4, 19500),
  ('mythic', 5, 58500), ('secret', 6, 187000)
on conflict (rarity) do update set
  ordinal = excluded.ordinal, min_net_worth = excluded.min_net_worth;

create or replace function app.rarity_for_net_worth(p_net_worth integer)
returns text language sql stable strict as $$
  select coalesce(
    (select rarity from app.rarity_bands
      where min_net_worth <= greatest(p_net_worth, 0)
      order by min_net_worth desc limit 1),
    'common'
  )
$$;

-- star_level is the only writable mastery representation after this migration.
-- fusion_tier remains as a deprecated lineage column so this live migration
-- never destroys historical data; application code no longer reads it.
update app.owned_characters
   set star_level = greatest(star_level, least(5, fusion_tier + 1));

-- 0013 gave legacy rows a temporary zero. Backfill each at its authored rarity
-- floor, or Common when no definition is available.
update app.owned_characters oc
   set net_worth = coalesce(
     (select rb.min_net_worth
        from app.character_definitions cd
        join app.rarity_bands rb on rb.rarity = cd.rarity
       where cd.definition_id = oc.definition_id
         and cd.version = oc.definition_version),
     500
   )
 where oc.net_worth = 0;

alter table app.owned_characters alter column net_worth set default 500;

update app.owned_characters
   set rarity = app.rarity_for_net_worth(net_worth),
       locked = (status = 'locked');
alter table app.owned_characters drop constraint if exists owned_characters_rarity_check;
alter table app.owned_characters alter column rarity set not null;
alter table app.owned_characters
  add constraint owned_characters_rarity_check
    check (rarity in ('common','uncommon','rare','epic','legendary','mythic','secret'));
alter table app.owned_characters
  add constraint owned_characters_lock_state_check
    check (locked = (status = 'locked'));

create or replace function app.derive_owned_character_rarity()
returns trigger language plpgsql as $$
begin
  new.rarity := app.rarity_for_net_worth(new.net_worth);
  return new;
end
$$;

drop trigger if exists owned_character_rarity_from_worth on app.owned_characters;
create trigger owned_character_rarity_from_worth
before insert or update of net_worth, rarity on app.owned_characters
for each row execute function app.derive_owned_character_rarity();

create index if not exists owned_characters_player_worth_idx
  on app.owned_characters(player_id, net_worth desc);

alter table app.owned_characters enable row level security;
drop policy if exists player_isolation on app.owned_characters;
create policy player_isolation on app.owned_characters for all
  using (player_id = current_setting('app.current_player', true))
  with check (player_id = current_setting('app.current_player', true));

-- Reconcile the draft attack kind names with the product contract.
alter table app.attacks drop constraint if exists attacks_kind_check;
alter table app.attacks
  add constraint attacks_kind_check check (kind in ('basic','signature','special'));
alter table app.attacks
  add constraint attacks_min_rarity_fk foreign key (min_rarity)
    references app.rarity_bands(rarity);

alter table app.character_attacks
  add column definition_version integer not null default 1;
alter table app.character_attacks drop constraint character_attacks_pkey;
alter table app.character_attacks
  add primary key (definition_id, definition_version, attack_id);
alter table app.character_attacks
  add constraint character_attacks_definition_fk
    foreign key (definition_id, definition_version)
    references app.character_definitions(definition_id, version) on delete cascade;

create or replace view app.available_character_attacks
with (security_invoker = true) as
select oc.player_id, oc.id as character_id, a.id as attack_id,
       a.name, a.kind, a.power, a.effect, a.min_rarity
  from app.owned_characters oc
  join app.character_attacks ca
    on ca.definition_id = oc.definition_id
   and ca.definition_version = oc.definition_version
  join app.attacks a on a.id = ca.attack_id
  join app.rarity_bands instance_band on instance_band.rarity = oc.rarity
  join app.rarity_bands attack_band on attack_band.rarity = a.min_rarity
 where instance_band.ordinal >= attack_band.ordinal;

alter table app.character_images
  add column definition_version integer not null default 1;
alter table app.character_images drop constraint character_images_pkey;
alter table app.character_images
  add primary key (definition_id, definition_version, rarity);
alter table app.character_images
  add constraint character_images_definition_fk
    foreign key (definition_id, definition_version)
    references app.character_definitions(definition_id, version) on delete cascade;
alter table app.character_images
  add constraint character_images_rarity_fk foreign key (rarity)
    references app.rarity_bands(rarity);

create or replace function app.character_image_key(
  p_definition_id text, p_definition_version integer, p_rarity text
)
returns text language sql stable as $$
  select coalesce(
    (select ci.image_key from app.character_images ci
      where ci.definition_id = p_definition_id
        and ci.definition_version = p_definition_version
        and ci.rarity = p_rarity),
    p_definition_id || '-' || p_rarity
  )
$$;

-- World-readable catalogue, default-deny audited, runtime read-only.
alter table app.character_definitions enable row level security;
alter table app.rarity_bands enable row level security;
alter table app.attacks enable row level security;
alter table app.character_attacks enable row level security;
alter table app.character_images enable row level security;

drop policy if exists catalog_read on app.character_definitions;
drop policy if exists catalog_read on app.rarity_bands;
drop policy if exists catalog_read on app.attacks;
drop policy if exists catalog_read on app.character_attacks;
drop policy if exists catalog_read on app.character_images;
create policy catalog_read on app.character_definitions for select to nutriquest_app using (true);
create policy catalog_read on app.rarity_bands for select to nutriquest_app using (true);
create policy catalog_read on app.attacks for select to nutriquest_app using (true);
create policy catalog_read on app.character_attacks for select to nutriquest_app using (true);
create policy catalog_read on app.character_images for select to nutriquest_app using (true);

revoke insert, update, delete on app.character_definitions, app.rarity_bands,
  app.attacks, app.character_attacks, app.character_images from nutriquest_app;
grant select on app.character_definitions, app.rarity_bands, app.attacks,
  app.character_attacks, app.character_images, app.available_character_attacks
  to nutriquest_app;
grant execute on function app.rarity_for_net_worth(integer) to nutriquest_app;
grant execute on function app.character_image_key(text, integer, text) to nutriquest_app;

insert into ops.schema_migrations(version, name)
values ('0014', '0014_phase2_invariants.sql')
on conflict (version) do nothing;
