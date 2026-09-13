import { existsSync } from "fs";
import { join } from "path";
import { describe, expect, it } from "vitest";
import { CHARACTERS, CRATES, JOKE_CHARACTER_IDS } from "./lootTable";
import { spriteRelPath } from "./characterArt";

const ART_DIR = join(__dirname, "..", "..", "..", "game-assets");

describe("character cartoon sprites", () => {
  it("points every loot character at a file that exists", () => {
    for (const id of Object.keys(CHARACTERS)) {
      const file = spriteRelPath(id);
      expect(existsSync(join(ART_DIR, file)), `${id} -> ${file}`).toBe(true);
    }
  });

  it("keeps hurt poses on disk for the same roster", () => {
    for (const id of Object.keys(CHARACTERS)) {
      const file = spriteRelPath(id, true);
      expect(existsSync(join(ART_DIR, file)), `${id} hurt -> ${file}`).toBe(true);
    }
  });

  it("keeps brainrot jokes in the secret crate only", () => {
    expect(CRATES["secret-crate"].characterIds).toEqual([...JOKE_CHARACTER_IDS]);
    for (const crate of Object.values(CRATES)) {
      if (crate.id === "secret-crate") continue;
      for (const id of JOKE_CHARACTER_IDS) {
        expect(crate.characterIds).not.toContain(id);
      }
    }
  });
});
