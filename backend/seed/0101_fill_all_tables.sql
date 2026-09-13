-- 0101_fill_all_tables.sql
-- Fills every remaining empty table (32 app + 10 ops) with realistic sample data,
-- building on 0100 (players p_alice/p_bob/p_cara, their game_days, characters,
-- battle ba77..01, season 5ea5..01, crate 'standard/v1', promo welcome100).
-- Demo-only. Idempotent via ON CONFLICT where a PK could collide.
-- Runs as owner (tsdbadmin), which bypasses RLS.

begin;

-- ---- identity: sessions, devices ----------------------------------------
insert into app.devices(id, player_id, platform, push_token_ref) values
  ('de100000-0000-0000-0000-0000000000a1','p_alice','ios','apns-alice-01'),
  ('de100000-0000-0000-0000-0000000000b1','p_bob','ios','apns-bob-01'),
  ('de100000-0000-0000-0000-0000000000c1','p_cara','watchos','apns-cara-01')
on conflict do nothing;

insert into app.sessions(token_hash, player_id, device_id, expires_at) values
  (decode(md5('alice-session-1'),'hex'),'p_alice','de100000-0000-0000-0000-0000000000a1', now() + interval '30 days'),
  (decode(md5('bob-session-1'),'hex'),  'p_bob',  'de100000-0000-0000-0000-0000000000b1', now() + interval '30 days'),
  (decode(md5('cara-session-1'),'hex'), 'p_cara', 'de100000-0000-0000-0000-0000000000c1', now() + interval '30 days')
on conflict do nothing;

-- ---- media objects + meal draft ------------------------------------------
insert into app.media_objects(id, player_id, object_key, purpose, status, hash) values
  ('ed100000-0000-0000-0000-0000000000a1','p_alice','meals/alice/plate-01.jpg','meal_photo','active','sha256-a1'),
  ('ed100000-0000-0000-0000-0000000000c1','p_cara','gym/cara/checkin-01.jpg','gym_photo','active','sha256-c1'),
  ('ed100000-0000-0000-0000-0000000000c2','p_cara','art/void-seraph.png','generated_art','active','sha256-c2')
on conflict do nothing;

insert into app.meal_drafts(id, player_id, media_ref, analysis_status, model_version, expires_at) values
  ('d4a00000-0000-0000-0000-0000000000a1','p_alice','ed100000-0000-0000-0000-0000000000a1','ready','vision-v1', now() + interval '1 day')
on conflict do nothing;

-- ---- workouts + product enrichment ---------------------------------------
insert into app.workouts(id, player_id, source_system, source_workout_id, workout_type, started_at, ended_at, duration_s, energy_kcal) values
  (gen_random_uuid(),'p_alice','healthkit','wk-alice-1','run',  now() - interval '26 hours', now() - interval '25 hours', 1800, 320)
on conflict do nothing;
insert into app.workouts(id, player_id, source_system, source_workout_id, workout_type, started_at, ended_at, duration_s, energy_kcal) values
  (gen_random_uuid(),'p_cara','healthkit','wk-cara-1','cycling', now() - interval '3 hours', now() - interval '150 minutes', 1800, 410)
on conflict do nothing;

insert into app.product_enrichment(barcode, provider, region, price_inputs, fetched_at) values
  ('0038000138416','pricegrid','US','{"avg_price_usd":3.49,"scarcity":"common"}', now() - interval '1 day')
on conflict do nothing;

-- ---- gym check + training buff -------------------------------------------
insert into app.gym_checks(id, player_id, game_day_id, object_ref, verification_status, result_version) values
  ('c6000000-0000-0000-0000-0000000000c1','p_cara','dc000000-0000-0000-0000-000000000001','ed100000-0000-0000-0000-0000000000c1','verified','gymcheck-v1')
on conflict do nothing;

insert into app.training_buffs(id, player_id, source_kind, source_ref, kind, starts_at, ends_at, rules_version) values
  (gen_random_uuid(),'p_cara','gym_check','c6000000-0000-0000-0000-0000000000c1','attack_boost', now() - interval '2 hours', now() + interval '4 hours','v1')
on conflict do nothing;

-- ---- receipts, quests, comeback, achievements ----------------------------
insert into app.claim_receipts(id, player_id, entitlement_type, entitlement_key, xp_effect, currency_effect) values
  ('c8100000-0000-0000-0000-0000000000a1','p_alice','quest','2026-09-12:log_meal',50,'{"keys":10}'),
  ('c8100000-0000-0000-0000-0000000000c1','p_cara','season_reward','5ea50001:tier_5',0,'{"capsules":2}')
