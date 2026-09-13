import { describe, it, expect, beforeEach } from "vitest";
import { questsForDay, questStatuses, claimQuest, todayKey } from "./quests";
import { db } from "../db";
import { stateFor, resetPlayer } from "../services/lootboxState";

// Daily quests: deterministic picks per UTC date, server-verified progress,
// one-claim-per-day rewards paid in crate keys.

const PID = "quest-test-player";

beforeEach(() => {
  db.prepare(`DELETE FROM quest_claim WHERE player_id = ?`).run(PID);
  db.prepare(`DELETE FROM scan_seen WHERE player_id = ?`).run(PID);
  db.prepare(`DELETE FROM lootbox_drop WHERE player_id = ?`).run(PID);
  resetPlayer(PID);
});

describe("quests — deterministic daily pick", () => {
  it("returns exactly 3 quests, same set for the same day", () => {
    const a = questsForDay("2026-09-10");
    const b = questsForDay("2026-09-10");
    expect(a).toHaveLength(3);
    expect(a.map((q) => q.id)).toEqual(b.map((q) => q.id));
    // No repeats within the day.
    expect(new Set(a.map((q) => q.id)).size).toBe(3);
  });

  it("different dates can pick different sets", () => {
    const days = ["2026-09-10", "2026-09-11", "2026-09-12", "2026-09-13", "2026-09-14"];
    const sets = new Set(days.map((d) => questsForDay(d).map((q) => q.id).join(",")));
    expect(sets.size).toBeGreaterThan(1);
  });
});

describe("quests — server-verified progress", () => {
  it("scan quests count today's scan_seen rows", () => {
    const day = todayKey();
    const scanQuest = questsForDay(day).find((q) => q.kind === "scans") ?? questsForDay(day)[0];
    if (scanQuest.kind !== "scans") return; // today's trio has no scan quest — nothing to verify

    db.prepare(`INSERT INTO scan_seen (player_id, barcode, seen_at) VALUES (?, 'aaa', datetime('now'))`).run(PID);
    const status = questStatuses(PID).find((q) => q.id === scanQuest.id)!;
    expect(status.progress).toBe(1);
    expect(status.done).toBe(scanQuest.target <= 1);
  });
});

describe("quests — claim", () => {
  it("rejects a quest that is not on today's list", () => {
    expect(() => claimQuest(PID, "not-a-quest")).toThrow("QUEST_NOT_TODAY");
  });

  it("rejects an incomplete quest", () => {
    const quest = questStatuses(PID).find((q) => !q.done)!;
    expect(quest).toBeTruthy();
    expect(() => claimQuest(PID, quest.id)).toThrow("QUEST_INCOMPLETE");
  });

  it("grants keys once, then 409s on the second claim", () => {
    const day = todayKey();
    const quest = questsForDay(day).find((q) => q.kind === "scans" && q.target <= 2)
      ?? questsForDay(day)[0];
    if (quest.kind !== "scans") return;

    for (let i = 0; i < quest.target; i++) {
      db.prepare(`INSERT INTO scan_seen (player_id, barcode, seen_at) VALUES (?, ?, datetime('now'))`).run(PID, `bc-${i}`);
    }

    const before = stateFor(PID).keys;
    const { keys } = claimQuest(PID, quest.id);
    expect(keys).toBe(before + quest.reward);
    expect(() => claimQuest(PID, quest.id)).toThrow("QUEST_ALREADY_CLAIMED");
  });
});
