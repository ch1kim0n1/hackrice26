// Stats breakdown renderer — turns session telemetry + scoring into a
// visual proof page: score gauge, per-signal checks vs thresholds,
// per-round timelines, RT distribution bars. Pure DOM/SVG, no libs.

import { THRESHOLDS } from "./scoring.js";

const TYPE_LABEL = { tapAll: "tap all", color: "color filter", order: "sequence" };
const RT_SCALE = 1600; // ms mapped to 100% bar width

const esc = (s) => String(s).replace(/[&<>"]/g, (c) => `&#${c.charCodeAt(0)};`);

function rtClass(rt) {
  if (rt < THRESHOLDS.RT_IMPOSSIBLE) return "rt-bad";
  if (rt < THRESHOLDS.RT_FLOOR) return "rt-warn";
  return "rt-good";
}

/** Score ring: SVG arc 0–100, colored by verdict. */
function gauge(score, verdict) {
  const r = 52;
  const c = 2 * Math.PI * r;
  const fill = (score / 100) * c;
  const color =
    verdict === "pass" ? "var(--success)" : verdict === "escalate" ? "var(--gold)" : "var(--warning)";
  return `
    <div class="gauge" style="color:${color}">
      <svg viewBox="0 0 130 130" width="130" height="130">
        <circle cx="65" cy="65" r="${r}" fill="none" stroke="var(--hairline)" stroke-width="11"/>
        <circle cx="65" cy="65" r="${r}" fill="none" stroke="currentColor" stroke-width="11"
          stroke-linecap="round" stroke-dasharray="${fill} ${c}"
          transform="rotate(-90 65 65)" class="gauge-arc"/>
        <text x="65" y="58" text-anchor="middle" class="gauge-num">${score}</text>
        <text x="65" y="76" text-anchor="middle" class="gauge-cap">suspicion</text>
        <text x="65" y="90" text-anchor="middle" class="gauge-cap">0 = human</text>
      </svg>
    </div>`;
}

/** One row per scoring signal: observed value vs threshold, weighted. */
function signalRows(sc) {
  const s = sc.stats;
  const checks = [
    {
      name: "reaction floor",
      desc: `median RT ${s.medianRt ?? "-"}ms vs floor ${THRESHOLDS.RT_FLOOR}ms`,
      tripped: s.medianRt != null && s.medianRt < THRESHOLDS.RT_FLOOR,
    },
    {
      name: "pre-click",
      desc: `${s.impossible} hit(s) under ${THRESHOLDS.RT_IMPOSSIBLE}ms`,
      tripped: s.impossible > 0,
    },
    {
      name: "RT variance",
      desc: `stdev ${s.rtStdev ?? "-"}ms vs floor ${THRESHOLDS.RT_STDEV_FLOOR}ms`,
      tripped: s.rtStdev != null && s.rtStdev < THRESHOLDS.RT_STDEV_FLOOR && s.hits >= 4,
    },
    {
      name: "tap cadence",
      desc: `gap stdev ${s.gapStdev ?? "-"}ms vs floor ${THRESHOLDS.GAP_STDEV_FLOOR}ms`,
      tripped: s.gapStdev != null && s.gapStdev < THRESHOLDS.GAP_STDEV_FLOOR,
    },
    {
      name: "pointer trajectory",
      desc: `${Math.round(s.teleportRatio * 100)}% teleports vs limit 80%`,
      tripped: s.teleportRatio > 0.8,
    },
    {
      name: "error profile",
      desc: `${s.misses} missed, ${s.decoyTaps} decoy, ${s.strayTaps} stray, ${s.wrongOrder} wrong-order`,
      tripped: false,
      neutral: true,
    },
  ];
  return checks
    .map(
      (c) => `
      <div class="sig-row ${c.tripped ? "sig-tripped" : ""} ${c.neutral ? "sig-neutral" : ""}">
        <span class="sig-icon">${c.neutral ? "·" : c.tripped ? "⚑" : "✓"}</span>
        <span class="sig-name">${esc(c.name)}</span>
        <span class="sig-desc">${esc(c.desc)}</span>
      </div>`
    )
    .join("");
}

/**
 * Mini timeline per round. Each lane = one orb. The colored bar is how
 * long that orb stayed on screen (appears -> expires). A black tick is
 * the tap that landed on it; a grey tick at the bar's end means it
 * expired untouched (a miss). Faded bars are decoys (never counted).
 */
function roundTimeline(result) {
  const { spec } = result;
  const end = Math.max(...spec.targets.map((t) => t.appearAtMs + t.lifetimeMs)) * 1.05;
  const lanes = spec.targets
    .map((t) => {
      const x1 = (t.appearAtMs / end) * 100;
      const w = (t.lifetimeMs / end) * 100;
      const hit = result.hits.find((h) => h.targetId === t.id);
      const tick = hit
        ? `<span class="tl-tick tl-hit" style="left:${(hit.tHit / end) * 100}%"></span>`
        : !t.isDecoy
          ? `<span class="tl-tick tl-miss" style="left:${((t.appearAtMs + t.lifetimeMs) / end) * 100}%"></span>`
          : "";
      return `
        <div class="tl-lane">
          <span class="tl-bar tl-${t.color} ${t.isDecoy ? "tl-decoy" : ""}"
            style="left:${x1}%;width:${w}%"></span>
          ${tick}
        </div>`;
    })
    .join("");
  return `
    <div class="tl">${lanes}</div>
    <div class="tl-axis">
      <span>0s</span>
      <span class="tl-axis-label">orb lifespan (colored bar) · tap (black tick) · miss (grey tick)</span>
      <span>${(end / 1000).toFixed(1)}s</span>
    </div>`;
}

/**
 * Reaction-time bars: one bar per tap, length = ms between the orb
 * appearing and the tap landing. The dark notch is the 90ms bot floor:
 * bars ending left of it are faster than a human can react.
 */
function rtBars(result) {
  if (!result.hits.length) return `<div class="rt-none">no hits</div>`;
  const threshX = (THRESHOLDS.RT_FLOOR / RT_SCALE) * 100;
  const bars = result.hits
    .slice()
    .sort((a, b) => a.tHit - b.tHit)
    .map(
      (h) => `
      <div class="rt-row">
        <span class="rt-label">${Math.round(h.rt)}ms</span>
        <div class="rt-track">
          <span class="rt-fill ${rtClass(h.rt)}" style="width:${Math.min(100, (h.rt / RT_SCALE) * 100)}%"></span>
          <span class="rt-thresh" style="left:${threshX}%"></span>
        </div>
      </div>`
    )
    .join("");
  return `
    <div class="rt-bars">${bars}</div>
    <div class="rt-axis">
      <span>0ms</span>
      <span class="rt-axis-mark" style="left:${threshX}%">| ${THRESHOLDS.RT_FLOOR}ms bot floor</span>
      <span>${RT_SCALE}ms+</span>
    </div>`;
}

function roundCard(result, i) {
  const { spec } = result;
  const sorted = result.hits.map((h) => h.rt).sort((a, b) => a - b);
  const med = sorted.length
    ? Math.round(
        sorted.length % 2
          ? sorted[(sorted.length - 1) / 2]
          : (sorted[sorted.length / 2 - 1] + sorted[sorted.length / 2]) / 2
      )
    : null;
  return `
    <div class="stat-card">
      <div class="stat-card-head">
        <span class="stat-card-title">Round ${i + 1}${spec.difficulty >= 2 ? " · bonus" : ""}</span>
        <span class="stat-card-sub">rule: ${TYPE_LABEL[spec.type] ?? spec.type} · ${spec.targets.length} orbs spawned</span>
      </div>
      ${roundTimeline(result)}
      <div class="rt-section">
        <div class="rt-head">reaction times <span class="rt-legend"><i class="rt-good"></i>ok <i class="rt-warn"></i>&lt;${THRESHOLDS.RT_FLOOR} <i class="rt-bad"></i>&lt;${THRESHOLDS.RT_IMPOSSIBLE}</span></div>
        ${rtBars(result)}
      </div>
      <div class="stat-chips">
        <span class="chip">median ${med ?? "-"}ms</span>
        <span class="chip">${result.hits.length}/${spec.expectedHits} hit</span>
        ${result.misses.length ? `<span class="chip chip-warn">${result.misses.length} missed</span>` : ""}
        ${result.decoyTaps ? `<span class="chip chip-bad">${result.decoyTaps} decoy taps</span>` : ""}
        ${result.wrongOrder ? `<span class="chip chip-warn">${result.wrongOrder} wrong order</span>` : ""}
      </div>
    </div>`;
}

/**
 * @param {HTMLElement} container
 * @param {object} session {referenceId, results, scoring, escalations, flagged, account}
 */
export function renderStats(container, session) {
  const sc = session.scoring;
  const verdictLabel = { pass: "clean pass", escalate: "escalated", flag: "flagged" }[sc.verdict];

  container.innerHTML = `
    <div class="stats-wrap">
      <div class="stats-hero stat-card">
        ${gauge(sc.score, sc.verdict)}
        <div class="stats-hero-info">
          <h1 class="headline">Session breakdown</h1>
          <p class="subhead">verdict: <b>${verdictLabel}</b>${session.flagged ? " · flag recorded on account" : ""} · account: <b>${esc(session.account?.account?.username ?? "created")}</b></p>
          <p class="subhead">higher score = more bot-like</p>
          <code class="stats-ref">${esc(session.referenceId)}</code>
        </div>
      </div>

      <div class="stat-card">
        <div class="stat-card-title">why this score</div>
        <p class="sig-explainer">Each check compares one signal against its human threshold. ⚑ = suspicious (adds to the score), ✓ = human-looking, · = informational.</p>
        <div class="sig-list">${signalRows(sc)}</div>
        <p class="sig-note">verdict bands: &lt;${THRESHOLDS.VERDICT_PASS} pass, ${THRESHOLDS.VERDICT_PASS}–${THRESHOLDS.VERDICT_FLAG} escalate, &gt;${THRESHOLDS.VERDICT_FLAG} flag</p>
      </div>

      ${session.results.map((r, i) => roundCard(r, i)).join("")}

      <div class="stat-card">
        <div class="stat-card-title">raw telemetry</div>
        <p class="sig-explainer">Everything above, unprocessed. Used by the checks and sent to debug tooling.</p>
        <div class="raw-grid">
          <span>hits</span><b>${sc.stats.hits}</b>
          <span>median RT</span><b>${sc.stats.medianRt ?? "-"}ms</b>
          <span>RT range</span><b>${sc.stats.minRt ?? "-"}–${sc.stats.maxRt ?? "-"}ms</b>
          <span>RT stdev</span><b>${sc.stats.rtStdev ?? "-"}ms</b>
          <span>gap stdev</span><b>${sc.stats.gapStdev ?? "-"}ms</b>
          <span>teleport ratio</span><b>${sc.stats.teleportRatio}</b>
          <span>misses</span><b>${sc.stats.misses}</b>
          <span>decoy taps</span><b>${sc.stats.decoyTaps}</b>
          <span>stray taps</span><b>${sc.stats.strayTaps}</b>
          <span>wrong order</span><b>${sc.stats.wrongOrder}</b>
          <span>escalations</span><b>${session.escalations}</b>
          <span>rounds</span><b>${session.results.length}</b>
        </div>
      </div>

      <button class="btn btn-primary btn-block" id="btn-stats-continue">Continue</button>
      <p class="fine-print">Pre-gate telemetry only. Persona verdict is separate.</p>
    </div>`;
}