on conflict do nothing;

insert into app.daily_quests(player_id, game_day_id, quest_id, definition_version, progress, target) values
  ('p_alice','da000000-0000-0000-0000-000000000001','log_meal','v1',1,1),
  ('p_alice','da000000-0000-0000-0000-000000000001','scan_food','v1',2,3),
  ('p_bob',  'db000000-0000-0000-0000-000000000001','scan_food','v1',1,3)
on conflict do nothing;

insert into app.quest_claims(player_id, game_day_id, quest_id, result_ref) values
  ('p_alice','da000000-0000-0000-0000-000000000001','log_meal','c8100000-0000-0000-0000-0000000000a1')
on conflict do nothing;

insert into app.comeback_claims(player_id, eligibility_interval_id) values
  ('p_bob','gap-2026-09-10')
on conflict do nothing;

insert into app.achievement_unlocks(player_id, achievement_id, definition_version, evidence_ref) values
  ('p_cara','streak_21',1,'streak_state'),
  ('p_alice','first_win',1,'battle:ba77')
on conflict do nothing;

-- ---- character content (lore/art) ----------------------------------------
insert into app.character_content(content_identity, content_version, lore, art_ref, generator_status, generator_version) values
  ('char_void_seraph',1,'Born of fasting discipline, the Void Seraph channels restraint into power.','ed100000-0000-0000-0000-0000000000c2','ready','art-v1')
on conflict do nothing;

-- ---- pity + promo redemption ---------------------------------------------
insert into app.pity_state(player_id, pity_scope, counters) values
  ('p_alice','standard','{"since_epic":3,"since_legendary":12}'),
  ('p_cara','standard','{"since_epic":0,"since_legendary":1}')
on conflict do nothing;

insert into app.promo_redemptions(code_id, player_id) values
  ('9401c0de-0000-0000-0000-000000000001','p_bob')
on conflict do nothing;
update app.promo_codes set uses = uses + 1 where id = '9401c0de-0000-0000-0000-000000000001';

-- ---- fusion: 5 fodder copies -> 1 result (Bob) ---------------------------
insert into app.owned_characters(id, player_id, definition_id, definition_version, fusion_tier, status) values
  ('0cf00000-0000-0000-0000-0000000000b1','p_bob','char_berry_belle',1,0,'consumed'),
  ('0cf00000-0000-0000-0000-0000000000b2','p_bob','char_berry_belle',1,0,'consumed'),
  ('0cf00000-0000-0000-0000-0000000000b3','p_bob','char_berry_belle',1,0,'consumed'),
  ('0cf00000-0000-0000-0000-0000000000b4','p_bob','char_berry_belle',1,0,'consumed'),
  ('0cf00000-0000-0000-0000-0000000000b5','p_bob','char_berry_belle',1,0,'consumed'),
  ('0cf00000-0000-0000-0000-0000000000bf','p_bob','char_iron_oak',1,1,'available')
on conflict do nothing;

insert into app.fusion_operations(id, player_id, rules_version, result_character_id, status) values
  ('f5000000-0000-0000-0000-0000000000b1','p_bob','v1','0cf00000-0000-0000-0000-0000000000bf','completed')
on conflict do nothing;

insert into app.fusion_inputs(operation_id, character_id) values
  ('f5000000-0000-0000-0000-0000000000b1','0cf00000-0000-0000-0000-0000000000b1'),
  ('f5000000-0000-0000-0000-0000000000b1','0cf00000-0000-0000-0000-0000000000b2'),
  ('f5000000-0000-0000-0000-0000000000b1','0cf00000-0000-0000-0000-0000000000b3'),
  ('f5000000-0000-0000-0000-0000000000b1','0cf00000-0000-0000-0000-0000000000b4'),
  ('f5000000-0000-0000-0000-0000000000b1','0cf00000-0000-0000-0000-0000000000b5')
on conflict do nothing;

-- ---- second battle (arena) + escrow + request ----------------------------
insert into app.battles(id, stream_started_at, mode, rules_version, seed, status, ended_at, settlement_state, last_event_sequence) values
  ('ba770000-0000-0000-0000-000000000002', now() - interval '20 minutes','arena','v1','seed_bt2','settled', now() - interval '15 minutes','settled',3)
on conflict do nothing;

