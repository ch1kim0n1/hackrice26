import { Router, Response } from "express";
import { UserProfile, Character, LootDrop } from "../types";
import { PlayerRequest, requirePlayerId } from "../middleware/player";
import { db } from "../db";
import { stateFor } from "../services/lootboxState";
import { vitalsStoreFor } from "../vitals/vitalsStore";
import { rateLimitByPlayer } from "../middleware/security";
import { CHARACTERS, RARITY_TIERS, CHARACTER_FLAVOR, CRATES } from "../data/lootTable";
import { questStatuses, claimQuest, todayKey } from "../game/quests";
import { hasDatabaseUrl } from "../db/pg";
import { openCrate, advancePity } from "../services/lootboxEngine";
import { characterPayload } from "./lootbox";
import { RankTier, tierForPoints, pointsToNextTier } from "../game/rankTiers";
import { awardCapped, RP_PER_QUEST } from "../game/rankPoints";
import { rollSeason, seasonNumber } from "../game/rankSeason";
import { isFatigued } from "../game/fatigue";
import { bmi, bmiBand } from "../game/targets";
import { goalProfileFor } from "../game/goals";
import { Activity, Goal, Sex, bodyVitals } from "../vitals/bodyMetrics";
import { enqueueMirror } from "../services/mirrorQueue";
import { profileUpsertSchema } from "../schemas/gameSchemas";

export const userRouter = Router();
userRouter.use(requirePlayerId);

/**
 * Per-player profile store. Keyed by the X-Player-Id header (or the :id param,
 * which must match). Persisted to SQLite so profiles survive restarts
 * (issue #23).
 *
 * Response shapes are unchanged from the original hardcoded version:
 * GET returns { profile: UserProfile } — additive fields only.
 */

interface PlayerProfile extends UserProfile {
  createdAt: string;
  updatedAt: string;
  /** Consistency ladder (#82/#83): points + derived tier, server-managed. */
  rankPoints?: number;
  rankTier?: RankTier;
  /** UTC day + amount already earned — the award cap's bookkeeping (#83). */
  rankDay?: string;
  rankEarnedToday?: number;
  /** Last season number this profile was reconciled against (rankSeason.ts).
   *  Never null after creation; awardRankPoints rolls it forward lazily. */
  rankSeason?: number;
  /** Ranked-loss squad fatigue (#67): set to a future ISO timestamp on a
   *  ranked loss, cleared early by claiming any daily quest. Null/absent
   *  means not fatigued. */
  squadFatigueUntil?: string | null;
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
}

// ===== XP / progression =====
//
// Total-lifetime-xp model: each level costs more than the last, so early
// levels come fast and later ones stretch. Level n costs
// `XP_BASE + XP_STEP * (n - 1)` points. xp() on the profile is lifetime
// total; level and into-level progress are always derived, never stored,
// so the two can never drift apart.
const XP_BASE = 100;
const XP_STEP = 50;

export function xpForLevel(level: number): number {
  return XP_BASE + XP_STEP * (level - 1);
}

export function xpProgression(totalXp: number): {
  level: number; xp: number; xpIntoLevel: number; xpForLevel: number; progress: number;
} {
  let level = 1;
  let remaining = Math.max(0, totalXp);
  while (remaining >= xpForLevel(level)) {
    remaining -= xpForLevel(level);
    level += 1;
  }
  return { level, xp: totalXp, xpIntoLevel: remaining, xpForLevel: xpForLevel(level), progress: remaining / xpForLevel(level) };
}

/** Award XP and persist the derived level. Centralized so every route
 *  grants through one funnel — XP sources stay tunable in one place. */
export function awardXP(playerId: string, amount: number, reason: string): void {
  const profile = getOrCreate(playerId);
  profile.xp = (profile.xp ?? 0) + Math.max(0, amount);
  const prog = xpProgression(profile.xp);
  const leveled = prog.level > profile.level;
  profile.level = prog.level;
  profile.updatedAt = new Date().toISOString();
  saveProfile(playerId, profile);
  if (leveled) {
    console.log(`[xp] ${playerId} reached level ${prog.level} via ${reason}`);
  }
}

/** Award consistency rank points, capped per UTC day (#83). Centralized like
 *  awardXP — every award path goes through here so the cap holds. Returns
 *  the applied delta and tier change for the caller to surface. */
