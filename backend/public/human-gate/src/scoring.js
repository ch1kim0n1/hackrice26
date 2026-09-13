// Suspicion scoring — turns RoundResult telemetry into a 0–100
// score + verdict. Thresholds are starting calibration; the doc
// calls out real-human testing as the actual work here.

const WEIGHTS = {
  inhumanSpeed: 55,   // median RT below physical minimum
  singleImpossible: 15, // any hit < 60ms (pre-click / scripted)
  lowVariance: 30,    // RTs too uniform to be biological
  noTrajectory: 25,   // mouse teleports between targets, no path
  tooUniformGap: 20,  // inter-tap intervals metronomic
  allPerfect: 10,     // zero misses/decoys/strays on hard rounds — weak signal
};

const RT_FLOOR = 90;        // ms — human reflex floor is ~150ms; 90 is generous
const RT_IMPOSSIBLE = 60;   // ms — essentially pre-click
const RT_STDEV_FLOOR = 12;  // ms — biology jitters more than this
const GAP_STDEV_FLOOR = 18; // ms — inter-tap metronome floor
const VERDICT_PASS = 30;    // any single weighted flag is worth ~10–55;
const VERDICT_FLAG = 70;    // escalate lives between these

export const THRESHOLDS = {
  RT_FLOOR,
  RT_IMPOSSIBLE,
  RT_STDEV_FLOOR,
  GAP_STDEV_FLOOR,
  VERDICT_PASS,
  VERDICT_FLAG,
};

function median(xs) {
  if (!xs.length) return 0;
  const s = xs.slice().sort((a, b) => a - b);
  const m = Math.floor(s.length / 2);
  return s.length % 2 ? s[m] : (s[m - 1] + s[m]) / 2;
}

function stdev(xs) {
  if (xs.length < 2) return Infinity;
  const mean = xs.reduce((a, b) => a + b, 0) / xs.length;
  return Math.sqrt(xs.reduce((a, x) => a + (x - mean) ** 2, 0) / xs.length);
}

/**
 * Fraction of mouse hits with no pointer trail preceding them.
 * Touch is exempt — fingers lift and land without a path.
 */
function teleportRatio(rounds) {
  let mouseHits = 0;
  let teleports = 0;
  for (const r of rounds) {
    for (const h of r.hits) {
      if (h.pt !== "mouse" && h.pt !== "pen") continue;
      mouseHits++;
      // any trail sample within the 150ms before this hit, near its position?
      const tHit = r.startedAt + h.tHit;
      const hasPath = r.trail.some(
        (s) =>
          (s.pt === "mouse" || s.pt === "pen") &&
          Math.abs(r.startedAt + s.t - tHit) < 150 &&
          Math.hypot(s.x - h.x, s.y - h.y) < 40
      );
      if (!hasPath) teleports++;
    }
  }
  return mouseHits ? teleports / mouseHits : 0;
}

/**
 * @param {Array<object>} rounds RoundResult[] from game.js
 * @returns {{score:number, flags:string[], verdict:'pass'|'escalate'|'flag', stats:object}}
 */
export function scoreSession(rounds) {
  const flags = [];
  let score = 0;

  const rts = rounds.flatMap((r) => r.hits.map((h) => h.rt));
  // inter-tap gaps per round — the pause between rounds is human
  // think-time, not part of the cadence signal
  const gaps = rounds.flatMap((r) => {
    const ts = r.hits.map((h) => h.tHit ?? 0).sort((a, b) => a - b);
    return ts.slice(1).map((t, i) => t - ts[i]);
  });

  // --- reaction time signals ---
  if (rts.length) {
    const med = median(rts);
    const sd = stdev(rts);

    if (med < RT_FLOOR) {
      score += WEIGHTS.inhumanSpeed;
      flags.push(`inhuman-speed: median RT ${med.toFixed(0)}ms < ${RT_FLOOR}ms`);
    }

    const impossible = rts.filter((rt) => rt < RT_IMPOSSIBLE).length;
    if (impossible) {
      score += Math.min(impossible, 3) * WEIGHTS.singleImpossible;
      flags.push(`pre-click: ${impossible} hit(s) < ${RT_IMPOSSIBLE}ms`);
    }

    if (rts.length >= 4 && sd < RT_STDEV_FLOOR) {
      score += WEIGHTS.lowVariance;
      flags.push(`low-variance: RT stdev ${sd.toFixed(1)}ms < ${RT_STDEV_FLOOR}ms`);
    }
  }

  // --- inter-tap metronome ---
  const gapSd = stdev(gaps);
  if (gaps.length >= 3 && gapSd < GAP_STDEV_FLOOR) {
    score += WEIGHTS.tooUniformGap;
    flags.push(`metronome: inter-tap stdev ${gapSd.toFixed(1)}ms`);
  }

  // --- trajectory ---
  const tele = teleportRatio(rounds);
  if (tele > 0.8) {
    score += WEIGHTS.noTrajectory;
    flags.push(`no-trajectory: ${(tele * 100).toFixed(0)}% of mouse hits teleported`);
  }

  // --- perfection on hard content (weak signal, low weight) ---
  const hardRounds = rounds.filter((r) => r.spec.difficulty >= 1);
  if (
    hardRounds.length &&
    hardRounds.every((r) => !r.misses.length && !r.decoyTaps && !r.wrongOrder && !r.strayTaps)
  ) {
    score += WEIGHTS.allPerfect;
    flags.push("flawless-hard: zero errors on escalated rounds");
  }

  score = Math.min(100, Math.round(score));

  const verdict =
    score < VERDICT_PASS ? "pass" : score <= VERDICT_FLAG ? "escalate" : "flag";

  return {
    score,
    flags,
    verdict,
    stats: {
      hits: rts.length,
      medianRt: rts.length ? Math.round(median(rts)) : null,
      rtStdev: rts.length >= 2 ? Math.round(stdev(rts)) : null,
      minRt: rts.length ? Math.round(Math.min(...rts)) : null,
      maxRt: rts.length ? Math.round(Math.max(...rts)) : null,
      gapStdev: gaps.length >= 2 ? Math.round(gapSd) : null,
      teleportRatio: Math.round(tele * 100) / 100,
      impossible: rts.filter((rt) => rt < RT_IMPOSSIBLE).length,
      misses: rounds.reduce((a, r) => a + r.misses.length, 0),
      decoyTaps: rounds.reduce((a, r) => a + r.decoyTaps, 0),
      strayTaps: rounds.reduce((a, r) => a + r.strayTaps, 0),
      wrongOrder: rounds.reduce((a, r) => a + r.wrongOrder, 0),
    },
  };
}

/** Re-verdict after escalation rounds: stricter, but still no hard fail. */
export function verdictAfterEscalation(score) {
  return score < 60 ? "pass" : "flag";
}
