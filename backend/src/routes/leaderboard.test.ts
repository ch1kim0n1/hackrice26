import { describe, it, expect, beforeAll, afterAll } from "vitest";
import express from "express";
import { rmSync } from "fs";
import { tmpdir } from "os";
import path from "path";

// Leaderboard ordering — spec §6: RR desc, then ranked wins, then win rate.

const DB_FILE = path.join(tmpdir(), `nutriquest-lb-${process.pid}-${Date.now()}.db`);
process.env.NUTRIQUEST_DB = DB_FILE;

let close: () => void = () => {};

afterAll(() => {
  close();
  rmSync(DB_FILE, { force: true });
  rmSync(`${DB_FILE}-wal`, { force: true });
  rmSync(`${DB_FILE}-shm`, { force: true });
});

function seedProfile(
  db: typeof import("../db").db,
  id: string,
  fields: { rr?: number; rankedWins?: number; rankedLosses?: number }
): void {
  db.prepare(`INSERT INTO players (id, display_name, is_portable) VALUES (?, ?, 0)`).run(id, id);
  db.prepare(
    `INSERT INTO user_profile (player_id, payload, created_at, updated_at)
     VALUES (?, ?, datetime('now'), datetime('now'))`
  ).run(id, JSON.stringify({ id, displayName: id, createdAt: "", updatedAt: "", ...fields }));
}

describe("GET /user/leaderboard", () => {
  it("orders RR desc → ranked wins desc → win rate desc", async () => {
    const { db } = await import("../db");
    const { userRouter } = await import("./user");

    // Deliberately scrambled insert order.
    seedProfile(db, "lb_low", { rr: 50, rankedWins: 9, rankedLosses: 1 });
    seedProfile(db, "lb_tie_wins", { rr: 200, rankedWins: 7, rankedLosses: 3 });
    seedProfile(db, "lb_top", { rr: 500, rankedWins: 1, rankedLosses: 99 });
    seedProfile(db, "lb_tie_wr", { rr: 200, rankedWins: 7, rankedLosses: 1 }); // same RR+wins, better WR
    seedProfile(db, "lb_tie_worse_wr", { rr: 200, rankedWins: 7, rankedLosses: 9 });

    const app = express();
    app.use("/user", userRouter);
    const server = app.listen(0);
    close = () => server.close();
    await new Promise<void>((r) => server.once("listening", r));
    const port = (server.address() as { port: number }).port;
    const res = await fetch(`http://127.0.0.1:${port}/user/leaderboard`, {
      headers: { "X-Player-Id": "lb_low" }
    });
    expect(res.status).toBe(200);
    const { entries } = (await res.json()) as { entries: { id: string; rank: number }[] };
    const order = entries.map((e) => e.id);
    expect(order).toEqual([
      "lb_top",          // highest RR wins outright
      "lb_tie_wr",       // 200 RR, 7 wins, 7/8 = .875 WR
      "lb_tie_wins",     // 200 RR, 7 wins, 7/10 = .700 WR
      "lb_tie_worse_wr", // 200 RR, 7 wins, 7/16 = .4375 WR
      "lb_low"
    ]);
    expect(entries[0].rank).toBe(1);
  });
});
