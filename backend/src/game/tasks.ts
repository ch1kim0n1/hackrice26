// Daily tasks — spec §6. Replaces the key-paying quest pool (quests.ts).
//
// Three tasks per UTC day, one per category: nutrition, battle, flex.
// Each claim pays 250 coins via the append-only coin ledger; claiming all
// three pays a 500 bonus — 1,250 coins/day maximum.
//
// Progress is verified server-side against real tables (meal_log,
// scan_seen, battle_history, lootbox_drop) — clients only ever claim.
// Nutrition and battle tasks are RR-eligible (+5 task RR, capped +10/day
// and unable to cross a rank boundary — see game/rr.ts); flex tasks are not.
// Claiming a nutrition task also revives one fainted monster (spec §6).

import { createHash } from "crypto";
import { db } from "../db";
import { writeCoinEntryInTransaction } from "../services/coins";
import { randomUUID } from "crypto";
import {
  TASK_REWARD_COINS,
  TASK_ALL_DONE_BONUS
} from "./spec";
import { applyTaskRR, rankForRR, RankId } from "./rr";

export function todayKey(): string {
  return new Date().toISOString().slice(0, 10);
}

export type TaskCategory = "nutrition" | "battle" | "flex";

export interface DailyTask {
  id: string;
  category: TaskCategory;
  label: string;
  /** Whether claiming awards task RR (spec §5). */
  rrEligible: boolean;
}

interface TaskDef extends DailyTask {
  /** Server-side completion check against today's records. */
  done: (playerId: string, ctx: TaskContext) => boolean;
}

/** What the checks read — profile fields come in via ctx so tasks.ts stays
 *  independent of the profile store's shape. */
export interface TaskContext {
  proteinTargetG?: number;
}

const NUTRITION_POOL: TaskDef[] = [
  {
    id: "log-meal",
    category: "nutrition",
    label: "Log a meal",
    rrEligible: true,
    done: (p) => countToday("meal_log", "logged_at", p) > 0
  },
  {
    id: "scan-food",
    category: "nutrition",
    label: "Scan a food barcode",
    rrEligible: true,
    done: (p) => countToday("scan_seen", "seen_at", p) > 0
  },
  {
    id: "hit-protein",
    category: "nutrition",
    label: "Hit your protein target",
    rrEligible: true,
    done: (p, ctx) => {
      const row = db
        .prepare(
          `SELECT COALESCE(SUM(protein_g), 0) AS g FROM meal_log
           WHERE player_id = ? AND removed = 0 AND date(logged_at) = date('now')`
        )
        .get(p) as { g: number };
      return row.g >= (ctx.proteinTargetG ?? 50);
    }
  }
];

const BATTLE_POOL: TaskDef[] = [
  {
    id: "win-battle",
    category: "battle",
    label: "Win a battle",
    rrEligible: true,
    done: (p) =>
      (db
        .prepare(
          `SELECT COUNT(*) AS n FROM battle_history
           WHERE player_id = ? AND result = 'win' AND date(created_at) = date('now')`
        )
        .get(p) as { n: number }).n > 0
  },
  {
    id: "play-ranked",
    category: "battle",
    label: "Play a ranked battle",
    rrEligible: true,
    done: (p) =>
      (db
        .prepare(
          `SELECT COUNT(*) AS n FROM battle_history
           WHERE player_id = ? AND mode = 'ranked' AND date(created_at) = date('now')`
        )
        .get(p) as { n: number }).n > 0
  },
  {
    id: "clear-dungeon-floor",
    category: "battle",
    label: "Clear a dungeon floor",
    rrEligible: true,
    done: (p) =>
      (db
        .prepare(
          `SELECT COUNT(*) AS n FROM battle_history
           WHERE player_id = ? AND mode = 'dungeon'
             AND json_extract(detail, '$.floorsCleared') > 0
             AND date(created_at) = date('now')`
        )
        .get(p) as { n: number }).n > 0
  }
];

const FLEX_POOL: TaskDef[] = [
  {
    id: "open-cookbook",
    category: "flex",
    label: "Open a cookbook",
    rrEligible: false,
    done: (p) =>
      (db
        .prepare(
          `SELECT COUNT(*) AS n FROM lootbox_drop
           WHERE player_id = ? AND date(json_extract(payload, '$.openedAt')) = date('now')`
        )
        .get(p) as { n: number }).n > 0
  },
  {
    id: "play-any-battle",
    category: "flex",
    label: "Finish a battle in any mode",
    rrEligible: false,
    done: (p) =>
      (db
        .prepare(
          `SELECT COUNT(*) AS n FROM battle_history
           WHERE player_id = ? AND date(created_at) = date('now')`
        )
        .get(p) as { n: number }).n > 0
  },
  {
    id: "log-or-scan",
    category: "flex",
    label: "Log or scan any food",
    rrEligible: false,
    done: (p) => countToday("meal_log", "logged_at", p) > 0 || countToday("scan_seen", "seen_at", p) > 0
  }
];