insert into app.battle_participants(battle_id, slot, player_id, is_npc, profile_version_id, game_day_id, unit_snapshot, multiplier) values
  ('ba770000-0000-0000-0000-000000000002',0,'p_alice',false,'a0000000-0000-0000-0000-000000000001','da000000-0000-0000-0000-000000000001','{"lead":"char_lumen_stag"}',1.15),
  ('ba770000-0000-0000-0000-000000000002',1,'p_bob',  false,'b0000000-0000-0000-0000-000000000001','db000000-0000-0000-0000-000000000001','{"lead":"char_iron_oak"}',1.00)
on conflict do nothing;

insert into app.battle_results(battle_id, winner_slot, is_draw, compact_outcome, rounds, final_hp, replay_hash, settlement_receipt, algorithm_version) values
  ('ba770000-0000-0000-0000-000000000002',0,false,'{"winner":"p_alice"}',3,'{"0":40,"1":0}','rhash_bt2', null,'battle_v1')
on conflict do nothing;

insert into app.arena_escrows(battle_id, stakes, currency, status, settlement_operation) values
  ('ba770000-0000-0000-0000-000000000002','{"p_alice":50,"p_bob":50}','keys','settled','0be00000-0000-0000-0000-0000000000e2')
on conflict do nothing;

insert into app.battle_requests(id, requester_id, challenged_id, matchmaking_ref, status, expires_at) values
  ('b8e00000-0000-0000-0000-0000000000b1','p_bob','p_alice',null,'accepted', now() - interval '25 minutes'),
  ('b8e00000-0000-0000-0000-0000000000c1','p_cara','p_alice',null,'pending', now() + interval '1 hour')
on conflict do nothing;

-- ---- dungeon -------------------------------------------------------------
insert into app.dungeon_runs(id, player_id, seed, rules_version, squad_snapshot, carry_hp, best_floor, status) values
  ('d0d00000-0000-0000-0000-0000000000a1','p_alice','seed_dun_a1','v1','{"lead":"char_lumen_stag"}','{"hp":110}',3,'active')
on conflict do nothing;

insert into app.dungeon_floor_results(run_id, floor, battle_id, compact_outcome) values
  ('d0d00000-0000-0000-0000-0000000000a1',1,null,'{"result":"clear","hp_left":130}'),
  ('d0d00000-0000-0000-0000-0000000000a1',2,null,'{"result":"clear","hp_left":118}'),
  ('d0d00000-0000-0000-0000-0000000000a1',3,null,'{"result":"clear","hp_left":110}')
on conflict do nothing;

insert into app.dungeon_state(player_id, best_floor, accrual_boundary, fractional_remainder, current_rate) values
  ('p_alice',5, now() - interval '2 hours',0.4,12),
  ('p_bob',  2, now() - interval '5 hours',0.0,4),
  ('p_cara', 8, now() - interval '30 minutes',0.7,20)
on conflict do nothing;

-- ---- ranked matchmaking + fatigue ----------------------------------------
insert into app.matchmaking_entries(player_id, mode, rating, season_id, squad_version, expires_at) values
  ('p_bob','ranked',1005,'5ea50001-0000-0000-0000-000000000001',1, now() + interval '10 minutes')
on conflict do nothing;

insert into app.fatigue(scope, scope_kind, until, source_battle) values
  ('0c000000-0000-0000-0000-0000000000c1','character', now() + interval '2 hours','ba770000-0000-0000-0000-000000000001')
on conflict do nothing;

-- ---- season progress + reward claim --------------------------------------
insert into app.season_progress(season_id, player_id, score, daily_caps) values
  ('5ea50001-0000-0000-0000-000000000001','p_alice',120,'{"2026-09-12":30}'),
  ('5ea50001-0000-0000-0000-000000000001','p_cara', 340,'{"2026-09-12":30}')
on conflict do nothing;

insert into app.season_reward_claims(season_id, player_id, reward_id) values
  ('5ea50001-0000-0000-0000-000000000001','p_cara','tier_5')
on conflict do nothing;

-- ---- tournaments + entries + matches (LAN casual) ------------------------
insert into app.tournaments(id, name, bracket_revision, host_trust) values
  ('70000000-0000-0000-0000-000000000001','Weekend Cup',1,'unverified_local')
on conflict do nothing;

insert into app.tournament_entries(tournament_id, player_id, seed) values
  ('70000000-0000-0000-0000-000000000001','p_alice',1),
  ('70000000-0000-0000-0000-000000000001','p_bob',2),
  ('70000000-0000-0000-0000-000000000001','p_cara',3)
