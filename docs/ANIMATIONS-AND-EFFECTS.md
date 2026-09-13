# Animations & Effects — Plan

Scope: every place motion, haptics, sound, or particle effects touch the iOS
app. This is a **plan**, not a changelog — it audits what exists today (more
than you'd guess), names the gaps, and sequences the work. Written after a
full pass over `ios/Sources/NutriQuestUI`, every screen in
`ios/Sources/NutriQuest/Screens`, `BattleKit`, and the `design/*.dc.html`
mockups.

**Read this before touching any animation code.** The single biggest risk
here is not "missing effects" — it's building a fourth bespoke reveal
animation when a fifth, better one already exists in `NutriQuestUI`. Section
2 exists to stop that.

---

## 1. Housekeeping — read this first

`C:\hackrice26\NutriQuestUI\` (repo root, **not** `ios/Sources/NutriQuestUI/`)
is a **stale duplicate**. It's a 4-tier-rarity snapshot of the design system
from before it moved under `ios/Sources/`, committed in `57c6fb6 local to
github`. It is not part of the Xcode project and nothing imports it. Anyone
(human or AI) grepping for `NutriQuestUI` will find both trees — always
verify you're editing `ios/Sources/NutriQuestUI/`. Deleting the stray root
copy is a 5-minute PR and should happen before this plan's Phase 1 lands, so
it stops shadowing search results.

---

## 1b. Status

This plan was written against `main` at `a38230b`. `428166d "Rebuild game
systems around final-dev-doc spec"` then rewrote several of the audited
screens — `BattleView` (576 → 982 lines), the crate flow (now coin-bought
Cookbooks granting rarity **Cases**; keys, pity and multi-open are gone), and
parts of Scan, Dungeon, Journey, Profile and onboarding. The audit below has
been corrected where that rebuild invalidated it.

**Landed** (this branch):

| Phase | Item | State |
|---|---|---|
| 0 | Stale root `NutriQuestUI/` deleted | done |
| 0 | `NQConfetti` + `NQCheckmarkDraw` Reduce Motion | done |
| 1 | Scan summon overlay Reduce Motion (the P0) | done |
| 1 | Crate/Case opening Reduce Motion | done |
| 2 | Crit flash + rarity-scaled shake | done |
| 2 | Faint droop + `ChibiExpression.fainted` | done |
| 2 | Victory confetti | done |
| 2 | ★5 leader aura (arena + squad picker) | done |
| 2 | HP bar `maxHP` correctness | **obsolete** — `428166d` replaced the hardcoded `140` with real per-unit HP |
| 2 | Expedition scoped as outcome-feed-only | done (decision recorded in `DungeonView`) |
| 4 | `nqRarityTreatment` + applied to all five reveal surfaces | done |
| 4 | `NQBracketBanner` extracted | done |
| 6 | Reduce Motion P2/P3 sweep (carousel, casino hub, onboarding) | done |

**Not started**, and deliberately so:

- **Phase 3 (battle animator extraction).** The plan sequences it after Phase
  2 and it is a refactor, not a behaviour change. Worth revisiting now that
  `428166d` has already restructured `BattleView` around a `BattleScene`
  model — that rebuild did some of the same work from a different angle.
- **Phase 5 (Collection→Detail hero transition, onboarding migration onto
  `NQTransition`, Home gauge consistency).** Only the Reduce Motion half of
  the onboarding item landed.
- **Phase 6 (quests).** Still gated on the screen existing at all — see §4.4.
- The `NQCountUpText` standardisation and the `CaseOpeningView` → `NQCapsule`
  consolidation from §4.2. `CaseOpeningView` got the shared rarity treatment
  so its reveal no longer looks flat, but it still runs its own roulette-reel
  mechanic rather than the capsule one.

**Not verified.** None of this has been compiled. It was written on Windows,
which has a Swift toolchain but no iOS SDK and no SwiftUI, so every changed
file was checked with `swiftc -parse` (syntax only — no type checking, no
symbol resolution). The `xcodegen generate` → build → `./scripts/test-ios.sh`
gate from `CLAUDE.md` still has to run on macOS before this merges, and the
zero-warnings rule in particular cannot be confirmed from here.

---

## 2. What already exists — the reuse-first map

`ios/Sources/NutriQuestUI` is **not a stub**. It's a mature, mostly
`accessibilityReduceMotion`-aware animation kit. The plan below is written
against this inventory — new work should extend these types, not invent
parallel ones.

| Need | Already built | File |
|---|---|---|
| Timing/easing vocabulary | `NQMotion.snappy/springy/bouncy/gentle/quick/fill` | `NQAnimations.swift` |
| Haptics | `NQHaptic.light/medium/success/warning/error/selection` | `NQAnimations.swift` |
| Haptic+sound bundled | `NQJuice.tap/success/reveal/error/unlock/hit(heavy:)/crit/keys/wagerResult` | `NQSound.swift` |
| Sound bank | 21 named `NQSound.Effect` cases incl. `hit`, `hitHeavy`, `crit`, `victory`, `bust` | `NQSound.swift` |
| Press feedback | `NQPressableStyle`, `nqSquish()` | `NQAnimations.swift` |
| Entrances | `NQPopIn`, `NQSlideUp`, `NQCascade` | `NQAnimations.swift` |
| Error/attention shake | `NQShake` | `NQAnimations.swift` |
| Hit/camera shake | `NQImpactShake` ("battle hits", already documented as such) | `NQAnimations.swift` |
| Damage/reward number popup | `NQFloatingValue` | `NQAnimations.swift` |
| Radial success burst | `NQSuccessBurst` | `NQAnimations.swift` |
| Full-screen confetti | `NQConfetti` (36 pieces, physics fall) | `NQMicroInteractions.swift` |
| Legendary shimmer | `NQShineSweep`, `NQBreathingGlow`, `NQLockedShimmer` | `NQAnimations.swift` / `NQTransitions.swift` |
| Screen/card transitions | `NQTransition.pop/slideUp/push/summon/flip` | `NQTransitions.swift` |
| Loading | `NQSkeleton`, `NQDotsLoader`, `NQProgressRing`, `NQCheckmarkDraw` | `NQLoadingStates.swift` |
| Character idle motion | `NQCharacterMotion` (`idle/excited/sleepy/talk/sad/wave`) + `AnimatedChibi` (blink loop) | `NQLoadingStates.swift` |
| Reward/character reveal shell | `NQSummonReveal` (blur+scale materialize) | `NQLoadingStates.swift` |
| **Full reward-reveal state machine** | `NQCapsule` / `NQCapsuleStage` (`dropping→charging→shaking→cracking→open`), rarity-tinted, fully reduce-motion compliant | `Components/NQCapsule.swift` |
| Rarity color/stroke lookup | `NQRarity` (7 tiers: common…secret) | `NQRarity.swift` |
| Number ticking | `NQCountUpText` | `NQMicroInteractions.swift` |
| Barcode scan feedback | `NQScanBeam` | `NQLoadingStates.swift` |
| Swipeable card stack | `NQCoverFlowCarousel` | `Components/NQCoverFlowCarousel.swift` |

**Two documented design philosophies already baked into the kit — keep
following them:**
1. *"Motion is one-shot and interaction-driven, never a permanent idle
   loop... premium products keep screens calm."* (`NQAnimatedIconView` doc
   comment.) Don't add new ambient loops without a specific reason.
