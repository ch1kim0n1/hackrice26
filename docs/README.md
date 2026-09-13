# NutriQuest — Developer Documentation

NutriQuest is a daily nutrition RPG for iOS: every meal you scan summons an anime food character, a balanced real-world diet powers your squad and earns rank points, and your collection can be merged, sold, gambled, and battled.

**Branch map:**

| Branch | Contents |
|---|---|
| `main` | README only |
| `barcode-feature` | SwiftUI barcode scanner + Open Food Facts lookup + character generation (Pollinations art) |
| `design` | UI design source (`.dc.html` mockups) + `NutriQuestUI` SwiftUI design system & animation kit |
| `battle-system` | Battle design doc + `BattleKit` deterministic engine + daily multiplier |
| `Apple-Watch-Data-Connection` | Watch → HealthKit → iPhone pipeline |
| `Loot-Boxes-Logic` | Capsule/loot box mechanics |
| `swiftui-implementation` | App implementation work |

## Docs in this folder

1. [ARCHITECTURE.md](ARCHITECTURE.md) — system split, data flow, tech decisions
2. [SETUP.md](SETUP.md) — local development environment
3. [DATA-MODELS.md](DATA-MODELS.md) — every entity, field, and relationship
4. [API.md](API.md) — backend endpoint contracts
5. [SECURITY.md](SECURITY.md) — auth, RLS, anti-cheat, verification
6. [CONVENTIONS.md](CONVENTIONS.md) — code style, git flow, definition of done
7. [NET-WORTH.md](NET-WORTH.md) — rarity bands, the star economy, and what a monster is worth
8. [DATABASE.md](DATABASE.md) — migrations, RLS, and running the schema tests
9. [TIGERDATA-MIGRATION.md](TIGERDATA-MIGRATION.md) — repository-wide database inventory, target architecture, and migration sequence
10. [RANK-PROGRESSION.md](RANK-PROGRESSION.md) — the consistency ladder: rank points, squad fatigue, seasons, and the leaderboard
11. [ANIMATIONS-AND-EFFECTS.md](ANIMATIONS-AND-EFFECTS.md) — audit of the existing `NutriQuestUI` animation kit, the gaps per screen, and the phased plan to close them

Working with an AI assistant? Start at [`CLAUDE.md`](../CLAUDE.md) in the repo
root — it covers how to run and test each layer, and the traps that are
expensive to find by trial and error.

## Product rules (non-negotiable)

- Food only. Healthier eating → stronger squad, via **balanced intake**, never a single-hero-food rule.
- Character collections are permanent **until the player chooses** — merge, sell, or gamble are deliberate, server-verified actions; nothing is lost on a battle loss.
- **No real-money gambling.** Coins and capsules are earned in-game; pot gambling and Monster Crash stake characters, never cash. All outcomes are server-seeded and provably fair.
- Battles and all value mutations are **server-authoritative**. Clients replay, never decide.
- Gym photo verification is demo theater, never a core mechanic.

## Roadmap

New feature work is ticketed as epics #67–#81 with engineering sub-issues #82–#134, sequenced in milestones Phase 1 (decisions/foundations) → Phase 5 (iOS & docs). Design docs reflect the target vision; the implemented schema is in `backend/migrations/`, documented in [`db-documentation/03-relational-model.md`](../db-documentation/03-relational-model.md).
