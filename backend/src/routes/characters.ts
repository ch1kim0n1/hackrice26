import { Router } from "express";
import { existsSync } from "fs";
import { join } from "path";
import { sampleCharacters } from "../data/sampleCharacters";
import { ROSTER, rosterCharacter } from "../data/roster";
import { spriteRelPath } from "../data/characterArt";
import { characterArtURL } from "../services/artPrompt";
import { rateLimitByPlayer } from "../middleware/security";
import { PlayerRequest, requirePlayerId } from "../middleware/player";
import { FUSION_COPIES_PER_LEVEL } from "../game/rarityBands";
import { Rarity } from "../types";
import { scaledStat } from "../game/power";
import { characterPayload } from "./lootbox";
import { coinBalance, coinHistory } from "../services/coins";
import { hasDatabaseUrl } from "../db/pg";
import { MUTATION_ERRORS, mergeDrops, sellDrops } from "../services/characterMutations";
import { enqueueMirror } from "../services/mirrorQueue";

export const charactersRouter = Router();

// GET /characters -- the signed-in user's collection.
charactersRouter.get("/", (_req, res) => {
  res.json({ characters: sampleCharacters });
});

// ===== Pokédex catalog (issue #95) ==========================================

/** Directory holding the pre-generated base art (per-rarity variants are #98). */
const ART_DIR = join(__dirname, "..", "..", "..", "game-assets");

/** Resolve the art file for (character, rarity) — issue #99. Prefers a
 *  per-rarity variant (`<imageKey>-<rarity>.png`), falls back to the base
 *  image, then to the generated-art route when no file exists at all. */
export function imageFor(characterId: string, rarity: Rarity): {
  imageKey: string;
  file: string | null;
  variant: "rarity" | "base" | "generated";
  url: string;
} {
  const entry = rosterCharacter(characterId);
  const imageKey = entry?.imageKey ?? `${characterId}-char`;
  const variantFile = `${imageKey}-${rarity}.png`;
  if (existsSync(join(ART_DIR, variantFile))) {
    return { imageKey, file: variantFile, variant: "rarity", url: `/assets/${variantFile}` };
  }
  const cartoon = spriteRelPath(characterId);
  if (existsSync(join(ART_DIR, cartoon))) {
    return { imageKey, file: cartoon, variant: "base", url: `/assets/${cartoon}` };
  }
  for (const candidate of [`${imageKey}.png`, `${imageKey}-char.png`]) {
    if (existsSync(join(ART_DIR, candidate))) {
      return { imageKey, file: candidate, variant: "base", url: `/assets/${candidate}` };
    }
  }
  return { imageKey, file: null, variant: "generated", url: `/characters/${characterId}/art` };
}

// GET /characters/catalog -- the 14 authored characters, Pokédex-style.
// The catalog entry is the spec's master record: permanent id, display name,
// baseHealth/baseAttack/baseMana, the 3 authored standard moves + the Mana
// Special (full move objects so clients never join against a second table),
// art reference and lore. No element, no stat blob, no intrinsic rarity —
// rarity is rolled per instance at mint.
charactersRouter.get("/catalog", (_req, res) => {
  res.json({
    catalog: ROSTER.map((c) => ({
      id: c.id,
      name: c.name,
      colorHex: c.colorHex,
      tagline: c.tagline,
      bio: c.bio,
      baseHealth: c.baseHealth,
      baseAttack: c.baseAttack,
      baseMana: c.baseMana,
      moves: c.moves,
      special: c.special,
      image: imageFor(c.id, "common")
    }))
  });
});

// GET /characters/:id/image?rarity= -- per-rarity art resolution (#99).
// GET /characters/coins -- balance plus the rows behind it.
//
// Registered above the "/:id" routes below: Express matches in order, so a
// literal path declared after a wildcard is a path that never runs.
charactersRouter.get("/coins", requirePlayerId, (req: PlayerRequest, res) => {
  res.json({
    balance: coinBalance(req.playerId!),
    history: coinHistory(req.playerId!, 50)
  });
});

