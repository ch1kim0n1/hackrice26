import { Router, Response } from "express";
import { UserProfile, Character, LootDrop } from "../types";
import { PlayerRequest, requirePlayerId } from "../middleware/player";
import { db } from "../db";
import { stateFor } from "../services/lootboxState";
import { MAX_SNAPSHOTS, vitalsStoreFor } from "../vitals/vitalsStore";
import { activityByDay } from "../vitals/activityCalendar";
import { rateLimitByPlayer } from "../middleware/security";
import { RARITY_TIERS } from "../data/lootTable";
import {
  claimTask,
  faintedIds,
  nextNutritionStreak,
  taskStatuses,
  todayKey,
  TaskContext
} from "../game/tasks";
import { hasDatabaseUrl } from "../db/pg";
import { rankForRR, rrToNextRank, RANK_LABELS, RankId } from "../game/rr";
import { bmi, bmiBand } from "../game/targets";
import { goalProfileFor } from "../game/goals";
import { Activity, Goal, Sex, bodyVitals } from "../vitals/bodyMetrics";
import { enqueueMirror } from "../services/mirrorQueue";
import { profileUpsertSchema } from "../schemas/gameSchemas";
import { STREAK_BOOST_EVERY } from "../game/spec";

export const userRouter = Router();
userRouter.use(requirePlayerId);

/**
 * Per-player profile store. Keyed by the X-Player-Id header (or the :id param,
 * which must match). Persisted to SQLite so profiles survive restarts
 * (issue #23).
 *
 * Spec §5/§6: progression is RR + battle history + tasks + streak. There is
 * no XP, no levels, no consistency ladder, no seasons, no fatigue, and no
 * comeback crate — those columns/fields from earlier builds are inert.
 */

interface PlayerProfile extends UserProfile {
  createdAt: string;
  updatedAt: string;
  /** Ranked Rating (spec §5). Server-managed; never below 0. */
  rr?: number;
  /** Ranked record — leaderboard tiebreakers (RR → wins → win rate). */
  rankedWins?: number;
  rankedLosses?: number;
  /** Task-RR bookkeeping: UTC day + amount already applied (cap +10). */
  taskRRDay?: string;
  taskRRToday?: number;
  /** Nutrition streak (spec §6): consecutive days with ≥1 eligible action. */
  nutritionStreakDays?: number;
  lastNutritionDay?: string;
  /** Unspent Cookbook Boosts — every 5 streak days earns one. */
  cookbookBoosts?: number;
  /** Body metrics, client-writable (#88): feed BMI/BMR goals (#89/#90). */
  weightKg?: number;
  heightCm?: number;
  bodyType?: string;
  /** BMR inputs (#89): needed before the vitals endpoint can report
   *  Mifflin-St Jeor numbers. All optional — vitals degrades gracefully. */
  age?: number;
  sex?: Sex;
  activity?: Activity;
  goal?: Goal;
  /** User-editable dashboard targets (spec §7 home dashboard). */
  calorieTarget?: number;
  proteinTargetG?: number;
  carbsTargetG?: number;
  fatTargetG?: number;
  /** Explicit watch-data opt-in (spec §7 consent). */
  watchOptIn?: boolean;
}

export type { PlayerProfile };

// ===== Battle history (spec §6) ============================================

export type BattleMode = "ranked" | "friendly" | "dungeon";

/**
 * Append one completed battle. Ranked results carry their RR delta; friendly
 * battles are recorded with rrDelta 0 — history is complete, not selective.
 */
export function recordBattle(
  playerId: string,
  mode: BattleMode,
  result: "win" | "loss",
  opts: {
    opponent?: string;
    rrDelta?: number;
    squad: { id: string; name: string }[];
    detail?: object;
  }
): void {
  db.prepare(
    `INSERT INTO battle_history (player_id, mode, result, opponent, rr_delta, squad, detail)
     VALUES (?, ?, ?, ?, ?, ?, ?)`
  ).run(
    playerId,
    mode,
    result,
    opts.opponent ?? null,
    opts.rrDelta ?? 0,
    JSON.stringify(opts.squad.slice(0, 3)),
    opts.detail ? JSON.stringify(opts.detail) : null
  );
}

