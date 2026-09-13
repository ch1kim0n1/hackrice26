import { describe, it, expect } from "vitest";
import { bmr, bmi, bmiBand, deriveTargets, deriveTargetsRounded } from "./targets";

describe("personal targets (Mifflin-St Jeor, BattleKit PlayerProfile)", () => {
  it("BMR matches Mifflin-St Jeor for a known male profile", () => {
    // 10*80 + 6.25*180 - 5*34 + 5 = 1760
    expect(bmr({ age: 34, sex: "male", heightCm: 180, weightKg: 80, activity: "light", goal: "maintain" })).toBe(1760);
  });

  it("BMR subtracts 161 for female", () => {
    // 10*62 + 6.25*168 - 5*28 - 161 = 1369
    expect(bmr({ age: 28, sex: "female", heightCm: 168, weightKg: 62, activity: "moderate", goal: "cut" })).toBe(1369);
  });

  it("maintain male: activity + protein/kg + fiber scaling", () => {
    const t = deriveTargets({ age: 34, sex: "male", heightCm: 180, weightKg: 80, activity: "light", goal: "maintain" });
    expect(t.calorieTarget).toBeCloseTo(1760 * 1.375, 6); // 2420
    expect(t.proteinTarget).toBeCloseTo(80 * 1.2, 6); // 96
    expect(t.fiberTarget).toBeCloseTo(25 * ((1760 * 1.375) / 2000), 6); // 30.25
  });

  it("cut applies -15% calories and 1.8 g/kg protein", () => {
    const t = deriveTargetsRounded({ age: 28, sex: "female", heightCm: 168, weightKg: 62, activity: "moderate", goal: "cut" });
    // 1369 * 1.55 * 0.85 = 1803.66 -> 1804
    expect(t.calorieTarget).toBe(1804);
    expect(t.proteinTarget).toBe(Math.round(62 * 1.8)); // 112
  });

  it("bulk applies +10% calories", () => {
    const maintain = deriveTargets({ age: 22, sex: "male", heightCm: 175, weightKg: 70, activity: "active", goal: "maintain" });
    const bulk = deriveTargets({ age: 22, sex: "male", heightCm: 175, weightKg: 70, activity: "active", goal: "bulk" });
    expect(bulk.calorieTarget).toBeCloseTo(maintain.calorieTarget * 1.1, 6);
  });
});

describe("bmi / bmiBand", () => {
  it("computes kg/m²", () => {
    expect(bmi(80, 180)).toBeCloseTo(24.69, 2);
    expect(bmi(100, 175)).toBeCloseTo(32.65, 2);
  });

  it("returns 0 for invalid height instead of NaN/Infinity", () => {
    expect(bmi(80, 0)).toBe(0);
    expect(bmi(80, -10)).toBe(0);
  });

  it("bands at WHO boundaries", () => {
    expect(bmiBand(18.4)).toBe("underweight");
    expect(bmiBand(18.5)).toBe("healthy");
    expect(bmiBand(24.9)).toBe("healthy");
    expect(bmiBand(25)).toBe("overweight");
    expect(bmiBand(29.9)).toBe("overweight");
    expect(bmiBand(30)).toBe("obese");
  });
});
