import { afterEach, describe, expect, it } from "vitest";
import { DatabaseSync } from "node:sqlite";
import { applyMigrations, currentVersion, MigrationError } from "./migrate";
import { migrations } from "./migrations";

let db: DatabaseSync | undefined;

afterEach(() => {
  if (db?.isOpen) db.close();
  db = undefined;
});

describe("SQLite migrations", () => {
  it("creates a fully constrained fresh database and is idempotent", () => {
    db = new DatabaseSync(":memory:");
    expect(applyMigrations(db, migrations)).toBe(migrations.length);
    expect(currentVersion(db)).toBe(migrations.length);
    expect(applyMigrations(db, migrations)).toBe(migrations.length);
    expect(db.prepare("PRAGMA foreign_keys").get()).toEqual({ foreign_keys: 1 });
    expect(db.prepare("PRAGMA foreign_key_check").all()).toEqual([]);
  });

  it("upgrades existing version-1 data without losing it", () => {
    db = new DatabaseSync(":memory:");
    applyMigrations(db, [migrations[0]]);
    db.prepare(`INSERT INTO scan_seen(player_id, barcode) VALUES ('legacy_player', '123')`).run();
    expect(applyMigrations(db, migrations)).toBe(migrations.length);
    expect(db.prepare(`SELECT barcode FROM scan_seen WHERE player_id = 'legacy_player'`).get()).toEqual({ barcode: "123" });
    expect(db.prepare(`SELECT is_portable FROM players WHERE id = 'legacy_player'`).get()).toEqual({ is_portable: 0 });
  });

  it("auto-registers demo players, cascades deletes, and validates JSON", () => {
    db = new DatabaseSync(":memory:");
    applyMigrations(db, migrations);
    db.prepare(`INSERT INTO scan_character(player_id, char_id, payload) VALUES ('demo_123', 'c1', '{}')`).run();
    expect(db.prepare(`SELECT id FROM players WHERE id = 'demo_123'`).get()).toEqual({ id: "demo_123" });
    expect(() => db!.prepare(`INSERT INTO scan_character VALUES ('demo_123', 'c2', 'bad json')`).run()).toThrow();
    db.prepare(`DELETE FROM players WHERE id = 'demo_123'`).run();
    expect(db.prepare(`SELECT count(*) AS n FROM scan_character`).get()).toEqual({ n: 0 });
  });

  it("rolls back a failed migration without advancing the version", () => {
    db = new DatabaseSync(":memory:");
    expect(() => applyMigrations(db, [{ version: 1, name: "broken", sql: "CREATE TABLE ok(id); invalid sql" }]))
      .toThrow(MigrationError);
    expect(currentVersion(db)).toBe(0);
    expect(db.prepare(`SELECT name FROM sqlite_master WHERE name = 'ok'`).get()).toBeUndefined();
  });
});

describe("003 cauldron", () => {
  it("gives drops pulled before the casino existed a stable id", () => {
    db = new DatabaseSync(":memory:");
    // A collection built on the pre-casino schema.
    applyMigrations(db, migrations.slice(0, 2));
    const insert = db.prepare(`INSERT INTO lootbox_drop(player_id, payload) VALUES ('veteran', ?)`);
    for (const value of [15, 220, 3000]) insert.run(JSON.stringify({ value }));

    applyMigrations(db, migrations);

    const rows = db.prepare(`SELECT seq, drop_id FROM lootbox_drop ORDER BY seq`).all() as unknown as
      { seq: number; drop_id: string }[];
    expect(rows).toHaveLength(3);
    for (const row of rows) expect(row.drop_id).toBe(`legacy-${row.seq}`);

    // Re-running must not rename anything: a live wager holds these ids.
    applyMigrations(db, migrations);
    expect(db.prepare(`SELECT seq, drop_id FROM lootbox_drop ORDER BY seq`).all()).toEqual(rows);
  });

  it("keeps two pulls of one character distinct", () => {
    db = new DatabaseSync(":memory:");
    applyMigrations(db, migrations);
    const insert = db.prepare(`INSERT INTO lootbox_drop(player_id, drop_id, payload) VALUES ('demo_dupes', ?, '{}')`);
    insert.run("instance-a");
    insert.run("instance-b");
    expect(db.prepare(`SELECT count(*) AS n FROM lootbox_drop`).get()).toEqual({ n: 2 });
    // The same monster cannot be in the inventory twice under one id.
    expect(() => insert.run("instance-a")).toThrow();
  });

  it("registers the player, refuses a nonsense status, and cascades", () => {
    db = new DatabaseSync(":memory:");
    applyMigrations(db, migrations);
    const round = (status: string) =>
      db!.prepare(
        `INSERT INTO cauldron_round(round_id, player_id, wager, starting_net_worth, crash_multiplier,
                                    status, started_at, fairness)
         VALUES (?, 'demo_gambler', '[]', 100, 2.5, ?, '2026-01-01T00:00:00Z', '{}')`
      ).run(`r-${status}`, status);

    round("ACTIVE");
    expect(db.prepare(`SELECT id FROM players WHERE id = 'demo_gambler'`).get()).toEqual({ id: "demo_gambler" });
    expect(() => round("SORT_OF_ACTIVE")).toThrow();

    db.prepare(`DELETE FROM players WHERE id = 'demo_gambler'`).run();
    expect(db.prepare(`SELECT count(*) AS n FROM cauldron_round`).get()).toEqual({ n: 0 });
  });
});
