// Personal targets — port of BattleKit `PlayerProfile` (battle-system branch,
// DailyMultiplier.swift §4) and the DB `derive_targets()` function. Keep all
// three in sync: Swift (device), this TS (backend), and Postgres (canonical).

export type Sex = "male" | "female";
export type Activity = "sedentary" | "light" | "moderate" | "active";
export type Goal = "cut" | "maintain" | "bulk";

export interface ProfileInput {
  age: number;
  sex: Sex;
  heightCm: number;
  weightKg: number;
  activity: Activity;
  goal: Goal;
}

export interface PersonalTargets {
  calorieTarget: number;
  proteinTarget: number;
  fiberTarget: number;
}

const ACTIVITY_FACTOR: Record<Activity, number> = {
  sedentary: 1.2,
  light: 1.375,
  moderate: 1.55,
  active: 1.725
};

const GOAL_ADJUSTMENT: Record<Goal, number> = {
  cut: -0.15,
  maintain: 0,
  bulk: 0.1
};

const PROTEIN_PER_KG: Record<Goal, number> = {
  maintain: 1.2,
  cut: 1.8,
  bulk: 1.8
};

/** Mifflin-St Jeor BMR. */
export function bmr(p: ProfileInput): number {
  const base = 10 * p.weightKg + 6.25 * p.heightCm - 5 * p.age;
  return p.sex === "male" ? base + 5 : base - 161;
}

/** Body mass index, kg/m². Zero or negative height yields 0 rather than NaN. */
export function bmi(weightKg: number, heightCm: number): number {
  if (heightCm <= 0) return 0;
  const m = heightCm / 100;
  return weightKg / (m * m);
}

export type BmiBand = "underweight" | "healthy" | "overweight" | "obese";

/**
 * WHO bands. This is what the dynamic-goal layer (#90) keys food priorities
 * off: as a player's weight moves them across a band boundary, their daily
 * objectives shift with it.
 */
export function bmiBand(value: number): BmiBand {
  if (value < 18.5) return "underweight";
  if (value < 25) return "healthy";
  if (value < 30) return "overweight";
  return "obese";
}

/** Exact (unrounded) targets — matches BattleKit's Double values. */
export function deriveTargets(p: ProfileInput): PersonalTargets {
  const calories = bmr(p) * ACTIVITY_FACTOR[p.activity] * (1 + GOAL_ADJUSTMENT[p.goal]);
  return {
    calorieTarget: calories,
    proteinTarget: p.weightKg * PROTEIN_PER_KG[p.goal],
    fiberTarget: 25 * (calories / 2000)
  };
}

/** Rounded integer targets — matches the DB `profiles` int columns. */
export function deriveTargetsRounded(p: ProfileInput): PersonalTargets {
  const t = deriveTargets(p);
  return {
    calorieTarget: Math.round(t.calorieTarget),
    proteinTarget: Math.round(t.proteinTarget),
    fiberTarget: Math.round(t.fiberTarget)
  };
}