2. Selection state should **not** pulse (`NQSelectedGlow`'s doc comment is
   explicit about this) — a static ring, not a breathing one.

**Known inconsistencies inside the kit itself** (fix opportunistically, not
urgent):
- `NQConfetti` is the only major one-shot effect that does **not** check
  `accessibilityReduceMotion`.
- `NQCheckmarkDraw` also skips the reduce-motion check the rest of the file
  has.
- `NQSummonReveal`'s doc comment claims it includes "particle burst +
  confetti for legendary" — it doesn't; those are composed manually at each
  call site (see `NQAnimationDemoView.summonOverlay` for the reference
  pattern). Either fix the comment or fold the composition into the type.
- `NQTransition.flip` is a scale transition, not a 3D flip — misleading name.
- `NQMicroInteractions.swift`'s icon doc claims per-icon animation variety
  ("pulse for flame/heart, bounce for battle/star, spin for barcode") but
  every icon actually gets the same settle-bounce. Either implement the
  variety or correct the comment.
- `NQCoverFlowCarousel` only zeroes `rotation3D` under reduce motion; scale
  and position still animate — partial compliance.

---

## 3. Design principles

These aren't new — they're what the existing kit already does, made
explicit so new work stays consistent:

1. **Rarity is the visual grammar.** Every reveal, card, and reward escalates
   by the same 7-tier ramp (`NQRarity`), not a bespoke per-screen scheme.
   Today only `CrateOpeningView` actually does this (§4.2) — that's the gap,
   not the principle.
