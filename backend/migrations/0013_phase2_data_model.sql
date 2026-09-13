-- 0013_phase2_data_model.sql — Phase 2 (Data Model & Valuation)
-- Issues #132 (unified instance model), #118/#119 (net_worth + rarity), #106
-- (attacks), #97 (image variants). RARITIES = common..secret (7 tiers).

-- #132 / #118 / #119 — unified character instance shape.
alter table app.owned_characters
  add column if not exists net_worth integer not null default 0 check (net_worth >= 0);
alter table app.owned_characters add column if not exists rarity text;
do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'owned_characters_rarity_check') then
    alter table app.owned_characters add constraint owned_characters_rarity_check
      check (rarity is null or rarity in ('common','uncommon','rare','epic','legendary','mythic','secret'));
  end if;
end $$;
alter table app.owned_characters add column if not exists locked boolean not null default false;
alter table app.owned_characters add column if not exists image_key text;
create index if not exists owned_characters_net_worth_idx on app.owned_characters(net_worth desc);

update app.owned_characters oc
   set rarity = cd.rarity
  from app.character_definitions cd
 where oc.rarity is null
   and oc.definition_id = cd.definition_id
   and oc.definition_version = cd.version;

-- #106 — attacks catalogue + definition movesets.
create table if not exists app.attacks (
  id         text primary key,
  name       text not null,
  kind       text not null check (kind in ('physical','special','status','ultimate')),
  power      integer not null check (power >= 0),
  effect     jsonb not null default '{}'::jsonb,
  min_rarity text not null check (min_rarity in ('common','uncommon','rare','epic','legendary','mythic','secret')),
  created_at timestamptz not null default now()
);

create table if not exists app.character_attacks (
  definition_id text not null,
  attack_id     text not null references app.attacks(id) on delete cascade,
  primary key (definition_id, attack_id)
);
create index if not exists character_attacks_def_idx on app.character_attacks(definition_id);

-- #97 — per-(character, rarity) image variant lookup.
create table if not exists app.character_images (
  definition_id text not null,
  rarity        text not null check (rarity in ('common','uncommon','rare','epic','legendary','mythic','secret')),
  image_key     text not null,
  primary key (definition_id, rarity)
);

grant select on app.attacks, app.character_attacks, app.character_images to nutriquest_app;

insert into ops.schema_migrations(version, name)
values ('0013','0013_phase2_data_model.sql') on conflict do nothing;
