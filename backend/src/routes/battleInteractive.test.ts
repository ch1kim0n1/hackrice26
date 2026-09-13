import { describe, it, expect, beforeAll, afterAll } from "vitest";
import express from "express";
import { rmSync } from "fs";
import { tmpdir } from "os";
import path from "path";
import { Battle, MAX_TURNS } from "../services/battleEngine";
import type { BattleUnitSpec, ScriptedAction } from "../services/battleEngine";

// ============================================================================
// Interactive battle protocol — begin/commit routes.
//
// Spec §4 battles are player-driven but server-authoritative: /begin locks
// squads + seed, the client plays locally, /commit replays the decision
// script deterministically. These tests pin the wire contract: what begin
// returns, what commit accepts/rejects, and the single-use/expiry guards.
// ============================================================================

const DB_FILE = path.join(tmpdir(), `nutriquest-interactive-${process.pid}-${Date.now()}.db`);

beforeAll(() => {
  process.env.NUTRIQUEST_DB = DB_FILE;
});

afterAll(() => {
  rmSync(DB_FILE, { force: true });
  rmSync(`${DB_FILE}-wal`, { force: true });
  rmSync(`${DB_FILE}-shm`, { force: true });
});

type Call = (method: string, path: string, body?: unknown, player?: string) => Promise<Response>;
let counter = 0;

/** An express app with the battle router and a stocked player. */
async function withBattle(
  run: (call: Call, playerId: string) => Promise<void>,
  stock: { characterId: string; stars?: number; value?: number }[] = []
): Promise<void> {
  const { battleRouter } = await import("./battle");
  const { stateFor } = await import("../services/lootboxState");
  const { testDrop, testCharacter } = await import("../testkit");

  const playerId = `itv_${counter++}_${Date.now()}`;
  const session = stateFor(playerId);
  for (const s of stock) {
    session.record(testDrop({
      crateId: "starter-crate",
      character: testCharacter("common", s.characterId),
      stars: s.stars ?? 1,
      value: s.value ?? 500,
      rolls: { rarity: 0.1, character: 0.1, mintSegment: 0, mintPosition: 0.1 },
      fairness: { serverSeedHash: "hash", clientSeed: "seed", nonce: 0 },
      openedAt: new Date().toISOString()
    })).drop;
  }

  const app = express();
  app.use(express.json());
  app.use("/battle", battleRouter);
  const server = app.listen(0);
  await new Promise<void>((resolve) => server.once("listening", resolve));
  const port = (server.address() as { port: number }).port;
  const call: Call = (method, url, body, player = playerId) =>
    fetch(`http://127.0.0.1:${port}${url}`, {
      method,
      headers: { "Content-Type": "application/json", "X-Player-Id": player },
      body: body === undefined ? undefined : JSON.stringify(body)
    });
  try {
    await run(call, playerId);
  } finally {
    await new Promise<void>((resolve) => server.close(() => resolve()));
  }
}

const STOCK = [
  { characterId: "broccoli-bud" },
  { characterId: "bean-sprout" },
  { characterId: "carrot-cadet" }
];
const SQUAD_BODY = STOCK.map((s) => ({ id: s.characterId, name: s.characterId }));

interface BeginBody {
  matchId: string;
  seed: string;
  opponent?: { bot: boolean; playerId?: string };
  yourSquad: BattleUnitSpec[];
  opponentSquad: BattleUnitSpec[];
}

/** Play the parked match locally the way the honest client does — side A
 *  always picks the first legal move, first living replacement. */
function recordScript(begin: BeginBody): ScriptedAction[] {
  const live = new Battle(begin.yourSquad, begin.opponentSquad, BigInt(begin.seed), {
    firstTurn: "coinFlip",
    manualReplacement: 0
  });
  const script: ScriptedAction[] = [];
  while (!live.finished && live.turn < MAX_TURNS) {
    if (live.needsReplacement(0)) {
      const idx = live.sideState(0).findIndex((u, i) => !u.fainted && i !== live.activeIndex(0));
      script.push({ type: "choose", unitIndex: idx });
      live.chooseReplacement(0, idx);
      continue;
    }
    if (live.currentSide === "A") {
      script.push({ type: "move", moveIndex: 0 });
      live.act(0, { type: "move", moveIndex: 0 });
    } else {
      live.act(1, Battle.defaultPolicy(live, 1));
    }
  }
  return script;
}

