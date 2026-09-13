import { describe, it, expect, beforeAll, afterAll } from "vitest";
import express from "express";
import { rmSync } from "fs";
import { tmpdir } from "os";
import path from "path";

// ============================================================================
// Ranked battle -> rank points/XP/fatigue, end to end over real HTTP against
// a real SQLite file (same harness as mines.test.ts).
//
// The win case is a regression test: /battle/ranked used to fetch `profile`
// once at the top for tier lookup, then reuse that same stale object at the
// end of the handler to bump battlesWon and save -- silently overwriting the
// rank-point and XP awards that awardRankPoints/awardXP had just persisted
// moments earlier via their own independent getOrCreate/saveProfile calls.
// Every ranked win or loss was granting rank points and XP that vanished
// before the response even went out. This test fails on that regression.
// ============================================================================

const DB_FILE = path.join(tmpdir(), `nutriquest-ranked-${process.pid}-${Date.now()}.db`);

beforeAll(() => {
  process.env.NUTRIQUEST_DB = DB_FILE;
});

afterAll(() => {
  rmSync(DB_FILE, { force: true });
  rmSync(`${DB_FILE}-wal`, { force: true });
  rmSync(`${DB_FILE}-shm`, { force: true });
});

type Call = (method: string, url: string, playerId: string, body?: unknown) => Promise<Response>;

let counter = 0;
function freshPlayerId(): string {
  return `ranked_${counter++}_${Date.now()}`;
}

async function withApp(run: (call: Call) => Promise<void>): Promise<void> {
  const { battleRouter } = await import("./battle");
  const { userRouter } = await import("./user");
  const { db } = await import("../db");

  // Ranked matchmaking (battle.ts) picks the closest-power same-tier squad
  // from *any* player's last snapshot. Every test's fresh, deliberately
  // extreme squad (near 0 or maxed) would otherwise out-match a real bot for
  // a later test's squad at the same extreme, making outcomes depend on test
  // order. Each test gets an empty pool so its first ranked call always
  // fights a bot; a test's own later calls still see its own snapshot, which
  // matchmaking already excludes via `player_id != ?`.
  db.exec("DELETE FROM friend_squad");

  const app = express();
  app.use(express.json());
  app.use("/battle", battleRouter);
  app.use("/user", userRouter);

  const server = app.listen(0);
  await new Promise<void>((resolve) => server.once("listening", resolve));
  const port = (server.address() as { port: number }).port;

  const call: Call = (method, url, playerId, body) =>
    fetch(`http://127.0.0.1:${port}${url}`, {
      method,
      headers: { "Content-Type": "application/json", "X-Player-Id": playerId },
      body: body === undefined ? undefined : JSON.stringify(body)
    });

  try {
    await run(call);
  } finally {
    await new Promise<void>((resolve) => server.close(() => resolve()));
  }
}

// Battles now resolve strength server-side from the player's real collection
// (battle.ts resolveOwnUnit/trustedToSim, added alongside the cartoony QA
// pass) -- a client can no longer hand the sim fabricated power/guard/etc.
// So instead of forcing outcomes with extreme stats, these squads use real
// starter ids (data/sampleCharacters.ts) and lean on a *structural* edge
// (rarity, or fielding fewer units than the bot) plus a small retry loop to
// absorb ordinary battle RNG (crit/miss/variance/turn order).

function unit(id: string, name: string, statType: "protein" | "fiber" | "vitamin" | "hydration") {
  return { id, name, statType };
}

// All three starters above common rarity (rare/epic/legendary) vs a
// bronze-tier bot's three commons -- a large, structural rarity-multiplier
// edge (docs/BATTLE-SYSTEM.md §2: common x1.0 .. legendary x1.4).
const STRONG_SQUAD = [
  unit("sushi-sam", "Sushi Sam", "protein"),
  unit("berry-belle", "Berry Belle", "vitamin"),
  unit("grape-gus", "Grape Gus", "hydration")
];

// A single common starter alone vs the bot's three -- fewer possible
// survivors is a structural disadvantage in the elimination-style sim.
const WEAK_SQUAD = [unit("broccoli-bud", "Broccoli Bud", "fiber")];

/** Retry a ranked call with the same player/squad until `winner` matches, or give up. */
async function rankedUntil(
  call: Call,
  playerId: string,
  squad: ReturnType<typeof unit>[],
  winner: "A" | "B",
  maxAttempts = 8
): Promise<{ res: Response; body: any; attempts: number; wins: number; losses: number }> {
  let wins = 0;
  let losses = 0;
  for (let attempt = 1; attempt <= maxAttempts; attempt++) {
    const res = await call("POST", "/battle/ranked", playerId, { squad });
    const body = (await res.json()) as any;
    if (res.status === 409) {
      // An unlucky earlier loss fatigued the squad mid-retry. The loss-side
      // tests return before ever retrying past their first loss, so this
      // only fires while chasing a win -- fail loudly rather than return a
      // response shaped like a battle result when it isn't one.
      throw new Error(`Squad fatigued after ${attempt - 1} attempt(s) while retrying toward "${winner}"`);
    }
    if (body.winner === "A") wins++;
    else losses++;
    if (body.winner === winner) return { res, body, attempts: attempt, wins, losses };
  }
  throw new Error(`Never got a "${winner}" outcome in ${maxAttempts} attempts`);
}

