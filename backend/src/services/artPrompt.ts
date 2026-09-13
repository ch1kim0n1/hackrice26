import { createHash } from "crypto";

// Character art via Pollinations' free flux image endpoint. The prompt is
// built server-side (never from raw user input fields) and the route
// 302-redirects to the generated URL — no asset storage, deterministic
// per-character seed so the same unit always summons the same face.

export interface ArtInput {
  name: string;
  colorHex: string;
  rarity: string;
  /** Optional personality hint. The old stat-driven vibe table is gone with
   *  the type system — pass `flavor` for character voice instead. */
  statType?: string;
  flavor?: string;
}

const STAT_VIBE: Record<string, string> = {
  protein: "strong, determined energy",
  fiber: "grounded, earthy calm",
  vitamin: "bright, zesty energy",
  hydration: "cool, fluid calm"
};

const RARITY_AURA: Record<string, string> = {
  common: "",
  uncommon: "subtle green sparkle",
  rare: "soft blue shimmer",
  epic: "purple glow aura",
  legendary: "golden radiant halo",
  mythic: "fiery red aura",
  secret: "holographic prismatic shimmer"
};

export function characterArtPrompt(input: ArtInput): string {
  const vibe = (input.statType ? STAT_VIBE[input.statType] : undefined) ?? "cheerful energy";
  const aura = RARITY_AURA[input.rarity];
  return [
    "cute chibi anime mascot character",
    `a kawaii food creature personifying "${input.name}"`,
    input.flavor ? `personality: ${input.flavor}` : "",
    `dominant color ${input.colorHex}`,
    vibe,
    aura,
    "glossy anime eyes, rosy blush, simple smile",
    "thick clean sticker outline, soft cel shading",
    "plain pale cream background, centered, square composition",
    "mobile game mascot art style"
  ].filter(Boolean).join(", ");
}

export function characterArtURL(input: ArtInput, characterId: string): string {
  // Pollinations requires seed <= int32 max.
  const seedNum = parseInt(createHash("sha256").update(characterId).digest("hex").slice(0, 8), 16) & 0x7fffffff;
  const prompt = encodeURIComponent(characterArtPrompt(input));
  return `https://image.pollinations.ai/prompt/${prompt}?width=512&height=512&nologo=true&seed=${seedNum}`;
}
