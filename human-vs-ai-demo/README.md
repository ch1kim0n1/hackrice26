# Human vs AI Security Demo

Sandbox-only demo: a human and a scripted AI agent both request the same
protected NutriQuest resource through the same server-side authorization
check. The human can satisfy Persona sandbox verification and gets in; the
agent never completes real verification, so it is denied and routed into an
isolated honeypot.

Backend pieces live in `backend/src/demo/` (routes at `/demo/*`), gated by
`ENABLE_PERSONA_DEMO=true`. This directory is only the static frontend —
same "no build step" pattern as `../persona-challenge`.

## Run

```sh
# backend
cd ../backend
echo "ENABLE_PERSONA_DEMO=true" >> .env   # plus PERSONA_API_KEY / PERSONA_TEMPLATE_ID for the real sandbox
npm run dev                                # http://localhost:4000

# frontend (separate terminal)
cd ../human-vs-ai-demo
python3 -m http.server 8124
# open http://localhost:8124
```

Without `PERSONA_API_KEY`/`PERSONA_TEMPLATE_ID` set, the backend falls back
to a dev-only mock adapter (`backend/src/demo/mockPersonaAdapter.ts`) so the
whole flow is still clickable locally — see that file for exactly what it
does and does not simulate. It never verifies an agent session, and it's
never used ahead of the real Persona sandbox when the sandbox is configured.

API base resolution: `?api=` query param > `window.NQ_API_BASE` >
`http://localhost:4000`.

## What's real vs scripted

- **Real**: session creation, the `/demo/protected` authorization check, the
  Persona sandbox inquiry/verification round-trip, the honeypot route, and
  every Security Monitor event — all server state, nothing client-faked.
- **Scripted (v1)**: the AI agent's *decision loop* (`src/agent.js`) — which
  endpoint to call next and how long to wait between steps. Every call it
  makes is a real request to the real backend, hitting the same
  `/demo/protected` check the human panel hits. Swapping in a real
  browser/LLM agent later means replacing the loop in `agent.js`, not the
  backend contract.

## Files

| file | role |
|---|---|
| `index.html` | human panel, agent panel, security monitor, rickroll overlay |
| `styles.css` | NutriQuest palette/fonts, reused from `persona-challenge` |
| `src/api.js` | backend client for `/demo/*` |
| `src/persona.js` | Persona embedded-flow wrapper (same pattern as `persona-challenge/src/persona.js`) |
| `src/human.js` | human panel state machine |
| `src/agent.js` | scripted AI agent runner (v1) |
| `src/monitor.js` | live security monitor — SSE with polling fallback |
| `src/main.js` | wiring + rickroll overlay |

## Security notes

- The backend never trusts a client-reported Persona status — `/demo/persona/complete`
  re-reads the inquiry from Persona itself before recording anything.
- There is no `if (isAI) { rickroll() }` anywhere. `/demo/protected` only ever
  checks `personaStatus === "verified"`; the agent is blocked because its
  scripted run never completes a real Persona verification, not because the
  server detects it's an agent.
- The honeypot (`/demo/honeypot`) returns static decoy content only — no real
  user data, no mutation of real player state.