describe("POST /battle/ranked — award persistence + fatigue (#67)", () => {
  it("a win persists rank points, XP, and battlesWon together (regression: these used to be clobbered)", async () => {
    await withApp(async (call) => {
      const playerId = freshPlayerId();
      const { body, wins, losses } = await rankedUntil(call, playerId, STRONG_SQUAD, "A");
      expect(body.winner).toBe("A");
      expect(body.rank.applied).toBeGreaterThan(0);

      const profileRes = await call("GET", `/user/${playerId}`, playerId);
      const profile = (await profileRes.json()) as {
        profile: { rankPoints: number; xp: number; battlesWon: number };
        rank: { points: number };
      };
      expect(profile.profile.rankPoints).toBeGreaterThan(0);
      expect(profile.profile.xp).toBeGreaterThan(0);
      // Every win in the retry loop (including any losses along the way)
      // actually persisted -- the point of this regression test.
      expect(profile.profile.battlesWon).toBe(wins);
      expect(losses).toBeGreaterThanOrEqual(0);
      expect(profile.rank.points).toBe(profile.profile.rankPoints);
    });
  });

  it("a loss deducts rank points, fatigues the squad, and blocks the next ranked battle", async () => {
    await withApp(async (call) => {
      const playerId = freshPlayerId();
      const { body } = await rankedUntil(call, playerId, WEAK_SQUAD, "B");
      expect(body.winner).toBe("B");
      // A fresh player's points floor at 0 (rankTiers.ts), so a first-ever
      // loss can show `applied: 0` rather than negative -- assert it never
      // goes the wrong way instead of assuming headroom to lose from.
      expect(body.rank.applied).toBeLessThanOrEqual(0);
      expect(body.fatigue.fatigued).toBe(true);
      expect(body.fatigue.until).not.toBeNull();

      const blocked = await call("POST", "/battle/ranked", playerId, { squad: STRONG_SQUAD });
      expect(blocked.status).toBe(409);
      const blockedBody = (await blocked.json()) as { error: { code: string } };
      expect(blockedBody.error.code).toBe("SQUAD_FATIGUED");
    });
  });

  it("claiming a completed daily quest clears fatigue early", async () => {
    const { questsForDay, todayKey } = await import("../game/quests");
    const { db } = await import("../db");

    await withApp(async (call) => {
      const playerId = freshPlayerId();
      // Fatigue the squad first.
      const { body: lossBody } = await rankedUntil(call, playerId, WEAK_SQUAD, "B");
      expect(lossBody.fatigue.fatigued).toBe(true);

      const quest = questsForDay(todayKey())[0];
      if (quest.kind === "scans") {
        for (let i = 0; i < quest.target; i++) {
          db.prepare(`INSERT OR REPLACE INTO scan_seen (player_id, barcode, seen_at) VALUES (?, ?, ?)`)
            .run(playerId, `test-barcode-${i}`, new Date().toISOString());
        }
      } else {
        for (let i = 0; i < quest.target; i++) {
          db.prepare(`INSERT INTO lootbox_drop (player_id, payload) VALUES (?, ?)`)
            .run(playerId, JSON.stringify({ openedAt: new Date().toISOString() }));
        }
      }

      const claimRes = await call("POST", `/user/quests/${quest.id}/claim`, playerId);
      expect(claimRes.status).toBe(200);
      const claimBody = (await claimRes.json()) as { fatigue: { fatigued: boolean; until: string | null } };
      expect(claimBody.fatigue.fatigued).toBe(false);
      expect(claimBody.fatigue.until).toBeNull();

      const retry = await call("POST", "/battle/ranked", playerId, { squad: STRONG_SQUAD });
      expect(retry.status).toBe(200);
    });
  });
});

describe("GET /user/leaderboard?sort=rank", () => {
  it("sorts by rank points instead of battles won", async () => {
    await withApp(async (call) => {
      const playerA = freshPlayerId();
      const playerB = freshPlayerId();

      // Outcome doesn't matter here -- just needs two players with some
      // rank-points value on the books to check sort order against.
      await call("POST", "/battle/ranked", playerA, { squad: STRONG_SQUAD });
      await call("POST", "/battle/ranked", playerB, { squad: WEAK_SQUAD });

      const res = await call("GET", "/user/leaderboard?sort=rank", playerA);
      expect(res.status).toBe(200);
      const body = (await res.json()) as {
        sort: string;
        entries: { id: string; rankPoints: number; rankTier: string }[];
      };
      expect(body.sort).toBe("rank");
      for (let i = 1; i < body.entries.length; i++) {
        expect(body.entries[i - 1].rankPoints).toBeGreaterThanOrEqual(body.entries[i].rankPoints);
      }
      expect(body.entries.every((e) => typeof e.rankTier === "string")).toBe(true);
    });
  });
});
