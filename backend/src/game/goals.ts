// Dynamic daily goals (issue #90). The player's BMI band — recomputed from
// every weight log (#88/#89) — decides which foods the day log asks for.
// Losing weight crosses band boundaries and the priorities shift with it:
// that is the whole feature, so the mapping lives in one place.

import { BmiBand } from "./targets";

export interface GoalProfile {
  band: BmiBand;
  /** Food groups the day log should push, most important first. */
  priorityGroups: string[];
  /** Food groups to de-emphasise. */
  deemphasized: string[];
  /** Adjustment to the protein target, as a multiplier. */
  proteinBoost: number;
  /** One-line explanation shown with today's objectives. */
  note: string;
}

export const GOAL_PROFILES: Record<BmiBand, GoalProfile> = {
  underweight: {
    band: "underweight",
    priorityGroups: ["protein", "dairy", "grain"],
    deemphasized: [],
    proteinBoost: 1.1,
    note: "Building up: protein and calorie-dense staples first."
  },
  healthy: {
    band: "healthy",
    priorityGroups: ["protein", "produce", "grain"],
    deemphasized: [],
    proteinBoost: 1.0,
    note: "Hold the line: balanced plate, all groups."
  },
  overweight: {
    band: "overweight",
    priorityGroups: ["protein", "produce"],
    deemphasized: ["grain"],
    proteinBoost: 1.2,
    note: "Cut leaning: protein and produce up, starches down."
  },
  obese: {
    band: "obese",
    priorityGroups: ["produce", "protein"],
    deemphasized: ["grain", "dairy"],
    proteinBoost: 1.2,
    note: "Volume eating: fibre and water-weight foods lead."
  }
};

export function goalProfileFor(band: BmiBand): GoalProfile {
  return GOAL_PROFILES[band];
}
