# NutriQuest

Daily nutrition RPG for iOS: every meal you scan summons an anime food character, and a balanced real-world diet powers your squad in PvP battles for the next 24 hours.

**Eat food → Scan barcode → Summon character → Balance your day → Battle → Earn capsules.** No real-money gambling — capsules are earned. Collections are permanent; only daily buffs reset.

## Repository layout (integrated)

```
ios/
  Package.swift              SPM workspace: 3 targets
  Sources/NutriQuest/        the app — 8 screens, scanning, game state
    Scanning/                VisionKit scanner + Open Food Facts + stat derivation
    App/GameState.swift      shared state: scans → squad → battle
  Sources/NutriQuestUI/      design system + animation kit (canonical)
  Sources/BattleKit/         deterministic battle engine + daily multiplier
backend/                     TypeScript/Express API (Railway)
  src/routes/scan.ts         real OFF lookup + server-side stat derivation
  src/routes/battle.ts       server-authoritative battle simulation (BattleKit port)
  src/vitals/                Apple Watch HealthKit pipeline
watch/                       HealthHackathon Watch app (HealthKit source)
design/                      UI mockups (.dc.html) + hand-drawn character SVGs
docs/                        developer documentation (architecture, schema, API, security)
prompts/                     character art prompt system
```

## Quick start

**iOS** — generate the app project with XcodeGen, then run in Xcode (16+). Camera scanning needs a real device; simulator supports manual flows.

```bash
cd ios && xcodegen generate && open NutriQuest.xcodeproj
```

Tests (picks an iPhone simulator automatically): `ios/scripts/test-ios.sh`

**Backend**

```bash
cd backend && npm install && npm run dev   # :4000
```

**Docs** — start at [docs/README.md](docs/README.md): architecture, data models, API contracts, security model, conventions.

## How the pieces connect

1. **Scan** (VisionKit, on-device) → Open Food Facts lookup → `CharacterFactory` derives battle stats from nutrition (protein→Power, fiber→Guard, micros→Vitality, protein/sugar→Tempo).
2. **Character** joins your permanent collection; the day log updates.
3. **Daily Party Multiplier** (0.8×–1.5×) recalculates from your *whole day* of eating — balanced intake wins, junk days penalize. Personal targets come from your profile (age/sex/height/weight/goal, Mifflin-St Jeor).
4. **Battle** — 3v3, deterministic seeded simulation (`BattleKit` on device, identical port in `backend/src/routes/battle.ts`). Server is authoritative; clients replay.
5. **Rewards** — XP + earned summon capsules (no real money). Loss = 2h squad fatigue, collection untouched.

## Branch history

Integrated from: `swiftui-implementation` (app + backend), `barcode-feature` (scanner + OFF), `design` (UI kit), `battle-system` (BattleKit), `docs` (dev docs), `Apple-Watch-Data-Connection` (HealthKit pipeline). Feature branches remain for reference; `main` is the integrated system.
