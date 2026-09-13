import { describe, expect, it } from "vitest";
import { goalProfileFor } from "./goals";
import { bmiBand } from "./targets";

describe("goalProfileFor", () => {
  it("every band has a profile", () => {
    for (const band of ["underweight", "healthy", "overweight", "obese"] as const) {
      expect(goalProfileFor(band).band).toBe(band);
      expect(goalProfileFor(band).priorityGroups.length).toBeGreaterThan(0);
    }
  });

  it("priorities shift as weight crosses bands", () => {
    // A player dropping from obese to healthy should see produce-led
    // priorities flip to a balanced plate.
    expect(goalProfileFor("obese").priorityGroups[0]).toBe("produce");
    expect(goalProfileFor("healthy").priorityGroups).not.toEqual(
      goalProfileFor("obese").priorityGroups
    );
    expect(goalProfileFor("underweight").proteinBoost).toBeGreaterThan(1);
  });

  it("chains from a computed BMI", () => {
    // 100kg at 175cm -> BMI 32.7 -> obese -> produce first.
    expect(goalProfileFor(bmiBand(100 / 1.75 ** 2)).priorityGroups[0]).toBe("produce");
  });
});