/** Apply a ranked outcome to the profile: RR delta + record counters. */
export function applyRankedToProfile(
  playerId: string,
  result: { delta: number; rr: number },
  won: boolean
): PlayerProfile {
  const profile = getOrCreate(playerId);
  profile.rr = result.rr;
  profile.rankedWins = (profile.rankedWins ?? 0) + (won ? 1 : 0);
  profile.rankedLosses = (profile.rankedLosses ?? 0) + (won ? 0 : 1);
  if (won) profile.battlesWon = (profile.battlesWon ?? 0) + 1;
  profile.updatedAt = new Date().toISOString();
  saveProfile(playerId, profile);
  return profile;
}

// ===== Nutrition streak / Cookbook Boosts (spec §6) ========================

/**
 * Count one eligible nutrition action for today (called from the scan and
 * meal-log paths as well as nutrition-task claims). Idempotent within a day.
 */
export function recordNutritionAction(playerId: string): { streakDays: number; boostEarned: boolean; boosts: number } {
  const profile = getOrCreate(playerId);
  const day = todayKey();
  const { streakDays, boostEarned } = nextNutritionStreak(profile, day);
  if (profile.lastNutritionDay !== day) {
    profile.nutritionStreakDays = streakDays;
    profile.lastNutritionDay = day;
    if (boostEarned) profile.cookbookBoosts = (profile.cookbookBoosts ?? 0) + 1;
    profile.updatedAt = new Date().toISOString();
    saveProfile(playerId, profile);
  }
  return {
    streakDays: profile.nutritionStreakDays ?? 0,
    boostEarned,
    boosts: profile.cookbookBoosts ?? 0
  };
}

/**
 * Spend one stored Cookbook Boost (consumed by the cookbook-open path — the
 * open renormalizes Rare+ weights ×1.15). Returns false when none are held.
 * The spend is atomic with the caller's transaction when invoked inside one.
 */
export function consumeCookbookBoost(playerId: string): boolean {
  const profile = getOrCreate(playerId);
  if ((profile.cookbookBoosts ?? 0) < 1) return false;
  profile.cookbookBoosts = (profile.cookbookBoosts ?? 0) - 1;
  profile.updatedAt = new Date().toISOString();
  saveProfile(playerId, profile);
  return true;
}

export function cookbookBoosts(playerId: string): number {
  return getOrCreate(playerId).cookbookBoosts ?? 0;
}

// ===== Profile CRUD =========================================================

function defaultProfile(playerId: string): PlayerProfile {
  return {
    id: playerId,
    displayName: `Trainer ${playerId.slice(0, 6)}`,
    level: 1,
    xp: 0,
    streakDays: 0,
    battlesWon: 0,
    activeCharacterId: null,
    colorMode: "none",
    rr: 0,
    rankedWins: 0,
    rankedLosses: 0,
    cookbookBoosts: 0,
    nutritionStreakDays: 0,
    createdAt: new Date().toISOString(),
    updatedAt: new Date().toISOString()
  };
}

export function getOrCreate(playerId: string): PlayerProfile {
  const row = db
    .prepare(`SELECT payload FROM user_profile WHERE player_id = ?`)
    .get(playerId) as { payload: string } | undefined;
  if (row) return JSON.parse(row.payload) as PlayerProfile;

  const profile = defaultProfile(playerId);
  db.prepare(
    `INSERT INTO user_profile (player_id, payload, created_at, updated_at) VALUES (?, ?, ?, ?)`
  ).run(playerId, JSON.stringify(profile), profile.createdAt, profile.updatedAt);
  return profile;
}

export function saveProfile(playerId: string, profile: PlayerProfile): void {
  db.prepare(
    `UPDATE user_profile SET payload = ?, updated_at = ? WHERE player_id = ?`
  ).run(JSON.stringify(profile), profile.updatedAt, playerId);
}

