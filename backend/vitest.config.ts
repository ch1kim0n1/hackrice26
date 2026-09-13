import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    // Only run the TypeScript sources — `npm run build` also emits compiled
    // copies into dist/ that vitest must not pick up.
    include: ["src/**/*.test.ts"],
    // Several suites open the same on-disk sqlite file in WAL mode; parallel
    // test files raced and failed with "database is locked". Serial files are
    // ~1.5s slower and deterministic.
    fileParallelism: false
  }
});