charactersRouter.get("/:id/image", (req, res) => {
  const entry = rosterCharacter(req.params.id);
  if (!entry) return res.status(404).json({ error: "Character not found" });
  // Catalog entries have no intrinsic rarity; the query picks the art
  // variant, defaulting to the base (common) sprite.
  const rarity = (typeof req.query.rarity === "string" ? req.query.rarity : "common") as Rarity;
  res.json({ characterId: entry.id, rarity, image: imageFor(entry.id, rarity) });
});

// GET /characters/art?name=&color=&type=&rarity= -- generated anime art for
// dynamic (scanned-food) characters. Redirects to the image service; the
// client keeps its procedural chibi as the loading/offline fallback.
charactersRouter.get("/art", rateLimitByPlayer({ windowMs: 60_000, max: 30, keyPrefix: "art", message: "Art requests too frequent." }), (req, res) => {
  const { name, color, rarity } = req.query as Record<string, string | undefined>;
  if (typeof name !== "string" || name.length === 0 || name.length > 60) {
    return res.status(400).json({ error: "name is required (max 60 chars)" });
  }
  const safe = {
    name: name.slice(0, 60),
    colorHex: typeof color === "string" && /^#[0-9a-fA-F]{6}$/.test(color) ? color : "#9AA4B2",
    rarity: typeof rarity === "string" ? rarity : "common"
  };
  res.redirect(characterArtURL(safe, name.toLowerCase()));
});

// GET /characters/:id/art -- generated art for a catalog or owned character.
charactersRouter.get("/:id/art", rateLimitByPlayer({ windowMs: 60_000, max: 30, keyPrefix: "art", message: "Art requests too frequent." }), (req, res) => {
  const c = rosterCharacter(req.params.id) ?? sampleCharacters.find((s) => s.id === req.params.id);
  if (!c) return res.status(404).json({ error: "Character not found" });
  const input = {
    name: c.name,
    colorHex: c.colorHex,
    rarity: "rarity" in c && typeof c.rarity === "string" ? c.rarity : "common",
    flavor: c.tagline
  };
  res.redirect(characterArtURL(input, c.id));
});

// GET /characters/:id
charactersRouter.get("/:id", (req, res) => {
  const character = sampleCharacters.find((c) => c.id === req.params.id);
  if (!character) {
    return res.status(404).json({ error: "Character not found" });
  }
  res.json({ character });
});


// ===== Merge / sell (issues #111, #115, #133) ===============================
//
// Both go through services/characterMutations.ts — one transactional path
// that locks, mutates, revalues, and writes the ledger. Routes keep only
// input validation, error mapping, and the TigerData event hooks.

const MUTATION_STATUS: Record<string, number> = {
  [MUTATION_ERRORS.NOT_OWNED]: 404,
  [MUTATION_ERRORS.LOCKED]: 409,
  [MUTATION_ERRORS.MAX_STAR]: 409,
  [MUTATION_ERRORS.MISMATCH]: 409,
  [MUTATION_ERRORS.RACE]: 409,
  [MUTATION_ERRORS.WORTHLESS]: 409
};

const MUTATION_MESSAGE: Record<string, string> = {
  [MUTATION_ERRORS.NOT_OWNED]: "Every dropId must be a monster you own.",
  [MUTATION_ERRORS.LOCKED]: "One of those monsters is staked and cannot be touched until the battle settles.",
  [MUTATION_ERRORS.MAX_STAR]: "These monsters are already at the maximum star level.",
  [MUTATION_ERRORS.MISMATCH]: "All three must be the same character, rarity, and star level.",
  [MUTATION_ERRORS.RACE]: "One of those monsters is no longer available.",
  [MUTATION_ERRORS.WORTHLESS]: "That monster is worth nothing and cannot be sold."
};

function mutationFailure(res: import("express").Response, err: unknown) {
  const code = err instanceof Error ? err.message : "INTERNAL";
  const status = MUTATION_STATUS[code];
  if (!status) throw err;
  return res.status(status).json({ error: { code, message: MUTATION_MESSAGE[code] ?? code } });
}