/** Public rank block — RR + derived rank + progress to the next floor. */
export function rankBlock(profile: PlayerProfile) {
  const rr = profile.rr ?? 0;
  const rank = rankForRR(rr);
  return {
    rr,
    rank,
    rankLabel: RANK_LABELS[rank],
    rrToNextRank: rrToNextRank(rr)
  };
}

const COLOR_MODES = ["active", "bestUnselected", "none"] as const;

/** :id must match the caller's X-Player-Id -- otherwise one player could
 *  read or overwrite another player's profile just by naming their id in
 *  the URL, since the header is what's actually trusted. */
function requireOwnId(req: PlayerRequest, res: Response): boolean {
  if (req.params.id !== req.playerId) {
    res.status(403).json({
      error: { code: "PLAYER_ID_MISMATCH", message: "The :id in the URL must match your X-Player-Id header." }
    });
    return false;
  }
  return true;
}

/** GET /user/leaderboard — spec §6 ordering: RR desc, then ranked wins,
 *  then win rate. Registered before /:id so "leaderboard" is not swallowed
 *  by the :id param. Read-only and privacy-safe. */
userRouter.get("/leaderboard", (req: PlayerRequest, res) => {
  const rows = db
    .prepare(`SELECT player_id, payload FROM user_profile`)
    .all() as { player_id: string; payload: string }[];
  const entries = rows
    .map((r) => JSON.parse(r.payload) as PlayerProfile)
    .map((p) => {
      const wins = p.rankedWins ?? 0;
      const losses = p.rankedLosses ?? 0;
      const games = wins + losses;
      return {
        id: p.id,
        displayName: p.displayName,
        rr: p.rr ?? 0,
        rank: rankForRR(p.rr ?? 0),
        rankLabel: RANK_LABELS[rankForRR(p.rr ?? 0)],
        rankedWins: wins,
        rankedLosses: losses,
        winRate: games > 0 ? wins / games : 0,
        isYou: p.id === req.playerId
      };
    })
    .sort((a, b) => b.rr - a.rr || b.rankedWins - a.rankedWins || b.winRate - a.winRate)
    .slice(0, 50)
    .map((e, i) => ({ ...e, rank: i + 1 }));
  res.json({ entries });
});

// ===== Daily tasks (spec §6) ===============================================

function taskContext(profile: PlayerProfile): TaskContext {
  return {
    proteinTargetG: profile.proteinTargetG,
    watchConnected: profile.watchOptIn === true
  };
}

/** GET /user/tasks/today — the day's three tasks with verified progress. */
userRouter.get("/tasks/today", (req: PlayerRequest, res) => {
  const profile = getOrCreate(req.playerId!);
  res.json({ day: todayKey(), tasks: taskStatuses(req.playerId!, todayKey(), taskContext(profile)) });
});

/** POST /user/tasks/:taskId/claim — verified completion -> 250 coins
 *  (+500 when it completes the trio). One claim per (player, day, task). */
userRouter.post("/tasks/:taskId/claim", rateLimitByPlayer({ windowMs: 60_000, max: 10, keyPrefix: "task", message: "Too many task claims." }), (req: PlayerRequest, res) => {
  try {
    const profile = getOrCreate(req.playerId!);
    const { result, profilePatch } = claimTask(
      req.playerId!,
      req.params.taskId,
      { ...profile, rr: profile.rr ?? 0 },
      todayKey(),
      taskContext(profile)
    );
    if (Object.keys(profilePatch).length) {
      Object.assign(profile, profilePatch);
      profile.updatedAt = new Date().toISOString();
      saveProfile(req.playerId!, profile);
    }
    if (hasDatabaseUrl()) {
      enqueueMirror(
        "gameplay_event",
        `task_claim:${req.playerId!}:${req.params.taskId}:${todayKey()}`,
        { playerId: req.playerId!, type: "task_claim", detail: { taskId: req.params.taskId } }
      );
    }
    res.json(result);
  } catch (err: unknown) {
    const message = err instanceof Error ? err.message : String(err);
    const status: Record<string, number> = {
      TASK_NOT_TODAY: 404,
      TASK_INCOMPLETE: 409,
      TASK_ALREADY_CLAIMED: 409
    };
    res.status(status[message] ?? 400).json({ error: { code: message, message } });
  }
});

