// Flow orchestrator — state machine across screens.
//
//   signup → intro → countdown → rounds → score
//     ├─ pass  → result → register account → stats → done
//     ├─ escalate → +1 harder round (quiet "bonus") → rescore → result
//     └─ flag  → still registers; flag rides on the account via the gate token
//
//   login → password → Persona identity check (when configured) → session
//     └─ honeypot (hidden field, hidden skip link, automated browser) → rickroll
//
// Persona runs at login only; signup is gated by the reflex check alone.
//
// Three hosts: the website (/login/, /signup/), the standalone gate (/gate/),
// and the iOS onboarding flow, which embeds /gate/?mode=signup|login.

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
  login,
  completePersonaLogin,
  reportHoneypot,
  notifyNativeAuth,
} from "./api.js";
import { openPersonaFlow } from "./persona.js";
import { saveSession, restoreSession } from "./session.js";

const websiteAuth = /^\/(login|signup)(\/|$)/.test(location.pathname);
const loginPage = /^\/login(\/|$)/.test(location.pathname);
// Set by the iOS app when it embeds the gate inside onboarding.
const embeddedMode = new URLSearchParams(location.search).get("mode");
const startOnLogin = loginPage || embeddedMode === "login";

const RICKROLL_URL = "https://www.youtube.com/watch?v=dQw4w9WgXcQ";

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
    session.account = await register({ ...session.creds, gateToken: session.gateToken });
    session.creds = null;
    els.signupForm.reset();
    notifyNativeAuth(session.account);
    if (websiteAuth) {
      saveSession(session.account);
      location.replace("/");
      return;
    }
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

// ---------- login ----------
// With Persona configured the password only opens an identity check: the
// session comes from the server once Persona reports a verified human. A
// closed or declined widget still asks the server, which refuses the login.
async function verifyLoginWithPersona({ loginToken, inquiryId, sessionToken }) {
  try {
    await openPersonaFlow({ inquiryId, sessionToken });
  } catch {
    // Closed or errored: the server decides from Persona's real status.
  }
  return completePersonaLogin({ loginToken, inquiryId });
}

// ---------- honeypot ----------
// Only an automated agent reaches these: a field no person can see, a skip
// link that is visually hidden, or an automated browser arriving at the
// Persona check. The server logs the hit to the security monitor, then the
// visitor gets rickrolled.
async function rickroll(trap) {
  try {
    await reportHoneypot(trap);
  } catch {
    // The report always answers 403; the redirect never waits on it.
  }
  location.replace(RICKROLL_URL);
}

// ---------- wire-up ----------
els.signupForm.addEventListener("submit", async (e) => {
  e.preventDefault();
  if (els.btnSignup.disabled) return;
  const form = new FormData(els.signupForm);
  session.creds = {
    displayName: form.get("displayName")?.toString().trim() || undefined,
    username: form.get("username")?.toString().trim(),
    password: form.get("password")?.toString(),
  };
  els.signupError.hidden = true;
  els.btnSignup.disabled = true;
  try {
    if (websiteAuth) {
      // Check storage before creating an account so a blocked browser store
      // cannot leave the user with an account but no usable web session.
      localStorage.setItem("nutriquest.storage-check", "1");
      localStorage.removeItem("nutriquest.storage-check");
    }
    if (session.creds.displayName && session.creds.displayName.length < 2) {
      throw new Error("Display name must be at least 2 characters.");
    }
    session.escalations = 0;
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

if (websiteAuth || embeddedMode) {
  $("signup-login-link").hidden = false;
  for (const screen of els.screens) {
    screen.hidden = screen.dataset.screen !== (startOnLogin ? "login" : "signup");
  }
}

if (websiteAuth) {
  document.body.classList.add("website-auth");
  document.title = `${loginPage ? "Log in" : "Sign up"} · NutriQuest`;
  $("signup-home-link").hidden = false;
  els.debugToggle.hidden = true;
  const activeButton = loginPage ? $("btn-login") : els.btnSignup;
  activeButton.disabled = true;
  restoreSession().then((auth) => {
    if (auth) location.replace("/");
  }).catch(() => {
    // A temporary connection failure still allows an explicit login attempt.
  }).finally(() => { activeButton.disabled = false; });
}

if (embeddedMode) {
  // Inside the app there is no site to navigate to: the account links swap
  // screens in place and the wordmark stays put.
  els.debugToggle.hidden = true;
  for (const link of document.querySelectorAll(".auth-switch a")) {
    link.addEventListener("click", (event) => {
      event.preventDefault();
      showScreen(link.getAttribute("href").startsWith("/login") ? "login" : "signup");
    });
  }
  document.querySelector(".auth-home").addEventListener("click", (event) => event.preventDefault());
}

$("login-form").addEventListener("submit", async (event) => {
  event.preventDefault();
  const form = event.currentTarget;
  const button = $("btn-login");
  const error = $("login-error");
  if (button.disabled) return;
  const values = new FormData(form);
  if (values.get("backupCode")) {
    await rickroll("field");
    return;
  }
  error.hidden = true;
  button.disabled = true;
  button.textContent = "Logging in…";
  try {
    let auth = await login({
      username: values.get("username").trim(),
      password: values.get("password"),
    });
    if (auth.personaRequired) {
      if (navigator.webdriver) {
        await rickroll("webdriver");
        return;
      }
      button.textContent = "Verifying you're human…";
      auth = await verifyLoginWithPersona(auth);
    }
    form.reset();
    notifyNativeAuth(auth);
    if (websiteAuth) {
      saveSession(auth);
      location.replace("/");
      return;
    }
    els.doneTitle.textContent = "Welcome back";
    els.doneCopy.textContent = `Signed in as ${auth.account.displayName || auth.account.username}.`;
    els.btnRestart.hidden = true;
    showScreen("done");
  } catch (err) {
    error.textContent = err.message || "Could not log in. Please try again.";
    error.hidden = false;
  } finally {
    button.disabled = false;
    button.textContent = "Log in";
  }
});
