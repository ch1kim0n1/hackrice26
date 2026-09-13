// Challenge spec generation — combinatorial space over:
//   instruction type × target count × positions × colors ×
//   appear-time offsets × lifetimes × decoys
// Millions of distinct rounds; every parameter CSPRNG-drawn.

import { randomInt, randomFloat, pick, shuffle } from "./rng.js";

const COLORS = ["mint", "gold", "violet", "red"];

// Safe spawn area as fraction of arena (keeps orbs off edges/HUD).
const SAFE = { xMin: 0.08, xMax: 0.92, yMin: 0.08, yMax: 0.88 };

/**
 * Distinct spawn points via jittered grid cells.
 * @returns {Array<{x:number,y:number}>} normalized coords
 */
function spawnPositions(count) {
  const cols = 5;
  const rows = 4;
  const cells = shuffle(
    Array.from({ length: cols * rows }, (_, i) => ({
      cx: i % cols,
      cy: Math.floor(i / cols),
    }))
  ).slice(0, count);

  return cells.map(({ cx, cy }) => {
    const jx = randomFloat(-0.28, 0.28); // jitter inside cell
    const jy = randomFloat(-0.28, 0.28);
    const x = SAFE.xMin + ((cx + 0.5 + jx) / cols) * (SAFE.xMax - SAFE.xMin);
    const y = SAFE.yMin + ((cy + 0.5 + jy) / rows) * (SAFE.yMax - SAFE.yMin);
    return { x, y };
  });
}

/**
 * Build one round spec.
 * difficulty 0 = baseline, 1 = harder, 2 = escalation round.
 */
export function generateRound(index, difficulty = 0) {
  const type = pick(["tapAll", "color", "order"]);
  const hard = difficulty >= 1;

  const targetCount = {
    tapAll: randomInt(3, hard ? 6 : 4),
    color: randomInt(3, hard ? 5 : 4),
    order: randomInt(3, hard ? 5 : 4),
  }[type];
  const decoyCount =
    type === "color" ? randomInt(1, hard ? 3 : 2) : hard ? randomInt(0, 2) : 0;

  const total = targetCount + decoyCount;
  const positions = spawnPositions(total);

  // Staggered appearances — bots can't pre-compute timing.
  const gap = hard ? randomInt(140, 380) : randomInt(220, 520);
  const offsets = shuffle(
    Array.from({ length: total }, (_, i) => i * gap + randomInt(0, Math.floor(gap * 0.6)))
  );

  const lifetime = hard ? randomInt(850, 1300) : randomInt(1300, 1900);

  // red is reserved for "avoid" — targets never spawn red, so the
  // color signal stays consistent across instruction types
  const targetColors = COLORS.filter((c) => c !== "red");
  const targetColor = pick(targetColors);

  const targets = positions.map((pos, i) => {
    const isDecoy = i >= targetCount;
    const color = isDecoy ? pick(["red", "red", pick(COLORS)]) : type === "color" ? targetColor : pick(targetColors);
    return {
      id: i,
      x: pos.x,
      y: pos.y,
      color,
      isDecoy,
      seq: type === "order" && !isDecoy ? i + 1 : null,
      appearAtMs: offsets[i],
      lifetimeMs: lifetime + randomInt(-120, 120),
    };
  });

  // For order rounds, seq numbers must reflect visual order, not spawn id.
  if (type === "order") {
    const seqTargets = shuffle(targets.filter((t) => !t.isDecoy));
    seqTargets.forEach((t, i) => (t.seq = i + 1));
  }

  return {
    index,
    difficulty,
    type,
    targetColor,
    targets,
    expectedHits: targetCount,
  };
}

/** Human-facing instruction HTML for a round spec. */
export function instructionFor(spec) {
  const colorSpan = (c) => `<span class="hl-${c === "mint" ? "mint" : c === "gold" ? "gold" : c === "red" ? "red" : "violet"}">${c}</span>`;
  switch (spec.type) {
    case "tapAll":
      return `Tap every orb, <span class="hl-mint">fast!</span>`;
    case "color":
      return `Tap only the <b>${colorSpan(spec.targetColor)}</b> orbs. Avoid ${colorSpan("red")}`;
    case "order":
      return `Tap orbs <span class="hl-gold">in order</span>: 1, 2, 3…`;
    default:
      return "Tap the orbs";
  }
}

/**
 * Full session: baseline rounds, plus escalation rounds generated on demand.
 */
export function generateSession() {
  const roundCount = randomInt(2, 3);
  const rounds = [];
  for (let i = 0; i < roundCount; i++) {
    rounds.push(generateRound(i, i === 0 ? 0 : randomInt(0, 1)));
  }
  return { rounds, nextIndex: roundCount };
}

/** Add one harder escalation round to an existing session. */
export function escalationRound(session) {
  const spec = generateRound(session.nextIndex, 2);
  session.rounds.push(spec);
  session.nextIndex += 1;
  return spec;
}