/** GET /user/:id -- profile plus rank, streak, faint and task state. Creates
 *  the profile on first access with per-player defaults. */
userRouter.get("/:id", (req: PlayerRequest, res) => {
  if (!requireOwnId(req, res)) return;
  const profile = getOrCreate(req.playerId!);
  const wins = profile.rankedWins ?? 0;
  const losses = profile.rankedLosses ?? 0;
  const games = wins + losses;
  res.json({
    profile,
    rank: rankBlock(profile),
    record: { rankedWins: wins, rankedLosses: losses, winRate: games > 0 ? wins / games : 0 },
    streak: {
      days: profile.nutritionStreakDays ?? 0,
      boosts: profile.cookbookBoosts ?? 0,
      nextBoostIn: STREAK_BOOST_EVERY - ((profile.nutritionStreakDays ?? 0) % STREAK_BOOST_EVERY)
    },
    fainted: faintedIds(req.playerId!),
    tasks: taskStatuses(req.playerId!, todayKey(), taskContext(profile))
  });
});

/** GET /user/:id/history — completed battles, newest first (spec §6). */
userRouter.get("/:id/history", (req: PlayerRequest, res) => {
  if (!requireOwnId(req, res)) return;
  const limit = Math.max(1, Math.min(Number(req.query.limit ?? 25) || 25, 100));
  const rows = db
    .prepare(
      `SELECT seq, mode, result, opponent, rr_delta, squad, detail, created_at
       FROM battle_history WHERE player_id = ? ORDER BY seq DESC LIMIT ?`
    )
    .all(req.playerId!, limit) as {
    seq: number; mode: BattleMode; result: "win" | "loss"; opponent: string | null;
    rr_delta: number; squad: string; detail: string | null; created_at: string;
  }[];
  res.json({
    battles: rows.map((r) => ({
      id: r.seq,
      mode: r.mode,
      result: r.result,
      opponent: r.opponent,
      rrDelta: r.rr_delta,
      squad: JSON.parse(r.squad) as { id: string; name: string }[],
      detail: r.detail ? (JSON.parse(r.detail) as object) : null,
      at: r.created_at
    }))
  });
});

/** GET /user/:id/goals — BMI/BMR-driven daily food priorities (#89/#90).
 *  Needs heightCm + weightKg on the profile (PUT /user/:id); without them
 *  there is no band to compute, so the route says so rather than guessing. */
userRouter.get("/:id/goals", (req: PlayerRequest, res) => {
  if (!requireOwnId(req, res)) return;
  const profile = getOrCreate(req.playerId!);
  if (!profile.weightKg || !profile.heightCm) {
    return res.status(400).json({
      error: { code: "NO_METRICS", message: "Set weightKg and heightCm via PUT /user/:id first." }
    });
  }
  const value = bmi(profile.weightKg, profile.heightCm);
  const band = bmiBand(value);
  res.json({ bmi: Math.round(value * 10) / 10, band, goals: goalProfileFor(band) });
});

/** GET /user/:id/vitals — BMI/BMR readout (#89). Always 200: whatever can
 *  be computed is computed, and `missing` names the inputs still needed
 *  for the rest, so the client can prompt for them. */
userRouter.get("/:id/vitals", (req: PlayerRequest, res) => {
  if (!requireOwnId(req, res)) return;
  const profile = getOrCreate(req.playerId!);
  res.json(
    bodyVitals({
      weightKg: profile.weightKg,
      heightCm: profile.heightCm,
      age: profile.age,
      sex: profile.sex,
      activity: profile.activity,
      goal: profile.goal
    })
  );
});

/** GET /user/:id/nutrition/today — spec §7 home dashboard: today's logged
 *  kcal/protein/carbs/fat against the player's editable targets. */
