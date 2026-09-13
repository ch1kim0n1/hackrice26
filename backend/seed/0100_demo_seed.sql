-- 0100_demo_seed.sql
-- Demo seed exercising the end-to-end TigerData loop for visualization.
-- Three players; recent timestamps so continuous aggregates show data.
-- Idempotent-ish: run against a fresh DB. Uses fixed UUIDs for cross-references.

begin;

-- ---------------------------------------------------------------------------
-- Rule set + season + crate + product catalogue (shared config)
-- ---------------------------------------------------------------------------
insert into app.rule_sets(version, config, checksum, activated_at) values
  ('v1', '{"tiers":7,"loot":"seven_tier","combat":"v1"}', 'chk_v1', now())
on conflict do nothing;

insert into app.seasons(id, mode, rules, starts_at, ends_at, state) values
  ('5ea50001-0000-0000-0000-000000000001', 'ranked', '{"tiers":["bronze","silver","gold"]}',
   now() - interval '10 days', now() + interval '20 days', 'active')
on conflict do nothing;

insert into app.crate_definitions(crate_id, rules_version, cost, cost_currency, pool, rarity_weights, pity_policy) values
  ('standard', 'v1', 100, 'keys',
   '["char_berry_belle","char_iron_oak","char_lumen_stag","char_ember_fox","char_glacier_whale","char_void_seraph"]',
   '{"common":50,"uncommon":25,"rare":13,"epic":7,"legendary":3,"mythic":1.5,"celestial":0.5}',
   '{"hard_pity":90}')
on conflict do nothing;

insert into app.character_definitions(definition_id, version, name, rarity, element, base_stats) values
  ('char_berry_belle',  1, 'Berry Belle',  'common',    'nature', '{"hp":80,"atk":18,"def":12}'),
  ('char_iron_oak',     1, 'Iron Oak',     'uncommon',  'earth',  '{"hp":120,"atk":22,"def":28}'),
  ('char_lumen_stag',   1, 'Lumen Stag',   'rare',      'light',  '{"hp":140,"atk":30,"def":24}'),
  ('char_ember_fox',    1, 'Ember Fox',    'epic',      'fire',   '{"hp":150,"atk":42,"def":26}'),
  ('char_glacier_whale',1, 'Glacier Whale','legendary', 'water',  '{"hp":220,"atk":38,"def":48}'),
  ('char_void_seraph',  1, 'Void Seraph',  'mythic',    'void',   '{"hp":200,"atk":60,"def":40}')
on conflict do nothing;

insert into app.products(barcode, name, brand, food_group, nutrition) values
  ('0049000028911', 'Greek Yogurt',  'DairyCo',  'dairy',   '{"calories":120,"protein_g":15,"carbs_g":8,"fat_g":3,"sodium_mg":50}'),
  ('0038000138416', 'Oat Cereal',    'GrainCo',  'grain',   '{"calories":220,"protein_g":6,"carbs_g":44,"fat_g":4,"sodium_mg":180}'),
  ('0071990300000', 'Almond Pack',   'NuttyCo',  'nuts',    '{"calories":170,"protein_g":6,"carbs_g":6,"fat_g":15,"sodium_mg":0}')
on conflict do nothing;

insert into app.promo_codes(id, code_norm, code_display, reward, max_uses, expires_at) values
  ('9401c0de-0000-0000-0000-000000000001', 'welcome100', 'WELCOME100', '{"keys":100}', 1000, now() + interval '30 days')
on conflict do nothing;

-- ---------------------------------------------------------------------------
-- Players + identity + progression
-- ---------------------------------------------------------------------------
insert into app.players(id, display_name, account_status) values
  ('p_alice', 'Alice',  'active'),
  ('p_bob',   'Bob',    'active'),
  ('p_cara',  'Cara',   'active')
on conflict do nothing;

insert into app.credentials(player_id, username_norm, username_display, password_hash) values
  ('p_alice','alice','Alice','argon2id$demo$aaa'),
  ('p_bob','bob','Bob','argon2id$demo$bbb'),
  ('p_cara','cara','Cara','argon2id$demo$ccc')
on conflict do nothing;

