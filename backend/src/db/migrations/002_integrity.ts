import type { DatabaseSync } from "node:sqlite";
import type { Migration } from "../migrate";

function columns(db: DatabaseSync, table: string): Set<string> {
  return new Set(
    (db.prepare(`PRAGMA table_info(${table})`).all() as { name: string }[]).map((row) => row.name)
  );
}

function rebuild(db: DatabaseSync, table: string, create: string, names: string): void {
  db.exec(`ALTER TABLE ${table} RENAME TO __old_${table};`);
  db.exec(create);
  db.exec(`INSERT INTO ${table} (${names}) SELECT ${names} FROM __old_${table};`);
  db.exec(`DROP TABLE __old_${table};`);
}

function portableExpression(id: string): string {
  return `CASE WHEN length(${id}) = 36
    AND substr(${id}, 9, 1) = '-' AND substr(${id}, 14, 1) = '-'
    AND substr(${id}, 19, 1) = '-' AND substr(${id}, 24, 1) = '-'
    THEN 1 ELSE 0 END`;
}

export const migration: Migration = {
  version: 2,
  name: "player-integrity",
  run(db) {
    // Old files received these fields through boot-time ALTER statements. Make
    // the historical baseline complete before rebuilding it with constraints.
    if (!columns(db, "scan_seen").has("seen_at")) {
      db.exec(`ALTER TABLE scan_seen ADD COLUMN seen_at TEXT NOT NULL DEFAULT '1970-01-01T00:00:00Z'`);
      db.exec(`UPDATE scan_seen SET seen_at = datetime('now') WHERE seen_at = '1970-01-01T00:00:00Z'`);
    }
    const lootColumns = columns(db, "lootbox_session");
    if (!lootColumns.has("since_epic")) {
      db.exec(`ALTER TABLE lootbox_session ADD COLUMN since_epic INTEGER NOT NULL DEFAULT 0`);
    }
    if (!lootColumns.has("since_legendary")) {
      db.exec(`ALTER TABLE lootbox_session ADD COLUMN since_legendary INTEGER NOT NULL DEFAULT 0`);
    }

    db.exec(`
      CREATE TABLE players (
        id TEXT PRIMARY KEY,
        display_name TEXT NOT NULL CHECK(length(display_name) BETWEEN 1 AND 32),
        created_at TEXT NOT NULL DEFAULT (datetime('now')),
        last_seen_at TEXT,
        is_portable INTEGER NOT NULL DEFAULT 0 CHECK(is_portable IN (0, 1))
      );
    `);

    const sources = [
      ["account", "player_id"], ["lootbox_session", "player_id"],
      ["lootbox_retired", "player_id"], ["lootbox_drop", "player_id"],
      ["user_profile", "player_id"], ["scan_seen", "player_id"],
      ["scan_character", "player_id"], ["vitals_snapshot", "player_id"],
      ["dish_analysis", "player_id"], ["quest_claim", "player_id"],
      ["player_seen", "player_id"], ["friend_squad", "player_id"],
      ["async_battle", "challenger_id"], ["async_battle", "defender_id"],
      ["dungeon_state", "player_id"], ["promo_redeem", "player_id"]
    ] as const;
    const insertPlayer = db.prepare(
      `INSERT OR IGNORE INTO players (id, display_name, is_portable) VALUES (?, ?, ?)`
    );
    for (const [table, field] of sources) {
      const rows = db.prepare(`SELECT DISTINCT ${field} AS id FROM ${table} WHERE ${field} <> ''`).all() as { id: string }[];
      for (const { id } of rows) {
        const portable = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(id) ? 1 : 0;
        insertPlayer.run(id, `Trainer ${id.slice(0, 6)}`.slice(0, 32), portable);
      }
    }

    rebuild(db, "account", `CREATE TABLE account (
      player_id TEXT PRIMARY KEY REFERENCES players(id) ON DELETE CASCADE,
      username TEXT NOT NULL UNIQUE COLLATE NOCASE,
      password_hash TEXT NOT NULL,
      display_name TEXT NOT NULL DEFAULT '',
      created_at TEXT NOT NULL DEFAULT (datetime('now')),
      last_login_at TEXT
    )`, "player_id, username, password_hash, display_name, created_at, last_login_at");
    rebuild(db, "session", `CREATE TABLE session (
      token_hash TEXT PRIMARY KEY,
      player_id TEXT NOT NULL REFERENCES account(player_id) ON DELETE CASCADE,
      created_at TEXT NOT NULL DEFAULT (datetime('now')),
      expires_at TEXT NOT NULL,
      revoked INTEGER NOT NULL DEFAULT 0 CHECK(revoked IN (0, 1))
    )`, "token_hash, player_id, created_at, expires_at, revoked");
    rebuild(db, "lootbox_session", `CREATE TABLE lootbox_session (
      player_id TEXT PRIMARY KEY REFERENCES players(id) ON DELETE CASCADE,
      keys INTEGER NOT NULL CHECK(keys >= 0), server_seed TEXT NOT NULL,
      server_seed_hash TEXT NOT NULL, client_seed TEXT NOT NULL,
      nonce INTEGER NOT NULL CHECK(nonce >= 0), created_at TEXT NOT NULL,
      since_epic INTEGER NOT NULL DEFAULT 0 CHECK(since_epic >= 0),
      since_legendary INTEGER NOT NULL DEFAULT 0 CHECK(since_legendary >= 0)
    )`, "player_id, keys, server_seed, server_seed_hash, client_seed, nonce, created_at, since_epic, since_legendary");
    rebuild(db, "lootbox_retired", `CREATE TABLE lootbox_retired (
      player_id TEXT NOT NULL REFERENCES players(id) ON DELETE CASCADE,
      server_seed TEXT NOT NULL, server_seed_hash TEXT NOT NULL, client_seed TEXT NOT NULL,
      nonce INTEGER NOT NULL CHECK(nonce >= 0), created_at TEXT NOT NULL, retired_at TEXT NOT NULL
    )`, "player_id, server_seed, server_seed_hash, client_seed, nonce, created_at, retired_at");
    rebuild(db, "lootbox_drop", `CREATE TABLE lootbox_drop (
      seq INTEGER PRIMARY KEY AUTOINCREMENT,
      player_id TEXT NOT NULL REFERENCES players(id) ON DELETE CASCADE,
      payload TEXT NOT NULL CHECK(json_valid(payload))
    )`, "seq, player_id, payload");
    rebuild(db, "user_profile", `CREATE TABLE user_profile (
      player_id TEXT PRIMARY KEY REFERENCES players(id) ON DELETE CASCADE,
      payload TEXT NOT NULL CHECK(json_valid(payload)), created_at TEXT NOT NULL, updated_at TEXT NOT NULL
    )`, "player_id, payload, created_at, updated_at");
    rebuild(db, "scan_seen", `CREATE TABLE scan_seen (
      player_id TEXT NOT NULL REFERENCES players(id) ON DELETE CASCADE,
      barcode TEXT NOT NULL, seen_at TEXT NOT NULL DEFAULT (datetime('now')),
      PRIMARY KEY(player_id, barcode)
    )`, "player_id, barcode, seen_at");
    rebuild(db, "scan_character", `CREATE TABLE scan_character (
      player_id TEXT NOT NULL REFERENCES players(id) ON DELETE CASCADE,
      char_id TEXT NOT NULL, payload TEXT NOT NULL CHECK(json_valid(payload)),
      PRIMARY KEY(player_id, char_id)
    )`, "player_id, char_id, payload");
    rebuild(db, "vitals_snapshot", `CREATE TABLE vitals_snapshot (
      seq INTEGER PRIMARY KEY AUTOINCREMENT,
      player_id TEXT NOT NULL REFERENCES players(id) ON DELETE CASCADE,
      payload TEXT NOT NULL CHECK(json_valid(payload))
    )`, "seq, player_id, payload");
    rebuild(db, "dish_analysis", `CREATE TABLE dish_analysis (
      analysis_id TEXT PRIMARY KEY,
      player_id TEXT NOT NULL REFERENCES players(id) ON DELETE CASCADE,
      payload TEXT NOT NULL CHECK(json_valid(payload)), created_at TEXT NOT NULL DEFAULT (datetime('now')),
      consumed INTEGER NOT NULL DEFAULT 0 CHECK(consumed IN (0, 1))
    )`, "analysis_id, player_id, payload, created_at, consumed");
    rebuild(db, "quest_claim", `CREATE TABLE quest_claim (
      player_id TEXT NOT NULL REFERENCES players(id) ON DELETE CASCADE,
      day TEXT NOT NULL, quest_id TEXT NOT NULL, claimed_at TEXT NOT NULL DEFAULT (datetime('now')),
      PRIMARY KEY(player_id, day, quest_id)
    )`, "player_id, day, quest_id, claimed_at");
    rebuild(db, "player_seen", `CREATE TABLE player_seen (
      player_id TEXT PRIMARY KEY REFERENCES players(id) ON DELETE CASCADE,
      last_seen_at TEXT NOT NULL, comeback_pending_at TEXT, comeback_claimed_at TEXT
    )`, "player_id, last_seen_at, comeback_pending_at, comeback_claimed_at");
    rebuild(db, "friend_squad", `CREATE TABLE friend_squad (
      player_id TEXT PRIMARY KEY REFERENCES players(id) ON DELETE CASCADE,
      payload TEXT NOT NULL CHECK(json_valid(payload)), updated_at TEXT NOT NULL
    )`, "player_id, payload, updated_at");
    rebuild(db, "async_battle", `CREATE TABLE async_battle (
      seq INTEGER PRIMARY KEY AUTOINCREMENT,
      challenger_id TEXT NOT NULL REFERENCES players(id) ON DELETE CASCADE,
      defender_id TEXT NOT NULL REFERENCES players(id) ON DELETE CASCADE,
      winner_side INTEGER NOT NULL CHECK(winner_side IN (0, 1)),
      rounds INTEGER NOT NULL CHECK(rounds > 0), created_at TEXT NOT NULL DEFAULT (datetime('now')),
      seen_by_defender INTEGER NOT NULL DEFAULT 0 CHECK(seen_by_defender IN (0, 1))
    )`, "seq, challenger_id, defender_id, winner_side, rounds, created_at, seen_by_defender");
    rebuild(db, "dungeon_state", `CREATE TABLE dungeon_state (
      player_id TEXT PRIMARY KEY REFERENCES players(id) ON DELETE CASCADE,
      best_floor INTEGER NOT NULL DEFAULT 0 CHECK(best_floor >= 0), last_claim_at TEXT NOT NULL, last_run_at TEXT
    )`, "player_id, best_floor, last_claim_at, last_run_at");
    rebuild(db, "promo_code", `CREATE TABLE promo_code (
      code TEXT PRIMARY KEY, reward TEXT NOT NULL,
      uses_limit INTEGER NOT NULL DEFAULT 0 CHECK(uses_limit >= 0),
      uses INTEGER NOT NULL DEFAULT 0 CHECK(uses >= 0 AND (uses_limit = 0 OR uses <= uses_limit)),
      created_at TEXT NOT NULL DEFAULT (datetime('now')), expires_at TEXT
    )`, "code, reward, uses_limit, uses, created_at, expires_at");
    rebuild(db, "promo_redeem", `CREATE TABLE promo_redeem (
      player_id TEXT NOT NULL REFERENCES players(id) ON DELETE CASCADE,
      code TEXT NOT NULL REFERENCES promo_code(code) ON DELETE CASCADE,
      redeemed_at TEXT NOT NULL DEFAULT (datetime('now')), PRIMARY KEY(player_id, code)
    )`, "player_id, code, redeemed_at");

    db.exec(`
      CREATE INDEX idx_session_player ON session(player_id);
      CREATE INDEX idx_lootbox_retired_player ON lootbox_retired(player_id);
      CREATE INDEX idx_lootbox_drop_player ON lootbox_drop(player_id);
      CREATE INDEX idx_vitals_snapshot_player ON vitals_snapshot(player_id);
      CREATE INDEX idx_dish_analysis_player ON dish_analysis(player_id);
      CREATE INDEX idx_async_battle_defender ON async_battle(defender_id, seen_by_defender);
      CREATE INDEX idx_promo_redeem_code ON promo_redeem(code);
    `);

    // Header-based demo users do not have an account-registration event. Each
    // player-scoped insert therefore materializes its parent before FK checks.
    const autoTables = [
      "lootbox_session", "lootbox_retired", "lootbox_drop", "user_profile",
      "scan_seen", "scan_character", "vitals_snapshot", "dish_analysis",
      "quest_claim", "player_seen", "friend_squad", "dungeon_state", "promo_redeem"
    ];
    for (const table of autoTables) {
      db.exec(`CREATE TRIGGER trg_${table}_ensure_player BEFORE INSERT ON ${table}
        BEGIN
          INSERT OR IGNORE INTO players(id, display_name, is_portable)
          VALUES (NEW.player_id, substr('Trainer ' || NEW.player_id, 1, 32), ${portableExpression("NEW.player_id")});
        END;`);
    }
    db.exec(`CREATE TRIGGER trg_async_battle_ensure_players BEFORE INSERT ON async_battle
      BEGIN
        INSERT OR IGNORE INTO players(id, display_name, is_portable)
        VALUES (NEW.challenger_id, substr('Trainer ' || NEW.challenger_id, 1, 32), ${portableExpression("NEW.challenger_id")});
        INSERT OR IGNORE INTO players(id, display_name, is_portable)
        VALUES (NEW.defender_id, substr('Trainer ' || NEW.defender_id, 1, 32), ${portableExpression("NEW.defender_id")});
      END;`);
  }
};
