// Body-metric service (#89). Pure composition over the canonical formulas
// in game/targets.ts (ported from BattleKit + Postgres derive_targets) —
// this module exists so routes never hand-roll the math and missing inputs
// degrade gracefully instead of producing NaN.

import {
  Activity,
  BmiBand,
  Goal,
  PersonalTargets,
  Sex,
  bmi,
  bmiBand,
  bmr,
  deriveTargetsRounded
} from "../game/targets";

export { bmi, bmiBand, bmr };
export type { Activity, BmiBand, Goal, PersonalTargets, Sex };

export interface BodyMetricsInput {
  weightKg?: number | null;
  heightCm?: number | null;
  age?: number | null;
  sex?: Sex | null;
  activity?: Activity | null;
  goal?: Goal | null;
}

export interface BodyVitals {
  /** kg/m², 1 decimal. Null until weight + height are both set. */
  bmi: number | null;
  bmiBand: BmiBand | null;
  /** Mifflin-St Jeor kcal/day. Null until age + sex join the metrics. */
  bmr: number | null;
  /** Full daily targets. Null until every input is present. */
  targets: PersonalTargets | null;
  /** Names of inputs still needed, for the client's "finish setup" UI. */
  missing: string[];
}

const DEFAULT_ACTIVITY: Activity = "light";
const DEFAULT_GOAL: Goal = "maintain";

/** A field counts as present when it is a finite number above zero. */
const present = (v: unknown): v is number => Number.isFinite(v) && (v as number) > 0;

/**
 * Compute whatever is computable from the inputs given.
 * BMI needs weight + height. BMR additionally needs age + sex.
 * Targets need the full profile; activity/goal fall back to neutral
 * defaults rather than blocking the result.
 */
export function bodyVitals(input: BodyMetricsInput): BodyVitals {
  const missing: string[] = [];
  if (!present(input.weightKg)) missing.push("weightKg");
  if (!present(input.heightCm)) missing.push("heightCm");
  if (!present(input.age)) missing.push("age");
  if (!input.sex) missing.push("sex");

  const hasBmi = present(input.weightKg) && present(input.heightCm);
  const hasBmr = hasBmi && present(input.age) && !!input.sex;

  const bmiValue = hasBmi ? bmi(input.weightKg!, input.heightCm!) : null;

  let targets: PersonalTargets | null = null;
  let bmrValue: number | null = null;
  if (hasBmr) {
    const profile = {
      weightKg: input.weightKg!,
      heightCm: input.heightCm!,
      age: input.age!,
      sex: input.sex!,
      activity: input.activity ?? DEFAULT_ACTIVITY,
      goal: input.goal ?? DEFAULT_GOAL
    };
    bmrValue = Math.round(bmr(profile));
    targets = deriveTargetsRounded(profile);
  }

  return {
    bmi: bmiValue === null ? null : Math.round(bmiValue * 10) / 10,
    bmiBand: bmiValue === null ? null : bmiBand(bmiValue),
    bmr: bmrValue,
    targets,
    missing
  };
}