const POOLS: Record<TaskCategory, TaskDef[]> = {
  nutrition: NUTRITION_POOL,
  battle: BATTLE_POOL,
  flex: FLEX_POOL
};

function countToday(table: "meal_log" | "scan_seen", column: string, playerId: string): number {
  // Table/column are compile-time constants — never user input.
  const extra = table === "meal_log" ? "AND removed = 0" : "";
  return (
    db
      .prepare(`SELECT COUNT(*) AS n FROM ${table} WHERE player_id = ? AND date(${column}) = date('now') ${extra}`)
      .get(playerId) as { n: number }
  ).n;
}

/** One pick per category, deterministic from the UTC date — every player
 *  gets the same trio, and no state is needed to know what today asks. */
export function tasksForDay(day: string): DailyTask[] {
  return (Object.keys(POOLS) as TaskCategory[]).map((category) => {
    const pool = POOLS[category];
    const h = createHash("sha256").update(`tasks:${day}:${category}`).digest();
    const pick = pool[h[0] % pool.length];
    const { done: _done, ...pub } = pick;
    return pub;
  });
}

export interface TaskStatus extends DailyTask {
  done: boolean;
  claimed: boolean;
}

export function taskStatuses(playerId: string, day = todayKey(), ctx: TaskContext = {}): TaskStatus[] {
  const claimed = new Set(
    (db
      .prepare(`SELECT quest_id FROM quest_claim WHERE player_id = ? AND day = ?`)
      .all(playerId, day) as { quest_id: string }[]).map((r) => r.quest_id)
  );
  return tasksForDay(day).map((task) => {
    const def = POOLS[task.category].find((t) => t.id === task.id)!;
    return { ...task, done: def.done(playerId, ctx), claimed: claimed.has(task.id) };
  });
}

// ---------------------------------------------------------------------------
// Faints (spec §4/§6): monsters that hit 0 HP stay fainted until the daily
// reset or an eligible nutrition task revives one. `fainted_monster` rows are
// day-stamped; anything older than today is already recovered.
// ---------------------------------------------------------------------------

export function markFainted(playerId: string, charIds: string[], day = todayKey()): void {
  const stmt = db.prepare(
    `INSERT OR IGNORE INTO fainted_monster (player_id, char_id, day) VALUES (?, ?, ?)`
  );
  for (const id of charIds) stmt.run(playerId, id, day);
}

/** Currently-fainted ids — today's rows only. Older rows self-heal: the
 *  daily reset is a delete of yesterday's records, applied lazily on read. */
export function faintedIds(playerId: string, day = todayKey()): string[] {
  db.prepare(`DELETE FROM fainted_monster WHERE player_id = ? AND day < ?`).run(playerId, day);
  return (db
    .prepare(`SELECT char_id FROM fainted_monster WHERE player_id = ? AND day = ?`)
    .all(playerId, day) as { char_id: string }[]).map((r) => r.char_id);
}

/** Nutrition-task recovery: revive one fainted monster (FIFO). Returns the
 *  revived id or null when nothing was down. */
export function reviveOneFainted(playerId: string, day = todayKey()): string | null {
  const ids = faintedIds(playerId, day);
  const first = ids[0];
  if (!first) return null;
  db.prepare(`DELETE FROM fainted_monster WHERE player_id = ? AND char_id = ?`).run(playerId, first);
  return first;
}

// ---------------------------------------------------------------------------
// Claim
// ---------------------------------------------------------------------------

export interface TaskClaimResult {
  taskId: string;
  coins: number;
  bonusCoins: number;
  allDone: boolean;
  /** Task RR actually applied (0 for flex tasks, at cap, or at rank top). */
  rrApplied: number;
  rr: number;
  rank: RankId;
  /** Monster revived by a nutrition-task claim, if any. */
  revived: string | null;
  /** Streak fields — set when the claim counted as a nutrition action. */
  streakDays?: number;
  boostEarned?: boolean;
}

/**
 * Claim a task: verify today's task is done, mark the claim, pay 250 coins,
 * and — when it completes the trio — pay the 500 all-done bonus. Claim row,
 * coin entries, RR award and faint revive commit in one transaction.
 */
