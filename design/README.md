# NutriQuest — UI Design Source

Editable source for the NutriQuest iOS UI mockups (Design Components format, authored with Claude Design). The implementation that ships in the app lives in `../ios` (SwiftUI) and `../backend` (TypeScript) — this folder is the visual spec those are built from, not app code.

**Live, editable canvas:** https://claude.ai/code/artifact/eac69e9a-5490-43ce-8371-380f6f6ef0f2

## Screens

- `Main.dc.html` — Home / dashboard
- `Collection.dc.html` — character collection (rarity-outlined cards)
- `Stats.dc.html` — nutrition stats
- `Scan.dc.html` — barcode scan flow (states: idle / scanning)
- `GymCheck.dc.html` — AI training check (states: capture / verified)
- `Battle.dc.html` — battle mode (states: normal turn / fatigued)
- `Profile.dc.html` — profile, pfp, settings
- `WatchConnect.dc.html` — Apple Watch connect flow (states: prompt / searching / connected)
- `CharacterCard.dc.html` — shared character-card component (used by Collection; states: normal / active / suggested / locked / loading)

## UI Kit

In `ui kit/`, on its own canvas page ("UI Kit"):

- `Colors.dc.html` — palette (core, elevation tokens, conditional-accent states, text, 7-tier rarity, semantic)
- `Typography.dc.html` — Baloo 2 / Quicksand type scale
- `Components.dc.html` — NQCard elevation, buttons, chips/badges (7-tier rarity), stat bars, banners, bottom nav
- `Characters.dc.html` — chibi anatomy legend, stat badge variants, rarity rings (all 7 tiers, live component), size scale
- `States.dc.html` — generic Loading/Empty/Locked/Success patterns, plus every per-screen state side by side: CharacterCard (normal/active/suggested/locked/loading), Scan (idle/scanning), Gym Check (capture/verified), Battle (normal/fatigued), Connect Apple Watch (prompt/searching/connected)

`canvas.json` — layout manifest for both canvas pages ("App Screens" and "UI Kit").

## Design system

- Main app color: white / off-white.
- Secondary/accent color: derived from the selected (or best unselected) character's color, exposed as `accentColor` + `colorMode` ("active" / "best-unselected" / "none") tweak props on every screen — `colorMode: "none"` forces neutral grey. See the Colors sheet in the UI kit for the three accent-mode swatches, and the States sheet for every other per-screen state. Threaded further than button/outline usage: hero glows, banner tints, chip fills.
- Elevation: three named shadow levels (E1 resting, E2 raised, E3 floating) plus an accent-tinted glow layer, used consistently across CharacterCard, NQCard and banners instead of flat outlines. See the Colors and Components sheets.
- Characters: chibi-anime style mascots; each carries a `statType` (protein/fiber/vitamin/hydration) that picks the icon shown on its chest badge. Character illustration style is unchanged by this pass.
- Rarity — **7 tiers**: common/uncommon/rare/epic/legendary/mythic/secret, drives the Collection card's ring color (a filled band, not a stroke) independent of ACTIVE/SUGGESTED state. Secret is the one holographic ring in the system. See `CharacterCard.dc.html` for the full ramp and the reasoning behind the two new tiers (uncommon, mythic).

To regenerate the seeded, publishable canvas file from this source, use the `design` skill's `seed-canvas.mjs` helper against these `.dc.html` files and `canvas.json`.
