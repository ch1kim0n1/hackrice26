import { describe, it, expect, beforeAll, beforeEach } from "vitest";
import { rmSync } from "fs";
import { tmpdir } from "os";
import path from "path";

// Daily tasks, streaks and faints — spec §6. Three tasks/day (nutrition,
// battle, flex) × 250 coins, +500 all-done bonus = 1,250/day max. Nutrition
// and battle tasks pay +5 task RR (capped +10/day, never promotes); a
// nutrition claim revives one fainted monster. Streak earns a Cookbook
// Boost every 5 days.

const DB_FILE = path.join(tmpdir(), `nutriquest-tasks-${process.pid}-${Date.now()}.db`);
process.env.NUTRIQUEST_DB = DB_FILE;

type Db = typeof import("../db");
type Tasks = typeof import("./tasks");
type Coins = typeof import("../services/coins");

let db: Db["db"];
let tasksForDay: Tasks["tasksForDay"];
let taskStatuses: Tasks["taskStatuses"];
let claimTask: Tasks["claimTask"];
let todayKey: Tasks["todayKey"];
let markFainted: Tasks["markFainted"];
let faintedIds: Tasks["faintedIds"];
let reviveOneFainted: Tasks["reviveOneFainted"];
let nextNutritionStreak: Tasks["nextNutritionStreak"];
let coinBalance: Coins["coinBalance"];

beforeAll(async () => {
  ({ db } = await import("../db"));
  ({
    tasksForDay,
    taskStatuses,
    claimTask,
    todayKey,
    markFainted,
    faintedIds,
    reviveOneFainted,
    nextNutritionStreak
  } = await import("./tasks"));
  ({ coinBalance } = await import("../services/coins"));
});

let counter = 0;
function freshPlayer(): string {
  const id = `task_p${counter++}_${Date.now()}`;
  db.prepare(`INSERT INTO players (id, display_name, is_portable) VALUES (?, ?, 0)`).run(id, `P${counter}`);
  return id;
}

/** Insert enough real records that every task in every pool is satisfied. */
function satisfyAll(playerId: string): void {
  db.prepare(
    `INSERT INTO meal_log (meal_id, player_id, source, name, calories, protein_g)
     VALUES (?, ?, 'barcode', 'Test Meal', 500, 60)`
  ).run(`meal_${playerId}`, playerId);
  db.prepare(`INSERT INTO scan_seen (player_id, barcode) VALUES (?, ?)`).run(playerId, `bc_${playerId}`);
  db.prepare(
    `INSERT INTO battle_history (player_id, mode, result, opponent, rr_delta, squad, detail)
     VALUES (?, 'ranked', 'win', 'bot', 20, '[]', '{}')`
  ).run(playerId);
  db.prepare(
    `INSERT INTO battle_history (player_id, mode, result, opponent, rr_delta, squad, detail)
     VALUES (?, 'dungeon', 'win', 'dungeon', 0, '[]', '{"floorsCleared":3}')`
  ).run(playerId);
  db.prepare(`INSERT INTO lootbox_drop (player_id, payload, drop_id) VALUES (?, ?, ?)`).run(
    playerId,
    JSON.stringify({ openedAt: new Date().toISOString() }),
    `drop_${playerId}`
  );
}

const PROFILE = { rr: 50 };

beforeEach(() => {
  counter += 100; // keep ids unique across tests that share a wall-clock ms
});

describe("tasksForDay", () => {
  it("picks exactly three tasks — one per category", () => {
    const tasks = tasksForDay(todayKey());
    expect(tasks).toHaveLength(3);
    expect(new Set(tasks.map((t) => t.category))).toEqual(new Set(["nutrition", "battle", "flex"]));
  });

  it("is deterministic for the same UTC day", () => {
    expect(tasksForDay("2026-01-15")).toEqual(tasksForDay("2026-01-15"));
  });
});

