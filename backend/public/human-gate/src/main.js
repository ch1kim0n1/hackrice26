// Flow orchestrator — state machine across screens.
//
//   signup → intro → countdown → rounds → score
//     ├─ pass  → result → register account → stats → done
//     ├─ escalate → +1 harder round (quiet "bonus") → rescore → result
//     └─ flag  → still registers; flag rides on the account via the gate token

import { randomId } from "./rng.js";
import {
  generateSession,
  escalationRound,
  instructionFor,
} from "./challenge.js";
import { playRound } from "./game.js";
import { scoreSession, verdictAfterEscalation } from "./scoring.js";
import { renderStats } from "./stats.js";
import {
  createGateSession,
  submitGateResult,
  register,
  notifyNativeAuth,
  createPersonaInquiry,
  completePersonaInquiry,
} from "./api.js";
import { openPersonaFlow } from "./persona.js";

const $ = (id) => document.getElementById(id);

const els = {
  screens: [...document.querySelectorAll(".screen")],
  signupForm: $("signup-form"),
  signupError: $("signup-error"),
  btnSignup: $("btn-signup"),
  btnStart: $("btn-start"),
  arena: $("arena"),
  countdown: $("arena-countdown"),
  instruction: $("hud-instruction"),
  progress: $("hud-progress"),
  roundLabel: $("hud-round"),
  streak: $("hud-streak"),
  resultTitle: $("result-title"),
  resultCopy: $("result-copy"),
  resultSpinner: $("result-spinner"),
  btnBackSignup: $("btn-back-signup"),
  statsBody: $("stats-body"),
  doneTitle: $("done-title"),
  doneCopy: $("done-copy"),
  btnRestart: $("btn-restart"),
  debugToggle: $("debug-toggle"),
  debugDrawer: $("debug-drawer"),
  debugOutput: $("debug-output"),
};

// ---------- session state ----------
const session = {
  referenceId: randomId(),
  spec: null,
  results: [],
  scoring: null,
  flagged: false,
  escalations: 0,
  gateToken: null,
  creds: null,
  account: null,
  persona: null, // { inquiryId, status } once the Persona leg runs
};

function updateDebug() {
  els.debugOutput.textContent = JSON.stringify(
    {
      referenceId: session.referenceId,
      roundsPlayed: session.results.length,
      escalations: session.escalations,
      scoring: session.scoring
        ? {
            score: session.scoring.score,
            verdict: session.scoring.verdict,
            flags: session.scoring.flags,
            stats: session.scoring.stats,
          }
        : null,
      flagged: session.flagged,
      persona: session.persona,
    },
    null,
    2
  );
}

// ---------- screen transitions ----------
function showScreen(name) {
  for (const s of els.screens) {
    const active = s.dataset.screen === name;
    if (active) {
      s.hidden = false;
      s.classList.remove("leaving");
      s.classList.add("entering");
      setTimeout(() => s.classList.remove("entering"), 500);
    } else if (!s.hidden) {
      s.classList.add("leaving");
      setTimeout(() => {
        s.hidden = true;
        s.classList.remove("leaving");
      }, 340);
    }
  }
}

// ---------- HUD ----------
function renderProgress(total, current, doneCount) {
  els.progress.innerHTML = "";
  for (let i = 0; i < total; i++) {
    const d = document.createElement("div");
    d.className = "hud-dot" + (i < doneCount ? " done" : i === current ? " active" : "");
    els.progress.appendChild(d);
  }
}

let streak = 0;
function bumpStreak(rt) {
  streak = rt < 500 ? streak + 1 : 0;
  if (streak >= 2) {
    els.streak.hidden = false;
    els.streak.textContent = `×${streak}`;
    els.streak.style.animation = "none";
    void els.streak.offsetWidth;
    els.streak.style.animation = "";
  }
}
function resetStreak() {
  streak = 0;
  els.streak.hidden = true;
}

// ---------- countdown ----------
function countdown() {
  return new Promise((resolve) => {
    els.countdown.hidden = false;
    const ticks = ["3", "2", "1", "GO"];
    let i = 0;
    const step = () => {
      if (i >= ticks.length) {
        els.countdown.hidden = true;
        els.countdown.innerHTML = "";
        resolve();
        return;
      }
      els.countdown.innerHTML = `<span class="tick">${ticks[i]}</span>`;
      i++;
      setTimeout(step, i === ticks.length ? 450 : 700);
    };
    step();
  });
}

// ---------- game loop ----------
async function runRounds() {
  showScreen("game");

  for (let i = 0; i < session.spec.rounds.length; i++) {
    const spec = session.spec.rounds[i];
    if (session.results[i]) continue; // already played (escalation re-entry)

    els.instruction.innerHTML = instructionFor(spec);
    els.roundLabel.textContent =
      spec.difficulty >= 2 ? "Bonus round" : `Round ${i + 1}`;
    renderProgress(session.spec.rounds.length, i, i);

    await (i === 0 ? countdown() : sleep(650));
    const result = await playRound(els.arena, spec, {
      onHit: bumpStreak,
      onDecoy: resetStreak,
      onMiss: resetStreak,
    });
    session.results[i] = result;
    updateDebug();
  }
}

