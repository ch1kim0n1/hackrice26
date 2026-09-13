# Squad rarity VFX

The production change wraps only `CollectionView.gridCard`'s existing `CharacterArtwork(...).frame(width: 96, height: 124)` node. Every existing card, border, badge, label, button, filter, spacing, navigation, gesture, faint sprite and game-state call is preserved. Locked cards still pass nil artwork to the existing card implementation. CharacterArtwork's local, variant, remote, loading and missing-art behavior is unchanged. Battle/SquadPicker, fusion ceremonies and other screens are untouched.

## Files

New code is in `ios/Sources/NutriQuest/VFX/`: `RarityAnimationConfiguration.swift`, `RarityVFXAssetManifest.swift`, `RarityFrameCache.swift`, `RarityEffectLayers.swift`, `MonsterRarityPresentationView.swift`, and `RarityAuraDemoView.swift`. Tests: `ios/Tests/NutriQuestTests/RarityVFXTests.swift`. Asset preparation: `ios/scripts/prepare-rarity-vfx.py`. Only selected PNGs and license/credit records live in `ios/Sources/NutriQuest/Resources/RarityVFX/`.

Modified existing files: `CollectionView.swift` (artwork wrapper), `NutriQuestApp.swift` (identity-in-Release debug demo modifier), `project.yml` and `Package.swift` (production folder resource), and the regenerated `NutriQuest.xcodeproj/project.pbxproj`. Root `ATTRIBUTIONS.md` and `docs/rarity-vfx-assets.json` preserve provenance. No original character art was modified.

## Inspected packs and production choices

All four original ZIPs were opened read-only and extracted into a temporary directory. All PNGs were inspected for dimensions, alpha and bounds, with contact sheets for every effect family; four nested stylized ZIPs were also extracted and inspected. Raw packs, PSDs, Unity packages, ZIPs and temporary previews are not in the repository or app bundle.

| Pack / original ZIP | Inspected | Production selection |
| --- | --- | --- |
| Free Game FX / `Free Game FX.zip` | Seven 20-frame RGBA sequences, 256²; seven matching 1280×1024 sheets and PSDs | `S-PNG Frames/67/670000.png`–`670019.png` → `epic/epic_000.png`–`epic_019.png`; `69/690000.png`–`690019.png` → `gold/gold_000.png`–`gold_019.png`; `72/720000.png`–`720019.png` → `red/red_000.png`–`red_019.png` |
| Free Stylized Sprite VFX / `Stylized VFX.zip` | Bonfire, Butterfly, Dizzy + alternate, FireFlies, GasBurner, Green Portal, Heal + alternate, Leaves Falling, Portals v2, Quest, Quest Complete, Shield Aura, Smoke, Sword Slash, Torch; 512² RGBA frames | `Bonfire/1.png`–`16.png` → `flame/flame_000.png`–`flame_015.png` |
| Kenney Particle Pack / `kenney_particle-pack.zip` | 80 particle shapes with transparent and black-background versions, 16 rotated variants of each, preview and Unity package | `PNG (Transparent)/circle_05.png` → `mote/mote_000.png`; `PNG (Transparent)/star_04.png` → `spark/spark_000.png` |
| Smoke Aura / `Smoke.zip` | `0000.png`–`0090.png`, 256² RGBA; frame 0090 repeats the visible loop endpoint | `0000.png`, `0003.png`, …, `0087.png` → `smoke/smoke_000.png`–`smoke_029.png` |

[Exact per-file source paths, output paths, dimensions and shared crop coordinates](rarity-vfx-assets.json). Total: **108 PNGs, 5,202,742 bytes**. No manual target membership or path fix is needed: XcodeGen copies only `RarityVFX` as a folder; SwiftPM uses `.copy` to preserve the same lookup paths.

The Free Game FX files are already an appropriate 256² resolution; no upscaling or independent frame trimming was performed. Bonfire uses a single union crop with a safety margin for the whole sequence and is downscaled to at most 256 pixels. Kenney textures are 64². RGB/alpha shading is preserved; runtime `colorMultiply` gives Mythic a red treatment, and neutral smoke supports a near-black core with a gray rim. Frame order comes from explicit numeric ranges, never bundle enumeration.

Rejected: Free Game FX 66 (green poison/confetti palette and dense center), 68 (dense yellow disc), 70 (flower/radial motif), 71 (filled rain-like oval). Stylized Butterfly/Leaves/FireFlies are decorative environmental effects; Dizzy/Heal/Quest/Shield imply unrelated status or UI meaning; portal greens conflict with this rarity palette; GasBurner/Torch are localized flames; Sword Slash is an attack; the stylized Smoke plume is narrow and directional, unlike the selected surrounding smoke loop. All unused sheets/PSDs, Unity packages, black-backed particle images, rotated duplicates and extra particle shapes were rejected as unnecessary weight or opaque-background risk. The selected Bonfire is used only as a faint Mythic layer/surge, never a full-size foreground fire.

