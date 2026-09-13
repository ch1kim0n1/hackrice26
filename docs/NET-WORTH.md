# Net worth: rarity bands and the star economy

Canonical design for what a monster is **worth**. Issues #121 (exponential
bands), #130 (rarity vs mastery), epics #77 and #80.

Implementation: [`backend/src/game/rarityBands.ts`](../backend/src/game/rarityBands.ts).
Tests: `rarityBands.test.ts`. Every table below is generated from that module —
if you change the constants, regenerate the tables rather than editing them.

> **Scope.** This document is about economic value only. Battle stats and
> combat scaling are a separate system and are deliberately **not** decided
> here — see [Combat is deferred](#combat-is-deferred).

---

## The two rules

**1. Rarity is the primary driver, and it scales exponentially.**
The gap from Common to Uncommon is pocket change; the gap from Epic to
Legendary is a fortune. That is the whole point of #77: climbing the ladder has
to get harder in absolute terms, not just feel rarer.

**2. Stars add value; they do not multiply it.**
A star bonus is a property of the **rarity band**, not of the individual
monster. Two Commons worth 500 and 900 both gain exactly +240 at ★3, so the
difference between them survives mastery. A flat `+100 per star` across all
rarities is explicitly wrong — the bonus has to scale with the band, or stars
become meaningless at the top and overpowering at the bottom.

```
current net worth = base net worth + star bonus(rarity, star)
```

`monster.value` always holds the result. Anything that needs a monster's worth
reads that field and never recomputes it — Cauldron Crash sums `value` across
the wager and has no idea stars exist.

---

## Rarity bands

A geometric ladder from a single base. `floor(n+1) = floor(n) × factor(n)`,
with the factors escalating (2.2 → 3.2) so the gaps widen as you climb.

- `BAND_BASE = 500` — the cheapest possible Common. Re-basing the entire
  economy is this one number.
- `BAND_FACTORS = [2.2, 2.4, 2.6, 2.8, 3.0, 3.2]`

| Rarity | Band floor | Band ceiling | Band width |
|---|---:|---:|---:|
| Common | 500 | 1,099 | 600 |
| Uncommon | 1,100 | 2,649 | 1,550 |
| Rare | 2,650 | 6,899 | 4,250 |
| Epic | 6,900 | 19,499 | 12,600 |
| Legendary | 19,500 | 58,499 | 39,000 |
| Mythic | 58,500 | 186,999 | 128,500 |
| Secret | 187,000 | — | 411,000 |

The bands tile the number line exactly — no gaps, no overlaps — so any net
worth maps to exactly one rarity. A value *below* the Common floor is still
Common: the floor is where the cheapest Common sits, not a bar that value has
to clear.

**Where a fresh pull lands.** Rarity picks the band; the power roll and the
holo variant decide where inside it the monster sits, capped at 80% of the band
width. A brand-new monster, however lucky, never reaches the next band's floor
— climbing bands is what fusion and the cauldron are for.

---

## The star economy

Fusion is **3 identical monsters of the same rarity and star level → 1 of the
next star**, to a maximum of ★5.

| Star | 1★ copies |
|---|---:|
| ★1 | 1 |
| ★2 | 3 |
| ★3 | 9 |
| ★4 | 27 |
| ★5 | 81 |

Bonuses for levels 2–4 are fractions of the band's own width (15%, 40%, 75%).
**★5 is not a free parameter** — it is solved from the balancing anchor below.

| Rarity | +★2 | +★3 | +★4 | +★5 |
|---|---:|---:|---:|---:|
| Common | +90 | +240 | +450 | +833 |
| Uncommon | +233 | +620 | +1,163 | +2,188 |
| Rare | +638 | +1,700 | +3,188 | +6,140 |
| Epic | +1,890 | +5,040 | +9,450 | +18,450 |
| Legendary | +5,850 | +15,600 | +29,250 | +58,275 |
| Mythic | +19,275 | +51,400 | +96,375 | +190,150 |
| Secret | +61,650 | +164,400 | +308,250 | +472,650 |

---

## The balancing anchor

> **A ★5 monster is worth about the same as a ★2 monster of the next rarity up.**

Everything else in the star economy is a consequence of that one sentence. It
is implemented as an equation, not a table of guesses:

```
bonus5(N) = width(N) + bonus2(N+1)
```

which places ★5 of rarity N exactly on ★2 of rarity N+1:

| Rarity | ★1 | ★2 | ★3 | ★4 | ★5 |
|---|---:|---:|---:|---:|---:|
| Common | 500 | 590 | 740 | 950 | 1,333 |
| Uncommon | 1,100 | 1,333 | 1,720 | 2,263 | 3,288 |
| Rare | 2,650 | 3,288 | 4,350 | 5,838 | 8,790 |
| Epic | 6,900 | 8,790 | 11,940 | 16,350 | 25,350 |
| Legendary | 19,500 | 25,350 | 35,100 | 48,750 | 77,775 |
| Mythic | 58,500 | 77,775 | 109,900 | 154,875 | 248,650 |
| Secret | 187,000 | 248,650 | 351,400 | 495,250 | 659,650 |

Read down the ★5 column and across to ★2 of the next row: 1,333 = 1,333,
3,288 = 3,288, 8,790 = 8,790, and so on. Break that and the whole mastery
economy drifts, which is why `rarityBands.test.ts` asserts it exactly rather
than approximately.

### Overlap is intentional, domination is not

A ★5 Common (1,333) beats *some* 1★ Uncommons — the Uncommon band starts at
1,100 — and that is correct: 81 copies of anything should buy real ground. But
1,333 sits in the **lower third** of the Uncommon band, which runs to 2,649. A
maxed lower-rarity monster overlaps the bottom of the next rarity; it never
dominates it.

**Stars never change rarity.** A ★5 Common worth 1,333 is still Common, however
much Uncommon territory its value covers. Rarity is a property the monster
carries; the band lookup exists to price rewards, not to re-label monsters you
already own.

### Fusion concentrates value, it does not print it

A ★5 Common costs 81 copies (81 × 500 = 40,500 of raw material) and is worth
1,333. Fusion is a sink: it removes 80 monsters from the economy and
concentrates a fraction of their value into the survivor. If it ever paid more
than its inputs, duplicate-farming would become the only sensible way to play.

---

## Combat is deferred

Issue #130 also asks for `power = f(base_stats, rarity_mult, star_mult)` and an
answer to "does a 2★ Common beat a 1★ Uncommon *in a fight*".

That half is **not decided here**, deliberately:

- The net worth specification explicitly excludes battle stats and combat
  scaling, and asks that their formulas stay separate from the value economy.
- The implementation issues for it — #131 (power curve + simulation tests) and
  #112 (star-level stat scaling) — are **Phase 3**, not Phase 1.

Today combat still scales the way it always has: `statMultiplier` per rarity
(1.0 → 1.7 across the seven tiers) times `1 + 0.08 × fusion tier`, mirrored in
BattleKit and `routes/battle.ts`. That curve was never designed against the
star economy above and should be revisited in Phase 3 — under the current
numbers a maxed lower-rarity monster out-scales several rarity steps in
combat, which is a stronger claim than the *economic* overlap this document
sanctions.

Whoever picks up #131: the economic answer is "overlap the bottom of the next
band". Matching that in combat would mean a star step worth clearly less than
a rarity step.

---

## Changing any of this

Everything is configurable and lives in one module:

| Constant | What it moves |
|---|---|
| `BAND_BASE` | The whole economy, proportionally |
| `BAND_FACTORS` | How fast rarity gets expensive |
| `STAR_STEP_FRACTIONS` | How much ★2–★4 are worth |
| `MAX_STAR_LEVEL`, `FUSION_COPIES_PER_LEVEL` | The fusion recipe |
| `BAND_POSITION_SPAN`, `SHINY_BAND_BONUS` | Spread of a fresh pull inside its band |

Boot-time invariants fail loudly if a change breaks the ladder: bands must
tile, widths must widen with scarcity, star bonuses must increase, and a fresh
pull must never escape its own band. Regenerate the tables above after any
change.
