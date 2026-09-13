-- 0103_phase2_catalog.sql — idempotent Phase 2 catalogue seed (#94, #97).
-- Authored prose remains in src/data/characters.json; this seed stores the
-- canonical battle/economy fields plus provenance and all 14 x 7 image keys.
begin;

insert into app.character_definitions
  (definition_id, version, name, rarity, element, base_stats, provenance)
values
  ('broccoli-bud',1,'Broccoli Bud','common','fiber','{"power":28,"guard":46,"vitality":34,"tempo":30}','{"source":"mvp_roster","imageKey":"broccoli-bud"}'),
  ('carrot-cadet',1,'Carrot Cadet','common','vitamin','{"power":30,"guard":28,"vitality":45,"tempo":33}','{"source":"mvp_roster","imageKey":"carrot-cadet"}'),
  ('water-droplet',1,'Water Droplet','common','hydration','{"power":22,"guard":30,"vitality":32,"tempo":48}','{"source":"mvp_roster","imageKey":"water-droplet"}'),
  ('bean-sprout',1,'Bean Sprout','common','protein','{"power":44,"guard":26,"vitality":30,"tempo":34}','{"source":"mvp_roster","imageKey":"bean-sprout"}'),
  ('spinach-scout',1,'Spinach Scout','uncommon','vitamin','{"power":38,"guard":36,"vitality":58,"tempo":40}','{"source":"mvp_roster","imageKey":"spinach-scout"}'),
  ('almond-knight',1,'Almond Knight','uncommon','protein','{"power":56,"guard":48,"vitality":34,"tempo":30}','{"source":"mvp_roster","imageKey":"almond-knight"}'),
  ('salmon-striker',1,'Salmon Striker','rare','protein','{"power":68,"guard":40,"vitality":46,"tempo":52}','{"source":"mvp_roster","imageKey":"salmon-striker"}'),
  ('avocado-aegis',1,'Avocado Aegis','rare','fiber','{"power":42,"guard":70,"vitality":50,"tempo":36}','{"source":"mvp_roster","imageKey":"avocado-aegis"}'),
  ('kale-colossus',1,'Kale Colossus','epic','vitamin','{"power":58,"guard":62,"vitality":78,"tempo":38}','{"source":"mvp_roster","imageKey":"kale-colossus"}'),
  ('chia-chieftain',1,'Chia Chieftain','epic','fiber','{"power":50,"guard":80,"vitality":60,"tempo":44}','{"source":"mvp_roster","imageKey":"chia-chieftain"}'),
  ('pomegranate-paladin',1,'Pomegranate Paladin','legendary','vitamin','{"power":66,"guard":72,"vitality":88,"tempo":48}','{"source":"mvp_roster","imageKey":"pomegranate-paladin"}'),
  ('turmeric-titan',1,'Turmeric Titan','legendary','vitamin','{"power":74,"guard":58,"vitality":90,"tempo":52}','{"source":"mvp_roster","imageKey":"turmeric-titan"}'),
  ('spirulina-wyrm',1,'Spirulina Wyrm','mythic','protein','{"power":92,"guard":70,"vitality":84,"tempo":66}','{"source":"mvp_roster","imageKey":"spirulina-wyrm"}'),
  ('the-first-seed',1,'The First Seed','secret','fiber','{"power":88,"guard":96,"vitality":90,"tempo":82}','{"source":"mvp_roster","imageKey":"the-first-seed"}')
on conflict (definition_id, version) do nothing;

insert into app.character_images(definition_id, definition_version, rarity, image_key)
select cd.definition_id, cd.version, rb.rarity,
       cd.definition_id || '-' || rb.rarity
  from app.character_definitions cd
 cross join app.rarity_bands rb
 where cd.version = 1
   and cd.provenance ->> 'source' = 'mvp_roster'
on conflict (definition_id, definition_version, rarity) do nothing;

commit;
