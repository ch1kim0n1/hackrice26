# NutriQuest — iOS App (SwiftUI)

SwiftUI implementation of the NutriQuest design (see `../design`). Packaged as a Swift Package (`Package.swift`) so it can be added to an Xcode project as a local package, or its `Sources/NutriQuest` folder copied straight into an app target.

## Layout

- `DesignSystem/` — `Color+Hex.swift` (hex + HSL color inits), `DesignTokens.swift` (the accent-color rule: `DesignTokens.tone(for:mode:)` mirrors the design's `getTone()` exactly — same HSL math, same fallback grey for `colorMode == .none`)
- `Models/` — `Character` (each has an `artworkAssetName` mapping to its hand-drawn asset), `Rarity`, `StatType`, `ColorMode`
- `Components/` — `CharacterArtworkView` (shows a character's real artwork from `Resources/Characters.xcassets` when one exists, falling back to `ChibiCharacterView`'s generic procedural shape for locked/placeholder characters), `ChibiCharacterView` (the fallback shape, drawn with `Canvas`/`Path`), `CharacterCardView` (rarity ring + ACTIVE/SUGGESTED badge + locked state), buttons, `StatBar`, `Banner`, `BottomNavBar`
- `Screens/` — one SwiftUI view per screen: `HomeView`, `CollectionView`, `StatsView`, `ScanView`, `GymCheckView`, `BattleView`, `ProfileView`, `WatchConnectView`
- `App/` — `NutriQuestApp.swift` (entry point) and `RootTabView.swift` (tab bar + sample data wiring)
- `Resources/Characters.xcassets` — hand-drawn vector artwork for the 6 named characters (Broccoli Bud, Sushi Sam, Berry Belle, Citrus Chip, Grape Gus, Sprout Wisp), each with its own real silhouette rather than one shape recolored. PDF vector images, "Preserve Vector Data" on — drag this whole folder into your Xcode project (or add the SPM resource, see below) and it just works. Editable SVG sources + regeneration instructions are in `../design/characters/`.

## Notes for whoever wires this into the real app

- **Fonts**: screens use `.rounded` system fonts as a stand-in for Baloo 2 (display) / Quicksand (body). Bundle the actual `.ttf` files in the Xcode target and swap the two functions in `AppTypography` to use them by PostScript name.
- **Chibi icons**: the chest-badge icon uses an SF Symbol per `StatType` as a placeholder for the design's custom icon paths (see `ICONS` in `design/CharacterCard.dc.html`). Swap `StatType.systemImageName` for a custom asset/path once one exists.
- **Character artwork**: if you add `Resources/Characters.xcassets` as an SPM resource (add `resources: [.copy("Resources/Characters.xcassets")]` to the target in `Package.swift`) rather than dragging it into an app target directly, `Image("BroccoliBud")` needs `Image("BroccoliBud", bundle: .module)` instead — update `CharacterArtworkView` if you go that route.
- **Sample data**: `RootTabView` and `SampleData.characters` hard-code a demo collection and a fixed `colorMode`. Replace with real state from the backend (`GET /characters`, `GET /user/:id`) once wired up.
- Not yet wired: pull-to-refresh, actual scan/camera capture, and networking — this package is the visual/structural layer only.
- No Swift toolchain was available to build/typecheck this in the authoring environment; review it in Xcode before merging.
