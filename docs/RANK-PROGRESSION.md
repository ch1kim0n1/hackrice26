# Rank Progression — the consistency ladder, battles, quests, and seasons.

> **Scope.** This covers the bronze/silver/gold/plat rank-points ladder end to
> end: how points move, squad fatigue after a ranked loss, and the 7-day
> season cycle. It does not cover XP/level (a separate, older ladder — see
> `xpProgression` in `user.ts`) or Elo (`game/elo.ts`, a dormant "how well you
> fight" ladder kept deliberately apart from this one).

Implementation: [`game/rankTiers.ts`](../backend/src/game/rankTiers.ts),
[`game/rankPoints.ts`](../backend/src/game/rankPoints.ts),
[`game/fatigue.ts`](../backend/src/game/fatigue.ts),
[`game/rankSeason.ts`](../backend/src/game/rankSeason.ts).
Tests: the `.test.ts` file beside each of those, plus
[`routes/rankedFatigueSeason.test.ts`](../backend/src/routes/rankedFatigueSeason.test.ts)
for the route-level wiring.

---

## 1. Points and tiers

Rank points are a single number per player, never reset except at a season
boundary (§4). Tier is always *derived* from points — never stored
independently — so a badge can never disagree with the number that produced
it (`tierForPoints`, `rankTiers.ts`).

| Tier | Floor (points) |
|---|---|
| Bronze | 0 |
| Silver | 100 |
| Gold | 300 |
| Plat | 600 |

## 2. Sources

| Source | Amount | Route |
|---|---|---|
| Ranked battle win | +15 | `POST /battle/ranked` |
| Ranked battle loss | −10 (floors at 0) | `POST /battle/ranked` |
| Daily quest claimed | +10 | `POST /user/quests/:questId/claim` |
| Food scan / meal photo | +5 | `POST /scan`, `POST /scan/photo/*` |

All positive sources share one **daily cap of 40 points** (`RP_DAILY_CAP`,
`rankPoints.ts`) — a perfect day tops out there regardless of how it was
earned. Losses are not capped: a bad day can still cost more than a good day
gained, which is deliberate (`awardCapped`).

Every source funnels through the single `awardRankPoints()` in `user.ts`, the
same way XP funnels through `awardXP()` — one chokepoint so the cap, season
rollover, and tier-change logging can never be bypassed by a new call site.

## 3. Squad fatigue on a ranked loss

A ranked loss fatigues the squad for **2 hours** (`FATIGUE_MS`,
`fatigue.ts`): `/battle/ranked` returns `409 SQUAD_FATIGUED` for any ranked
attempt until the expiry passes, or until it's cleared early.

**Recovery**: claiming *any* daily quest clears fatigue immediately
(`POST /user/quests/:questId/claim`). A claimed quest is already
server-verified evidence of a healthy day, so it doubles as the "did
something about it" recovery action rather than inventing a separate
verification path — the design doc's original phrasing ("balanced meal / gym
check") assumed a gym-photo verification flow that doesn't exist yet (only a
rate-limit constant and an iOS screen stub — see `GymCheckView.swift` and
`gymCheckLimit` in `security/rateLimits.ts`); wiring fatigue recovery to that
would have meant building an unrelated feature first.

Fatigue never blocks PvE (`/battle/simulate`, dungeon) or arena — only
ranked, matching the design doc's "Loss: −RP, squad fatigued 2h" under §5
Ranked system specifically.

## 4. Seasons

A season is **7 UTC days**, numbered from a fixed epoch (`seasonNumber`,
`rankSeason.ts`) — the same trick daily quests use (`todayKey()`): no cron,
no season row to create ahead of time, just a number both the server and a
stored `rankSeason` field can agree on.

At the first rank-point-moving event after a season boundary passes:

- Points **decay 20%** toward zero (`floor(points * 0.8)`).
- The tier held at the moment of decay pays out capsule keys:

| Tier at close | Keys |
|---|---|
| Bronze | 1 |
| Silver | 2 |
| Gold | 4 |
| Plat | 8 |

Skipping several seasons (a long absence) still applies **one** rollover, not
one compounded per missed week — the ladder is meant to reward showing up,
not to punish returning players disproportionately for having been away.

**Scope note**: Postgres already has an unused season schema from an earlier
design pass — `app.seasons`, `app.rankings` (`season_id`-keyed), and
`app.season_reward_claims` (`0005_battles_seasons.sql`) — never populated by
any app code. This rollover is intentionally SQLite/profile-blob only, matching
where the rest of the rank ladder already lives (SQLite is the gameplay
source of truth per `CLAUDE.md`). Wiring a real Postgres season lifecycle on
top of that dormant schema is a separate migration project, not part of this
pass.

## 5. Leaderboard

`GET /user/leaderboard?sort=wins|rank` — `wins` (battles won, the original
behavior) is the default; `rank` sorts by rank points instead. Every entry
carries `rankPoints`/`rankTier` regardless of sort mode, so a wins-sorted view
can still show a tier badge.

## 6. iOS

The rank-badge components (`NQRankTier`, `NQRankBadge`) and the ranked-queue
screen live on the **unmerged `ui-polish` branch**, not on `main`. The
leaderboard's Wins/Rank toggle added alongside this work (`LeaderboardView`)
does not depend on them — it uses a plain segmented control and text, so it
builds standalone on `main`. Whoever merges `ui-polish` and this branch
together should reconcile the leaderboard row to use `NQRankBadge` instead of
plain text for the rank-sorted view.

---

## History

- `#67/#82/#83/#84`: original rank-points ladder, matchmaking, and quest/scan
  award wiring.
- This pass: fixed a bug in `/battle/ranked` where the final handler-scoped
  `profile` object was read *before* the battle and reused to save
  `battlesWon` at the end — silently overwriting the rank-point and XP
  updates that `awardRankPoints`/`awardXP` had already persisted moments
  earlier through their own independent read/save. Every ranked result was
  granting rank points and XP that vanished before the response went out.
  Added squad fatigue, season rollover, and the rank-sorted leaderboard.
