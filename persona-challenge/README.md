# Prove You're Human — signup pre-gate

Reflex/motion mini-game that gates NutriQuest account creation. The game
scores human-likeness client-side, reports the verdict to the backend under
a single-use gate token, and the account is registered only with a completed
gate run attached.

## Run

No build step. The runtime files live in `backend/public/human-gate/` and the
backend serves them at `/gate` in production — same origin as the API. For
local development serve that directory (ES modules need http, not file://)
and have the backend up:

```sh
python3 -m http.server 8123 -d ../backend/public/human-gate
# backend: cd ../backend && npm run dev   (http://localhost:4000)
# open http://localhost:8123
```

API base resolution: `?api=` query param > `window.NQ_API_BASE` >
same origin (or `http://localhost:4000` on the :8123 dev server). Inside the
iOS WKWebView, set
`AppConfig.humanGateURL` — successful registration is posted back to the app
via `webkit.messageHandlers.nutriquest`.

## Flow

```
signup (username + password, no email)
  → POST /human-gate/session  (gate token, 15min TTL)
  → intro → countdown → 2–3 reflex rounds → score
    ├─ clean pass           → POST /result
    ├─ ambiguous (30–70)    → silent "bonus round" escalation → rescore
    └─ bot-like             → still proceeds; flag recorded on the account
  → POST /auth/register → stats → done

login (username + password)
  → POST /auth/login
    ├─ Persona not configured → session
    └─ Persona configured     → 202 { loginToken, inquiryId, sessionToken }
        widget opens → onComplete/onCancel
        POST /auth/login/persona/complete → session only when Persona
        reports the inquiry completed or approved
```

Persona runs at login only. Its config lives server-side (`PERSONA_API_KEY`,
`PERSONA_TEMPLATE_ID` in `backend/.env`). Each login opens a fresh inquiry
whose `reference-id` is `sha256(loginToken)`, so the raw token never goes to
Persona, and the status is read back from Persona server-side rather than
trusted from the widget. A declined, cancelled or expired check refuses the
login; the challenge is single use and lasts 10 minutes. Without Persona
configured, login returns the session straight from the password.

The backend requires a scored gate token at `/auth/register` — an account
cannot be created without a completed gate run. Verdicts are bound to the
account row (`human_gate_session.player_id`) for review.

## Honeypot

The login page carries three traps that only an automated agent reaches: a
visually hidden "Backup verification code" field, a visually hidden "Skip
identity verification" link, and a source comment pointing at
`/auth/login/skip-verification`. An automated browser (`navigator.webdriver`)
arriving at the Persona check trips it too. Nothing is skipped: the hit is
logged to the Human-vs-AI demo's security monitor (`HONEYPOT_TRIGGERED`,
`AGENT_RICKROLLED`) and the visitor is sent to the rickroll.

## Challenge design

- **CSPRNG everything** — `crypto.getRandomValues` only (`src/rng.js`).
- **Combinatorial space** — instruction type (tap-all / color-filter /
  sequence) × target count × jittered grid positions × staggered appear
  offsets × per-orb lifetimes × decoy count. Millions of combos per session.
- **Telemetry per round** — per-hit reaction time (`performance.now` diff vs
  paint timestamp), pointer trail at ~60hz, decoy/stray/out-of-order taps,
  pointer type.
- **Scoring** (`src/scoring.js`) — weighted signals: sub-90ms median RT,
  any <60ms pre-click, RT stdev <12ms, metronomic inter-tap gaps, mouse
  teleports with no trajectory, flawless hard rounds. Thresholds are
  starting calibration — needs real-human testing per the build doc.
- **No visible fail** — ambiguous sessions get a "bonus round", flagged
  sessions still register with the verdict bound to the account.

## Debug drawer

`∿` button bottom-right — live session JSON: referenceId, rounds played,
score, flags, escalation count. Useful for judging/demo.

## Files

| file | role |
|---|---|
| `index.html` | all screens (login, signup, intro, game, result, stats, done) |
| `styles.css` | full visual system — NutriQuest app theme, orb/anims, HUD |
| `src/rng.js` | CSPRNG helpers |
| `src/challenge.js` | combinatorial round-spec generation |
| `src/game.js` | arena renderer + telemetry capture |
| `src/scoring.js` | suspicion score + verdicts |
| `src/api.js` | backend client (gate session, result, register, iOS handoff) |
| `src/stats.js` | post-signup scoring breakdown renderer |
| `src/main.js` | screen state machine |

## Website login and signup

The backend serves the existing landing page at `/`, login at `/login/`,
and signup at `/signup/`. Start it with `cd backend && npm run dev` from
the repository root, then open `http://localhost:4000/login/`.

Website signup reuses the human check and automatically saves the issued
session and returns home. Returning users are checked through `/auth/me`;
expired sessions return to the form. The homepage login link becomes logout,
which revokes the session. The native/demo gate at `/gate/` keeps its stats
and completion screens. No passwords are saved in browser storage.

Browser regression tests against an isolated in-memory backend:

```sh
npm --prefix backend run build
npm --prefix persona-challenge ci
npm --prefix persona-challenge run test:website
```

Run `npx playwright install chromium` in `persona-challenge` if needed, or set
`PLAYWRIGHT_CHANNEL=msedge` to use an installed Edge browser. `WEBSITE_TEST_URL`
can point to an already-running disposable backend instead of starting one.
