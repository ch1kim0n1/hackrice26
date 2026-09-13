import { describe, it, expect, beforeAll, afterAll } from "vitest";
import express from "express";
import { rmSync } from "fs";
import { tmpdir } from "os";
import path from "path";

// ============================================================================
// Portal Wheel — one call, one outcome.
//
// There is no live round to protect, so what matters here is that the monster is
// spent exactly once, that the answer is internally consistent (the section the
// pointer stopped on really is the colour the result claims won), and that the
// published odds describe the wheel the client is actually being sent.
// ============================================================================

const DB_FILE = path.join(tmpdir(), `nutriquest-wheel-${process.pid}-${Date.now()}.db`);

beforeAll(() => {
  process.env.NUTRIQUEST_DB = DB_FILE;
});

afterAll(() => {
  rmSync(DB_FILE, { force: true });
  rmSync(`${DB_FILE}-wal`, { force: true });
  rmSync(`${DB_FILE}-shm`, { force: true });
});

type Call = (method: string, path: string, body?: unknown) => Promise<Response>;

let counter = 0;

async function withPlayer(
  run: (call: Call, monsters: { id: string; netWorth: number }[]) => Promise<void>,
  count = 12
): Promise<void> {
  const { portalWheelRouter } = await import("./portalWheel");
  const { stateFor } = await import("../services/lootboxState");
  const { testDrop, testCharacter } = await import("../testkit");

  const playerId = `wheel_${counter++}_${Date.now()}`;
  const session = stateFor(playerId);

  const seeded = Array.from({ length: count }, (_, i) =>
    session.record(testDrop({
      crateId: "starter-crate",
      character: testCharacter("common", "salmon-striker"),
      value: 20_000,
      rolls: { rarity: 0.1, character: 0.1, mintSegment: 0, mintPosition: 0.1 },
      fairness: { serverSeedHash: "hash", clientSeed: "seed", nonce: i },
      openedAt: new Date().toISOString()
    })).drop
  );

  const app = express();
  app.use(express.json());
  app.use("/portal-wheel", portalWheelRouter);

  const server = app.listen(0);
  await new Promise<void>((resolve) => server.once("listening", resolve));
  const port = (server.address() as { port: number }).port;

  const call: Call = (method, url, body) =>
    fetch(`http://127.0.0.1:${port}${url}`, {
      method,
      headers: { "Content-Type": "application/json", "X-Player-Id": playerId },
      body: body === undefined ? undefined : JSON.stringify(body)
    });

  try {
    await run(call, seeded.map((d) => ({ id: d.id, netWorth: d.value })));
  } finally {
    await new Promise<void>((resolve) => server.close(() => resolve()));
  }
}

interface Spin {
  spinId: string;
  wagerValue: number;
  pick: string;
  section: number;
  winningColor: string;
  won: boolean;
  multiplier: number;
  finalNetWorth: number;
  rarity: string | null;
  reward: { id: string; stars: number; netWorth: number } | null;
}

interface Config {
  houseEdge: number;
  worstHouseEdge: number;
  totalSections: number;
  wagerMonsters: number;
  layout: string[];
  colors: {
    color: string;
    label: string;
    colorHex: string;
    sections: number;
    totalSections: number;
    sectionIndexes: number[];
    probability: number;
    multiplier: number;
    houseEdge: number;
  }[];
  howItWorks: string;
}