insert into app.player_progress(player_id, xp, level, lifetime_scans, lifetime_opens, lifetime_wins) values
  ('p_alice', 5400, 12, 40, 18, 9),
  ('p_bob',   3100, 8,  22, 11, 4),
  ('p_cara',  8700, 17, 63, 30, 15)
on conflict do nothing;

insert into app.wallets(player_id, currency, balance) values
  ('p_alice','keys',450), ('p_alice','capsules',3),
  ('p_bob','keys',120),   ('p_bob','capsules',0),
  ('p_cara','keys',980),  ('p_cara','capsules',7)
on conflict do nothing;

insert into app.streak_state(player_id, last_qualifying_day, streak, best_streak, freeze_inventory) values
  ('p_alice', 1, 6, 14, 2),
  ('p_bob',   1, 2, 5,  1),
  ('p_cara',  1, 21, 21, 3)
on conflict do nothing;

insert into app.profile_versions(id, player_id, revision, measurements, activity_goal, calculated_targets, formula_version) values
  ('a0000000-0000-0000-0000-000000000001','p_alice',1,'{"height_cm":168,"weight_kg":62}','{"steps":9000}','{"calories":2000,"protein_g":90}','mifflin_v1'),
  ('b0000000-0000-0000-0000-000000000001','p_bob',  1,'{"height_cm":180,"weight_kg":82}','{"steps":8000}','{"calories":2400,"protein_g":110}','mifflin_v1'),
  ('c0000000-0000-0000-0000-000000000001','p_cara', 1,'{"height_cm":172,"weight_kg":68}','{"steps":11000}','{"calories":2200,"protein_g":100}','mifflin_v1')
on conflict do nothing;

-- game days (today, in UTC for the demo)
insert into app.game_days(id, player_id, sequence, display_date, timezone, starts_at, ends_at, profile_version_id, rules_version) values
  ('da000000-0000-0000-0000-000000000001','p_alice',1,current_date,'UTC',date_trunc('day',now()),date_trunc('day',now())+interval '1 day','a0000000-0000-0000-0000-000000000001','v1'),
  ('db000000-0000-0000-0000-000000000001','p_bob',  1,current_date,'UTC',date_trunc('day',now()),date_trunc('day',now())+interval '1 day','b0000000-0000-0000-0000-000000000001','v1'),
  ('dc000000-0000-0000-0000-000000000001','p_cara', 1,current_date,'UTC',date_trunc('day',now()),date_trunc('day',now())+interval '1 day','c0000000-0000-0000-0000-000000000001','v1')
on conflict do nothing;

insert into app.player_settings(player_id, game_timezone) values
  ('p_alice','UTC'), ('p_bob','UTC'), ('p_cara','UTC')
on conflict do nothing;

-- ---------------------------------------------------------------------------
-- Collection: acquisitions -> owned characters -> squads
-- ---------------------------------------------------------------------------
insert into app.character_acquisitions(id, player_id, source_kind, source_ref, character_snapshot, acquired_at) values
  ('ac000000-0000-0000-0000-0000000000a1','p_alice','lootbox','standard','{"def":"char_lumen_stag","v":1}', now() - interval '3 days'),
  ('ac000000-0000-0000-0000-0000000000a2','p_alice','scan','0049000028911','{"def":"char_berry_belle","v":1}', now() - interval '2 days'),
  ('ac000000-0000-0000-0000-0000000000b1','p_bob','lootbox','standard','{"def":"char_iron_oak","v":1}', now() - interval '5 days'),
  ('ac000000-0000-0000-0000-0000000000c1','p_cara','lootbox','standard','{"def":"char_void_seraph","v":1}', now() - interval '1 day'),
  ('ac000000-0000-0000-0000-0000000000c2','p_cara','lootbox','standard','{"def":"char_glacier_whale","v":1}', now() - interval '4 days')
on conflict do nothing;