describe("interactive battle protocol", () => {
  it("ranked begin parks a match with locked specs + seed", async () => {
    await withBattle(async (call) => {
      const res = await call("POST", "/battle/ranked/begin", { squad: SQUAD_BODY });
      expect(res.status).toBe(200);
      const body = (await res.json()) as BeginBody;
      expect(body.matchId.length).toBeGreaterThan(8);
      expect(/^\d+$/.test(body.seed)).toBe(true);
      expect(body.yourSquad).toHaveLength(3);
      expect(body.opponentSquad).toHaveLength(3);
      for (const u of body.yourSquad) {
        expect(u.moves.length).toBeGreaterThan(0);
        expect(u.baseHealth).toBeGreaterThan(0);
      }
      // Empty queue → a rank-calibrated bot.
      expect(body.opponent?.bot).toBe(true);
    }, STOCK);
  });

  it("a full honest script commits and pays ranked outcomes", async () => {
    await withBattle(async (call) => {
      const begin = (await (await call("POST", "/battle/ranked/begin", { squad: SQUAD_BODY })).json()) as BeginBody;
      const script = recordScript(begin);
      const res = await call("POST", "/battle/ranked/commit", { matchId: begin.matchId, actions: script });
      expect(res.status).toBe(200);
      const body = (await res.json()) as {
        winner: string; events: unknown[]; rank: { delta: number; rr: number };
        faintedA: string[]; opponentSquad: unknown[];
      };
      expect(["A", "B"]).toContain(body.winner);
      expect(body.events.length).toBeGreaterThan(0);
      expect(typeof body.rank.rr).toBe("number");
      expect(body.opponentSquad).toHaveLength(3);
    }, STOCK);
  });

  it("commit rejects an illegal action", async () => {
    await withBattle(async (call) => {
      const begin = (await (await call("POST", "/battle/ranked/begin", { squad: SQUAD_BODY })).json()) as BeginBody;
      const res = await call("POST", "/battle/ranked/commit", {
        matchId: begin.matchId,
        actions: [{ type: "move", moveIndex: 7 }]
      });
      expect(res.status).toBe(400);
      const body = (await res.json()) as { error: { code: string } };
      expect(body.error.code).toBe("ILLEGAL_SCRIPT");
    }, STOCK);
  });

  it("commit rejects a script that stops before the battle ends", async () => {
    await withBattle(async (call) => {
      const begin = (await (await call("POST", "/battle/ranked/begin", { squad: SQUAD_BODY })).json()) as BeginBody;
      const res = await call("POST", "/battle/ranked/commit", {
        matchId: begin.matchId,
        actions: [{ type: "move", moveIndex: 0 }]
      });
      expect(res.status).toBe(400);
      const body = (await res.json()) as { error: { code: string } };
      expect(body.error.code).toBe("ILLEGAL_SCRIPT");
    }, STOCK);
  });

  it("a match is single-use — second commit is gone", async () => {
    await withBattle(async (call) => {
      const begin = (await (await call("POST", "/battle/ranked/begin", { squad: SQUAD_BODY })).json()) as BeginBody;
      const script = recordScript(begin);
      const first = await call("POST", "/battle/ranked/commit", { matchId: begin.matchId, actions: script });
      expect(first.status).toBe(200);
      const second = await call("POST", "/battle/ranked/commit", { matchId: begin.matchId, actions: script });
      expect(second.status).toBe(410);
    }, STOCK);
  });

  it("a consumed-once match can't be re-driven by another player", async () => {
    await withBattle(async (call) => {
      const begin = (await (await call("POST", "/battle/ranked/begin", { squad: SQUAD_BODY })).json()) as BeginBody;
      const res = await call("POST", "/battle/ranked/commit",
        { matchId: begin.matchId, actions: [] }, "someone-else");
      expect(res.status).toBe(410);
    }, STOCK);
  });

  it("friendly begin 404s when the opponent never fielded a squad", async () => {
    await withBattle(async (call) => {
      const res = await call("POST", "/battle/friendly/begin", {
        opponentId: "ghost-player",
        squad: SQUAD_BODY
      });
      expect(res.status).toBe(404);
    }, STOCK);
  });

  it("friendly begin→commit round-trips and stays interactive", async () => {
    await withBattle(async (call, playerId) => {
      // Give the friend a snapshot: any ranked/friendly begin saves one.
      const friendStock = [
        { characterId: "water-droplet" },
        { characterId: "spinach-scout" },
        { characterId: "almond-knight" }
      ];
      const { stateFor } = await import("../services/lootboxState");
      const { testDrop, testCharacter } = await import("../testkit");
      const friend = stateFor("itv-friend");
      for (const s of friendStock) {
        friend.record(testDrop({
          crateId: "starter-crate",
          character: testCharacter("common", s.characterId),
          stars: 1,
          value: 500,
          rolls: { rarity: 0.1, character: 0.1, mintSegment: 0, mintPosition: 0.1 },
          fairness: { serverSeedHash: "hash", clientSeed: "seed", nonce: 0 },
          openedAt: new Date().toISOString()
        }));
      }
      void playerId;
      // The friend fields a squad via ranked begin — setup saves the
      // snapshot that friendly begin then loads.
      await call("POST", "/battle/ranked/begin", {
        squad: friendStock.map((s) => ({ id: s.characterId, name: s.characterId }))
      }, "itv-friend");

      const beginRes = await call("POST", "/battle/friendly/begin", {
        opponentId: "itv-friend",
        squad: SQUAD_BODY
      });
      expect(beginRes.status).toBe(200);
      const begin = (await beginRes.json()) as BeginBody;
      const script = recordScript(begin);
      const commit = await call("POST", "/battle/friendly/commit", {
        matchId: begin.matchId, actions: script
      });
      expect(commit.status).toBe(200);
      const body = (await commit.json()) as { winner: string; opponentId: string };
      expect(["A", "B"]).toContain(body.winner);
      expect(body.opponentId).toBe("itv-friend");
    }, STOCK);
  });
});
