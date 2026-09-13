type Sprite = { idle: string; hurt: string; dir?: string; ext?: string };

/** Cartoon idle/hurt filenames in game-assets/, keyed by character id. */
const SPRITES: Record<string, Sprite> = {
  "broccoli-bud": { idle: "broccoli-char", hurt: "brocoli-hurt" },
  "carrot-cadet": { idle: "carrot-char", hurt: "carrot-hurt" },
  "water-droplet": { idle: "water-char", hurt: "water-hurt" },
  "bean-sprout": { idle: "bean-sprout-char", hurt: "mean-sprout-hurt" },
  "spinach-scout": { idle: "spinach-char", hurt: "spanich-hurt" },
  "almond-knight": { idle: "almond-char", hurt: "almond-hurt" },
  "salmon-striker": { idle: "salmon-char", hurt: "salmon-hurt" },
  "avocado-aegis": { idle: "avocado-char", hurt: "avocado-hurt" },
  "kale-colossus": { idle: "kale-char", hurt: "kale-hurt" },
  "chia-chieftain": { idle: "chia-seed-char", hurt: "chia-hurt" },
  "pomegranate-paladin": { idle: "pomegranate-char", hurt: "pomegranate-hurt" },
  "turmeric-titan": { idle: "turmeric-char", hurt: "turmeric-hurt" },
  "spirulina-wyrm": { idle: "spirulina-char", hurt: "spirulia-hurt" },
  "the-first-seed": { idle: "seed-char", hurt: "seed-hurt" },
  "oat-sprout": { idle: "oat-char", hurt: "oat-hurt" },
  "rice-grain": { idle: "rice-char", hurt: "rice-hurt" },
  "yogurt-sage": { idle: "Yogurt-char", hurt: "yogurt-hurt" },
  "berry-bolt": { idle: "raspberry-char", hurt: "rasberry-hurt" },
  "quinoa-quill": { idle: "quinoa-char", hurt: "quinoa-hurt" },
  "mango-monarch": { idle: "mango-char", hurt: "mango-hurt" },
  "cacao-phantom": { idle: "cocoa-char", hurt: "coca-hurt" },
  "sushi-sam": { idle: "sushi-char", hurt: "sushi-hurt" },
  "berry-belle": { idle: "berry-char", hurt: "berry-hurt" },
  "citrus-chip": { idle: "orange-char", hurt: "orange-hurt" },
  "grape-gus": { idle: "grapes-char", hurt: "grape-hurt" },
  "sprout-wisp": { idle: "Sprout-char", hurt: "sprout-hurt" },
  "shark-brainrot": { idle: "shark-brainrot", hurt: "shark-brainrot", dir: "brainrot" },
  "zibra-zubra-zibralini": { idle: "Zibra-Zubra-Zibralini", hurt: "Zibra-Zubra-Zibralini", dir: "brainrot" },
  "frigo-camello": { idle: "Frigo-Camello", hurt: "Frigo-Camello", dir: "brainrot", ext: "webp" },
  "bobrini-cocosini": { idle: "Bobrini-Cocosini", hurt: "Bobrini-Cocosini", dir: "brainrot", ext: "webp" },
  "triple-t-brainrot": { idle: "triple-t-brainrot", hurt: "triple-t-brainrot", dir: "brainrot" }
};

const FALLBACK: Sprite = { idle: "other-dish-char", hurt: "other-dish-hurt" };

export function spriteFile(characterId: string, hurt = false): string {
  const id = characterId.replace(/^crate-/, "").replace(/^lan-opp:/, "");
  const pair = SPRITES[id] ?? FALLBACK;
  return hurt ? pair.hurt : pair.idle;
}

/** Path under game-assets/, including extension. */
export function spriteRelPath(characterId: string, hurt = false): string {
  const id = characterId.replace(/^crate-/, "").replace(/^lan-opp:/, "");
  const pair = SPRITES[id] ?? FALLBACK;
  const name = hurt ? pair.hurt : pair.idle;
  const ext = pair.ext ?? "png";
  return pair.dir ? `${pair.dir}/${name}.${ext}` : `${name}.${ext}`;
}
