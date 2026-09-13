// Base stats from nutrition — port of docs/BATTLE-SYSTEM.md §2 and the DB
// `compute_base_stats()` / `element_from_stats()` functions.

export interface BaseStats {
  power: number;
  guard: number;
  vitality: number;
  tempo: number;
}

export type Element = "protein" | "fiber" | "vitamin" | "hydration";

const clamp = (v: number) => Math.max(10, Math.min(100, Math.round(v)));

export interface Nutrition {
  proteinG: number;
  fiberG: number;
  sugarG: number;
  microScore: number; // 0..1
}

/**
 *   Power    = 20 + protein_g * 4
 *   Guard    = 20 + fiber_g   * 5
 *   Vitality = 20 + microScore * 45
 *   Tempo    = 20 + (protein_g / max(sugar_g,1)) * 10 + (50 - sugar_g) * 0.6
 * Each clamped to 10..100.
 */
export function computeBaseStats(n: Nutrition): BaseStats {
  return {
    power: clamp(20 + n.proteinG * 4),
    guard: clamp(20 + n.fiberG * 5),
    vitality: clamp(20 + n.microScore * 45),
    tempo: clamp(20 + (n.proteinG / Math.max(n.sugarG, 1)) * 10 + (50 - n.sugarG) * 0.6)
  };
}

/** Micronutrient score: share of the six tracked micronutrients present (0..1). */
const MICRONUTRIENT_KEYS = [
  ["vitamin-c", "vitamin_c"],
  ["vitamin-a", "vitamin_a"],
  ["iron"],
  ["calcium"],
  ["potassium"],
  ["vitamin-b12", "vitamin_b12"]
];

export function computeMicroScore(nutriments: Record<string, unknown> | null | undefined): number {
  if (!nutriments) return 0;
  const keys = Object.keys(nutriments);
  let present = 0;
  for (const group of MICRONUTRIENT_KEYS) {
    const found = group.some((base) =>
      keys.some((k) => {
        if (k !== base && !k.startsWith(base + "_")) return false;
        const v = Number(nutriments[k]);
        return Number.isFinite(v) && v > 0;
      })
    );
    if (found) present += 1;
  }
  return Math.round((present / 6) * 1e4) / 1e4;
}

/** Dominant stat -> element. power=protein, guard=fiber, vitality=vitamin, tempo=hydration. */
export function elementFromStats(s: BaseStats): Element {
  const pairs: [keyof BaseStats, number][] = [
    ["power", s.power],
    ["guard", s.guard],
    ["vitality", s.vitality],
    ["tempo", s.tempo]
  ];
  const best = pairs.reduce((a, b) => (b[1] > a[1] ? b : a))[0];
  return best === "power" ? "protein" : best === "guard" ? "fiber" : best === "vitality" ? "vitamin" : "hydration";
}
