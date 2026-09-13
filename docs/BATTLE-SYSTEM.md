# NutriQuest — Battle System Design

Daily nutrition RPG: every meal logged summons a food character; a balanced real-world diet powers your squad, earns rank points, and builds a collection you can merge, sell, gamble, and fight with.

---

## 1. Core loop

```
Eat food → Scan barcode → Character joins collection (permanent unless sold/merged/gambled)
                        → Nutrition day-log updates
                        → Daily Party Multiplier recalculates
                        → Rank points accrue from daily consistency
                        → Battle (PvE expedition / ranked PvP / arena)
                        → Earn XP + capsules + coins
Manage collection → Merge dupes → sell → gamble (pot / Monster Crash)
Midnight → daily buffs reset, rank points awarded, collection persists
```

Principles:
- **Collection is permanent until the player chooses otherwise.** Daily buffs reset; characters are only removed by deliberate merge, sell, or gamble actions.
- **No real money.** Coins and capsules are earned in-game; gambling stakes are characters, never currency with cash value.
- **Balanced diet beats gaming the system.** The multiplier rewards a full day of balance, not one hero food.
- **Everything value-bearing is server-authoritative.** Battles, merges, sells, and gambles resolve on the backend; clients never compute outcomes.

---

## 2. Character sheet

Every scanned food creates one character. Additionally, **14 established MVP characters** ship fully pre-generated (name, bio, image, stats, rarity) as the Pokédex-style roster.

```
FoodCharacter
├─ identity: name, barcode/food, bio, element (Protein/Fiber/Vitamin/Hydration)
├─ netWorth: coin value — THE source of truth for rarity
├─ rarity: Common / Uncommon / Rare / Epic / Legendary   (derived from net worth)
├─ starLevel: ★0 … ★5                                    (merge duplicates → +1★)
├─ stats: advanced stat block (base: Power/Guard/Vitality/Tempo, extensible)
├─ attacks: unique per character; special attacks gated by rarity
└─ art: pre-generated image variant per rarity tier
```

### Base stats from nutrition (per serving, from Open Food Facts)

