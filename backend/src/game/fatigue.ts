// Squad fatigue on a ranked loss (docs/BATTLE-SYSTEM.md §5: "Loss: -RP, squad
// fatigued 2h. Recovery quest ... clears it."). Pure and clock-injected so it
// needs no timer mocking upstream -- the route owns `Date.now()`.

export const FATIGUE_MS = 2 * 60 * 60 * 1000; // 2h

/** ISO timestamp fatigue clears, starting from `now`. */
export function fatigueUntil(now: number): string {
  return new Date(now + FATIGUE_MS).toISOString();
}

/** Whether a stored fatigue expiry (if any) is still in effect at `now`. */
export function isFatigued(until: string | null | undefined, now: number): boolean {
  if (!until) return false;
  const parsed = Date.parse(until);
  return Number.isFinite(parsed) && parsed > now;
}