function sleep(ms) {
  return new Promise((r) => setTimeout(r, ms));
}

// ---------- scoring / escalation ----------
async function evaluate() {
  session.scoring = scoreSession(session.results);
  updateDebug();

  if (session.scoring.verdict === "escalate" && session.escalations < 2) {
    session.escalations++;
    escalationRound(session.spec); // quietly appended — UI calls it "bonus"
    await runRounds();
    session.scoring = scoreSession(session.results);
    session.scoring.verdict = verdictAfterEscalation(session.scoring.score);
    updateDebug();
  }

  session.flagged = session.scoring.verdict === "flag";
  updateDebug();
}

// ---------- persona verification ----------
// Second layer of the gate: Persona's embedded flow (doc check + liveness).
// Runs only when the backend is configured — a 503 PERSONA_NOT_CONFIGURED
// means the key/template aren't set and the leg is skipped entirely. The
// outcome is non-punitive like the pre-gate: cancel or decline still let the
// account register, with the server-verified status bound to the session.
async function runPersonaLeg() {
  let inquiry;
  try {
    inquiry = await createPersonaInquiry(session.gateToken);
  } catch (err) {
    if (err.code === "PERSONA_NOT_CONFIGURED") return; // leg off — skip silently
    throw err;
  }
  session.persona = { inquiryId: inquiry.inquiryId, status: "started" };
  updateDebug();

  els.resultTitle.textContent = "One more check";
  els.resultCopy.textContent = "Quick identity verification: takes about a minute.";
  els.resultSpinner.style.display = "none";

  try {
    const { status } = await openPersonaFlow(inquiry);
    session.persona.status = status;
  } catch {
    session.persona.status = "closed"; // cancelled or widget error
  }
  updateDebug();

  // Record whatever Persona actually reports — not the client's word.
  try {
    const { status } = await completePersonaInquiry(session.gateToken, inquiry.inquiryId);
    session.persona.status = status;
  } catch { /* keep the client-observed status in the debug drawer */ }
  updateDebug();

  showScreen("result");
  els.resultTitle.textContent = "Human confirmed";
  els.resultSpinner.style.display = "";
}

// ---------- account creation ----------
// The gate token was issued at signup-submit time and is now scored. Report
// the verdict, then register — the token is consumed server-side and binds
// the verdict to the new account.
async function createAccount() {
  showScreen("result");
  els.resultTitle.textContent = "Human confirmed";
  els.resultCopy.textContent = "Nice reflexes. Creating your account…";
  els.resultSpinner.style.display = "";
  els.btnBackSignup.hidden = true;

  try {
    await submitGateResult(session.gateToken, session.scoring);
    await runPersonaLeg();
    els.resultCopy.textContent = "Nice reflexes. Creating your account…";
    session.account = await register({ ...session.creds, gateToken: session.gateToken });
    notifyNativeAuth(session.account);
  } catch (err) {
    els.resultTitle.textContent = "Signup failed";
    els.resultCopy.textContent = err.message || "Something went wrong.";
    els.resultSpinner.style.display = "none";
    els.btnBackSignup.hidden = false;
    return;
  }

  await sleep(700); // let the confirmation beat land
  renderStats(els.statsBody, session);
  els.statsBody.querySelector("#btn-stats-continue").onclick = () => {
    els.doneTitle.textContent = "You're in";
    els.doneCopy.textContent = `Welcome, ${session.account.account.displayName || session.account.account.username}. Your account is ready.`;
    showScreen("done");
  };
  showScreen("stats");
}

// ---------- wire-up ----------
els.signupForm.addEventListener("submit", async (e) => {
  e.preventDefault();
  const form = new FormData(els.signupForm);
  session.creds = {
    displayName: form.get("displayName")?.toString().trim() || undefined,
    username: form.get("username")?.toString().trim(),
    password: form.get("password")?.toString(),
  };
  els.signupError.hidden = true;
  els.btnSignup.disabled = true;
  try {
    const { gateToken } = await createGateSession();
    session.gateToken = gateToken;
    showScreen("intro");
  } catch (err) {
    els.signupError.textContent = err.message || "Could not start the human check.";
    els.signupError.hidden = false;
  } finally {
    els.btnSignup.disabled = false;
  }
});

els.btnBackSignup.addEventListener("click", async () => {
  // fresh token for the retry — the previous one may be consumed or scored
  session.gateToken = null;
  showScreen("signup");
});

els.btnStart.addEventListener("click", async () => {
  session.spec = generateSession();
  session.results = [];
  resetStreak();
  await runRounds();

  // escalate silently — bonus rounds play while still on the game screen
  await evaluate();

  await createAccount();
});

els.btnRestart.addEventListener("click", () => {
  session.referenceId = randomId();
  session.spec = null;
  session.results = [];
  session.scoring = null;
  session.flagged = false;
  session.escalations = 0;
  session.gateToken = null;
  session.creds = null;
  session.account = null;
  session.persona = null;
  els.resultSpinner.style.display = "";
  els.btnBackSignup.hidden = true;
  els.signupForm.reset();
  updateDebug();
  showScreen("signup");
});

els.debugToggle.addEventListener("click", () => {
  els.debugDrawer.hidden = !els.debugDrawer.hidden;
});

updateDebug();