2. **Named tokens, not magic numbers.** `CLAUDE.md`'s "raw hex/padding in
   feature code is a review reject" applies to motion too: new springs get a
   named `NQMotion` case, new one-shot effects get a shared type, not an
   inline `.spring(response: 0.31, dampingFraction: 0.64)` at a screen call
   site (this already happens in several places — see §4).
3. **Haptic + sound travel together, through `NQJuice`.** Raw `NQHaptic`/
   `NQSound` calls at a screen level are a code smell once a `NQJuice` bundle
   exists or should exist.
4. **Everything respects Reduce Motion, with an instant equivalent, not a
   disabled one.** The kit's pattern is "jump to the final state," never
   "show nothing." Every new effect must ship with its reduce-motion branch
   in the same PR, not as a follow-up.
5. **Motion is transform-based over static art, never frame sprites.**
   Characters are either hand-drawn vector art (PDF, per-rarity variants,
   `character_images` in the schema) or the procedural `ChibiCharacterView`
   fallback. Neither has animation frames. "Attack," "faint," "victory" are
   therefore *wrapper transforms* (offset/scale/rotation/opacity/tint)
   applied around whichever artwork is showing — see `CharacterArtwork` in
   `KitBridging.swift`, which already resolves real-art-vs-chibi and is the
   correct place to hang new motion, not a fork per art type.
6. **Server-authoritative outcomes stay server-authoritative in animation
   too.** Cauldron Crash's crash point is never sent to the client while a
   round is live (`CLAUDE.md`); the "vessel explosion" and any future
   suspense-building animation must only ever *react* to a result already
   resolved server-side, never imply information the server hasn't sent.
7. **One-shot by default; only named ambient effects loop.** Streak flames,
   locked shimmer, breathing glow on an *active* selection — fine. A new
   idle loop on every card is not.

---

## 4. Gap map by feature area

### 4.1 Battle (Ranked / Expedition / Arena / LAN)

All battle modes funnel through one screen — `BattleView.swift` — which LAN
reaches too after its own lobby/discovery UI resolves (`LANLobbyView.swift`
has zero battle-animation code of its own; it hands off entirely). That's
good: fixing `BattleView` fixes every mode at once, except Expedition, which
currently bypasses combat animation altogether (below).

`BattleView.animateReplay(_:)` walks `BattleReplay.events` with an `async`
`Task.sleep` sequence — no shared "battle animator," it's bespoke local state
(`yourLunge`, `opponentHit`, `damagePopups`, etc.) plus `playChoreography()`,
a self-labeled "staged theater" filler sequence that plays while waiting on
the server response and isn't driven by real replay data.

| Doc wishlist (`BATTLE-SYSTEM.md` §10) | Status |
|---|---|
| Attack lunge | **Done** — offset+scale squash/stretch, now via `NQMotion.attackLunge` |
| Damage popup | **Done** — `NQFloatingValue`, color-coded for normal/super-effective/crit/miss |
| Crit flash | **Done** — a gold `plusLighter` frame across the arena (`NQMotion.critFlash`, ~90ms) on top of the per-hit tint, plus shake intensity 12 vs 7 |
| Faint droop | **Done** — the fainted unit rotates 12°, sinks, desaturates and fades to 45% (`NQMotion.faintDroop`); the chibi fallback also gets `ChibiExpression.fainted` |
| Victory confetti | **Done** — `NQConfetti` fires from `finish()` alongside the existing `nqSuccessBurst` |

**Plan:**

