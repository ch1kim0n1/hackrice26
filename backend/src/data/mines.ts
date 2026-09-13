// Kitchen Mines configuration. Every tunable the game reads lives here, so the
// board can be rebalanced without touching the round logic in
// services/minesEngine.ts.

/** 5x5 board. */
export const BOARD_ROWS = 5;
export const BOARD_COLUMNS = 5;
export const TILE_COUNT = BOARD_ROWS * BOARD_COLUMNS;

/**
 * Mines the player may hide. At least one, and at least one safe dish must
 * remain -- 25 mines would be a board with no game in it.
 */
export const MIN_MINES = 1;
export const MAX_MINES = TILE_COUNT - 1;

/** Shortcut buttons the UI offers. Every value in 1..24 stays selectable. */
export const MINE_PRESETS = [1, 3, 5, 10, 15, 20, 24];

/**
 * The same edge Cauldron Crash runs at. Imported rather than redeclared so the
 * casino cannot end up with two house edges.
 */
export { HOUSE_EDGE } from "./cauldron";

/** Exactly one monster per round (spec: Wager). */
export const WAGER_MONSTERS = 1;

/**
 * Kitchen heat, by displayed multiplier only.
 *
 * Never by mine count, never by how close the next pick is to a mine. A player
 * who could read the danger off the lighting would be playing a different game
 * than the one the odds describe.
 */
export const HEAT_THRESHOLDS: { id: string; from: number }[] = [
  { id: "calm", from: 1 },
  { id: "warm", from: 2 },
  { id: "hot", from: 4 },
  { id: "searing", from: 8 }
];

/** Rounds older than this are abandoned and settled as lost. */
export const MAX_ROUND_AGE_MS = 6 * 60 * 60 * 1000;