insert into app.owned_characters(id, player_id, definition_id, definition_version, fusion_tier, status, acquisition_id) values
  ('0c000000-0000-0000-0000-0000000000a1','p_alice','char_lumen_stag',1,0,'in_squad','ac000000-0000-0000-0000-0000000000a1'),
  ('0c000000-0000-0000-0000-0000000000a2','p_alice','char_berry_belle',1,0,'available','ac000000-0000-0000-0000-0000000000a2'),
  ('0c000000-0000-0000-0000-0000000000b1','p_bob','char_iron_oak',1,0,'in_squad','ac000000-0000-0000-0000-0000000000b1'),
  ('0c000000-0000-0000-0000-0000000000c1','p_cara','char_void_seraph',1,0,'in_squad','ac000000-0000-0000-0000-0000000000c1'),
  ('0c000000-0000-0000-0000-0000000000c2','p_cara','char_glacier_whale',1,0,'available','ac000000-0000-0000-0000-0000000000c2')
on conflict do nothing;

insert into app.squads(id, player_id, name, mode) values
  ('50000000-0000-0000-0000-0000000000a1','p_alice','Alpha','default'),
  ('50000000-0000-0000-0000-0000000000c1','p_cara','Nova','default')
on conflict do nothing;

insert into app.squad_members(squad_id, slot, character_id) values
  ('50000000-0000-0000-0000-0000000000a1',1,'0c000000-0000-0000-0000-0000000000a1'),
  ('50000000-0000-0000-0000-0000000000c1',1,'0c000000-0000-0000-0000-0000000000c1')
on conflict do nothing;

-- ---------------------------------------------------------------------------
-- Fairness seeds + a couple of crate opens (economy receipts)
-- ---------------------------------------------------------------------------
insert into app.fairness_seeds(id, player_id, commitment, client_seed, next_nonce, state) values
  ('f0000000-0000-0000-0000-0000000000a1','p_alice','commit_alice_1','client_a',2,'active'),
  ('f0000000-0000-0000-0000-0000000000c1','p_cara','commit_cara_1','client_c',1,'active')
on conflict do nothing;

insert into app.crate_opens(id, player_id, seed_id, nonce, crate_id, rules_version, cost, acquired_character_id, commitment, opened_at) values
  ('c0e00000-0000-0000-0000-0000000000a1','p_alice','f0000000-0000-0000-0000-0000000000a1',0,'standard','v1',100,'0c000000-0000-0000-0000-0000000000a1','commit_alice_1', now() - interval '3 days'),
  ('c0e00000-0000-0000-0000-0000000000c1','p_cara','f0000000-0000-0000-0000-0000000000c1',0,'standard','v1',100,'0c000000-0000-0000-0000-0000000000c1','commit_cara_1', now() - interval '1 day')
on conflict do nothing;

-- Currency ledger. A balance is SUM(amount) over these rows, so the ledger has
-- to add up to the wallets above -- otherwise the demo data contradicts the rule
-- 0018 enforces, and the invariants suite has nothing to stand on. Every wallet
-- gets an opening grant, then the crate opens debit it.
insert into app.currency_entries(operation_id, entry_index, player_id, account, currency, amount, reason) values
  ('0be00000-0000-0000-0000-00000000a100',0,'p_alice','player','keys',      550,'grant'),
  ('0be00000-0000-0000-0000-00000000b100',0,'p_bob',  'player','keys',      120,'grant'),
  ('0be00000-0000-0000-0000-00000000c100',0,'p_cara', 'player','keys',     1080,'grant'),
  ('0be00000-0000-0000-0000-00000000a101',0,'p_alice','player','capsules',    3,'grant'),
  ('0be00000-0000-0000-0000-00000000c101',0,'p_cara', 'player','capsules',    7,'grant'),
  ('0be00000-0000-0000-0000-0000000000a1',0,'p_alice','player','keys',     -100,'crate_open'),
  ('0be00000-0000-0000-0000-0000000000c1',0,'p_cara', 'player','keys',     -100,'crate_open')
on conflict do nothing;