export function awardRankPoints(playerId: string, amount: number, reason: string) {
  const profile = getOrCreate(playerId);

  // Season rollover (#67, rankSeason.ts) happens before the new delta so a
  // reward reflects the tier held going into the boundary, not one diluted
  // by the event that triggered this call.
  const priorSeason = profile.rankSeason ?? null;
  const rollover = rollSeason(priorSeason, profile.rankPoints ?? 0, Date.now());
  if (rollover.season !== priorSeason) {
    profile.rankPoints = rollover.rankPoints;
    profile.rankTier = tierForPoints(rollover.rankPoints);
    profile.rankSeason = rollover.season;
    if (rollover.reward > 0) {
      stateFor(playerId).grantKeys(rollover.reward);
      console.log(`[rank] ${playerId} season closed at ${rollover.tierAtClose}: +${rollover.reward} keys`);
    }
  }

  const today = todayKey();
  // New day resets the earned counter; points themselves never reset daily.
  const earnedToday = profile.rankDay === today ? (profile.rankEarnedToday ?? 0) : 0;
  const { state, earnedToday: earned, change } = awardCapped(
    { rankPoints: profile.rankPoints ?? 0, rankTier: profile.rankTier ?? "bronze" },
    earnedToday,
    amount
  );
  const applied = state.rankPoints - (profile.rankPoints ?? 0);
  profile.rankPoints = state.rankPoints;
  profile.rankTier = state.rankTier;
  profile.rankDay = today;
  profile.rankEarnedToday = earned;
  profile.updatedAt = new Date().toISOString();
  saveProfile(playerId, profile);
  if (change.direction !== "none") {
    console.log(`[rank] ${playerId} ${change.direction}: ${change.from} -> ${change.to} via ${reason}`);
  }
  return { applied, earnedToday: earned, state, change, season: profile.rankSeason };
}

/** Public rank block for responses — badge + progress bar inputs. */
function rankBlock(profile: PlayerProfile) {
  const points = profile.rankPoints ?? 0;
  return {
    points,
    tier: tierForPoints(points),
    pointsToNextTier: pointsToNextTier(points),
    season: profile.rankSeason ?? seasonNumber(Date.now())
  };
}

/** Public fatigue block — whether ranked battles are currently blocked. */
export function fatigueBlock(profile: PlayerProfile) {
  const until = profile.squadFatigueUntil ?? null;
  return { fatigued: isFatigued(until, Date.now()), until };
}

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
    rankPoints: 0,
    rankTier: "bronze",
    rankSeason: seasonNumber(Date.now()),
    squadFatigueUntil: null,
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

/** GET /user/leaderboard?sort=wins|rank -- global ranking, "wins" (battles
 *  won) by default, "rank" for the consistency ladder (points + tier).
 *  Registered before /:id so "leaderboard" is not swallowed by the :id
 *  param. Read-only and privacy-safe: exposes display name + competitive
 *  stats only. Every entry carries rank fields regardless of sort mode so a
 *  wins-sorted view can still show a tier badge. */
userRouter.get("/leaderboard", (req: PlayerRequest, res) => {
  const sort = req.query.sort === "rank" ? "rank" : "wins";
  const rows = db
    .prepare(`SELECT player_id, payload FROM user_profile`)
    .all() as { player_id: string; payload: string }[];
  const entries = rows
    .map((r) => JSON.parse(r.payload) as PlayerProfile)
    .map((p) => ({
      id: p.id,
      displayName: p.displayName,
      level: p.level,
      battlesWon: p.battlesWon,
      streakDays: p.streakDays,
      rankPoints: p.rankPoints ?? 0,
      rankTier: tierForPoints(p.rankPoints ?? 0),
      isYou: p.id === req.playerId
    }))
    .sort(
      sort === "rank"
        ? (a, b) => b.rankPoints - a.rankPoints || b.battlesWon - a.battlesWon
        : (a, b) => b.battlesWon - a.battlesWon || b.level - a.level
    )
    .slice(0, 50)
    .map((e, i) => ({ rank: i + 1, ...e }));
  res.json({ entries, sort });
});

/** GET /user/quests/today -- the day's three quests with server-verified
 *  progress. Registered before /:id so "quests" is not swallowed by it. */
userRouter.get("/quests/today", (req: PlayerRequest, res) => {
  res.json({ day: todayKey(), quests: questStatuses(req.playerId!) });
});

/** POST /user/quests/:questId/claim -- verified completion -> key reward.
 *  One claim per (player, day, quest); double-claims 409. */