Stats are **directly determined by nutritional value**. Base set (extended schema in #101):

| Stat | Driven by | Formula (clamped 10–100) |
|---|---|---|
| **Power** | protein g | `20 + protein_g × 4` |
| **Guard** | fiber g | `20 + fiber_g × 5` |
| **Vitality** | micronutrient score (0–1) | `20 + microScore × 45` |
| **Tempo** | protein-to-sugar ratio + low sugar | `20 + (protein_g / max(sugar_g,1)) × 10 + (50 − sugar_g) × 0.6` |

Element = dominant stat's type. Element triangle: **Protein → Fiber → Hydration → Protein** (1.25× damage advantage); Vitamin is the wildcard (self +10% all stats in battle).

### Net worth → rarity (exponential bands)

Each character has a **net worth** in coins. Rarity is a pure function of net worth — direct correlation, single source of truth.

- Bands are **exponential**: Common→Uncommon is a small step; Epic→Legendary is a huge one.
- Reference shape (base `B`, factor `k`, tune in `rarityBands.ts`, issue #121):
  - Common: `[0, B)`, Uncommon: `[B, B·k)`, Rare: `[B·k, B·k²)`, Epic: `[B·k², B·k³)`, Legendary: `[B·k³, ∞)`
- Consequence: a high-tier character must be gambled **multiple times** to reach the next band.
- Net worth recomputes after every merge, gamble outcome, or value-changing event → rarity follows automatically (#120).

### Rarity stat multiplier

Common ×1.0, Uncommon ×1.08, Rare ×1.16, Epic ×1.27, Legendary ×1.4 (tune with #131 balance sim).

### Attacks and abilities

- Every character has **unique attacks/abilities** (Pokémon-style move set, min 1 basic + signature).
- **Higher rarities unlock special attacks** — `attacks.min_rarity` gates them.
- ★3 upgrades the signature move (×1.0 → ×1.25).

### Merging (stars)

**3 duplicate characters (same food, same ★) → merge → ★+1** (max ★5). Primary duplicate sink.

- Each star: stat multiplier per the power formula (below).
- ★5 unlocks **Leader aura** (+5% to squad's dominant stat).
- Supersedes legacy fusion (which consumed 5). Reconciliation tracked in #110.

### Power scale: rarity vs mastery — DECIDED (#130, simulated in #131)

```
power = baseStats × rarityMult(rarity) × starMult(star)
```

Calibrated: one star ≈ ×1.08 (`STAR_STEP`), rarity steps 1.0→1.7 across
seven tiers. Mastery narrows a rarity gap without crossing it **on stats** —
with one measured exception: the ★3+ signature-move boost (×1.25) is a second
axis outside this formula, so a ★5 Common beats a ★1 Legendary ~59% of the
time in sim (`power.test.ts` pins the matrix). Treat that crossover as the
price of letting signatures scale with mastery.

---

## 3. Daily Party Multiplier (the anti-gaming core)

One squad-wide multiplier, recomputed from the **whole day's log**, clamp **[0.80 × 1.50]**. Base 1.00.

| Component | Condition | Bonus |
|---|---|---|
| Protein window | ≥ 0.8× and ≤ 1.3× personal target | +0.12 (scaled linearly 0.8×→target) |
| Fiber | ≥ 25 g (scaled 0→25 g) | up to +0.12 |
| Diversity | ≥ 3 distinct food groups | +0.04 per group, cap +0.12 |
| Micronutrients | day-average microScore ≥ 0.5 | up to +0.12 |
| Calorie window | within ±10% of personal target | +0.20; within ±20% → +0.10 — scaled by food quality |
| Sugar penalty | added sugar > 50 g → −0.08; > 75 g → −0.15 | penalty |
| Nutrient-poor | day-average microScore < 0.2 | −0.10 |

Personal targets are **dynamic** (see §4). The multiplier applies to all squad damage and HP.

**Anti-gaming rules:**
- Same barcode counts once per day toward the multiplier.
- Max 3 items per hour count toward the day log.
- > 60% of calories from sugar → "Sludge" variant: −30% stats, still collectible.
- Scans only count while the app day is active (no backdating).

---

## 4. Dynamic goals from BMI / BMR / body type

Onboarding collects age, sex, height, weight, activity, goal — **and weight is logged continuously** (`body_metric_log`).

- **BMI** = `weight_kg / (height_m)²`; **BMR** = Mifflin-St Jeor.
- Targets recompute on **every** weight log — not just onboarding. Calorie target = BMR × activity × goal factor; protein 1.2–1.8 g/kg; fiber ~25 g/2000 kcal.
- **Daily food priorities shift with the player's BMI/BMR band.** Example: BMI trending down through a band flips priority from calorie-dense to protein/fiber-dense foods; the objectives in `daily_state` reflect the current band.
- Two players eating identically *relative to their own targets* earn equal credit — fair PvP.

---

## 5. Battle rules

### Squad
- 3 characters. Eligibility: scanned **today**, not fatigued, not locked (staked/in-pot).
- Squad bonus: +5% per distinct element (max +10%).

### Turn system
- Round-based. Turn order: Tempo, ties random-but-seeded.
- 12 rounds max; winner = more survivors, tie-break by total remaining HP %.

### Damage
```
dmg = movePower × atkStat × typeMod × crit × variance × partyMult
      ─────────────────────────────────────────────────────────
                1 + defStat / 90
```
- `movePower`: basic 1.0, signature 1.45, special attacks per `attacks` table.
- `typeMod`: 1.25 / 0.8 / 1.0. crit 6% ×1.6. miss 4%. `variance` 0.92–1.08.
- `Guard` mitigates; `HP = 55 + vitality × 1.1`.

### Modes
| Mode | Opponent | Stakes | Notes |
|---|---|---|---|
| **Expedition (PvE)** | seeded NPC squads | XP, capsule chance | always available, no fatigue |
| **Ranked PvP** | **exact-rank matchmaking** — same tier players, or bots at that tier when no match | RP + rewards | loss → squad fatigue 2h |
| **Arena** | challenged friend / matchmaking | capsule or **character stake** | winner takes pot −5% burn |

PvP is async and server-authoritative: backend simulates with `seed = HMAC(matchId, SERVER_SECRET)`; both clients replay the identical event list.

### Ranked system (#67)

- **Rank points accrue daily from eating consistency** (objectives completed, day-log quality) plus ranked battle results. Idempotent per (player, day).
- Tiers: **Bronze → Silver → Gold → Plat** (thresholds in `rankTiers.ts`). Badge on profile.
- **Matchmaking is exact-rank**: you only fight players (or generated bots) at your tier.
- **Higher rank = better pull odds** on new characters **and stronger opponents** — reward and difficulty scale together (#86).
- Loss: −RP, squad fatigued 2h; claiming any daily quest clears it early. Full mechanics, season rollover, and the rank leaderboard: [RANK-PROGRESSION.md](RANK-PROGRESSION.md).

---

## 6. Economy

Two currencies:

- **Summon Capsules** — pull currency, earned only (unchanged earn rules + pity).
- **Coins** — soft currency backing all character trade. `coin_ledger` append-only; balance = SUM(amount).

### Character value

Every character has a **net worth** (coins) from `valuation.ts`: f(stats, rarity, ★). Used identically by sell, merge preview, gamble pots, and stakes.

### Sell

`POST /characters/sell` — character → coins at net worth (or fixed fraction; decide). Locked characters (staked, in pot) cannot be sold.

### Gambling

All gambling: server-seeded (`HMAC`), provably fair — seed hash committed before, revealed after.

- **Pot gamble** (#78): throw **1–3 characters** into a pot; gamble resolves on the summed net worth. Win → payout character at resolved value; lose → whole pot gone. The risky alternative to merging.
- **Monster Crash** (#79): pot in; multiplier climbs 1.00× → 1.2× → 2× → 5× … until a server-chosen crash point. Cash out anytime — e.g., 2.4× on 5,000 risked ≈ 12,000-value monster. Crash first → pot lost.

### Arena staking

Characters (not just capsules) can be staked on arena matches; winner takes the stake. Staked characters are locked from sell/merge until settlement.

---

## 7. Season & progression

- **Daily reset** at midnight (local): multiplier, day log, squad eligibility, objectives; rank points awarded for the day.
- **Ranked season**: 7 days, tier rewards (capsules + exclusive skins), RP soft-reset 20% toward base.
- **Profile badge** displays current rank tier.
- **Season Score**: daily points from battles + objectives; feeds season track.

---

## 8. Anti-abuse

| Threat | Mitigation |
|---|---|
| One hero food spam | Multiplier needs balanced components; duplicate barcode counts once |
| Scan dumping | 3 items/hour cap toward day log |
| Sugar gaming | Sugar penalty + Sludge variant |
| Fake gym photos | Server-side Vision check + EXIF + 1/day |
| Client cheating | Server simulates battles; client sends selections only |
| Gamble rigging | HMAC-seeded outcomes, hash committed pre-round, revealed after |
| Double-spend (sell/stake/merge same char) | `locked` flag + atomic mutation service (#133); all value ops single-transaction |
| Cross-tier farming | Exact-rank matchmaking only |
| Smurfing | Device binding at sign-in; one account per device |

---

## 9. Architecture (Swift side)

```
BattleKit/
├─ BattleModels.swift      stats, characters, squads, moves, events
├─ SeededRNG.swift         SplitMix64 — deterministic battles
├─ BattleEngine.swift      actor: simulate(squadA, squadB, seed) -> BattleReplay
├─ DailyMultiplier.swift   day log + profile -> multiplier breakdown
└─ ProfileTargets.swift    BMI/BMR-driven targets (recomputed on weight log)
```

- `BattleEngine` is a Swift **actor**: pure, seedable, no I/O. TS backend ports the same formula.
- Backend owns: matchmaking, rank points, valuation, gambling, ledger, cron reset.
- Swift owns: local replay/UI, daily state, offline expedition.

---

## 10. Battle event flow (replay)

```
BattleReplay
├─ seed, squads, winner, rounds
└─ events: [.turnStart(unit), .move(unit, target, move, dmg, crit, typeMod),
            .faint(unit), .roundEnd(n), .victory(side)]
```

UI replays events with the animation kit: attack lunge, damage popup, crit flash, faint droop, victory confetti.