userRouter.get("/:id/nutrition/today", (req: PlayerRequest, res) => {
  if (!requireOwnId(req, res)) return;
  const profile = getOrCreate(req.playerId!);
  const row = db
    .prepare(
      `SELECT COALESCE(SUM(calories), 0) AS calories,
              COALESCE(SUM(protein_g), 0) AS proteinG,
              COALESCE(SUM(carbs_g), 0) AS carbsG,
              COALESCE(SUM(fat_g), 0) AS fatG
       FROM meal_log
       WHERE player_id = ? AND removed = 0 AND date(logged_at) = date('now')`
    )
    .get(req.playerId!) as { calories: number; proteinG: number; carbsG: number; fatG: number };
  res.json({
    day: todayKey(),
    logged: row,
    targets: {
      calories: profile.calorieTarget ?? null,
      proteinG: profile.proteinTargetG ?? null,
      carbsG: profile.carbsTargetG ?? null,
      fatG: profile.fatTargetG ?? null
    }
  });
});

/** PUT /user/:id -- partial update. Additive route; GET shape untouched.
 *  Only whitelisted client-writable fields accepted. Server-managed fields
 *  (rr, wins, streaks, boosts) are rejected to prevent self-ranking abuse. */
userRouter.put("/:id", rateLimitByPlayer({ windowMs: 60_000, max: 20, keyPrefix: "user", message: "Too many profile updates. Try again later." }), (req: PlayerRequest, res) => {
  if (!requireOwnId(req, res)) return;
  const profile = getOrCreate(req.playerId!);
  const body = req.body;
  if (body === null || typeof body !== "object" || Array.isArray(body)) {
    return res.status(400).json({ error: { code: "VALIDATION", message: "body must be a JSON object" } });
  }
  const fields = body as Record<string, unknown>;
  const errors: string[] = [];

  // Server-managed progression fields: client cannot self-rank.
  const serverManaged = [
    "level", "xp", "streakDays", "battlesWon",
    "rr", "rankedWins", "rankedLosses", "taskRRDay", "taskRRToday",
    "nutritionStreakDays", "lastNutritionDay", "cookbookBoosts"
  ] as const;
  for (const key of serverManaged) {
    if (fields[key] !== undefined) {
      errors.push(`${key} is server-managed and cannot be set by the client`);
    }
  }

  if (fields.displayName !== undefined) {
    if (typeof fields.displayName !== "string" || fields.displayName.trim().length < 2 || fields.displayName.length > 32) {
      errors.push("displayName must be a string of 2-32 characters");
    }
  }
  if (fields.activeCharacterId !== undefined && fields.activeCharacterId !== null) {
    if (typeof fields.activeCharacterId !== "string" || fields.activeCharacterId.length > 64) {
      errors.push("activeCharacterId must be a string of at most 64 characters");
    }
  }
  if (fields.colorMode !== undefined) {
    if (typeof fields.colorMode !== "string" || !COLOR_MODES.includes(fields.colorMode as (typeof COLOR_MODES)[number])) {
      errors.push(`colorMode must be one of: ${COLOR_MODES.join(", ")}`);
    }
  }
  if (fields.weightKg !== undefined) {
    if (!Number.isFinite(fields.weightKg) || (fields.weightKg as number) <= 0 || (fields.weightKg as number) > 500) {
      errors.push("weightKg must be a number between 0 and 500");
    }
  }
  if (fields.heightCm !== undefined) {
    if (!Number.isFinite(fields.heightCm) || (fields.heightCm as number) <= 0 || (fields.heightCm as number) > 300) {
      errors.push("heightCm must be a number between 0 and 300");
    }
  }
  if (fields.bodyType !== undefined) {
    if (typeof fields.bodyType !== "string" || !["ectomorph", "mesomorph", "endomorph"].includes(fields.bodyType)) {
      errors.push("bodyType must be one of: ectomorph, mesomorph, endomorph");
    }
  }
  if (fields.age !== undefined) {
    if (!Number.isFinite(fields.age) || (fields.age as number) < 5 || (fields.age as number) > 120) {
      errors.push("age must be a number between 5 and 120");
    }
  }
  if (fields.sex !== undefined) {
    if (!["male", "female"].includes(fields.sex as string)) {
      errors.push("sex must be one of: male, female");
    }
  }
  if (fields.activity !== undefined) {
    if (!["sedentary", "light", "moderate", "active"].includes(fields.activity as string)) {
      errors.push("activity must be one of: sedentary, light, moderate, active");
    }
  }
  if (fields.goal !== undefined) {
    if (!["cut", "maintain", "bulk"].includes(fields.goal as string)) {
      errors.push("goal must be one of: cut, maintain, bulk");
    }
  }
  for (const key of ["calorieTarget", "proteinTargetG", "carbsTargetG", "fatTargetG"] as const) {
    if (fields[key] !== undefined) {
      if (!Number.isFinite(fields[key]) || (fields[key] as number) < 0 || (fields[key] as number) > 100_000) {
        errors.push(`${key} must be a number between 0 and 100000`);
      }
    }
  }
  if (fields.watchOptIn !== undefined && typeof fields.watchOptIn !== "boolean") {
    errors.push("watchOptIn must be a boolean");
  }

  if (errors.length > 0) {
    return res.status(400).json({ error: { code: "VALIDATION", message: errors.join("; ") } });
  }

  if (fields.displayName !== undefined) profile.displayName = (fields.displayName as string).trim();
  if (fields.activeCharacterId !== undefined) {
    profile.activeCharacterId = fields.activeCharacterId as string | null;
  }
  if (fields.colorMode !== undefined) {
    profile.colorMode = fields.colorMode as UserProfile["colorMode"];
  }
  if (fields.weightKg !== undefined) profile.weightKg = fields.weightKg as number;
  if (fields.heightCm !== undefined) profile.heightCm = fields.heightCm as number;
  if (fields.bodyType !== undefined) profile.bodyType = fields.bodyType as string;
  if (fields.age !== undefined) profile.age = fields.age as number;
  if (fields.sex !== undefined) profile.sex = fields.sex as Sex;
  if (fields.activity !== undefined) profile.activity = fields.activity as Activity;
  if (fields.goal !== undefined) profile.goal = fields.goal as Goal;
  for (const key of ["calorieTarget", "proteinTargetG", "carbsTargetG", "fatTargetG"] as const) {
    if (fields[key] !== undefined) profile[key] = fields[key] as number;
  }
  if (fields.watchOptIn !== undefined) profile.watchOptIn = fields.watchOptIn as boolean;
  profile.updatedAt = new Date().toISOString();
  saveProfile(req.playerId!, profile);

  // Best-effort mirror: a weight update is a weigh-in -> body_metrics hypertable.
  if (hasDatabaseUrl() && fields.weightKg !== undefined) {
    const loggedAt = new Date().toISOString();
    enqueueMirror("body_metric", `${req.playerId!}:${loggedAt}`, {
      playerId: req.playerId!,
      metric: { loggedAt, weightKg: fields.weightKg as number, source: "manual" },
    });
  }

  res.json({ profile });
});

