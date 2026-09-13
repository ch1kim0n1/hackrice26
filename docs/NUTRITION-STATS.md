# Nutrition → Stat Mapping (#104)

Deterministic, pure-function mapping from a portion's nutrition to a
character's battle stats. Implementation: `backend/src/game/nutritionStats.ts`
(`mapNutrition`). The canonical four-stat formula is unchanged from
`baseStats.ts` / Postgres `compute_base_stats()` / BattleKit — this document
exists so the formula can be reviewed in one place.

## Inputs

| input | source | unit |
|---|---|---|
| `proteinG` | label / vision estimate | g |
| `fiberG` | label / vision estimate | g |
| `sugarG` | label / vision estimate | g |
| `microScore` or `micronutrients[]` | OFF tags / plate analysis | 0–1 or list of the six tracked micros |
| `calories` + `portionG` | label / vision estimate | kcal, g |

`microScore` = share of the six tracked micronutrients present
(vitamin A, C, B12, iron, calcium, potassium). Passing the list derives it.

## Formula

```
power    = 20 + proteinG * 4
guard    = 20 + fiberG   * 5
vitality = 20 + microScore * 45
tempo    = 20 + (proteinG / max(sugarG, 1)) * 10
           + (50 - sugarG) * 0.6
           + tempoShift(calorieDensity)
```

Every stat is clamped to **10–100**.

## Calorie density overlay (new)

`calorieDensity = calories / portionG` (kcal/g). Null when either input is
missing — then `tempoShift = 0` and output is exactly the canonical formula.

```
tempoShift = clamp((2.0 - density) * 6, -12, +12)
```

Rationale: energy-dense food burns fast and fades (low staying power →
lower tempo); light, bulky food sustains (higher tempo). Density 2.0 kcal/g
is neutral. The ±12 cap keeps macros dominant — density nudges, it never
decides.

### Density bands (reported for downstream use: goals, revaluation)

| band | density (kcal/g) | anchor foods |
|---|---|---|
| light | < 1.5 | leafy produce (~0.3), broth, cooked rice (~1.3) |
| balanced | 1.5–3.5 | chicken-and-rice (~1.4), bread (~2.6), burger (~2.9) |
| dense | > 3.5 | chocolate (~5.5), nuts, olive oil (~8.8) |

## Parity note

`power`/`guard`/`vitality` and the macro part of `tempo` are identical to
Postgres `compute_base_stats()` and BattleKit's `CharacterFactory` — a food
scanned by barcode vs analysed by photo produces the same base block. The
density overlay is a backend extension pending design review: if accepted,
it should be ported into `compute_base_stats()` and BattleKit together so
all three stay in sync.

## Element

Dominant stat → element: power=protein, guard=fiber, vitality=vitamin,
tempo=hydration (`elementFromStats`, unchanged).

## Worked example

Chicken + rice bowl, 350 g: protein 35 g, fiber 3 g, sugar 2 g,
microScore 0.5, 480 kcal.

```
density    = 480/350 ≈ 1.37  (light)
tempoShift = (2.0 - 1.37) * 6 ≈ +3.8

power    = 20 + 35*4              = 100 (clamped)
guard    = 20 + 3*5               = 35
vitality = 20 + 0.5*45            = 43   (42.5 -> 43)
tempo    = 20 + (35/2)*10 + 48*0.6 + 3.8 ≈ 100 (clamped)
```

Result: `{power:100, guard:35, vitality:43, tempo:100}`, element `protein`.
