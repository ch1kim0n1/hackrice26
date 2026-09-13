# Prove You're Human — MVP Build Doc

## What we're building

A two-layer human verification flow for the Persona "Prove You're Human" challenge.

1. **Pre-gate**: a fast, game-like reflex/motion challenge that runs before Persona opens. Catches bots cheaply, feels like a two-second mini-game, not an interrogation.
2. **Persona widget**: handles the actual identity verification (doc + selfie liveness) once the pre-gate passes.
3. **Escalation hook**: if the pre-gate response looks bot-like but isn't a clean fail, flag it instead of hard-blocking, and let that flag inform how the Persona result gets treated.

Judging criteria to keep in mind while building: this is explicitly scored on UX ("make it feel good"), not just on how hard it is to spoof. Don't build something that feels punitive.

---

## Architecture

```
User lands on page
      ↓
[Pre-gate challenge] — CSPRNG-generated, sub-second, reflex/motion based
      ↓
  clean pass ──────────────→ Persona.Client.open() → full KYC flow → onComplete
      ↓
  ambiguous/suspicious → harder round OR flag referenceId for extra scrutiny
```

Key point: the pre-gate must run **before** `client.open()`, not fused into Persona's flow. Persona's document/selfie steps are network-bound (multi-second), so timing signals inside that flow aren't comparable to your reflex-loop timing. Keep the two systems separate.

---

## Build order (rough effort estimates)

| Piece | Effort | Notes |
|---|---|---|
| CSPRNG challenge generation | Trivial | `crypto.getRandomValues()` client-side or `crypto.randomBytes()` server-side |
| Combinatorial challenge space | Moderate | Design task more than engineering. Pick 4-5 params (position, color, timing offset, sequence, target count) with enough range to hit millions of combos |
| Session-bound, one-shot challenge | Moderate | Bind to Persona's `referenceId`/`inquiryId` instead of building your own session system — see below |
| Adaptive difficulty / escalation | Moderate | Simple state machine, score response → escalate quietly, don't show a visible "you failed" moment |
| Latency exploitation | Hardest | Mechanism is easy (`performance.now()` diffs), calibration against real human response times is the actual work. Budget real testing time, not just build time |
| Persona SDK integration | Setup, not code | ~30-60 min, mostly dashboard config (template ID, sandbox key) |

**Don't build a separate session/token system.** Persona already gives you `inquiryId` / `referenceId` / `environmentId` from the widget. Use `referenceId` as your binding key for the pre-gate challenge instead of rolling your own.

---

## Persona integration

- Docs home: https://docs.withpersona.com/
- Getting started: https://docs.withpersona.com/getting-started
- How Persona works: https://docs.withpersona.com/how-persona-works
- Choosing an integration method (web vs mobile): https://docs.withpersona.com/choosing-an-integration-method
- Environments (sandbox vs prod): https://docs.withpersona.com/environments
- Embedded Flow quickstart (this is the one we want): https://docs.withpersona.com/2023-01-05/embedded-flow
- API quickstart tutorial (for pre-creating inquiries via API): https://docs.withpersona.com/api-quickstart-tutorial
- API reference: https://docs.withpersona.com/api-reference/
- Webhooks: https://docs.withpersona.com/webhooks
- Webhooks quickstart: https://docs.withpersona.com/quickstart-webhooks
- Cases (manual review — relevant for our escalation path): https://docs.withpersona.com/cases
- Help center: https://help.withpersona.com/getting-started

### Web SDK (what we're using)

```
npm install persona
```

```js
import Persona from 'persona';

const client = new Persona.Client({
  templateId: '<your template ID, starts with itmpl_>',
  referenceId: '<bind this to your pre-gate session>',
  environmentId: '<starts with env_, sandbox for now>',
  onReady: () => client.open(),
  onComplete: ({ inquiryId, status, fields }) => {
    // send inquiryId + status to your server
  },
});
```

### Mobile SDKs (not needed for MVP, here if we go there)

- React Native: `npm i react-native-persona` — https://docs.withpersona.com/react-native-sdk-integration-guide
- Android Maven repo: `https://sdk.withpersona.com/android/releases`
- iOS / Android native guides: linked from the docs sidebar under Integration → Mobile SDKs

### Sandbox testing

Sandbox has a built-in pass/fail toggle, so every path (including the fail case) can be demoed without needing real IDs. Confirm exact toggle location with Persona's engineers at their table, it wasn't fully clear from docs alone.

---

## Typeface

**Sharp Type's Ghost** — clean humanist sans, use for the product wordmark/headline only.

- Foundry: https://sharptype.co
- Purchase / specimen: https://myfonts.com/collections/ghost-font-sharp-type
- Pricing: individual styles from $60, full family (10 styles) $360

Use it for: logo, headline copy, result screen.
Don't use it for: body copy, form labels, anything inside the live verification flow — legibility under time pressure matters more than personality there.

Free alternatives if licensing isn't worth it for a hackathon: Inter, General Sans, Satoshi. All have a similar clean humanist-sans feel.

---

## Open questions for Persona's table

- Can we attach custom metadata to `referenceId` *before* an inquiry starts, to carry our pre-gate's suspicion score into their system?
- Exact sandbox toggle mechanism for forcing pass/fail demo paths.
- Any rate limits on sandbox API calls we should know about before demo day.
