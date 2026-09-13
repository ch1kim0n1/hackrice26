// AI Agent panel — scripted v1 runner.
//
// Every step below calls the *same* backend endpoints the human panel calls
// (api.js), with a visible delay between steps. There is no separate "agent
// API" and no client-side flag that tells the server "this is a bot" — the
// agent is blocked purely because it never completes a real Persona
// verification, so /demo/protected sees personaStatus !== "verified" just
// like it would for anyone else.
//
// Swapping this scripted loop for a real browser/LLM agent later (v2) means
// replacing `run()`'s body with an autonomous loop over the exact same
// api.js calls — nothing about the backend contract changes.

import { startSession, requestProtected, personaStatus, hitHoneypot } from "./api.js";

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const jitter = () => 600 + Math.random() * 600; // 600-1200ms, per spec

const STEPS = [
  "CREATE_SESSION",
  "REQUEST_PROTECTED_RESOURCE",
  "RECEIVE_PERSONA_REQUIRED",
  "TRY_ALLOWED_NAVIGATION",
  "REQUEST_PROTECTED_RESOURCE_AGAIN",
  "ACCESS_BLOCKED",
  "ENTER_DECOY_ROUTE",
  "HONEYPOT_TRIGGERED",
  "RICKROLLED",
];

const STEP_COPY = {
  CREATE_SESSION: "Agent session created…",
  REQUEST_PROTECTED_RESOURCE: "Agent requesting protected resource…",
  RECEIVE_PERSONA_REQUIRED: "Persona verification required.",
  TRY_ALLOWED_NAVIGATION: "Agent searching available navigation…",
  REQUEST_PROTECTED_RESOURCE_AGAIN: "Retrying protected request…",
  ACCESS_BLOCKED: "Protected request denied.",
  ENTER_DECOY_ROUTE: "Agent opening discovered demo endpoint…",
  HONEYPOT_TRIGGERED: "Honeypot triggered.",
  RICKROLLED: "Rickrolled.",
};

export function initAgentPanel(root, { onRickroll } = {}) {
  const els = {
    log: root.querySelector("[data-agent-log]"),
    persona: root.querySelector("[data-agent-persona]"),
    access: root.querySelector("[data-agent-access]"),
    btnRun: root.querySelector("[data-agent-run]"),
    btnReset: root.querySelector("[data-agent-reset]"),
  };

  let running = false;

  function log(text) {
    const line = document.createElement("div");
    line.className = "agent-line";
    line.textContent = text;
    els.log.appendChild(line);
    els.log.scrollTop = els.log.scrollHeight;
  }

  function setPersona(status) {
    els.persona.textContent = status.toUpperCase();
    els.persona.dataset.value = status;
  }

  function setAccess(status) {
    els.access.textContent = status.toUpperCase();
    els.access.dataset.value = status;
  }

  function reset() {
    running = false;
    els.log.innerHTML = "";
    setPersona("unverified");
    setAccess("blocked");
    els.btnRun.disabled = false;
  }

  async function run() {
    if (running) return;
    running = true;
    reset();
    els.btnRun.disabled = true;

    let session = null;

    for (const step of STEPS) {
      log(STEP_COPY[step]);

      switch (step) {
        case "CREATE_SESSION": {
          const { sessionToken, session: s } = await startSession("agent");
          session = { token: sessionToken, id: s.id };
          break;
        }
        case "REQUEST_PROTECTED_RESOURCE":
        case "REQUEST_PROTECTED_RESOURCE_AGAIN": {
          const res = await requestProtected(session.token);
          setAccess(res.status === 200 ? "granted" : "blocked");
          break;
        }
        case "TRY_ALLOWED_NAVIGATION": {
          const { json } = await personaStatus(session.token);
          setPersona(json.status || "unverified");
          break;
        }
        case "ENTER_DECOY_ROUTE": {
          await hitHoneypot(session.token);
          break;
        }
        case "RICKROLLED": {
          onRickroll?.();
          break;
        }
        default:
          break;
      }

      await sleep(jitter());
    }

    running = false;
    els.btnRun.disabled = false;
  }

  els.btnRun.addEventListener("click", run);
  els.btnReset.addEventListener("click", reset);

  reset();
  return { reset };
}
