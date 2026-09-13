# NutriQuestUI — SwiftUI UI Kit

Complete, reusable design system for NutriQuest. Ported 1:1 from the design branch mockups (`design/`): white-first base, dynamic accent derived from the displayed character, chibi mascots, rarity system.

## Structure

```
NutriQuestUI/
  NQTheme.swift                  tokens: colors, spacing, radii, shadows, type scale
  NQAccent.swift                 dynamic accent system + environment injection
  NQRarity.swift                 rarity (outline colors) + stat types
  Characters/
    ChibiCharacterView.swift     parameterized chibi mascot (color, stat badge, expression)
  Components/
    NQButton.swift               NQButton (primary/secondary/ghost/destructive),
                                 NQStreakPill, NQChip, NQStatBadge
    NQStatBar.swift              NQStatBar, NQBanner, NQSectionHeader
    NQCard.swift                 NQCard, NQCharacterCard (rarity outline + ribbons),
                                 NQEmptyState
    NQNavigation.swift           NQTopBar, NQBottomNav, NQScreen scaffold, NQTab, NQLogoMark
  Animations/
    NQAnimations.swift           NQMotion presets, NQHaptic, NQPressableStyle,
                                 pop-in / slide-up / cascade / shake / success burst /
                                 shine sweep / breathing glow / floating sparkles
    NQMicroInteractions.swift    NQIcon vector set (16 icons, static + animated),
                                 NQTabIcon (bounce on select), NQCountUpText,
                                 NQHeartBurst, NQFlamePulse, NQConfetti
    NQLoadingStates.swift        AnimatedChibi (7 character motions), NQSummonReveal,
                                 NQScanBeam, NQSkeleton, NQDotsLoader, NQProgressRing,
                                 NQCheckmarkDraw
    NQTransitions.swift          NQTransition (pop/slideUp/push/summon/flip),
                                 NQRibbon, NQContentState (loading/empty/error/offline),
                                 NQSelectedGlow, NQWobble, NQLockedShimmer,
                                 NQBanner semantic presets
  NQUIDemoView.swift             component gallery (Xcode preview)
  NQAnimationDemoView.swift      live animation gallery (Xcode preview)
```

## Core concept: dynamic accent

Every screen reads its accent from the **displayed character's color**. Three modes:

| Mode | When | Accent |
|---|---|---|
| `.active` | character selected | light tint of that character's color |
| `.bestUnselected` | none selected, squad non-empty | best owned character's color |
| `.none` | empty squad | neutral grey |

Derived palette (computed, never hardcoded): `accentBg` (90% white), `accentSoft` (72% white), `accent` (base), `accentDark` (25% black).

### Wiring (once, at app root)

```swift
@State private var activeCharacter: Character? = ...

var accentContext: NQAccentContext {
    if let c = activeCharacter {
        return NQAccentContext(mode: .active, character: c.color)
    }
    if let best = squad.best() {
        return NQAccentContext(mode: .bestUnselected, character: best.color)
    }
    return .neutral
}

ContentView().nqAccentContext(accentContext)
```

Read anywhere inside:

```swift
@Environment(\.nqAccent) private var accent
// accent.accent, accent.accentSoft, accent.accentDark, accent.accentBg
```

## Building a screen

```swift
struct HomeView: View {
    @Binding var tab: NQTab

    var body: some View {
        NQScreen(tab: $tab, trailing: { NQStreakPill(count: 3) }) {
            ScrollView {
                VStack(alignment: .leading, spacing: NQTheme.spaceL) {
                    NQBanner("Display character: **Fibelle**")
                    NQSectionHeader("Today's quests", trailing: "3 left")
                    NQCard {
                        NQStatBar(label: "Protein", value: 0.72, valueText: "72%")
                    }
                    NQButton("Scan a snack", icon: "barcode.viewfinder") { ... }
                }
                .padding()
            }
        }
    }
}
```

## Character cards

```swift
NQCharacterCard(
    name: "Fibelle",
    color: .mint,                    // NQCharacterColor preset or custom
    rarity: .common,                 // drives outline: grey/blue/purple/gold
    statType: .fiber,                // chest badge icon
    state: .active                   // .normal / .active / .suggested / .locked
)
```

## Chibi mascot

```swift
ChibiCharacterView(
    color: .blossom,                 // body/head color + derived shading
    statType: .vitamin,              // chest badge
    expression: .happy               // .happy / .neutral / .sleepy / .sparkle
)
```

## Fonts

Type scale expects **Baloo 2** (headings) and **Quicksand** (body). Download both from
Google Fonts, add the TTFs to the app target + Info.plist (`UIAppFonts`). Without them,
`Font.custom` falls back to the system font gracefully — nothing breaks.

## Design tokens reference

| Token | Value |
|---|---|
| Ink (text) | `#3A342E` |
| Muted / faint | `#8A857C` / `#B9B4AC` |
| Surface | `#FAFAF8` |
| Hairline | `#EFEDE9` |
| Flame (streak) | `#FF9F5A` |
| Gold (legendary) | `#FFC24B` |
| Rarity outlines | grey `#C9C4BB`, blue `#56B8F5`, purple `#B892FF`, gold `#FFC24B` |
| Character presets | mint `#5FCB82`, sky `#56B8F5`, blossom `#F78FB3`, peach `#FFB86B`, lilac `#B892FF`, lime `#8FE3A0` |

## Screens to build with this kit

Main (home), Collection, Stats, Scan, GymCheck, Battle, Profile, WatchConnect —
mockups live in `design/*.dc.html` on this branch.