-- ---------------------------------------------------------------------------
-- Nutrition: meals + revisions + items ; a correction on Alice's meal
-- ---------------------------------------------------------------------------
insert into app.meals(id, player_id, current_revision, consumed_at, game_day_id, source_kind, status) values
  ('ea100000-0000-0000-0000-0000000000a1','p_alice',2, now() - interval '5 hours','da000000-0000-0000-0000-000000000001','scan','confirmed'),
  ('ea100000-0000-0000-0000-0000000000b1','p_bob',  1, now() - interval '4 hours','db000000-0000-0000-0000-000000000001','scan','confirmed'),
  ('ea100000-0000-0000-0000-0000000000c1','p_cara', 1, now() - interval '3 hours','dc000000-0000-0000-0000-000000000001','manual','confirmed')
on conflict do nothing;

insert into app.meal_revisions(meal_id, revision, correction_reason, totals) values
  ('ea100000-0000-0000-0000-0000000000a1',1,null,'{"calories":600,"protein_g":30}'),
  ('ea100000-0000-0000-0000-0000000000a1',2,'portion corrected 600->450','{"calories":450,"protein_g":24}'),
  ('ea100000-0000-0000-0000-0000000000b1',1,null,'{"calories":220,"protein_g":6}'),
  ('ea100000-0000-0000-0000-0000000000c1',1,null,'{"calories":290,"protein_g":21}')
on conflict do nothing;

insert into app.meal_items(meal_id, revision, item_id, barcode, label, portion_g, food_group, calories, protein_g, carbs_g, fat_g, sodium_mg) values
  ('ea100000-0000-0000-0000-0000000000a1',1,'17e00000-0000-0000-0000-0000000000a1','0038000138416','Oat Cereal (large)',273,'grain',600,30,120,10,220),
  ('ea100000-0000-0000-0000-0000000000a1',2,'17e00000-0000-0000-0000-0000000000a1','0038000138416','Oat Cereal (medium)',205,'grain',450,24,90,8,165),
  ('ea100000-0000-0000-0000-0000000000b1',1,'17e00000-0000-0000-0000-0000000000b1','0038000138416','Oat Cereal',100,'grain',220,6,44,4,180),
  ('ea100000-0000-0000-0000-0000000000c1',1,'17e00000-0000-0000-0000-0000000000c1','0049000028911','Greek Yogurt + Almonds',242,'dairy',290,21,14,18,50)
on conflict do nothing;

insert into app.scan_claims(player_id, game_day_id, barcode, entitlement, rules_version) values
  ('p_alice','da000000-0000-0000-0000-000000000001','0038000138416','daily_barcode','v1'),
  ('p_bob','db000000-0000-0000-0000-000000000001','0038000138416','daily_barcode','v1')
on conflict do nothing;

-- ---------------------------------------------------------------------------
-- Daily activity + daily state/history (authoritative projections)
-- ---------------------------------------------------------------------------
insert into app.daily_activity(player_id, game_day_id, steps, active_energy_kcal, exercise_minutes, stand_hours, latest_measured_at) values
  ('p_alice','da000000-0000-0000-0000-000000000001',7420,410,38,9, now() - interval '20 minutes'),
  ('p_bob','db000000-0000-0000-0000-000000000001',5210,300,22,7, now() - interval '35 minutes'),
  ('p_cara','dc000000-0000-0000-0000-000000000001',10230,560,51,11, now() - interval '10 minutes')
on conflict do nothing;

insert into app.daily_state(player_id, game_day_id, multiplier, objective_state) values
  ('p_alice','da000000-0000-0000-0000-000000000001',1.15,'{"protein_goal":"on_track"}'),
  ('p_bob','db000000-0000-0000-0000-000000000001',1.00,'{"protein_goal":"behind"}'),
  ('p_cara','dc000000-0000-0000-0000-000000000001',1.30,'{"protein_goal":"ahead"}')
on conflict do nothing;

insert into app.daily_history(player_id, game_day_id, scan_count, open_count, battle_count, nutrition_totals, activity_totals) values
  ('p_alice','da000000-0000-0000-0000-000000000001',2,1,1,'{"calories":740}','{"steps":7420}')
on conflict do nothing;

-- ---------------------------------------------------------------------------
-- Battle: Alice (win) vs Cara (loss), completed ~25 min ago
-- ---------------------------------------------------------------------------
insert into app.battles(id, stream_started_at, mode, rules_version, seed, status, ended_at, settlement_state, last_event_sequence) values
  ('ba770000-0000-0000-0000-000000000001', now() - interval '30 minutes', 'friendly', 'v1', 'seed_bt1', 'settled', now() - interval '25 minutes', 'settled', 5)
