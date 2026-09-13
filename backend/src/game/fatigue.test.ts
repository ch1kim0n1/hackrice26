import { describe, it, expect } from "vitest";
import { FATIGUE_MS, fatigueUntil, isFatigued } from "./fatigue";

describe("fatigue — squad recovery window (BATTLE-SYSTEM §5)", () => {
  const now = Date.parse("2026-01-01T00:00:00Z");

  it("fatigueUntil is exactly 2h ahead of now", () => {
    expect(Date.parse(fatigueUntil(now)) - now).toBe(FATIGUE_MS);
  });

  it("is not fatigued with no stored expiry", () => {
    expect(isFatigued(null, now)).toBe(false);
    expect(isFatigued(undefined, now)).toBe(false);
  });

  it("is fatigued while now is before the stored expiry", () => {
    const until = fatigueUntil(now);
    expect(isFatigued(until, now)).toBe(true);
    expect(isFatigued(until, now + FATIGUE_MS - 1)).toBe(true);
  });

  it("clears once now reaches or passes the stored expiry", () => {
    const until = fatigueUntil(now);
    expect(isFatigued(until, now + FATIGUE_MS)).toBe(false);
    expect(isFatigued(until, now + FATIGUE_MS + 1)).toBe(false);
  });

  it("treats a garbage timestamp as not fatigued rather than throwing", () => {
    expect(isFatigued("not-a-date", now)).toBe(false);
  });
});
