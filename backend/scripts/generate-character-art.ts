// Pre-generate the roster's character art and check it in (issue #93).
//
// The app can already fetch character art at runtime: GET /characters/:id/art
// 302-redirects to Pollinations, seeded per character so the same unit always
// summons the same face. That is fine for a scanned one-off, and wrong for the
// established roster -- the 14 characters in characters.json are fixed, so
// their pictures should be too. Fetching them live costs a round trip, a rate
// limit, and a hard dependency on a third-party service being up during a demo.
//
// This script resolves each roster character through the *same* prompt and seed
// the runtime endpoint uses, then writes the result into the iOS asset catalog
// under the character's `imageKey`. Re-running it reproduces the same images.
//
//   npm run art:generate            # only fetch what is missing
//   npm run art:generate -- --force # re-fetch everything
//
// Deliberately a script, not part of the build: art generation is slow, needs
// the network, and its output is committed. CI must never depend on it.

import { mkdirSync, writeFileSync, existsSync, rmSync } from "fs";
import path from "path";
import { spawnSync } from "child_process";
import { ROSTER } from "../src/data/roster";
import { CHARACTER_FLAVOR } from "../src/data/lootTable";
import { characterArtURL } from "../src/services/artPrompt";

const ASSET_ROOT = path.join(
  __dirname,
  "..",
  "..",
  "ios",
  "Sources",
  "NutriQuest",
  "Resources",
  "Characters.xcassets"
);

const force = process.argv.includes("--force");

/**
 * Characters that already have hand-drawn art in the asset catalogue, keyed by
 * roster id -> existing imageset name.
 *
 * These are skipped: the hand-drawn vectors in design/characters are better
 * art than anything generated, and shipping both puts two imagesets in the
 * catalogue whose names collapse to the same generated Swift symbol -- which
 * Xcode warns about and then resolves arbitrarily.
 */
const HAND_DRAWN: Record<string, string> = {
  "broccoli-bud": "BroccoliBud"
};

/** Square edge the generator is asked for. */
const ART_SIZE = 512;
/** Share of the frame the provider's watermark occupies at the bottom. */
const WATERMARK_FRACTION = 0.1;

/** Xcode asset catalog metadata for a single raster image. */
function contentsJSON(filename: string): string {
  return JSON.stringify(
    {
      images: [{ filename, idiom: "universal", scale: "1x" }, { idiom: "universal", scale: "2x" }, { idiom: "universal", scale: "3x" }],
      info: { author: "nutriquest", version: 1 }
    },
    null,
    2
  );
}

/**
 * Sniff the real format from the magic bytes.
 *
 * The service advertises PNG and hands back JPEG. Trusting the request rather
 * than the bytes puts a JPEG in a file called .png, which Xcode's asset
 * catalogue will sometimes accept and sometimes silently drop -- the worst
 * kind of bug to chase, so name the file after what it actually is.
 */
function imageExtension(buffer: Buffer): "png" | "jpg" {
  if (buffer.length > 8 && buffer.subarray(0, 4).toString("hex") === "89504e47") return "png";
  if (buffer.length > 3 && buffer.subarray(0, 3).toString("hex") === "ffd8ff") return "jpg";
  throw new Error("response is neither PNG nor JPEG");
}

async function fetchArt(url: string): Promise<{ buffer: Buffer; ext: "png" | "jpg" }> {
  const response = await fetch(url, { signal: AbortSignal.timeout(180_000) });
  if (!response.ok) throw new Error(`HTTP ${response.status}`);
  const buffer = Buffer.from(await response.arrayBuffer());
  // The service answers errors with a tiny body and a 200, so size is the only
  // honest signal that an actual image came back.
  if (buffer.length < 5_000) throw new Error(`suspiciously small response (${buffer.length} bytes)`);
  return { buffer, ext: imageExtension(buffer) };
}

/**
 * Trim the provider's watermark off the bottom of the frame.
 *
 * The generator stamps "pollinations.ai" into the bottom-right corner despite
 * being asked not to. At runtime the app hides it by zooming the image 1.18x
 * (see CharacterArtwork.swift), but these files are checked in, so crop it out
 * once here rather than making every screen compensate forever. The subjects
 * are centred, so taking the bottom strip costs nothing.
 */
function cropWatermark(file: string): void {
  // sips only crops from the centre, so removing an N-pixel strip off the
  // bottom costs the same N off the top. That is a fair trade here: the
  // generator is asked for a centred subject, and losing a little empty
  // headroom is cheaper than shipping someone else's logo in our asset
  // catalogue or teaching every screen to zoom past it.
  const strip = Math.round(ART_SIZE * WATERMARK_FRACTION);
  const kept = ART_SIZE - strip * 2;
  const result = spawnSync("sips", ["-c", String(kept), String(ART_SIZE), file], { encoding: "utf8" });
  if (result.status !== 0) {
    throw new Error(`sips crop failed: ${result.stderr?.trim() || result.status}`);
  }
}

async function main(): Promise<void> {
  mkdirSync(ASSET_ROOT, { recursive: true });
  let written = 0;
  let skipped = 0;
  const failures: string[] = [];

  for (const character of ROSTER) {
    const handDrawn = HAND_DRAWN[character.id];
    if (handDrawn) {
      console.log(`  skip   ${character.imageKey} (hand-drawn art in ${handDrawn}.imageset)`);
      skipped++;
      continue;
    }

    const imagesetDir = path.join(ASSET_ROOT, `${character.imageKey}.imageset`);
    const existing = ["png", "jpg"]
      .map((ext) => path.join(imagesetDir, `${character.imageKey}.${ext}`))
      .find(existsSync);

    if (existing && !force) {
      console.log(`  skip   ${character.imageKey} (already checked in)`);
      skipped++;
      continue;
    }

    const url = characterArtURL(
      {
        name: character.name,
        colorHex: character.colorHex,
        rarity: character.rarity,
        statType: character.element,
        flavor: CHARACTER_FLAVOR[character.id] ?? character.tagline
      },
      character.id
    );

    try {
      process.stdout.write(`  fetch  ${character.imageKey} ... `);
      const { buffer, ext } = await fetchArt(url);
      const filename = `${character.imageKey}.${ext}`;
      mkdirSync(imagesetDir, { recursive: true });
      // Drop any previous file under the other extension so an imageset never
      // holds two copies of the same art.
      for (const stale of ["png", "jpg"].filter((candidate) => candidate !== ext)) {
        rmSync(path.join(imagesetDir, `${character.imageKey}.${stale}`), { force: true });
      }
      const written_path = path.join(imagesetDir, filename);
      writeFileSync(written_path, buffer);
      cropWatermark(written_path);
      writeFileSync(path.join(imagesetDir, "Contents.json"), contentsJSON(filename) + "\n");
      console.log(`${ext.toUpperCase()} ${(buffer.length / 1024).toFixed(0)} KB`);
      written++;
    } catch (err) {
      console.log(`FAILED (${err instanceof Error ? err.message : String(err)})`);
      failures.push(character.imageKey);
    }
  }

  console.log(`\n${written} written, ${skipped} already present, ${failures.length} failed`);
  if (failures.length) {
    console.log(`failed: ${failures.join(", ")}`);
    console.log("Re-run to retry only the missing ones.");
    process.exitCode = 1;
  }
}

void main();
