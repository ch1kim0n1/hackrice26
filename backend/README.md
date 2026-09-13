# NutriQuest — Backend (TypeScript)

Express + TypeScript API skeleton for NutriQuest. Types in `src/types.ts` mirror the Swift models in `../ios/Sources/NutriQuest/Models` field-for-field (`Character`, `Rarity`, `StatType`, `ColorMode`) so the two sides of the app never drift.

## Layout

- `src/index.ts` — app entry point, mounts the routers below
- `src/types.ts` — shared shapes (`Character`, `ScanResult`, `BattleState`, `UserProfile`)
- `src/data/sampleCharacters.ts` — the same 6 sample characters used in the iOS app's `SampleData`
- `src/routes/characters.ts` — `GET /characters`, `GET /characters/:id`
- `src/routes/scan.ts` — `POST /scan` (barcode → food lookup → possible character summon; food-database lookup is a `TODO`), plus the dish-photo routes below
- `src/nutrition/` — the dish photo analysis engine (see below), independent of the game
- `src/routes/battle.ts` — `GET /battle/:userId`
- `src/routes/user.ts` — `GET /user/:id` (profile + the accent-color rule inputs: `activeCharacterId`, `colorMode`)

## Running it

```
npm install
npm run dev    # ts-node-dev, auto-restarts on save
npm run build && npm start   # compiled
```

Verified with `npx tsc --noEmit` — compiles clean as of this commit. All routes currently return sample data; replace with real persistence and a real food/barcode lookup before shipping.

## Dish photo scan (no barcode)

Two steps, so nothing is minted from numbers nobody checked:

- `POST /scan/photo/analyze { image }` → a draft breakdown: every distinct food
  on the plate with its own estimated portion and nutrients. Mints nothing.
- `POST /scan/photo/confirm { analysisId, edits }` → applies the user's
  corrections and mints exactly one character from the confirmed plate.

Drafts are held server-side, so `edits` can only **rename, re-portion or
remove** items the server itself analysed — nutrient density always comes from
the analysis, so a client can never post its own macros. One analysis mints at
most one character.

### The vision provider

Defaults to OpenAI (`api.openai.com/v1/chat/completions`, `gpt-4o-mini`) — set
`VISION_API_KEY` (or `OPENAI_API_KEY`) and photo scanning works. Any
OpenAI-compatible endpoint can replace it:

```
VISION_API_URL=   # e.g. https://openrouter.ai/api/v1/chat/completions
VISION_MODEL=     # e.g. gpt-4o-mini
VISION_API_KEY=   # falls back to OPENAI_API_KEY
```

Try the engine against a real plate before trusting its numbers:

```
npm run analyze:photo -- path/to/plate.jpg
```

## Deploying to Railway

Config lives in `railway.json` (Nixpacks builder, `npm start`, healthcheck on
`/health`). `.nvmrc` pins Node 22 — required because `src/db.ts` uses the
built-in `node:sqlite` module (Node >= 22.5). Without the pin, Railway
provisions an older Node and the process crashes on boot.

Persistence: Railway's filesystem is **ephemeral** — a redeploy or restart
wipes `data/nutriquest.db` and every player's state with it. To keep state,
attach a Railway volume and point the database at it:

```
NUTRIQUEST_DB=/data/nutriquest.db   # with a volume mounted at /data
```

Leave `NUTRIQUEST_DB` unset for a throwaway demo deployment (in-file DB under
the project dir, reset on each deploy); set it to `memory` for a fully
ephemeral in-memory database.

The port is taken from Railway's injected `PORT` automatically. The iOS app
points at the deployment by setting `BackendBaseURL` in its Info.plist (see
`ios/project.yml`) — e.g. `https://<railway-app>.up.railway.app`.