userRouter.post("/quests/:questId/claim", rateLimitByPlayer({ windowMs: 60_000, max: 10, keyPrefix: "quest", message: "Too many quest claims." }), (req: PlayerRequest, res) => {
  try {
    const result = claimQuest(req.playerId!, req.params.questId);
    // Consistency ladder: a claimed quest is verified healthy-day progress.
    const rank = awardRankPoints(req.playerId!, RP_PER_QUEST, `quest:${req.params.questId}`);
    // Recovery quest (#67): any verified daily quest clears ranked-loss
    // fatigue early, same as the design doc's "balanced meal" recovery path.
    const profile = getOrCreate(req.playerId!);
    if (profile.squadFatigueUntil) {
      profile.squadFatigueUntil = null;
      profile.updatedAt = new Date().toISOString();
      saveProfile(req.playerId!, profile);
    }
    if (hasDatabaseUrl()) {
      // One claim per quest per day, so quest+day is the event's own identity.
      const claimDay = new Date().toISOString().slice(0, 10);
      enqueueMirror(
        "gameplay_event",
        `quest_claim:${req.playerId!}:${req.params.questId}:${claimDay}`,
        {
          playerId: req.playerId!,
          type: "quest_claim",
          detail: { questId: req.params.questId },
        }
      );
    }
    res.json({ ...result, rank, fatigue: fatigueBlock(profile) });
  } catch (err: any) {
    const status: Record<string, number> = {
      QUEST_NOT_TODAY: 404,
      QUEST_INCOMPLETE: 409,
      QUEST_ALREADY_CLAIMED: 409
    };
    res.status(status[err.message] ?? 400).json({ error: { code: err.message, message: err.message } });
  }
});

// --- Comeback crate ---------------------------------------------------------
//
// A player gone >3 days gets one free starter-crate pull on return. The
// profile GET is the session heartbeat: eligibility is decided BEFORE the
// touch updates last_seen_at, and a pending flag is persisted so the later
// claim request cannot lose the moment to the touch that created it.

const COMEBACK_GAP_MS = 3 * 24 * 60 * 60 * 1000;

interface SeenRow {
  last_seen_at: string;
  comeback_pending_at: string | null;
  comeback_claimed_at: string | null;
}

/** Touch the player and report whether a comeback crate is pending. */
function touchSeen(playerId: string): { eligible: boolean; daysAway: number } {
  const now = new Date();
  const row = db
    .prepare(`SELECT last_seen_at, comeback_pending_at, comeback_claimed_at FROM player_seen WHERE player_id = ?`)
    .get(playerId) as SeenRow | undefined;

  if (!row) {
    db.prepare(`INSERT INTO player_seen (player_id, last_seen_at) VALUES (?, ?)`).run(playerId, now.toISOString());
    return { eligible: false, daysAway: 0 };
  }

  const daysAway = (now.getTime() - new Date(row.last_seen_at).getTime()) / 86_400_000;
  let pending = row.comeback_pending_at !== null;

  // Long absence and no pending crate -> arm one. A pending crate survives
  // subsequent touches until claimed.
  if (now.getTime() - new Date(row.last_seen_at).getTime() >= COMEBACK_GAP_MS && !pending) {
    db.prepare(`UPDATE player_seen SET comeback_pending_at = ? WHERE player_id = ?`)
      .run(now.toISOString(), playerId);
    pending = true;
  }

  db.prepare(`UPDATE player_seen SET last_seen_at = ? WHERE player_id = ?`)
    .run(now.toISOString(), playerId);
  return { eligible: pending, daysAway: Math.floor(daysAway) };
}

/** GET /user/:id -- profile plus the accent-color rule inputs. Creates the
 *  profile on first access with per-player defaults (no more shared hardcoded
 *  "Trainer Arca" for every id). */
