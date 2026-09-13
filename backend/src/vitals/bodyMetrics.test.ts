import { describe, expect, it } from "vitest";
import { bodyVitals, bmi, bmiBand, bmr } from "./bodyMetrics";

describe("bmi / bmr passthrough (#89)", () => {
  it("bmi computes kg/m²", () => {
    expect(bmi(80, 180)).toBeCloseTo(24.69, 2);
  });

  it("bmr matches Mifflin-St Jeor", () => {
    // 10*80 + 6.25*180 - 5*34 + 5 = 1760
    expect(
      bmr({ age: 34, sex: "male", heightCm: 180, weightKg: 80, activity: "light", goal: "maintain" })
    ).toBe(1760);
  });

  it("bmiBand bands at WHO boundaries", () => {
    expect(bmiBand(18.4)).toBe("underweight");
    expect(bmiBand(18.5)).toBe("healthy");
    expect(bmiBand(30)).toBe("obese");
  });
});

describe("bodyVitals — graceful missing metrics", () => {
  it("returns everything for a complete profile", () => {
    const v = bodyVitals({ weightKg: 80, heightCm: 180, age: 34, sex: "male", activity: "light", goal: "maintain" });
    expect(v.bmi).toBeCloseTo(24.7, 1);
    expect(v.bmiBand).toBe("healthy");
    expect(v.bmr).toBe(1760);
    expect(v.targets).not.toBeNull();
    expect(v.missing).toEqual([]);
  });

  it("bmi only when weight+height present, bmr null without age/sex", () => {
    const v = bodyVitals({ weightKg: 70, heightCm: 175 });
    expect(v.bmi).toBeCloseTo(22.9, 1);
    expect(v.bmiBand).toBe("healthy");
    expect(v.bmr).toBeNull();
    expect(v.targets).toBeNull();
    expect(v.missing.sort()).toEqual(["age", "sex"]);
  });

  it("nothing but missing list for an empty profile", () => {
    const v = bodyVitals({});
    expect(v.bmi).toBeNull();
    expect(v.bmiBand).toBeNull();
    expect(v.bmr).toBeNull();
    expect(v.targets).toBeNull();
    expect(v.missing.sort()).toEqual(["age", "heightCm", "sex", "weightKg"]);
  });

  it("zero/garbage values count as missing, never NaN", () => {
    const v = bodyVitals({ weightKg: 0, heightCm: -5, age: NaN, sex: "male" });
    expect(v.bmi).toBeNull();
    expect(v.missing).toContain("weightKg");
    expect(v.missing).toContain("heightCm");
    expect(v.missing).toContain("age");
  });

  it("defaults activity/goal to neutral instead of blocking targets", () => {
    const v = bodyVitals({ weightKg: 62, heightCm: 168, age: 28, sex: "female" });
    // bmr 1369 * light(1.375) = 1882.375
    expect(v.targets!.calorieTarget).toBe(Math.round(1369 * 1.375));
  });
});