export function claimTask(
  playerId: string,
  taskId: string,
  profile: {
    rr: number;
    taskRRDay?: string;
    taskRRToday?: number;
    nutritionStreakDays?: number;
    lastNutritionDay?: string;
    cookbookBoosts?: number;
  },
  day = todayKey(),
  ctx: TaskContext = {}
): { result: TaskClaimResult; profilePatch: Partial<typeof profile> } {
  const task = tasksForDay(day).find((t) => t.id === taskId);
  if (!task) throw new Error("TASK_NOT_TODAY");
  const def = POOLS[task.category].find((t) => t.id === task.id)!;

  db.exec("BEGIN IMMEDIATE");
  try {
    if (!def.done(playerId, ctx)) throw new Error("TASK_INCOMPLETE");
    const res = db
      .prepare(`INSERT OR IGNORE INTO quest_claim (player_id, day, quest_id) VALUES (?, ?, ?)`)
      .run(playerId, day, taskId);
    if (res.changes === 0) throw new Error("TASK_ALREADY_CLAIMED");

    const now = new Date().toISOString();
    writeCoinEntryInTransaction({
      id: randomUUID(),
      playerId,
      amount: TASK_REWARD_COINS,
      reason: "task",
      refId: `task:${day}:${taskId}`,
      createdAt: now
    });

    // All-three bonus: this claim just completed the trio.
    const claimedCount = (
      db
        .prepare(`SELECT COUNT(*) AS n FROM quest_claim WHERE player_id = ? AND day = ?`)
        .get(playerId, day) as { n: number }
    ).n;
    const allDone = claimedCount >= tasksForDay(day).length;
    let bonusCoins = 0;
    if (allDone) {
      bonusCoins = TASK_ALL_DONE_BONUS;
      writeCoinEntryInTransaction({
        id: randomUUID(),
        playerId,
        amount: bonusCoins,
        reason: "task_bonus",
        refId: `task-bonus:${day}`,
        createdAt: now
      });
    }

    // Task RR — eligible tasks only, +5, capped +10/day, never promotes.
    const patch: Partial<typeof profile> = {};
    let rrApplied = 0;
    let rr = profile.rr;
    if (task.rrEligible) {
      const earnedToday = profile.taskRRDay === day ? (profile.taskRRToday ?? 0) : 0;
      const applied = applyTaskRR(profile.rr, earnedToday);
      rrApplied = applied.applied;
      rr = applied.rr;
      patch.rr = rr;
      patch.taskRRDay = day;
      patch.taskRRToday = earnedToday + rrApplied;
    }

    // Nutrition claim = today's eligible nutrition action: streak + faint.
    let revived: string | null = null;
    let streakDays: number | undefined;
    let boostEarned = false;
    if (task.category === "nutrition") {
      revived = reviveOneFainted(playerId, day);
      const streak = nextNutritionStreak(profile, day);
      streakDays = streak.streakDays;
      boostEarned = streak.boostEarned;
      patch.nutritionStreakDays = streak.streakDays;
      patch.lastNutritionDay = day;
      if (streak.boostEarned) patch.cookbookBoosts = (profile.cookbookBoosts ?? 0) + 1;
    }

    db.exec("COMMIT");
    return {
      result: {
        taskId,
        coins: TASK_REWARD_COINS,
        bonusCoins,
        allDone,
        rrApplied,
        rr,
        rank: rankForRR(rr),
        revived,
        streakDays,
        boostEarned
      },
      profilePatch: patch
    };
  } catch (err) {
    try {
      db.exec("ROLLBACK");
    } catch {
      // BEGIN already failed or the error came from the throw above.
    }
    throw err;
  }
}

/**
 * Streak arithmetic (spec §6): one eligible nutrition action per UTC day.
 * Consecutive days extend the streak; a gap resets it to 1. Every fifth
 * streak day earns one Cookbook Boost (floor(streak/5) earned in total).
 */
export function nextNutritionStreak(
  profile: { nutritionStreakDays?: number; lastNutritionDay?: string },
  day = todayKey()
): { streakDays: number; boostEarned: boolean } {
  if (profile.lastNutritionDay === day) {
    return { streakDays: profile.nutritionStreakDays ?? 0, boostEarned: false };
  }
  const yesterday = new Date(Date.parse(`${day}T00:00:00Z`) - 86_400_000).toISOString().slice(0, 10);
  const streakDays = profile.lastNutritionDay === yesterday ? (profile.nutritionStreakDays ?? 0) + 1 : 1;
  return { streakDays, boostEarned: streakDays % 5 === 0 };
}
