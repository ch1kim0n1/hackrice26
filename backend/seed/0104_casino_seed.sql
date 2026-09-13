-- 0104_casino_seed.sql — sample casino data so every hypertable/table shows rows.
-- Builds on the demo players (0100) and their owned characters.
begin;

-- Kitchen Mines: one served, one burnt.
insert into app.mines_rounds(round_id, player_id, wager, wager_value, mines, layout, revealed, status, started_at, cash_out_multiplier, final_net_worth, reward, completed_at, fairness) values
  (gen_random_uuid(),'p_alice','{"id":"scan-x","rarity":"rare"}',2650,3,'{2,9,17}','{0,1,5,6}','SERVED', now() - interval '35 minutes',2.2,5830,'{"id":"scan-x","budget":5830}', now() - interval '34 minutes','{"serverSeedHash":"h1","clientSeed":"c1","nonce":4}'),
  (gen_random_uuid(),'p_bob','{"id":"scan-y","rarity":"common"}',500,5,'{1,4,8,12,20}','{3,7}','BURNT', now() - interval '20 minutes',null,0,null, now() - interval '20 minutes','{"serverSeedHash":"h2","clientSeed":"c2","nonce":2}')
on conflict do nothing;

-- Plinko: two drops.
insert into app.plinko_drops(drop_id, player_id, wager, wager_value, path, slot, multiplier, final_net_worth, reward, created_at, fairness) values
  (gen_random_uuid(),'p_cara','{"id":"scan-z","rarity":"epic"}',6900,'{t,f,t,t,f,t,f,f,t,f,t,t}',8,2.5,17250,'{"id":"scan-z","budget":17250}', now() - interval '15 minutes','{"serverSeedHash":"h3","clientSeed":"c3","nonce":1}'),
  (gen_random_uuid(),'p_alice','{"id":"scan-w","rarity":"uncommon"}',1100,'{f,f,t,f,f,f,t,f,f,f,f,t}',3,0,0,null, now() - interval '10 minutes','{"serverSeedHash":"h4","clientSeed":"c4","nonce":1}')
on conflict do nothing;

commit;

-- gamble_events analytics stream (hypertable) mirroring the above + cauldron.
begin;
insert into telemetry.gamble_events(occurred_at, player_id, mode, outcome, wager_value, multiplier, net_worth_change, ref_id) values
  (now() - interval '34 minutes','p_alice','mines','served',   2650, 2.2, 3180, gen_random_uuid()),
  (now() - interval '20 minutes','p_bob',  'mines','burnt',     500, null, -500, gen_random_uuid()),
  (now() - interval '15 minutes','p_cara', 'plinko','dropped', 6900, 2.5, 10350, gen_random_uuid()),
  (now() - interval '10 minutes','p_alice','plinko','busted',  1100, 0,   -1100, gen_random_uuid()),
  (now() - interval '39 minutes','p_alice','crash','cashed_out',3200, 2.3, 4160, gen_random_uuid()),
  (now() - interval '25 minutes','p_bob',  'crash','crashed',  1500, null, -1500, gen_random_uuid());
commit;
