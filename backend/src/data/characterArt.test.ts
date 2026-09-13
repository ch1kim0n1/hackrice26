import { existsSync } from "fs";
import { join } from "path";
import { describe, expect, it } from "vitest";
import { ROSTER } from "./roster";
import { sampleCharacters } from "./sampleCharacters";
import { spriteRelPath } from "./characterArt";

const ART_DIR = join(__dirname, "..", "..", "..", "game-assets");

describe("character cartoon sprites", () => {
  const ids = [
    ...ROSTER.map((c) => c.id),
    ...sampleCharacters.map((c) => c.id)
  ];

  it("points every catalog and sample character at a file that exists", () => {
    for (const id of ids) {
      const file = spriteRelPath(id);
      expect(existsSync(join(ART_DIR, file)), `${id} -> ${file}`).toBe(true);
    }
  });

  it("keeps hurt poses on disk for the same roster", () => {
    for (const id of ids) {
      const file = spriteRelPath(id, true);
      expect(existsSync(join(ART_DIR, file)), `${id} hurt -> ${file}`).toBe(true);
    }
  });
});
