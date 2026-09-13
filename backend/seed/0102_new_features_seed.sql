-- 0102_new_features_seed.sql
-- Sample data for the features added in 0012 (casino, coins, ranks, body metrics, stars).
begin;

-- coins wallets + ledger
insert into app.wallets(player_id, currency, balance) values
  ('p_alice','coins',1250),('p_bob','coins',300),('p_cara','coins',4800)
on conflict do nothing;

-- These have to sum to the coin wallets above, for the same reason as 0100.
insert into app.currency_entries(operation_id, entry_index, player_id, account, currency, amount, reason) values
  ('c01d0000-0000-0000-0000-0000000000a1',0,'p_alice','player','coins', 1500,'daily_login'),
  ('c01d0000-0000-0000-0000-0000000000a2',0,'p_alice','player','coins', -250,'cauldron_wager'),
  ('c01d0000-0000-0000-0000-0000000000b1',0,'p_bob',  'player','coins',  300,'daily_login'),
  ('c01d0000-0000-0000-0000-0000000000c1',0,'p_cara', 'player','coins', 5000,'season_reward'),
  ('c01d0000-0000-0000-0000-0000000000c2',0,'p_cara', 'player','coins', -200,'cauldron_wager')
on conflict do nothing;

-- Rank points -- the consistency ladder (how well you EAT), which is NOT the Elo
-- rating seeded in 0100 (how well you FIGHT). This seed used to copy the Elo
-- numbers into rank_points and the Elo tier into rank_tier, which put every
-- badge out of step with its own point total: 640 points is plat under
-- game/rankTiers.ts, not bronze. Points only from here -- 0018's trigger derives
-- the tier, so there is no second place for the badge to disagree.
update app.rankings set rank_points = 420 where player_id = 'p_alice';
update app.rankings set rank_points = 720 where player_id = 'p_cara';
update app.rankings set rank_points =  80 where player_id = 'p_bob';

-- star levels on owned characters
update app.owned_characters set star_level = 3 where id = '0c000000-0000-0000-0000-0000000000c1'; -- cara void seraph
update app.owned_characters set star_level = 2 where id = '0c000000-0000-0000-0000-0000000000a1'; -- alice lumen stag
update app.owned_characters set star_level = 2 where id = '0cf00000-0000-0000-0000-0000000000bf'; -- bob fused iron oak

-- body types
update app.profile_versions set body_type = 'mesomorph' where player_id = 'p_alice';
update app.profile_versions set body_type = 'endomorph' where player_id = 'p_bob';
update app.profile_versions set body_type = 'ectomorph' where player_id = 'p_cara';

-- casino rounds: one per status
insert into app.cauldron_rounds(round_id, player_id, wager, starting_net_worth, crash_multiplier, status, started_at, cash_out_at, cash_out_multiplier, final_net_worth, reward, fairness, completed_at) values
  (gen_random_uuid(),'p_alice','{"coins":250}', 3200, 4.80,'CASHED_OUT', now() - interval '40 minutes', now() - interval '39 minutes', 2.30, 3775,'{"coins":575}','{"server_seed_hash":"h_a1","nonce":7}', now() - interval '39 minutes'),
  (gen_random_uuid(),'p_bob',  '{"coins":100}', 1500, 1.90,'CRASHED',    now() - interval '25 minutes', null, null, 1400, null,'{"server_seed_hash":"h_b1","nonce":3}', now() - interval '25 minutes'),
  (gen_random_uuid(),'p_cara', '{"coins":500}', 8800, 12.5,'ACTIVE',      now() - interval '2 minutes',  null, null, null, null,'{"server_seed_hash":"h_c1","nonce":11}', null)
on conflict do nothing;

commit;

-- body metrics weigh-ins (hypertable): a downward trend per player over ~5 weeks
begin;
insert into telemetry.body_metrics(player_id, logged_at, weight_kg, body_fat_pct, source)
select p.pid,
       now() - (g * interval '7 days'),
       (p.base - g * 0.4)::numeric(5,1),
       (p.fat  - g * 0.2)::numeric(4,1),
       case when g = 0 then 'onboarding' else 'healthkit' end
from (values ('p_alice',62.0,24.0),('p_bob',82.0,22.0),('p_cara',68.0,20.0)) as p(pid, base, fat),
     generate_series(0,5) as g;
commit;
