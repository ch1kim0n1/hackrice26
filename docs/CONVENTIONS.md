# Conventions

## Git

- Branch per feature off `main`: `barcode-feature`, `design`, `battle-system`, `docs`, `battle-ui`, `backend-api`...
- PR into `main` with summary + test plan. No direct pushes to `main`.
- Commit style: imperative subject ≤ 60 chars, body explains why. Devin co-author trailer on AI-assisted commits.

## Swift

- Design system: **always** consume `NutriQuestUI` tokens — `NQText` for type, `nqElevation`, `nqPadding`, `nqAccent`. Raw sizes/colors/paddings in feature code = review reject.
- Dynamic accent: read `@Environment(\.nqAccent)`; never hardcode brand colors in screens.
- Animations: respect `accessibilityReduceMotion` (see kit patterns). Haptics via `NQHaptic`.
- Game math: pure + deterministic. No `Date()`, no `Double.random` inside `BattleKit` — seeded RNG only.
- Actors for mutable game state (`DailyState`, `BattleEngine`).
- Typecheck gate: `swiftc -typecheck` against iOS simulator SDK must be clean (0 errors, 0 warnings).

## TypeScript

- Fastify/Hono routes thin; logic in services. Zod-validate every body.
- Battle simulation mirrors `BattleKit` formulas exactly — port tests alongside.
- No `any`. ESLint strict.

## Definition of done

- Typecheck clean (iOS + TS)
- Logic tests pass
- Works on device (camera features)
- Accessibility: VoiceOver labels + Reduce Motion respected
- No secrets committed