- **Faint droop** — add a wrapper transform (rotate ~12°, sink offset, desaturate/fade to ~40% opacity over ~500ms) applied to `CharacterArtwork` in the fainted slot, triggered on `.faint`. Per principle 5, this wraps the artwork container — it works identically for real art and the chibi fallback. As a bonus, add a `ChibiExpression.fainted` case (closed ×-eyes) for when the fallback specifically is on screen; it's a nice-to-have layered on top of the transform, not a substitute for it.
- **Crit flash** — add a genuine full-arena flash distinct from the per-hit tint: a brief white/gold radial flash (~80ms) layered on top of the existing tint for `crit == true` only. `NQCapsule`'s "crack" white-flash is the nearest existing pattern to adapt.
- **Victory confetti** — call `NQConfetti` from `present(_:mySide:)` alongside the existing `nqSuccessBurst`, gated by `accessibilityReduceMotion` (and note: this is also the fix for `NQConfetti`'s own missing reduce-motion check from §2 — do both in the same PR).
- ~~**HP bar accuracy**~~ — was normalized against a hardcoded `140`. Obsolete: `428166d` rebuilt the arena around a `BattleScene` model carrying real per-unit `hp`/`maxHP`, so the bars are already accurate.
- **Extract a shared battle animator.** `animateReplay`/`playChoreography`'s hand-rolled state today lives entirely inside `BattleView`. Mirror `NQCapsule`'s architecture (an explicit stage enum + `.task(id:)` sequencing, cancellation-safe) as a `NQBattleAnimator`-shaped type in `NutriQuestUI` or a UI-adjacent module. This isn't just cleanliness: it's what lets Expedition (below) and any future PvE combat screen get the same juice without copy-pasting `BattleView`'s internals.
- **Leader aura.** `NET-WORTH.md`: a ★5 character grants a squad-wide "Leader aura" (+5% dominant stat). There is currently no visual marker for this anywhere. Add a subtle `NQBreathingGlow` (tinted to that unit's accent) on the leader's card in the squad row and in `SquadPickerView` — distinct from the existing "ACTIVE" ribbon, so a viewer can tell "this squad has a maxed leader" at a glance.
- **Sludge variant.** A day where >60% of calories come from sugar produces a "Sludge" character variant (−30% stats, still collectible, per `BATTLE-SYSTEM.md` §3). No visual treatment exists for this anywhere in the four screen audits. Low priority, but worth a small desaturated/grimy tint + a "Sludge" chip wherever `CharacterArtwork` renders one, so it reads as a distinct (if unfortunate) state rather than a rendering bug.
- **Expedition (PvE) has no combat animation at all.** `DungeonView` presents floor outcomes as a static checklist/feed (`runFeed`) with a spinner while "descending" — it never shows a fight. This may be an intentional scope choice (PvE is meant to feel like an idle/auto-battler), but it should be a *decision*, not a gap nobody noticed: either explicitly scope Expedition as "no battle animation, outcome-feed only" in this doc (recommended — it's a different genre of interaction and doesn't need `BattleView`'s choreography), or, if product wants Expedition fights to feel like real battles, it becomes the first consumer of the extracted battle animator above.

### 4.2 Casino & gambling minigames

Five reveal flows (`CrateOpeningView`, `CaseOpeningView`, `CauldronCrashView`,
`KitchenMinesView`, `PlinkoView`, `PortalWheelView` — six, really) exist with
**wildly inconsistent** production value, because each was built
independently rather than against a shared reveal architecture.

| Screen | Reveal mechanism | Rarity-scaled? | Shares `NQCapsule`/`NQConfetti`? |
|---|---|---|---|
| `CrateOpeningView` | Hold-to-charge → shake → crack → open (`NQCapsuleStage`) | **Yes** — legendary+ gets longer suspense, extra haptics, looped rumble sound, confetti gate | Yes — the reference implementation |
| `CaseOpeningView` | Horizontal roulette reel (`CaseRouletteStrip`) → plain `NQTransition.pop` | ~~No~~ → now via `nqRarityTreatment` | Reel mechanic still its own |
| `CauldronCrashView` | Bespoke vessel bubble/shake/explosion (~190 lines one-off particle code) | ~~No~~ → now via `nqRarityTreatment` | Confetti yes, capsule no |
| `KitchenMinesView` | Per-tile scale bump, emoji glyphs as tile sprites | ~~No~~ → now via `nqRarityTreatment` | Confetti yes, capsule no |
| `PlinkoView` | Custom ball physics, peg impact shockwave rings | ~~No~~ → now via `nqRarityTreatment` | Confetti yes, capsule no |
| `PortalWheelView` | Custom deceleration curve (`PortalWheelSpinCurve`), wedge glow | ~~No — glow keyed to the wheel colour~~ → now via `nqRarityTreatment` | Confetti yes, capsule no |

The gap this closed: pull a Secret-tier character from a crate and it got
confetti, a glow and a long haptic build; pull the same character from Plinko
or the Portal Wheel and it looked identical to a Common. One modifier now
owns that ladder for all five surfaces. What's still per-screen is the
*mechanic* — reel vs wheel vs capsule — which is intentional variety, unlike
the reveal, which was accidental inconsistency.

**Plan:**

- **Formalize `nqRarityTreatment(_ rarity: NQRarity)`** as a shared modifier
  in `NutriQuestUI` that escalates a fixed way: common/uncommon → nothing
  extra; rare → `NQShineSweep`; epic → `+ NQBreathingGlow`; legendary/mythic
  → `+ NQConfetti` gate; **secret → holographic shimmer**, which the design
  doc (`design/README.md`: *"Secret is the one holographic ring in the
  system"*) already specifies but no Swift code implements yet (`NQRarity`
  today is color/stroke-width only — see §2). This one modifier, applied at
  the moment of reveal in all five/six minigames, closes the whole
  consistency gap in one abstraction instead of five bespoke fixes.
- **Retire or absorb `CaseOpeningView`.** It's a second, materially inferior
  implementation of the exact mechanic `CrateOpeningView` already does well.
  Decide: either migrate the shop's coin-purchased "case" flow onto
  `NQCapsule` directly (recommended — it's the same reward-reveal shape,
  just a different currency/entry point), or, if the roulette-reel visual is
  intentionally kept for brand variety, at minimum wire `nqRarityTreatment`
  into it so a legendary case pull doesn't look identical to a common one.
- **Extract the duplicated bracket banner.** `CauldronCrashView.bracketBanner`
  and `KitchenMinesView.rarityBanner` are near-verbatim copies. Pull into one
  shared component in `NutriQuestUI` (something like `NQBracketBanner`) —
  small, but it's the kind of drift that will diverge further if left.
- **Consolidate the three bespoke "time → curve" functions.** `CauldronClock`
  (exponential), `PortalWheelSpinCurve` (power curve + its own hand-derived
  inverse), and Plinko's inline `accelerate`/`deflect`/`fallWithin` all solve
  the same problem — a deterministic function of elapsed time driving a
  `TimelineView` — independently. Not urgent, but if a fourth game is added,
  this becomes a real cost. Worth a small shared utility
  (`NQTimeCurve`-shaped) once there's a second consumer beyond the two that
  already exist, so it's extracted from real duplication rather than
  speculative infrastructure.
- **`AnimatedKeyCount` (CrateOpeningView) and native
  `.contentTransition(.numericText())` (Cauldron/Mines) both animate
  numbers, differently, next to `NQCountUpText`, a third implementation of
  the same idea already in the kit.** Standardize on `NQCountUpText`
  everywhere a currency/counter changes value; it already distinguishes
  "static display" vs. "value being awarded" via its `countsOnAppear` flag,
  which is exactly the distinction both bespoke versions are re-solving.
- **Reduce Motion pass.** `PortalWheelView` and `CaseRouletteStrip` are the
  reference implementations here (properly shortened durations, ticks
  disabled, `CaseRouletteStrip`'s comment — *"the suspense is exactly what
  Reduce Motion asks to skip"* — is the correct framing for every suspense
  mechanic in this section). `CrateOpeningView` only gates the hold-to-charge
  gesture via a raw `UIAccessibility.isReduceMotionEnabled` check instead of
  the `@Environment` key, and leaves drop/shake/crack/open ungated —
  fix to match the Wheel's standard. `CasinoHubView`'s tab-switch
  `matchedGeometryEffect` has no reduce-motion branch at all (low severity,
  but free to fix alongside the rest of this pass).

### 4.3 Scan → Summon → Collection

- **`ScanView`'s summon sequence is the best-produced reveal in the core
  loop** — a real four-stage capture moment (`.lock → .silhouette → .rarity →
  .reveal`, timed via `DispatchQueue.main.asyncAfter`, layering
  scale/opacity transitions and `NQConfetti`). This is not a gap; it's a
  template. **But**: `reduceMotion` is declared in `SummonRevealOverlay` and
  never read anywhere in the struct — the entire staged reveal, including
  every spring and the confetti, ignores Reduce Motion completely. Given
  this is the single most-repeated "wow" moment in the app (it fires on
  every scan), this is the **highest-priority Reduce Motion fix in the
  codebase** — higher than any casino gap, because casino games are opt-in
  and infrequent; scanning food is the core loop, done multiple times a day.
- **`DishReviewView`'s photo-scan path re-triggers the same
  `playSummonSequence()`** after confirming — good, no divergent path to
  maintain. Nothing to do here beyond fixing the shared overlay above.
- **`CollectionView` has no hero/shared-element transition** into
  `CharacterDetailView` — tapping a carousel card opens a plain `.sheet`,
  and the artwork just re-renders at a different size. A
  `matchedGeometryEffect` card-to-detail transition (iOS-16-compatible,
  `CasinoHubView`'s tab indicator already proves the pattern works on this
  deployment target) would be a meaningfully higher-perceived-quality change
  for one of the most-visited screens in the app. Medium priority — real
  payoff, moderate effort, no dependency on anything else in this doc.
- **Collection's carousel spring (`withAnimation(.spring(response: 0.38,
  dampingFraction: 0.82))`, both on filter change and card selection) is
  inlined rather than routed through `NQMotion`.** Small fix, folds into
  whatever PR touches this screen next — add `NQMotion.carousel` (or reuse
  `.springy` if the values are close enough) rather than leaving a bespoke
  literal.

### 4.4 Quests / daily objectives — no screen exists yet

This is the most important finding in this audit and it isn't an animation
gap at all: **there is no daily-quests/objectives screen anywhere in the iOS
app.** `JourneyView.swift` — the obvious candidate by name — is a read-only
stats/analytics dashboard (Swift Charts of scan history, crate opens,
collection distribution). Grepping the whole `Screens/` directory for
`quest|claim|objective` returns nothing but import statements. The backend
already has the shape of this (`daily_state.objectives jsonb`,
`POST /user/quests/:questId/claim` per `RANK-PROGRESSION.md` §2-3, which even
specifies that claiming a quest clears ranked squad fatigue) — the client
side simply hasn't been built.

**This needs a product/eng scoping pass beyond "add animation to it."** Once
that screen exists, the animation plan for it is straightforward and should
reuse, not invent:

- Objective rows: standard `NQCard` + `NQStatBar`-style progress fill via
  `NQMotion.fill`, matching `HealthDashboardView`'s calorie-ring pattern.
- The **claim moment** is the one that matters: `GymCheckView`'s "verified"
  state (`NQScanBeam` → `nqSuccessBurst` + `NQJuice.success()` +
  `NQTransition.summon`) is the closest existing analog in the app and
  should be the template — a claimed quest is functionally the same
  "did-a-thing, here's your reward" beat as a verified gym check.
- Rank-point gains from a claim should use `NQCountUpText` (`countsOnAppear:
  true`) on the rank-points/badge display, consistent with how XP already
  animates in `ProfileView`.
- If/when quest claiming is wired to clear squad fatigue (per the doc), the
  fatigue banner in `BattleView`/the design's `Battle.dc.html` "fatigued"
  state should animate *out* (not just disappear) when fatigue clears —
  reuse `NQTransition.pop` or a fade, so the causal link ("you claimed a
  quest → your squad is un-fatigued") is visually legible in the moment,
  not just on next screen load.

Flagging this now so it isn't silently dropped from the roadmap because it
doesn't show up in an "animations" search of the existing code.

### 4.5 Onboarding

`OnboardingView` + `OnboardingStepViews` + `OnboardingComponents` (~1,300
lines combined) are **entirely bespoke** — they don't use `NQAnimations`,
`NQTransitions`, or `NQMotion` at all. Step transitions are a hand-rolled
`.asymmetric(insertion: .move(.trailing)+opacity, removal: .move(.leading)+
opacity)` keyed by step id; the unit toggle uses a raw `.spring(...)`
literal; there's no `accessibilityReduceMotion` check anywhere in the flow.

This isn't necessarily wrong — onboarding is a one-time, self-contained
flow, and its own `OBTheme`/`OBPrimaryButton`/`OBOptionCard` component set is
internally consistent. But it means onboarding got a completely separate
animation system for no clear reason, and it's the one place in the app with
zero Reduce Motion accommodation. **Plan: migrate step transitions onto
`NQTransition.push`/`.slideUp` and route the option-card/toggle springs
through `NQMotion`, primarily to pick up Reduce Motion support for free**
(every `NQMotion`/`NQTransition` consumer gets it automatically per §2) —
not because the current visual is broken, but because it's currently the one
flow a Reduce-Motion user can't turn down.

### 4.6 Profile / Stats / Health — lowest priority, mostly fine

`ProfileView` (pop-in + cascade entrance, `NQMotion.springy` XP bar,
`NQCountUpText`) and `HomeView` (staggered `nqSlideUp` sections) already lean
correctly on shared primitives. Two small items:

- `HomeView`'s calorie gauge and macro rings animate via inlined
  `.easeOut(duration: 0.4)` rather than an `NQMotion` case, and `DayCoin`'s
  liquid fill snaps with no animation at all (visually inconsistent with the
  rings right next to it that do animate).
- `HealthDashboardView` and `BodyMetricsView` are the flattest screens in the
  app outside of static lists (`LeaderboardView`, `ShopView`) — no entrance
  choreography at all. Low priority: these are data-review screens, not
  celebratory moments, and under-animating here is a defensible choice, not
  an oversight. Only worth touching if/when either screen gets a redesign
  for other reasons — don't spend a dedicated pass on it.

---

## 5. New shared primitives this plan requires

Concrete additions to `NutriQuestUI`, named so implementation work has a
target to build against rather than re-deriving names mid-PR:

```swift
// NQLoadingStates.swift — extend the existing enum, don't fork it
enum NQCharacterMotion {
    case idle, excited, sleepy, talk, sad, wave, none
    case attack   // NEW — forward lunge + recoil, battle-only
    case faint    // NEW — rotate + sink + desaturate + fade
    case victory  // NEW — happy bounce, distinct from `.excited`'s summon bounce
}

// ChibiCharacterView.swift
enum ChibiExpression {
    case happy, neutral, sleepy, sparkle, hungry, proud, hurt
    case fainted  // NEW — closed ×-eyes; chibi-fallback-only detail, not a substitute for the wrapper transform above
}

// NQRarity.swift or a new file — the consistency fix for §4.2
func nqRarityTreatment(_ rarity: NQRarity) -> some ViewModifier
// common/uncommon: none. rare: NQShineSweep. epic: + NQBreathingGlow.
// legendary/mythic: + NQConfetti gate. secret: holographic shimmer (new — matches
// design/README.md's "Secret is the one holographic ring" intent, not yet coded anywhere).

// NQAnimations.swift — name the battle springs instead of inlining them
extension NQMotion {
    static let attackLunge: Animation   // currently BattleView's inline .spring(response:0.28, dampingFraction:0.6)
    static let faintDroop: Animation
}

// New shared component, NutriQuestUI — kills the Cauldron/Mines duplication
struct NQBracketBanner: View { ... }
```

None of these are large builds — the point is that they're *named and
shared* rather than the fourth bespoke reimplementation of the same idea,
which is the pattern this whole audit keeps finding.

---

## 6. Reduce Motion — remediation checklist

Ordered by how often a user hits the broken path, not by file:

| Priority | Location | Gap | Fix | State |
|---|---|---|---|---|
| **P0** | `ScanView` / `SummonRevealOverlay` | `reduceMotion` declared, never read — fires on every scan | Sequence jumps straight to `.reveal`; stage transitions cross-fade | done |
| P1 | `NQMicroInteractions.NQConfetti` | No reduce-motion check at all (kit-wide primitive) | Guarded in `fire()`, so every call site inherits it | done |
| P1 | `CrateOpeningView` | Only hold-to-charge gated, via raw `UIAccessibility`; drop/shake/crack/open ungated | Environment key + a `playReducedMotionReveal` path that lands on the payoff | done |
| P2 | Onboarding | Zero reduce-motion handling anywhere | Steps cross-fade instead of sliding | done |
| P2 | `NQCoverFlowCarousel` | Only `rotation3D` zeroed | Selection travel drops; scale/offset stay (they're layout, not motion — zeroing them collapses the cover flow) | done |
| P3 | `NQMicroInteractions.NQCheckmarkDraw` | Draws on appear regardless | Jumps to drawn | done |
| P3 | `CasinoHubView` | Tab-switch `matchedGeometryEffect` ungated | Snaps between halves | done |
| P3 | `CasinoLuckChart` | No handling (Swift Charts default animation) | Left alone — framework defaults, low risk | open |

Everything else audited (Wheel, Plinko, Mines, Cauldron's shake/explosion,
`CaseRouletteStrip`, `WatchConnectView`'s radar pulse, every `NQAnimations`
primitive except `NQConfetti`/`NQCheckmarkDraw`) already does this correctly
— use them as the reference when fixing the rows above.

---

## 7. Phased roadmap

Sequenced so each phase either unblocks the next or ships independently —
none of this needs to land as one PR, and per `CLAUDE.md` conventions each
phase is its own branch off `main`.

**Phase 0 — Housekeeping (before anything else)**
- Delete the stray root `NutriQuestUI/` (§1).
- Fix `NQConfetti`'s and `NQCheckmarkDraw`'s missing reduce-motion checks
  (§2, §6) — two small, isolated fixes that several later phases depend on.

**Phase 1 — Reduce Motion P0/P1 (§6)**
- Fix `ScanView`'s dead `reduceMotion` declaration. Highest-traffic fix in
  this entire plan.
- Fix `CrateOpeningView`'s partial gating.

**Phase 2 — Battle juice completion (§4.1)**
- Faint droop transform + `ChibiExpression.fainted`.
- Distinct crit flash.
- Victory confetti call.
- HP bar `maxHP` correctness fix.
- Leader aura on ★5 squad leaders.
- Explicitly scope Expedition as outcome-feed-only (a decision, written
  down, not a silent gap) — or ticket it as the first consumer of the
  extracted battle animator if product wants PvE to look like a real fight.

**Phase 3 — Battle animator extraction (§4.1)**
- Pull `animateReplay`/`playChoreography` into a shared, `NQCapsule`-shaped
  stage machine. Do this *after* Phase 2 so the new faint/crit/victory
  behavior is designed once against the final event set, not twice.

**Phase 4 — Casino consistency (§4.2)**
- Ship `nqRarityTreatment(_:)`, including the secret-tier holographic
  variant the design doc already calls for.
- Apply it to `CauldronCrashView`, `KitchenMinesView`, `PlinkoView`,
  `PortalWheelView`.
- Decide and execute the `CaseOpeningView` consolidation.
- Extract `NQBracketBanner` from the Cauldron/Mines duplication.
- Standardize number-ticking on `NQCountUpText` across all six screens.

**Phase 5 — Core loop polish (§4.3, §4.5)**
- `CollectionView` → `CharacterDetailView` hero transition.
- Onboarding migration onto `NQTransition`/`NQMotion`.
- `HomeView` calorie-gauge/macro-ring/`DayCoin` consistency pass.

**Phase 6 — Quests (§4.4)**
- Gated on the screen itself existing — flag to product/eng now, don't wait
  for an animation-specific trigger to raise it. Once scoped, the animation
  work is small (reuses `GymCheckView`'s claim pattern almost directly) and
  can land in the same pass as the screen itself rather than as a follow-up.

**Not scheduled — speculative, wait for a second real consumer:**
- The `NQTimeCurve` consolidation (§4.2) — three bespoke curve functions
  exist today; extracting a shared one now would be guessing at the right
  abstraction. Revisit if a fourth wager game is ever added.

---

## 8. Guardrails while implementing

Restating the parts of `CLAUDE.md` / `docs/CONVENTIONS.md` most likely to be
violated by animation work specifically, since they're easy to forget mid-PR:

- **Zero warnings, iOS 16 target.** No `scrollBounceBehavior`, no
  `.scrollTransition` (used correctly already — `NQCoverFlowCarousel`'s doc
  comment explicitly notes it avoids `scrollTransition` for this reason;
  follow that precedent for any new scroll-driven effect).
- **Design system only.** Every new effect is a named `NQMotion`/`NQTransition`
  case or a new `NutriQuestUI` type — never a raw `.spring(response:...)` or
  hex color inlined in a `Screens/` file. This is the single rule this whole
  plan is organized around.
- **`accessibilityReduceMotion` in the same PR as the effect**, not as a
  follow-up (see §6 for how much reduce-motion debt accumulates otherwise).
- **Haptics via `NQHaptic`/`NQJuice`**, never raw `UIImpactFeedbackGenerator`.
- **`BattleKit` stays pure.** Everything in this doc is presentation-layer —
  none of it touches `BattleEngine`/`SeededRNG`. Animation code may use
  `Date()`/randomness freely for its own timing (a confetti particle's fall
  duration, a shake's jitter) — that constraint is specifically about battle
  *math*, not battle *rendering*.
- **Server-authoritative economy stays server-authoritative.** No new
  casino/battle animation should reveal or imply an outcome before the
  server response arrives (principle 6, §3) — `playChoreography()`'s
  pre-resolution filler in `BattleView` is the existing example of doing
  this safely (it's cosmetic and discarded, not predictive).
- **VoiceOver labels.** Every new interactive element from this plan
  (claim buttons, new casino reveals) needs labels per the existing
  Definition of Done — easy to skip on a visual-focused pass.
