# NutriQuest Logo — Design Rationale

## Research

Studied 2025–2026 nutrition + gacha app logo trends:

| App | Approach | Takeaway for us |
|---|---|---|
| **Yazio** (Koto rebrand) | Yettie yeti mascot, bold type, "Good Dopamine" motion | Mascot-led warmth beats clinical tracking |
| **Yoa** | Orange fruit character, AI scan, gamified streaks | Fruit-as-character reads instantly as "food + friend" |
| **Macromascot** | Skia mascot animations, streaks, GPT-4o scan | Personality = retention |
| **BitePal** | Raccoon mascot, playful | Mascots reduce judgment |
| **Nutrivo / Nutri-Buddy** | PopMart-style fruit-animal hybrids, lime green | Collectable toy aesthetic = gacha fit |
| **Wist** | Bespoke illustration language, light + playful | Custom marks > stock icons |

**Common thread:** mascot-led, vibrant, anti-clinical, motion-aware. NutriQuest already has chibi mascots (Berry Belle, Citrus Chip, Broccoli Bud, Sprout Wisp, Grape Gus, Sushi Sam) — the logo should leverage that asset rather than introduce a foreign symbol.

## Design decisions

### Mark: "Quest Sprout"

A chibi sprout character (the app's `sprout-wisp` mascot, simplified) inside a rounded barcode-scan frame. Three signals in one mark:

1. **Sprout mascot** — the app's signature chibi style. Reads as "friend / companion / quest party member."
2. **Scan frame corners** — the four L-shaped corners echo the barcode scanner UI. Reads as "scan to summon."
3. **Sparkle** — top-right star burst. Reads as "gacha / loot / reward."

The sprout is the simplest of the six mascots (single stem + leaf + face), so it scales to 16×16 app icon size without losing recognition. Berry Belle's teardrop body and seeds would mud at small sizes.

### Color

- **Primary mark:** `#5FCB82` (NutriQuest green, already in the palette as `--green` / `NQTheme.success`).
- **Scan frame:** `#3A342E` (ink, the existing text color).
- **Sparkle:** `#FFC24B` (gold, the existing rarity/legendary color).

Single-color reproduction works: the mark is designed to read in pure `#3A342E` on light, or pure white on `#5FCB82` (the app icon background).

### Wordmark

Set in **Baloo 2 Bold** (already the app's display font). The "Q" in Quest gets a leaf-tail flourish that echoes the sprout's leaf — a quiet brand rhyme without a heavy ligature.

Two layouts:
- **Horizontal:** mark left, wordmark right. Used on landing page, nav bar, email header.
- **Stacked:** mark above wordmark. Used on app icon, splash screen, social cards.

### App icon

`#5FCB82` background, white mark. iOS single-corner radius applied. The scan-frame corners are pulled in slightly vs. the horizontal logo so they don't kiss the icon's safe-area inset.

### What we deliberately avoided

- **Checkmark** (current landing logo) — reads as "diet compliance / chore done." Wrong emotional register; the app is about adventure, not judgment.
- **Barcode itself** — too literal, too clinical, and indistinguishable from any retail app.
- **Heart / pulse** — reads as medical or dating.
- **Plate / fork** — reads as restaurant review app.
- **Full mascot bust** — Berry Belle etc. are great at 170×220 but mud at 60×60 app icon size. The sprout is the only one that survives the scale down.

## Files

- `mark.svg` — the sprout-in-scan-frame mark, full color
- `mark-mono.svg` — single-color version (ink on transparent)
- `wordmark.svg` — "NutriQuest" in Baloo 2 Bold with leaf-tail Q
- `logo-horizontal.svg` — mark + wordmark, horizontal lockup
- `logo-stacked.svg` — mark + wordmark, stacked lockup
- `app-icon.svg` — 1024×1024 app icon (green bg, white mark)
- `app-icon-dark.svg` — dark mode variant (ink bg, green mark)
- `favicon.svg` — 32×32 favicon (mark only, no frame)
