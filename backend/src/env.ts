// Loads backend/.env into process.env before anything else reads it.
// Must stay the FIRST import in index.ts — module-level env reads in other
// files (e.g. vision config) evaluate during import, before route bodies run.
// Node's built-in loader; existing env vars are never overridden.
import { join } from "path";

try {
  process.loadEnvFile(join(__dirname, "..", ".env"));
} catch {
  // no .env — local runs on defaults, production injects env directly
}