describe("spinning", () => {
  it("spends the monster and returns a consistent outcome", async () => {
    await withPlayer(async (call, monsters) => {
      const response = await call("POST", "/portal-wheel/spins", {
        dropId: monsters[0].id,
        color: "green"
      });
      expect(response.status).toBe(201);
      const { spin } = (await response.json()) as { spin: Spin };

      const config = (await (await call("GET", "/portal-wheel/config")).json()) as Config;

      expect(spin.pick).toBe("green");
      // The section the pointer stopped on must be the colour the result
      // claims -- this is what lets the client spin the wheel to that wedge
      // instead of animating something it made up.
      expect(spin.section).toBeGreaterThanOrEqual(0);
      expect(spin.section).toBeLessThan(config.totalSections);
      expect(config.layout[spin.section]).toBe(spin.winningColor);
      expect(spin.won).toBe(spin.winningColor === "green");
      expect(spin.finalNetWorth).toBe(spin.won ? Math.floor(20_000 * spin.multiplier) : 0);

      const state = (await (await call("GET", "/portal-wheel/state")).json()) as {
        wagerable: { id: string }[];
      };
      expect(state.wagerable.map((m) => m.id)).not.toContain(monsters[0].id);
    });
  });

  it("mints a new monster on the chosen colour and nothing on any other", async () => {
    await withPlayer(async (call, monsters) => {
      // Green is 7/16, so a dozen spins sees wins and losses either way.
      let wins = 0;
      let losses = 0;

      for (const monster of monsters) {
        const { spin } = (await (
          await call("POST", "/portal-wheel/spins", { dropId: monster.id, color: "green" })
        ).json()) as { spin: Spin };

        if (spin.won) {
          wins++;
          expect(spin.finalNetWorth).toBeGreaterThan(0);
          expect(spin.reward).not.toBeNull();
          expect(spin.reward!.stars).toBe(1);
          expect(spin.rarity).not.toBeNull();
          // The reward is a NEW instance, never the wagered one handed back.
          expect(spin.reward!.id).not.toBe(monster.id);
        } else {
          losses++;
          expect(spin.finalNetWorth).toBe(0);
          expect(spin.reward).toBeNull();
          expect(spin.rarity).toBeNull();
        }
      }

      expect(wins).toBeGreaterThan(0);
      expect(wins + losses).toBe(monsters.length);
    });
  });

  it("cannot spend the same monster twice", async () => {
    await withPlayer(async (call, monsters) => {
      const first = await call("POST", "/portal-wheel/spins", {
        dropId: monsters[0].id,
        color: "blue"
      });
      expect(first.status).toBe(201);
      // The monster is gone, so a replayed request has nothing to spend --
      // which is also what a refresh mid-animation would try to do.
      const replay = await call("POST", "/portal-wheel/spins", {
        dropId: monsters[0].id,
        color: "blue"
      });
      expect(replay.status).toBe(409);
    });
  });

  it("refuses a monster that isn't yours, and spends nothing", async () => {
    await withPlayer(async (call, monsters) => {
      const response = await call("POST", "/portal-wheel/spins", {
        dropId: "not-a-real-monster",
        color: "red"
      });
      expect(response.status).toBe(409);

      const state = (await (await call("GET", "/portal-wheel/state")).json()) as {
        wagerable: { id: string }[];
      };
      expect(state.wagerable.map((m) => m.id)).toContain(monsters[0].id);
    });
  });

  it("rejects a malformed wager without spending it", async () => {
    await withPlayer(async (call, monsters) => {
      expect((await call("POST", "/portal-wheel/spins", {})).status).toBe(400);
      expect((await call("POST", "/portal-wheel/spins", { dropId: monsters[0].id })).status).toBe(400);
      // A colour that isn't on the wheel is a bet that cannot be priced.
      expect(
        (await call("POST", "/portal-wheel/spins", { dropId: monsters[0].id, color: "purple" }))
          .status
      ).toBe(400);
      expect(
        (await call("POST", "/portal-wheel/spins", { dropId: monsters[0].id, color: "GREEN" }))
          .status
      ).toBe(400);

      const state = (await (await call("GET", "/portal-wheel/state")).json()) as {
        wagerable: { id: string }[];
      };
      expect(state.wagerable.map((m) => m.id)).toContain(monsters[0].id);
    });
  });
});

describe("published rules", () => {
  it("serves a wheel whose odds match its own sections", async () => {
    await withPlayer(async (call) => {
      const config = (await (await call("GET", "/portal-wheel/config")).json()) as Config;

      expect(config.wagerMonsters).toBe(1);
      expect(config.layout).toHaveLength(config.totalSections);
      expect(config.colors).toHaveLength(4);

      let sections = 0;
      let probability = 0;
      for (const entry of config.colors) {
        // Everything quoted has to be readable off the layout that was sent.
        const owned = config.layout.filter((section) => section === entry.color).length;
        expect(entry.sections).toBe(owned);
        expect(entry.sectionIndexes).toEqual(
          config.layout.flatMap((section, i) => (section === entry.color ? [i] : []))
        );
        expect(entry.probability).toBeCloseTo(owned / config.totalSections, 12);
        expect(entry.multiplier).toBeLessThanOrEqual(
          (1 - config.houseEdge) / entry.probability + 1e-9
        );
        expect(entry.multiplier).toBeGreaterThan(1);
        expect(entry.houseEdge).toBeGreaterThanOrEqual(config.houseEdge - 1e-9);
        expect(entry.colorHex).toMatch(/^#[0-9A-Fa-f]{6}$/);

        sections += owned;
        probability += entry.probability;
      }

      expect(sections).toBe(config.totalSections);
      expect(probability).toBeCloseTo(1, 12);
      expect(config.worstHouseEdge).toBeLessThan(config.houseEdge + 0.005);
    });
  });

  it("keeps a history of spins", async () => {
    await withPlayer(async (call, monsters) => {
      await call("POST", "/portal-wheel/spins", { dropId: monsters[0].id, color: "blue" });
      await call("POST", "/portal-wheel/spins", { dropId: monsters[1].id, color: "yellow" });

      const history = (await (await call("GET", "/portal-wheel/history?limit=5")).json()) as {
        spins: Spin[];
      };
      expect(history.spins.length).toBeGreaterThanOrEqual(2);
      expect(history.spins.map((s) => s.pick)).toContain("yellow");
      expect((await call("GET", "/portal-wheel/history?limit=0")).status).toBe(400);

      const state = (await (await call("GET", "/portal-wheel/state")).json()) as {
        lastSpin: Spin | null;
        recent: { pick: string; won: boolean }[];
      };
      expect(state.lastSpin).not.toBeNull();
      expect(state.recent.length).toBeGreaterThanOrEqual(2);
    });
  });
});