on conflict do nothing;

insert into app.battle_participants(battle_id, slot, player_id, is_npc, profile_version_id, game_day_id, unit_snapshot, multiplier) values
  ('ba770000-0000-0000-0000-000000000001',0,'p_alice',false,'a0000000-0000-0000-0000-000000000001','da000000-0000-0000-0000-000000000001','{"lead":"char_lumen_stag","hp":140}',1.15),
  ('ba770000-0000-0000-0000-000000000001',1,'p_cara', false,'c0000000-0000-0000-0000-000000000001','dc000000-0000-0000-0000-000000000001','{"lead":"char_void_seraph","hp":200}',1.30)
on conflict do nothing;

insert into app.battle_results(battle_id, winner_slot, is_draw, compact_outcome, rounds, final_hp, replay_hash, algorithm_version) values
  ('ba770000-0000-0000-0000-000000000001',0,false,'{"winner":"p_alice"}',4,'{"0":22,"1":0}','rhash_bt1','battle_v1')
on conflict do nothing;

commit;

-- ---------------------------------------------------------------------------
-- TIME-SERIES (hypertables). Recent timestamps so aggregates populate.
-- ---------------------------------------------------------------------------
begin;

-- health_samples: heart_rate every ~20 min over last 3h + hrv + resting_hr, per player
insert into telemetry.health_samples(player_id, source_system, source_sample_id, metric, measured_at, value, unit, quality)
select p.pid, 'watch', p.pid||'-hr-'||g, 'heart_rate',
       now() - (g * interval '20 minutes'),
       (p.base + (random()*18)::int)::double precision, 'bpm', 'good'
from (values ('p_alice',66),('p_bob',72),('p_cara',60)) as p(pid, base),
     generate_series(0,8) as g;

insert into telemetry.health_samples(player_id, source_system, source_sample_id, metric, measured_at, value, unit, quality)
select p.pid, 'watch', p.pid||'-hrv-'||g, 'hrv',
       now() - (g * interval '40 minutes'),
       (p.base + (random()*25)::int)::double precision, 'ms', 'good'
from (values ('p_alice',48),('p_bob',40),('p_cara',55)) as p(pid, base),
     generate_series(0,4) as g;

insert into telemetry.health_samples(player_id, source_system, source_sample_id, metric, measured_at, value, unit, quality)
select p.pid, 'watch', p.pid||'-rhr-'||g, 'resting_heart_rate',
       now() - (g * interval '60 minutes'),
       (p.base + (random()*6)::int)::double precision, 'bpm', 'good'
from (values ('p_alice',54),('p_bob',60),('p_cara',49)) as p(pid, base),
     generate_series(0,3) as g;

-- activity_observations: cumulative steps rising across the day (never summed)
insert into telemetry.activity_observations(player_id, source_system, source_observation_id, source_revision, game_day_id, metric, cumulative_value, measured_at)
select p.pid, 'healthkit', p.pid||'-steps-'||g, 1, p.gd, 'steps',
       (p.total * (g+1) / 6.0)::double precision,
       now() - ((6-g) * interval '2 hours')
from (values
  ('p_alice','da000000-0000-0000-0000-000000000001'::uuid,7420),
  ('p_bob','db000000-0000-0000-0000-000000000001'::uuid,5210),
  ('p_cara','dc000000-0000-0000-0000-000000000001'::uuid,10230)
) as p(pid, gd, total),
   generate_series(0,5) as g;