/** PATCH /user/:id — full nutrition-profile write. All six Mifflin-St Jeor
 *  inputs are required so a save from the Body & goals editor is a complete
 *  profile, not a sparse merge. PUT stays the displayName / colorMode path. */
userRouter.patch(
  "/:id",
  rateLimitByPlayer({ windowMs: 60_000, max: 20, keyPrefix: "user", message: "Too many profile updates. Try again later." }),
  (req: PlayerRequest, res) => {
    if (!requireOwnId(req, res)) return;
    const parsed = profileUpsertSchema.safeParse(req.body);
    if (!parsed.success) {
      const message = parsed.error.issues
        .map((issue) => `${issue.path.join(".") || "body"}: ${issue.message}`)
        .join("; ");
      return res.status(400).json({ error: { code: "VALIDATION", message } });
    }

    const profile = getOrCreate(req.playerId!);
    const { age, sex, heightCm, weightKg, activity, goal } = parsed.data;
    profile.age = age;
    profile.sex = sex;
    profile.heightCm = heightCm;
    profile.weightKg = weightKg;
    profile.activity = activity;
    profile.goal = goal;
    profile.updatedAt = new Date().toISOString();
    saveProfile(req.playerId!, profile);

    if (hasDatabaseUrl()) {
      const loggedAt = new Date().toISOString();
      enqueueMirror("body_metric", `${req.playerId!}:${loggedAt}`, {
        playerId: req.playerId!,
        metric: { loggedAt, weightKg, source: "manual" },
      });
    }

    res.json({ profile });
  }
);