userRouter.get("/:id", (req: PlayerRequest, res) => {
  if (!requireOwnId(req, res)) return;
  const profile = getOrCreate(req.playerId!);
  const comeback = touchSeen(req.playerId!);
  res.json({
    profile,
    progression: xpProgression(profile.xp ?? 0),
    comeback,
    rank: rankBlock(profile),
    fatigue: fatigueBlock(profile)
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

/** POST /user/comeback/claim -- spend the pending welcome-back crate.
 *  A free starter-crate pull: no key spend, same commit-reveal fairness as
 *  a paid open. 409 when nothing is pending. */
userRouter.post("/comeback/claim", rateLimitByPlayer({ windowMs: 60_000, max: 10, keyPrefix: "comeback", message: "Too many comeback claims." }), (req: PlayerRequest, res) => {
  const playerId = req.playerId!;
  const row = db
    .prepare(`SELECT comeback_pending_at FROM player_seen WHERE player_id = ?`)
    .get(playerId) as { comeback_pending_at: string | null } | undefined;

  if (!row?.comeback_pending_at) {
    return res.status(409).json({ error: { code: "NO_COMEBACK", message: "No welcome-back crate is pending." } });
  }

  const crate = CRATES["starter-crate"];
  const session = stateFor(playerId);
  const pair = session.current;
  const nonce = session.consumeNonce();
  // Rank-scaled odds apply to the free pull too (#86).
  const outcome = openCrate(crate, pair.serverSeed, pair.clientSeed, nonce, {
    sinceEpic: session.sinceEpic,
    sinceLegendary: session.sinceLegendary
  }, tierForPoints(getOrCreate(playerId).rankPoints ?? 0));

  const next = advancePity(
    { sinceEpic: session.sinceEpic, sinceLegendary: session.sinceLegendary },
    outcome.character.rarity
  );
  session.sinceEpic = next.sinceEpic;
  session.sinceLegendary = next.sinceLegendary;

  db.prepare(`UPDATE player_seen SET comeback_pending_at = NULL, comeback_claimed_at = datetime('now') WHERE player_id = ?`)
    .run(playerId);

  const drop = {
    crateId: crate.id,
    character: outcome.character,
    // Every monster instance carries its mastery, so the planned fusion
    // system is never handed an inventory where half the rows have no
    // stars at all. A fresh pull is always 1 star.
    stars: 1,
    power: outcome.power,
    powerLabel: outcome.powerLabel,
    shiny: outcome.shiny,
    value: outcome.value,
    rolls: outcome.rolls,
    pityForced: outcome.pityForced,
    fairness: session.fairnessFor(pair, nonce),
    openedAt: outcome.openedAt
  };
  session.record(drop);

  res.json({
    ...drop,
    character: characterPayload(outcome.character.id),
    reel: outcome.reel.map((c) => characterPayload(c)),
    reelWinnerIndex: outcome.reelWinnerIndex,
    keysRemaining: session.keys
  });
});

/** PUT /user/:id -- partial update. Additive route; GET shape untouched.
 *  Only whitelisted client-writable fields accepted: displayName,
 *  activeCharacterId, colorMode. Server-managed fields (level, streakDays,
 *  battlesWon) are rejected to prevent self-ranking abuse. */
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
  const serverManaged = ["level", "xp", "streakDays", "battlesWon", "rankPoints", "rankTier", "rankDay", "rankEarnedToday", "rankSeason", "squadFatigueUntil"] as const;
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

// GET /user/:id/journey — entertainment/engagement dashboard.
// Aggregates everything we know about this player: scans, crate pulls,
// collection distribution, vitals history, and wins. Returned in a shape
// the iOS JourneyView can chart directly.

function lootCharacterPayload(id: string) {
  const character = CHARACTERS[id];
  const tier = RARITY_TIERS[character.rarity];
  return {
    ...character,
    rarityLabel: tier.label,
    rarityColorHex: tier.colorHex,
    flavor: CHARACTER_FLAVOR[id] ?? ""
  };
}

function loadScannedCharacters(playerId: string): Character[] {
  return (db
    .prepare(`SELECT payload FROM scan_character WHERE player_id = ?`)
    .all(playerId) as any[])
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

function cratesByDay(playerId: string): { date: string; count: number }[] {
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
  const byElement = new Map<string, number>();
  for (const c of unique) {
    byRarity.set(c.rarity, (byRarity.get(c.rarity) ?? 0) + 1);
    byElement.set(c.statType, (byElement.get(c.statType) ?? 0) + 1);
  }

  const vitals = vitalsStoreFor(playerId).recent(30).map((s) => ({
    date: s.receivedAt.slice(0, 10),
    steps: s.snapshot.stepsToday ?? null,
    activeCalories: s.snapshot.activeCaloriesToday ?? null,
    heartRate: s.snapshot.heartRateBpm ?? null
  }));

  return {
    profile,
    summary: {
      totalScans: scanned.length,
      totalCrateOpens: drops.length,
      totalCharacters: unique.length,
      currentKeys: session.keys,
      totalLootValue: drops.reduce((sum, d) => sum + d.value, 0),
      totalVitalsSnapshots: vitalsStoreFor(playerId).count
    },
    collection: {
      byRarity: [...byRarity.entries()].map(([rarity, count]) => ({ rarity, count })).sort((a, b) => b.count - a.count),
      byElement: [...byElement.entries()].map(([element, count]) => ({ element, count })).sort((a, b) => b.count - a.count)
    },
    timeline: {
      scansByDay: scansByDay(playerId),
      cratesByDay: cratesByDay(playerId)
    },
    recentDrops: drops
      .slice(-6)
      .reverse()
      .map((d) => ({
        crateId: d.crateId,
        character: lootCharacterPayload(d.character.id),
        power: d.power,
        powerLabel: d.powerLabel,
        shiny: d.shiny,
        value: d.value,
        openedAt: d.openedAt
      })),
    vitals
  };
}

userRouter.get("/:id/journey", (req: PlayerRequest, res) => {
  if (!requireOwnId(req, res)) return;
  const profile = getOrCreate(req.playerId!);
  res.json(buildJourney(req.playerId!, profile));
});
