// Backend client for the Human vs AI Persona demo.
//
//   POST /demo/session          -> { sessionToken, session }
//   GET  /demo/protected        -> 200 (granted) or 403 PERSONA_REQUIRED
//   POST /demo/persona/start    -> { inquiryId, personaSessionToken, status }
//   POST /demo/persona/complete -> { status }   (backend-confirmed, never client-set)
//   GET  /demo/persona/status   -> { status }
//   GET  /demo/honeypot         -> decoy payload, logs the rickroll
//   GET  /demo/security-events(/stream)
//
// Base URL resolution matches persona-challenge/src/api.js: ?api= query
// param > window.NQ_API_BASE > localhost:4000.

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

/** Same shape whether the body carries `{error:{code,message}}` (most
 *  routes) or a bare `{code,message}` (the protected route). */
function errorFrom(res, json) {
  const err = json.error || json;
  return new ApiError(res.status, err.code || "ERROR", err.message || `Request failed (${res.status})`);
}

async function post(path, body, token) {
  let res;
  try {
    res = await fetch(`${apiBase()}${path}`, {
      method: "POST",
      headers: { "content-type": "application/json", ...(token ? { "x-demo-session": token } : {}) },
      body: JSON.stringify(body),
    });
  } catch {
    throw new ApiError(0, "UNREACHABLE", `Cannot reach the server at ${apiBase()}.`);
  }
  const json = await res.json().catch(() => ({}));
  if (!res.ok) throw errorFrom(res, json);
  return json;
}

async function get(path, token) {
  let res;
  try {
    res = await fetch(`${apiBase()}${path}`, {
      headers: token ? { "x-demo-session": token } : {},
    });
  } catch {
    throw new ApiError(0, "UNREACHABLE", `Cannot reach the server at ${apiBase()}.`);
  }
  const json = await res.json().catch(() => ({}));
  return { ok: res.ok, status: res.status, json };
}

export const startSession = (actorType) => post("/demo/session", { actorType });

export const requestProtected = (token) => get("/demo/protected", token);

export const startPersona = (token) => post("/demo/persona/start", {}, token);

export const completePersona = (token) => post("/demo/persona/complete", {}, token);

export const personaStatus = (token) => get("/demo/persona/status", token);

export const hitHoneypot = (token) => get("/demo/honeypot", token);

export const listSecurityEvents = () => get("/demo/security-events").then((r) => r.json.events || []);