// GET /user/:id/journey — engagement dashboard. Aggregates scans, drops,
// collection distribution, vitals history and wins into a shape the iOS
// JourneyView can chart directly.

function lootCharacterPayload(character: Character) {
  const tier = RARITY_TIERS[character.rarity];
  return {
    ...character,
    rarityLabel: tier.label,
    rarityColorHex: tier.colorHex
  };
}

function loadScannedCharacters(playerId: string): Character[] {
  return (db
    .prepare(`SELECT payload FROM scan_character WHERE player_id = ?`)
    .all(playerId) as { payload: string }[])
    .map((r) => JSON.parse(r.payload) as Character);
}

function scansByDay(playerId: string): { date: string; count: number }[] {
  return db
    .prepare(
      `SELECT date(seen_at) AS date, COUNT(*) AS count
       FROM scan_seen
       WHERE player_id = ?
       GROUP BY date
       ORDER BY date`
    )
    .all(playerId) as { date: string; count: number }[];
}

function dropsByDay(playerId: string): { date: string; count: number }[] {
  const rows = db
    .prepare(`SELECT payload FROM lootbox_drop WHERE player_id = ?`)
    .all(playerId) as { payload: string }[];
  const byDay = new Map<string, number>();
  for (const row of rows) {
    const drop = JSON.parse(row.payload) as LootDrop;
    const day = drop.openedAt.slice(0, 10);
    byDay.set(day, (byDay.get(day) ?? 0) + 1);
  }
  return [...byDay.entries()]
    .sort(([a], [b]) => a.localeCompare(b))
    .map(([date, count]) => ({ date, count }));
}

function buildJourney(playerId: string, profile: PlayerProfile) {
  const session = stateFor(playerId);
  const scanned = loadScannedCharacters(playerId);
  const drops = session.inventory;

  const allCharacters = [...scanned, ...drops.map((d) => d.character)];
  const unique = [...new Map(allCharacters.map((c) => [c.id, c])).values()];

  const byRarity = new Map<string, number>();
  for (const c of unique) {
    byRarity.set(c.rarity, (byRarity.get(c.rarity) ?? 0) + 1);
  }

  const vitals = vitalsStoreFor(playerId).recent(30).map((s) => ({
    date: s.receivedAt.slice(0, 10),
    steps: s.snapshot.stepsToday == null ? null : Math.round(s.snapshot.stepsToday),
    activeCalories: s.snapshot.activeCaloriesToday == null ? null : Math.round(s.snapshot.activeCaloriesToday),
    heartRate: s.snapshot.heartRateBpm ?? null
  }));

  return {
    profile,
    summary: {
      totalScans: scanned.length,
      totalDrops: drops.length,
      totalCharacters: unique.length,
      totalLootValue: drops.reduce((sum, d) => sum + d.value, 0),
      totalVitalsSnapshots: vitalsStoreFor(playerId).count
    },
    collection: {
      byRarity: [...byRarity.entries()].map(([rarity, count]) => ({ rarity, count })).sort((a, b) => b.count - a.count)
    },
    timeline: {
      scansByDay: scansByDay(playerId),
      dropsByDay: dropsByDay(playerId)
    },
    recentDrops: drops
      .slice(-6)
      .reverse()
      .map((d) => ({
        id: d.id,
        crateId: d.crateId,
        character: lootCharacterPayload(d.character),
        value: d.value,
        stars: d.stars ?? 1,
        openedAt: d.openedAt
      })),
    vitals,
    activity: {
      byDay: activityByDay(vitalsStoreFor(playerId).recent(MAX_SNAPSHOTS))
    }
  };
}

userRouter.get("/:id/journey", (req: PlayerRequest, res) => {
  if (!requireOwnId(req, res)) return;
  const profile = getOrCreate(req.playerId!);
  res.json(buildJourney(req.playerId!, profile));
});
