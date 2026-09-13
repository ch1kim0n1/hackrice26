// Daily quest trio — the "three reasons to come back today" checklist.
//
// Three quests are picked deterministically from a small pool by the UTC
// date, so every player gets the same set and no server state is needed to
// know what today asks. Completion is verified server-side against the
// per-player day log (scan_seen) and crate history (lootbox_drop) — clients
// report nothing, they only claim.

import { createHash } from "crypto";
import { db } from "../db";
import { stateFor } from "../services/lootboxState";

export interface DailyQuest {
  id: string;
  label: string;
  /** What the server counts today. */
  kind: "scans" | "crate_opens";
  target: number;
  /** Key reward on claim. */
  reward: number;
}

const QUEST_POOL: DailyQuest[] = [
  { id: "scan-1", label: "Scan your first food today", kind: "scans", target: 1, reward: 1 },
  { id: "scan-2", label: "Scan 2 different foods", kind: "scans", target: 2, reward: 1 },
  { id: "scan-3", label: "Scan 3 different foods", kind: "scans", target: 3, reward: 2 },
  { id: "crate-1", label: "Open a summon crate", kind: "crate_opens", target: 1, reward: 1 },
  { id: "crate-2", label: "Open 2 summon crates", kind: "crate_opens", target: 2, reward: 2 }
];

/** The three quests for a UTC date — stable for every player that day. */
export function questsForDay(day: string): DailyQuest[] {
  // Seeded pick without repetition: hash the date, walk the pool in a
  // scrambled order, take the first three.
  const h = createHash("sha256").update(`quests:${day}`).digest();
  const order = [...QUEST_POOL].sort((a, b) => {
    const ha = h[a.id.charCodeAt(0) % h.length] + a.id.length * 17;
    const hb = h[b.id.charCodeAt(0) % h.length] + b.id.length * 17;
    return ha - hb;
  });
  return order.slice(0, 3).sort((a, b) => a.id.localeCompare(b.id));
}

export function todayKey(): string {
  return new Date().toISOString().slice(0, 10);
}

/** Server-side progress for one quest kind on the current UTC day. */
function progressFor(playerId: string, kind: DailyQuest["kind"]): number {
  if (kind === "scans") {
    const row = db
      .prepare(`SELECT COUNT(*) AS n FROM scan_seen WHERE player_id = ? AND date(seen_at) = date('now')`)
      .get(playerId) as { n: number };
    return row.n;
  }
  const row = db
    .prepare(
      `SELECT COUNT(*) AS n FROM lootbox_drop
       WHERE player_id = ? AND date(json_extract(payload, '$.openedAt')) = date('now')`
    )
    .get(playerId) as { n: number };
  return row.n;
}

export interface QuestStatus extends DailyQuest {
  progress: number;
  done: boolean;
  claimed: boolean;
}

export function questStatuses(playerId: string, day = todayKey()): QuestStatus[] {
  const claimed = new Set(
    (db
      .prepare(`SELECT quest_id FROM quest_claim WHERE player_id = ? AND day = ?`)
      .all(playerId, day) as { quest_id: string }[]).map((r) => r.quest_id)
  );
  return questsForDay(day).map((q) => {
    const progress = progressFor(playerId, q.kind);
    return {
      ...q,
      progress,
      done: progress >= q.target,
      claimed: claimed.has(q.id)
    };
  });
}

/**
 * Claim a quest reward. Atomic-ish: the claim row is inserted first with
 * INSERT OR IGNORE — only the first claim for (player, day, quest) reaches
 * the key grant.
 */
export function claimQuest(playerId: string, questId: string, day = todayKey()): { keys: number } {
  const quest = questsForDay(day).find((q) => q.id === questId);
  if (!quest) throw new Error("QUEST_NOT_TODAY");

  const status = questStatuses(playerId, day).find((q) => q.id === questId)!;
  if (!status.done) throw new Error("QUEST_INCOMPLETE");

  const res = db
    .prepare(`INSERT OR IGNORE INTO quest_claim (player_id, day, quest_id) VALUES (?, ?, ?)`)
    .run(playerId, day, questId);
  if (res.changes === 0) throw new Error("QUEST_ALREADY_CLAIMED");

  return { keys: stateFor(playerId).grantKeys(quest.reward) };
}