on conflict do nothing;

insert into app.tournament_matches(tournament_id, round, slot, battle_id, outcome) values
  ('70000000-0000-0000-0000-000000000001',1,1,'ba770000-0000-0000-0000-000000000002','{"winner":"p_alice"}'),
  ('70000000-0000-0000-0000-000000000001',1,2,null,'{"status":"pending"}')
on conflict do nothing;

insert into app.lan_sessions(id, uploader_id, protocol_version, trust, summary_hash) values
  ('1a000000-0000-0000-0000-0000000000a1','p_alice','1.0','unverified_local','lan-hash-a1')
on conflict do nothing;

-- ---- notifications -------------------------------------------------------
insert into app.notifications(player_id, type, related_object, payload, status) values
  ('p_alice','battle_result','ba770000-0000-0000-0000-000000000002','{"result":"win"}','unread'),
  ('p_cara','achievement','streak_21','{"title":"21-day streak!"}','read'),
  ('p_bob','challenge','b8e00000-0000-0000-0000-0000000000b1','{"from":"p_alice"}','unread')
on conflict do nothing;

commit;

-- ===========================================================================
-- ops schema
-- ===========================================================================
begin;

insert into ops.command_receipts(player_id, command_id, command_type, request_hash, status, result_ref) values
  ('p_alice','cc000000-0000-0000-0000-0000000000a1','lootbox_open','req-hash-a1','completed','c0e00000-0000-0000-0000-0000000000a1'),
  ('p_cara','cc000000-0000-0000-0000-0000000000c1','quest_claim','req-hash-c1','completed','c8100000-0000-0000-0000-0000000000c1')
on conflict do nothing;

insert into ops.command_responses(player_id, command_id, response_body) values
  ('p_alice','cc000000-0000-0000-0000-0000000000a1','{"drop":"char_lumen_stag","rarity":"rare"}')
on conflict do nothing;

insert into ops.ingest_keys(player_id, source_system, source_id, revision, payload_hash, measured_at) values
  ('p_alice','healthkit','hk-hr-001',1,'phash-hr-001', now() - interval '1 hour'),
  ('p_cara','healthkit','hk-steps-001',1,'phash-steps-001', now() - interval '30 minutes')
on conflict do nothing;

insert into ops.health_sync_cursors(player_id, device_id, data_type, last_cursor, policy_version) values
  ('p_alice','de100000-0000-0000-0000-0000000000a1','heart_rate','anchor-hr-123','sync-v1'),
  ('p_cara','de100000-0000-0000-0000-0000000000c1','steps','anchor-steps-88','sync-v1')
on conflict do nothing;

insert into ops.outbox(aggregate_id, aggregate_version, payload, status) values
  ('battle:ba770000-0000-0000-0000-000000000002',1,'{"event":"battle_settled"}','pending'),
  ('player:p_cara',6,'{"event":"achievement_unlocked","id":"streak_21"}','sent')
on conflict do nothing;

insert into ops.jobs(job_key, kind, input_refs, next_run_at) values
  ('refresh:health_hourly','aggregate_refresh','{"view":"analytics.health_hourly"}', now() + interval '10 minutes'),
  ('cleanup:battle_events','guarded_retention','{"stream":"battle_events"}', now() + interval '1 hour')
on conflict do nothing;

insert into ops.player_sync_heads(player_id, next_sequence) values
  ('p_alice',4),('p_bob',2),('p_cara',6)
on conflict do nothing;

insert into ops.player_changes(player_id, sequence, entity, entity_version, tombstone) values
  ('p_alice',1,'wallet',1,false),
  ('p_alice',2,'owned_character',1,false),
  ('p_alice',3,'daily_state',1,false),
  ('p_cara',1,'ranking',1,false),
  ('p_cara',2,'achievement',1,false)
on conflict do nothing;

insert into ops.lifecycle_checkpoints(stream, range_start, range_end, task, status, watermark) values
  ('battle_events', now() - interval '7 days', now() - interval '3 days','retention','pending', now() - interval '3 days')
on conflict do nothing;

insert into ops.admin_audit(actor, action, target_refs, change_summary) values
  ('system','promo_create','{"code":"welcome100"}','created promo welcome100 (1000 uses)'),
  ('system','season_open','{"season":"5ea50001"}','opened ranked season')
on conflict do nothing;

commit;
