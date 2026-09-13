// Capsule opening — odds + pity, port of docs/BATTLE-SYSTEM.md §6 and the DB
// `roll_rarity()` / `open_capsule()` pity logic. The authoritative roll runs
// in Postgres (seeded by HMAC(openId, SERVER_SECRET)); this mirror exists so
// the pity guarantees can be unit-tested against a forced sequence.

import { createHmac } from "crypto";
import { Rarity } from "./rarity";

export const EPIC_PITY = 15; // guaranteed Epic+ every 15 opens
export const LEGENDARY_PITY = 40; // guaranteed Legendary every 40 opens

/** Base odds: Common 70 / Rare 22 / Epic 7 / Legendary 1. `unit` in [0,1). */
export function rollRarity(unit: number): Rarity {
  if (unit < 0.7) return "common";
  if (unit < 0.92) return "rare";
  if (unit < 0.99) return "epic";
  return "legendary";
}

/** Deterministic unit in [0,1) from HMAC-SHA256(openId, secret) — matches the
 *  DB's `('x'||substr(hex,1,15))::bit(60)::bigint / 2^60`. */
export function openUnit(openId: string, secret: string): number {
  const hex = createHmac("sha256", secret).update(openId).digest("hex");
  const bits60 = BigInt("0x" + hex.slice(0, 15)); // first 60 bits
  return Number(bits60) / 2 ** 60;
}

export interface PityState {
  sinceEpic: number;
  sinceLegendary: number;
  totalOpens: number;
}

export const freshPity = (): PityState => ({ sinceEpic: 0, sinceLegendary: 0, totalOpens: 0 });

export interface OpenResult {
  rarity: Rarity;
  state: PityState;
  forced: "legendary" | "epic" | null;
}

/** Apply one open: pity thresholds fire on this open (pre-increment counters). */
export function openOnce(prev: PityState, unit: number): OpenResult {
  const forcedLeg = prev.sinceLegendary + 1 >= LEGENDARY_PITY;
  const forcedEpic = prev.sinceEpic + 1 >= EPIC_PITY;

  let rarity = rollRarity(unit);
  let forced: "legendary" | "epic" | null = null;
  if (forcedLeg) {
    rarity = "legendary";
    forced = "legendary";
  } else if (forcedEpic && (rarity === "common" || rarity === "rare")) {
    rarity = "epic";
    forced = "epic";
  }

  const state: PityState = {
    sinceEpic: rarity === "legendary" || rarity === "epic" ? 0 : prev.sinceEpic + 1,
    sinceLegendary: rarity === "legendary" ? 0 : prev.sinceLegendary + 1,
    totalOpens: prev.totalOpens + 1
  };

  return { rarity, state, forced };
}