-- nutrition_deltas: intake legs + Alice's correction (reversal + replacement -> no double count)
insert into telemetry.nutrition_deltas(meal_id, meal_revision, item_id, leg, consumed_at, player_id, food_group, calories, protein_g, carbs_g, fat_g, sodium_mg, known_value_counts) values
  -- Alice rev1 intake +600
  ('ea100000-0000-0000-0000-0000000000a1',1,'17e00000-0000-0000-0000-0000000000a1','intake',      now() - interval '5 hours','p_alice','grain', 600, 30,120,10,220,'{"calories":1}'),
  -- Alice rev2 reversal -600 and replacement +450 (net 450)
  ('ea100000-0000-0000-0000-0000000000a1',2,'17e00000-0000-0000-0000-0000000000a1','reversal',    now() - interval '5 hours','p_alice','grain',-600,-30,-120,-10,-220,'{"calories":1}'),
  ('ea100000-0000-0000-0000-0000000000a1',2,'17e00000-0000-0000-0000-0000000000a1','replacement', now() - interval '2 hours','p_alice','grain', 450, 24, 90,  8,165,'{"calories":1}'),
  -- Bob + Cara single intake legs
  ('ea100000-0000-0000-0000-0000000000b1',1,'17e00000-0000-0000-0000-0000000000b1','intake',      now() - interval '4 hours','p_bob',  'grain', 220,  6, 44,  4,180,'{"calories":1}'),
  ('ea100000-0000-0000-0000-0000000000c1',1,'17e00000-0000-0000-0000-0000000000c1','intake',      now() - interval '3 hours','p_cara', 'dairy', 290, 21, 14, 18, 50,'{"calories":1}');

-- gameplay_events: scans / opens / quest claims in the last few hours
insert into telemetry.gameplay_events(event_id, occurred_at, player_id, event_type, payload) values
  (gen_random_uuid(), now() - interval '5 hours','p_alice','scan','{"barcode":"0038000138416"}'),
  (gen_random_uuid(), now() - interval '3 days','p_alice','open','{"crate":"standard"}'),
  (gen_random_uuid(), now() - interval '2 hours','p_alice','quest_claim','{"quest":"log_meal"}'),
  (gen_random_uuid(), now() - interval '4 hours','p_bob','scan','{"barcode":"0038000138416"}'),
  (gen_random_uuid(), now() - interval '90 minutes','p_cara','scan','{"barcode":"0049000028911"}'),
  (gen_random_uuid(), now() - interval '1 day','p_cara','open','{"crate":"standard"}'),
  (gen_random_uuid(), now() - interval '20 minutes','p_cara','achievement','{"id":"streak_21"}');

-- battle_events: ordered replay for the settled battle (anchor = battle stream_started_at)
insert into telemetry.battle_events(battle_id, stream_started_at, sequence, occurred_at, event_type, payload, payload_version)
select 'ba770000-0000-0000-0000-000000000001'::uuid, now() - interval '30 minutes', e.seq,
       now() - interval '30 minutes' + (e.seq * interval '45 seconds'),
       e.etype, e.payload::jsonb, 'v1'
from (values
  (1,'start','{"first":"p_alice"}'),
  (2,'turn','{"actor":"p_alice","move":"gore"}'),
  (3,'damage','{"target":"p_cara","amount":88}'),
  (4,'turn','{"actor":"p_cara","move":"nova"}'),
  (5,'end','{"winner":"p_alice"}')
) as e(seq, etype, payload);

-- battle_metrics: one participant fact per player for the completed battle
insert into telemetry.battle_metrics(battle_id, player_id, ended_at, mode, season_id, result, rounds, duration_s, damage, contribution_snapshot) values
  ('ba770000-0000-0000-0000-000000000001','p_alice', now() - interval '25 minutes','friendly','5ea50001-0000-0000-0000-000000000001','win', 4,225,142,'{"protein_bonus":1.15}'),
  ('ba770000-0000-0000-0000-000000000001','p_cara',  now() - interval '25 minutes','friendly','5ea50001-0000-0000-0000-000000000001','loss',4,225,96, '{"protein_bonus":1.30}');

commit;

-- rankings for the active season
insert into app.rankings(season_id, player_id, rating, tier, wins, losses) values
  ('5ea50001-0000-0000-0000-000000000001','p_alice',1180,'silver',9,4),
  ('5ea50001-0000-0000-0000-000000000001','p_cara', 1420,'gold',15,6),
  ('5ea50001-0000-0000-0000-000000000001','p_bob',  1005,'bronze',4,7)
on conflict do nothing;
