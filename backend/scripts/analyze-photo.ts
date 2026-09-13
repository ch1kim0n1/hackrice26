// Try the dish analysis engine against a real photo.
//
//   npx ts-node scripts/analyze-photo.ts path/to/plate.jpg
//
// The engine's logic is unit-tested against stubbed replies, but its real
// accuracy — does it find every food, are the portions believable? — can only
// be judged on actual plates. Run this over a spread of real, messy photos
// before trusting the numbers downstream. Prints what the user would see on
// the review screen, plus the derived signals the character is built from.

import { readFileSync } from "fs";
import { analyzeDishPhoto } from "../src/nutrition/analyze";
import { dishRarity } from "../src/nutrition/character";
import { per100g } from "../src/nutrition/totals";
import { NotFoodError, VisionUnavailableError } from "../src/nutrition/types";

async function main() {
  const path = process.argv[2];
  if (!path) {
    console.error("usage: ts-node scripts/analyze-photo.ts <photo.jpg>");
    process.exit(1);
  }

  const base64 = readFileSync(path).toString("base64");
  console.log(`Analyzing ${path} (${(base64.length / 1024).toFixed(0)} KB base64)…\n`);

  const started = Date.now();
  const analysis = await analyzeDishPhoto(base64);
  const elapsed = ((Date.now() - started) / 1000).toFixed(1);

  console.log(`${analysis.dishName}   [${elapsed}s, confidence ${analysis.confidence}]`);
  if (analysis.lowConfidence) console.log("  ** low confidence — the UI would ask the user to look closely");
  console.log();

  for (const item of analysis.items) {
    console.log(
      `  ${item.name.padEnd(30)} ${String(Math.round(item.portionG)).padStart(5)} g  ` +
        `${String(Math.round(item.calories)).padStart(5)} kcal  ` +
        `P${Math.round(item.proteinG)} C${Math.round(item.carbsG)} F${Math.round(item.fatG)} ` +
        `Fib${Math.round(item.fiberG)}  [${item.foodGroup}, conf ${item.confidence}]` +
        (item.micronutrients.length ? `  ${item.micronutrients.join(",")}` : "")
    );
  }

  const t = analysis.totals;
  console.log(`\n  TOTAL${"".padEnd(25)} ${String(Math.round(t.portionG)).padStart(5)} g  ${String(Math.round(t.calories)).padStart(5)} kcal`);
  console.log(`  protein ${t.proteinG} g · carbs ${t.carbsG} g · fat ${t.fatG} g · fiber ${t.fiberG} g · sugar ${t.sugarG} g`);
  console.log(`  micro score ${t.microScore}  groups [${t.foodGroups.join(", ")}]  dominant ${t.dominantFoodGroup}`);
  console.log(`  per 100 g: ${JSON.stringify(per100g(t))}`);
  console.log(`\n  would summon a ${dishRarity(analysis).toUpperCase()} character (nova ${analysis.nova})`);
}

main().catch((err) => {
  if (err instanceof VisionUnavailableError) {
    console.error(`Analyser unavailable: ${err.message}`);
    console.error(
      "\nThe default endpoint (Pollinations' anonymous tier) now answers 402 for\n" +
        "uncached requests. Point VISION_API_URL / VISION_MODEL / VISION_API_KEY at\n" +
        "any OpenAI-compatible vision endpoint and re-run."
    );
    process.exit(3);
  }
  if (err instanceof NotFoodError) {
    console.error(`Not food: ${err.message}`);
    process.exit(2);
  }
  console.error(err);
  process.exit(1);
});