charactersRouter.post("/merge", requirePlayerId, rateLimitByPlayer({ windowMs: 60_000, max: 10, keyPrefix: "merge", message: "Too many merges." }), (req: PlayerRequest, res) => {
  const { dropIds } = req.body as { dropIds?: unknown };
  if (!Array.isArray(dropIds) || dropIds.length !== FUSION_COPIES_PER_LEVEL || !dropIds.every((id) => typeof id === "string")) {
    return res.status(400).json({ error: `dropIds must be an array of ${FUSION_COPIES_PER_LEVEL} instance ids.` });
  }

  try {
    const result = mergeDrops(req.playerId!, dropIds as string[]);
    if (hasDatabaseUrl()) {
      // The merged instance is the event's identity: merging the same three
      // copies can only happen once, because they are consumed.
      enqueueMirror("gameplay_event", `merge:${result.merged.id}`, {
        playerId: req.playerId!,
        type: "merge",
        detail: { rarity: result.to.rarity, star: result.to.star, value: result.to.value },
      });
      // A merge mints a monster, so it belongs in the pull-luck series next to
      // crate opens and scans -- otherwise the rarity mix over time is missing
      // every unit the player built rather than found.
      enqueueMirror("acquisition_event", result.merged.id, {
        playerId: req.playerId!,
        sourceKind: "merge",
        rarity: result.to.rarity,
        netWorth: result.to.value,
        starLevel: result.to.star,
        characterRef: result.merged.id,
      });
    }
    res.json({
      ...result,
      // `to.attack` previews the fused unit's EffectiveAttack — base Attack x
      // rarity x star multipliers (spec §2/§4).
      to: {
        ...result.to,
        attack: Math.round(
          scaledStat(result.merged.character.baseAttack, result.to.rarity as Rarity, result.to.star)
        )
      }
    });
  } catch (err) {
    return mutationFailure(res, err);
  }
});

// POST /characters/sell { dropId } — a monster out, coins in at full net
// worth (issue #115; routed through the mutation service per #133). A batch
// form, { dropIds }, sells up to 20 at once. Locked (staked) monsters
// refuse with 409.
charactersRouter.post("/sell", requirePlayerId, rateLimitByPlayer({ windowMs: 60_000, max: 30, keyPrefix: "sell", message: "Too many sales." }), (req: PlayerRequest, res) => {
  const { dropId, dropIds } = req.body as { dropId?: unknown; dropIds?: unknown };
  const single = typeof dropId === "string" && dropId.length > 0;
  const batch = Array.isArray(dropIds) && dropIds.length >= 1 && dropIds.length <= 20 && dropIds.every((id) => typeof id === "string");
  if (!single && !batch) {
    return res.status(400).json({
      error: { code: "BAD_REQUEST", message: "dropId must be the id of a monster you own (or dropIds, an array of 1-20)." }
    });
  }
  const ids = single ? [dropId as string] : (dropIds as string[]);

  try {
    const result = sellDrops(req.playerId!, ids);
    if (hasDatabaseUrl()) {
      // Keyed on what was sold: the monsters are gone afterwards, so the same
      // id set cannot legitimately sell twice.
      enqueueMirror("gameplay_event", `sell:${[...ids].sort().join(",")}`, {
        playerId: req.playerId!,
        type: "sell",
        detail: { dropIds: ids, coins: result.coins },
      });
    }
    const sold = result.sold.map((s) => ({
      id: s.drop.id,
      character: characterPayload(s.drop.character.id, s.drop.character),
      stars: s.drop.stars ?? 1,
      netWorth: s.netWorth
    }));
    res.json({
      sold: single ? sold[0] : sold,
      coins: result.coins,
      balance: coinBalance(req.playerId!),
      ...(single
        ? { entryId: result.sold[0].entryId }
        : { entryIds: result.sold.map((s) => s.entryId) })
    });
  } catch (err) {
    return mutationFailure(res, err);
  }
});
