// Backend API client for the signup flow.
//
//   POST /human-gate/session  -> { gateToken }   (issued before the game)
//   POST /human-gate/result   -> score/verdict recorded against the token
//   POST /auth/register       -> account + session token (consumes gateToken)
//
// Base URL resolution: ?api= query param > window.NQ_API_BASE > localhost:4000.
// In the iOS WKWebView the app can inject NQ_API_BASE; for the standalone
// browser run, ?api=http://host:port overrides without a rebuild.

const DEFAULT_API = "http://localhost:4000";

export function apiBase() {
  const param = new URLSearchParams(location.search).get("api");
  return (param || window.NQ_API_BASE || DEFAULT_API).replace(/\/+$/, "");
}

export class ApiError extends Error {
  constructor(status, code, message) {
    super(message);
    this.status = status;
    this.code = code;
  }
}

async function post(path, body) {
  let res;
  try {
    res = await fetch(`${apiBase()}${path}`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(body),
    });
  } catch {
    throw new ApiError(0, "UNREACHABLE", `Cannot reach the server at ${apiBase()}.`);
  }
  const json = await res.json().catch(() => ({}));
  if (!res.ok) {
    const err = json.error || {};
    throw new ApiError(res.status, err.code || "ERROR", err.message || `Request failed (${res.status})`);
  }
  return json;
}

export const createGateSession = () => post("/human-gate/session", {});

export function submitGateResult(gateToken, scoring) {
  return post("/human-gate/result", {
    gateToken,
    score: scoring.score,
    verdict: scoring.verdict,
    flags: scoring.flags,
  });
}

export function register({ username, password, displayName, gateToken }) {
  return post("/auth/register", { username, password, displayName, gateToken });
}

// Persona leg — server creates an inquiry bound to the gate session and
// returns { inquiryId, sessionToken } for the embedded widget.
// Throws ApiError(503, "PERSONA_NOT_CONFIGURED") when the backend has no
// Persona key/template — callers treat that as "skip this step".
export function createPersonaInquiry(gateToken) {
  return post("/human-gate/persona/inquiry", { gateToken });
}

// Server reads the inquiry's real status from Persona and records it on the
// gate session. Call on widget close — complete and cancel alike.
export function completePersonaInquiry(gateToken, inquiryId) {
  return post("/human-gate/persona/complete", { gateToken, inquiryId });
}

/** Hand the issued session back to the iOS shell, if we are inside one. */
export function notifyNativeAuth(auth) {
  try {
    window.webkit?.messageHandlers?.nutriquest?.postMessage({
      type: "auth",
      token: auth.token,
      playerId: auth.playerId,
      username: auth.account?.username,
      displayName: auth.account?.displayName,
    });
  } catch {
    // no-op outside WKWebView
  }
}
