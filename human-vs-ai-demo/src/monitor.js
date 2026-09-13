// Live Security Monitor — SSE-first, polling fallback.
//
// Renders every SecurityEvent the backend emits (both actors' sessions) into
// a scrolling log, oldest first. Never renders anything not already present
// in the event's `message` — no secrets/tokens ever reach this feed.

import { apiBase, listSecurityEvents } from "./api.js";

const SEVERITY_LABEL = {
  info: "INFO",
  success: "SUCCESS",
  warning: "WARNING",
  blocked: "BLOCKED",
  honeypot: "HONEYPOT",
};

function timeOf(ts) {
  return new Date(ts).toLocaleTimeString("en-US", { hour12: false });
}

export function startMonitor(logEl) {
  const seen = new Set();

  function append(event) {
    if (seen.has(event.id)) return;
    seen.add(event.id);
    const row = document.createElement("div");
    row.className = `log-row log-${event.severity}`;
    row.innerHTML = `
      <span class="log-time">${timeOf(event.timestamp)}</span>
      <span class="log-actor log-actor-${event.actorType}">${event.actorType}</span>
      <span class="log-type">${event.type}</span>
      <span class="log-badge">${SEVERITY_LABEL[event.severity] || event.severity}</span>
    `;
    logEl.appendChild(row);
    logEl.scrollTop = logEl.scrollHeight;
  }

  listSecurityEvents().then((events) => events.forEach(append)).catch(() => {});

  let pollTimer = null;
  function startPolling() {
    if (pollTimer) return;
    pollTimer = setInterval(() => {
      listSecurityEvents().then((events) => events.forEach(append)).catch(() => {});
    }, 750);
  }

  let source;
  try {
    source = new EventSource(`${apiBase()}/demo/security-events/stream`);
    source.onmessage = (e) => {
      try {
        append(JSON.parse(e.data));
      } catch {
        /* ignore malformed frame */
      }
    };
    source.onerror = () => {
      source.close();
      startPolling();
    };
  } catch {
    startPolling();
  }

  return () => {
    source?.close();
    if (pollTimer) clearInterval(pollTimer);
  };
}
