# Character artwork — SVG sources

Hand-drawn source art for the 6 named characters, each with its own real silhouette (not one shape recolored) so they read as distinct food characters at a glance:

- `broccoli-bud.svg` — floret crown + trunk
- `sushi-sam.svg` — rounded roll with a nori band + roe topper
- `berry-belle.svg` — teardrop body + calyx leaves + seed texture
- `citrus-chip.svg` — round fruit + stem + leaf + peel texture
- `grape-gus.svg` — cluster of overlapping circles + a curly vine
- `sprout-wisp.svg` — curved stem with a small head and two leaves

Colors are baked in as hex, computed from each character's own color via the same HSL formula used everywhere else in the app (`getTone()` in the `.dc.html` screens / `DesignTokens.tone(for:mode:)` in Swift): `accent` = that hue at 58% lightness, `accentDark` = 36% lightness, saturation floored at 45%. If a character's base color ever changes, recompute those two shades with the same formula and edit the SVG's `fill` values to match.

All six share a `viewBox="0 0 100 130"` and the same face motif (glossy anime eyes, blush, simple smile) for family resemblance, but each has its own body shape, "topper" (stem/vine/leaf/roe/calyx in place of a generic cowlick), and texture details.

## Regenerating the Xcode asset catalog

The `.svg` files here are the editable source. `../../ios/Sources/NutriQuest/Resources/Characters.xcassets` is generated from them as PDF vector images (Xcode's native vector format — checked "Preserve Vector Data"). To regenerate after editing an SVG:

```
pip install cairosvg
python3 -c "import cairosvg; cairosvg.svg2pdf(url='broccoli-bud.svg', write_to='BroccoliBud.pdf')"
```

then drop the PDF into its `.imageset` folder in `Characters.xcassets`, replacing the existing one (filename must match what `Contents.json` in that imageset points to).

## Adding a new character

1. Draw a new `<slug>.svg` here (`viewBox="0 0 100 130"`, same face motif, its own body shape).
2. Convert to PDF and add a new `<Name>.imageset` folder to `Characters.xcassets` (copy an existing one's `Contents.json` as a template).
3. Add the character to `SampleData.characters` in `ios/Sources/NutriQuest/Models/Character.swift`, and add its `id` → asset name mapping in `Character.artworkAssetName`.

A character with no entry in `artworkAssetName` automatically falls back to the generic procedural chibi shape (`ChibiCharacterView`) — used today only for locked "???" placeholders.
