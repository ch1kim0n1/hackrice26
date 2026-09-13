// CSPRNG helpers — all challenge randomness flows through here.
// crypto.getRandomValues, never Math.random.

const buf = new Uint32Array(1);

function randomU32() {
  crypto.getRandomValues(buf);
  return buf[0];
}

/** Uniform int in [min, max] inclusive, with modulo-bias rejection. */
export function randomInt(min, max) {
  const range = max - min + 1;
  const limit = Math.floor(0x100000000 / range) * range;
  let v;
  do {
    v = randomU32();
  } while (v >= limit);
  return min + (v % range);
}

/** Uniform float in [min, max). */
export function randomFloat(min, max) {
  return min + (randomU32() / 0x100000000) * (max - min);
}

export function pick(arr) {
  return arr[randomInt(0, arr.length - 1)];
}

/** Fisher–Yates with CSPRNG. Returns new array. */
export function shuffle(arr) {
  const a = arr.slice();
  for (let i = a.length - 1; i > 0; i--) {
    const j = randomInt(0, i);
    [a[i], a[j]] = [a[j], a[i]];
  }
  return a;
}

/** Random session id, e.g. "pg_4f2a9c1e7b3d". */
export function randomId(prefix = "pg") {
  const bytes = new Uint8Array(8);
  crypto.getRandomValues(bytes);
  const hex = [...bytes].map((b) => b.toString(16).padStart(2, "0")).join("");
  return `${prefix}_${hex}`;
}