## Rarity mapping

| Rarity | Effect | Motion / particles |
| --- | --- | --- |
| Common, Uncommon | Original artwork only | None |
| Rare | Blue radial glow, opacity 0.30–0.50 over 2.3 seconds | Stationary art; no PNG animation/particles |
| Epic | Purple 67 loop at 16 FPS, soft purple glow | 4.5 pt float / 2 seconds; no particles |
| Legendary | Larger gold 69 loop at 18 FPS, brighter gold glow | 6 pt float / 2.1 seconds; five rising sparks; restrained pulse every 7.5 seconds |
| Mythic | Red 72 loop at 20 FPS, red glow, faint Bonfire layer | 7 pt float / 1.8 seconds; seven embers; surge every 8.5 seconds |
| Secret | Reversed Smoke Aura at 15 FPS, near-black core and neutral gray rim | 8 pt float / 1.8 seconds; ±1 pt drift; six particles physically converge; dark pulse every 10.5 seconds |

All layers are behind the character. Offsets affect only the artwork, not the card. Decoration is hidden from accessibility and ignores hit testing. A softly masked background may extend at most eight points around the artwork without participating in layout or altering parent clipping. Existing rarity label/chip colors are preserved, including Secret's existing cyan UI chip.

## Playback, caching and accessibility

A single SwiftUI TimelineView per active character drives frames, sinusoidal float, radial glow and a lightweight Canvas. No third-party dependencies or SpriteKit surfaces were necessary. Frame arrays are decoded on a shared actor with ImageIO caching enabled; concurrent requests for the same sequence serialize to one decode. The NSCache is limited to seven production sequences and 32 MiB; cache identity includes the preprocessing version. Tinting doesn't duplicate textures. All seven decoded sequences together are below 32 MiB. Memory warnings purge cached references; active views retain only their current textures.

Each artwork's background geometry checks viewport intersection, in addition to SwiftUI appearance/disappearance. Off-screen views have no TimelineView and drop their frame references; lifecycle-bound async loads cancel. Scene inactivity stops ticking. Changing rarity refreshes the load identity. An origin held in State prevents unrelated parent updates resetting the phase. Returning on-screen rejoins the continuous cycle. Particle count is fixed and capped at eight; no emitter nodes accumulate.

Reduce Motion (or the demo's static preview) removes timeline playback, floating/drift, moving particles and accents. Aura layers select a representative middle frame and the glow uses a fixed midpoint. Common/Uncommon remain the original image. Low Power Mode caps timeline updates at 12 FPS and removes particles/surges. Missing/corrupt frames are skipped with debug-only logging; empty sequences safely show only the remaining glow/character. Unknown presentation rarity strings resolve to the existing Common tier without changing decoding or game models.

## Open and use the demo

Set Xcode scheme Run → Arguments to `-rarityVFXDemo -skipOnboarding -tour.seen YES`, or launch the installed Debug app:

```sh
xcrun simctl launch booted com.nutriquest.app -rarityVFXDemo -skipOnboarding -tour.seen YES
```

This presents a debug sheet over the normal root, with Done to return. Release has no demo screen or navigation. Expand **Preview controls** for 0.5×/1×/1.5× speed; Small/Normal/Large scale; particle/float toggles; static preview; dark/light background; and the 28-card stress grid. Controls affect environment overrides only, never production defaults. The demo always uses the same existing Broccoli Bud base PNG, regardless of rarity. Both the whole demo and a Secret component have SwiftUI previews.

Extra Debug launch flags: `-rarityVFXLight`, `-rarityVFXStatic`, `-rarityVFXStress`. `-rarityVFXDisabled` makes the production wrapper return the original artwork directly, for the required before/after comparison. These switches do not persist changes to the player's game data.

## Tuning

In `RarityAnimationConfiguration.configuration(for:)`, change `auraScale` / `auraOpacity`, `auraFPS`, `glowOpacity` / `glowScale` / `glowDuration`, `particleCount` / `particleLifetime` / `particleSize` / `particleOpacity`, `floatDistance` / `floatDuration` / `horizontalDrift`, and `accentInterval` / `accentDuration` / `accentStrength`. `Metrics` holds the local overflow limit, soft-mask boundary, glow extent, neutral rim and secondary layer values, particle paths and refresh/count ceilings. Keep the layout contract and lower-tier motion rules intact.

## Licenses

See [ATTRIBUTIONS.md](../ATTRIBUTIONS.md) and bundled `RarityVFX/Licenses`. Kenney's original CC0 license is copied verbatim. The other ZIPs contain no license documents; their actual source-page terms and credits are recorded, rather than invented archive licenses. Free Game FX uses the author's CC BY 3.0 option, Smoke Aura is CC0, and Kalponic's displayed usage terms plus CC BY 4.0 metadata are both documented. No raw asset library is redistributed.

## Validation

Validation commands/results and screenshot comparison are recorded below after the final simulator pass.