describe("claimTask", () => {
  it("pays 250 per task plus the 500 all-three bonus — 1,250/day max", () => {
    const p = freshPlayer();
    satisfyAll(p);
    const day = todayKey();
    const tasks = tasksForDay(day);

    let total = 0;
    for (const [i, task] of tasks.entries()) {
      const { result } = claimTask(p, task.id, { ...PROFILE }, day);
      expect(result.coins).toBe(250);
      expect(result.bonusCoins).toBe(i === tasks.length - 1 ? 500 : 0);
      expect(result.allDone).toBe(i === tasks.length - 1);
      total += result.coins + result.bonusCoins;
    }
    expect(total).toBe(1250);
    expect(coinBalance(p)).toBe(1250);
  });

  it("refuses a second claim of the same task", () => {
    const p = freshPlayer();
    satisfyAll(p);
    const day = todayKey();
    const task = tasksForDay(day)[0];
    claimTask(p, task.id, { ...PROFILE }, day);
    expect(() => claimTask(p, task.id, { ...PROFILE }, day)).toThrowError("TASK_ALREADY_CLAIMED");
    // Failed claim pays nothing extra.
    expect(coinBalance(p)).toBe(250);
  });

  it("refuses a task that was not actually completed", () => {
    const p = freshPlayer(); // no records at all
    const task = tasksForDay(todayKey())[0];
    expect(() => claimTask(p, task.id, { ...PROFILE }, todayKey())).toThrowError("TASK_INCOMPLETE");
  });

  it("refuses an id that is not one of today's tasks", () => {
    const p = freshPlayer();
    satisfyAll(p);
    const today = new Set(tasksForDay(todayKey()).map((t) => t.id));
    const foreign = ["log-meal", "scan-food", "hit-protein", "win-battle", "play-ranked", "clear-dungeon-floor", "open-cookbook", "play-any-battle", "log-or-scan"].find(
      (id) => !today.has(id)
    );
    if (foreign) {
      expect(() => claimTask(p, foreign, { ...PROFILE }, todayKey())).toThrowError("TASK_NOT_TODAY");
    }
  });

  it("task RR respects the +10/day cap and never promotes", () => {
    const p = freshPlayer();
    satisfyAll(p);
    const day = todayKey();
    // Sit at 97 RR (Iron ceiling is 99): both RR-eligible claims together can
    // apply at most 2, and never reach Bronze.
    const eligible = tasksForDay(day).filter((t) => t.rrEligible);
    const profile = { rr: 97 };
    for (const task of eligible) {
      const { result, profilePatch } = claimTask(p, task.id, profile, day);
      Object.assign(profile, profilePatch);
      expect(result.rr).toBeLessThan(100);
    }
    expect(profile.rr).toBeLessThanOrEqual(99);
  });

  it("marks tasks done/claimed in taskStatuses", () => {
    const p = freshPlayer();
    satisfyAll(p);
    const day = todayKey();
    const task = tasksForDay(day)[0];
    claimTask(p, task.id, { ...PROFILE }, day);
    const statuses = taskStatuses(p, day);
    const claimed = statuses.find((s) => s.id === task.id)!;
    expect(claimed.done).toBe(true);
    expect(claimed.claimed).toBe(true);
  });
});

describe("streak", () => {
  it("extends on consecutive days and resets after a gap", () => {
    expect(nextNutritionStreak({}, "2026-02-01")).toEqual({ streakDays: 1, boostEarned: false });
    expect(nextNutritionStreak({ nutritionStreakDays: 1, lastNutritionDay: "2026-02-01" }, "2026-02-02"))
      .toEqual({ streakDays: 2, boostEarned: false });
    expect(nextNutritionStreak({ nutritionStreakDays: 4, lastNutritionDay: "2026-02-04" }, "2026-02-10"))
      .toEqual({ streakDays: 1, boostEarned: false });
  });

  it("earns a Cookbook Boost every 5th streak day", () => {
    let profile: { nutritionStreakDays?: number; lastNutritionDay?: string } = {};
    const boosts: boolean[] = [];
    for (let d = 1; d <= 10; d++) {
      const day = `2026-03-${String(d).padStart(2, "0")}`;
      const r = nextNutritionStreak(profile, day);
      boosts.push(r.boostEarned);
      profile = { nutritionStreakDays: r.streakDays, lastNutritionDay: day };
    }
    // Days 5 and 10 pay a boost — floor(streak/5) milestones.
    expect(boosts.filter(Boolean)).toHaveLength(2);
    expect(boosts[4]).toBe(true);
    expect(boosts[9]).toBe(true);
  });

  it("is idempotent within the same day", () => {
    const profile = { nutritionStreakDays: 3, lastNutritionDay: "2026-03-03" };
    const r = nextNutritionStreak(profile, "2026-03-03");
    expect(r.streakDays).toBe(3);
    expect(r.boostEarned).toBe(false);
  });
});

describe("faint recovery", () => {
  it("revives one fainted monster per nutrition claim (FIFO)", () => {
    const p = freshPlayer();
    const day = todayKey();
    markFainted(p, ["a", "b", "c"], day);
    expect(faintedIds(p, day)).toEqual(["a", "b", "c"]);
    expect(reviveOneFainted(p, day)).toBe("a");
    expect(faintedIds(p, day)).toEqual(["b", "c"]);
    expect(reviveOneFainted(p, day)).toBe("b");
    expect(reviveOneFainted(p, day)).toBe("c");
    expect(reviveOneFainted(p, day)).toBeNull();
  });

  it("daily reset recovers everything — yesterday's rows are gone on read", () => {
    const p = freshPlayer();
    markFainted(p, ["x"], "2020-01-01");
    expect(faintedIds(p)).toEqual([]);
  });

  it("a nutrition-task claim revives a fainted monster", () => {
    const p = freshPlayer();
    satisfyAll(p);
    const day = todayKey();
    markFainted(p, ["down-mon"], day);
    const nutrition = tasksForDay(day).find((t) => t.category === "nutrition")!;
    const { result } = claimTask(p, nutrition.id, { ...PROFILE }, day);
    expect(result.revived).toBe("down-mon");
    expect(faintedIds(p, day)).toEqual([]);
    // The claim also advanced the streak.
    expect(result.streakDays).toBe(1);
  });
});
