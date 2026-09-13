// Human panel — real Persona sandbox flow.
//
//   Start Human Demo
//     -> POST /demo/session {actorType:"human"}
//     -> GET  /demo/protected            (expect 403 PERSONA_REQUIRED)
//   Verify with Persona
//     -> POST /demo/persona/start        -> widget opens (sandbox) or resolves immediately (mock)
//     -> POST /demo/persona/complete     -> backend-confirmed status
//     -> GET  /demo/protected            (now 200, if verified)

import { startSession, requestProtected, startPersona, completePersona } from "./api.js";
import { openPersonaFlow } from "./persona.js";

const STATE_COPY = {
  idle: "Idle",
  session_created: "Session created",
  verification_required: "Persona verification required",
  verifying: "Verification in progress…",
  verified: "Verified",
  unlocked: "Protected resource unlocked",
};

export function initHumanPanel(root) {
  const els = {
    state: root.querySelector("[data-human-state]"),
    persona: root.querySelector("[data-human-persona]"),
    result: root.querySelector("[data-human-result]"),
    btnStart: root.querySelector("[data-human-start]"),
    btnVerify: root.querySelector("[data-human-verify]"),
  };

  let session = null; // { token, id }

  function setState(key) {
    els.state.textContent = STATE_COPY[key] || key;
    els.state.dataset.value = key;
  }

  function setPersona(status) {
    els.persona.textContent = status.toUpperCase();
    els.persona.dataset.value = status;
  }

  function reset() {
    session = null;
    setState("idle");
    setPersona("not_started");
    els.result.hidden = true;
    els.btnStart.disabled = false;
    els.btnVerify.hidden = true;
  }

  async function start() {
    els.btnStart.disabled = true;
    els.result.hidden = true;
    try {
      const { sessionToken, session: s } = await startSession("human");
      session = { token: sessionToken, id: s.id };
      setState("session_created");
      setPersona(s.personaStatus);

      const check = await requestProtected(session.token);
      if (check.status === 403) {
        setState("verification_required");
        els.btnVerify.hidden = false;
      } else {
        setState("unlocked");
        showGranted();
      }
    } catch (err) {
      setState("idle");
      els.btnStart.disabled = false;
      alert(err.message || "Could not start the human demo.");
    }
  }

  async function verify() {
    if (!session) return;
    els.btnVerify.disabled = true;
    setState("verifying");
    try {
      const start = await startPersona(session.token);
      setPersona(start.status);

      if (start.personaSessionToken) {
        try {
          await openPersonaFlow({ inquiryId: start.inquiryId, sessionToken: start.personaSessionToken });
        } catch {
          // Cancelled or errored client-side — the backend read below is
          // still the source of truth for what actually happened.
        }
      }

      const complete = await completePersona(session.token);
      setPersona(complete.status);

      if (complete.status === "verified") {
        setState("verified");
        const check = await requestProtected(session.token);
        if (check.status === 200) {
          setState("unlocked");
          showGranted();
        }
      } else {
        setState("verification_required");
      }
    } catch (err) {
      setState("verification_required");
      alert(err.message || "Persona verification failed.");
    } finally {
      els.btnVerify.disabled = false;
    }
  }

  function showGranted() {
    els.result.hidden = false;
    els.btnVerify.hidden = true;
  }

  els.btnStart.addEventListener("click", start);
  els.btnVerify.addEventListener("click", verify);

  reset();
  return { reset };
}
