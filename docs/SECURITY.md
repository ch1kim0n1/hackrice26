# Security

## AuthN / AuthZ

- **Not implemented yet.** Player identity today is the client-supplied `X-Player-Id` header, which is unauthenticated. Sign in with Apple is the post-hackathon plan.
- Every route extracts `player_id` from the verified token. **Never** from the request body.
- RLS enabled on every table:
  - `USING (player_id = auth.uid())` for all player-owned rows.
  - `products`, `seasons`, `character_lore`: world-readable, server-writable (service role only).
  - `battles.replay`: readable by `player_a`/`player_b` only.
  - `capsule_ledger`: readable by owner, **insertable only by service role** (backend).
  - `gym_checks`: owner-read, never client-writable.
- Storage: gym photos in **private** bucket, signed URLs (15 min) only for the owner + vision worker.

## Anti-cheat

| Vector | Defense |
|---|---|
| Forged battle results | Battles never computed client-side. Seed = HMAC(matchId, server secret). Replay stored server-side. |
| Squad forgery | Backend rebuilds squads from DB (today's scans, stats, multiplier) — client sends only character IDs. |
| Multiplier inflation | Day-log caps enforced in `/scan` (1 barcode/day, 3/hour, no backdating — `logged_at` server time). |
| Capsule duplication | Append-only ledger + single-transaction arena settle + balance CHECK trigger. |
| Gym photo spoofing | OpenAI Vision check + EXIF capture-time validation + 1/day + private storage. Demo-grade; never core economy. |
| Multi-account farming | Device hash binding (demo); anomaly detection post-hackathon. |
| Replay tampering | Replay served from DB only; client has no write path. |
| Lore/art prompt injection | Groq/OpenAI calls sanitize product names; output length-capped; stored once, never re-prompted from user input. |

## Secrets

- Railway env vars: `DATABASE_URL` (TLS, Tiger Cloud), `GROQ_API_KEY`, `OPENAI_API_KEY`, `SERVER_SECRET`.
- iOS: no secrets in code. OFF API needs no key. Pollinations needs no key. Art generation is client-side by design.
- `.xcconfig` files gitignored; CI injects secrets.

## Data protection

- Gym photos: private bucket, deleted after vision check + 24h retention job.
- No health data leaves the device except derived nutrition totals (calories/macros) — no weight/height leaves except profile targets computation, which can be client-computed and sent as targets only.
- PII minimal: display name + optional email. Delete-account endpoint cascades all tables.

## Transport

- HTTPS only (Railway default). Certificate pinning optional post-hackathon.
- Postgres RLS (`backend/migrations/0011`, `0017`) is the backstop, not the primary gate — the backend validates ownership on every write. It binds only when the app connects as the restricted `nutriquest_app` role.
