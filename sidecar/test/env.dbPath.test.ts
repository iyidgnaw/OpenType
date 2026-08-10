/**
 * STAGE-1 (red) test pinning P2: the default `dbPath` must be an absolute
 * path anchored under the sidecar source directory (via `import.meta.dir`),
 * NOT a cwd-relative "sidecar/.data/opentype.sqlite3". The relative default
 * silently produces two different SQLite DBs depending on the process cwd
 * (e.g. run from repo root vs. from `sidecar/`), splitting the user's memory
 * store in half.
 *
 * Desired fix: `loadEnv({}).dbPath` resolves to a stable absolute path
 * anchored to the sidecar module directory, independent of process.cwd().
 *
 * NOTE: this intentionally conflicts with the existing assertion in
 * `test/env.test.ts` (line ~11) that pins the OLD relative default
 * `"sidecar/.data/opentype.sqlite3"`. That existing assertion encodes the bug
 * and must be updated by the implement stage when this fix lands.
 */
import { describe, expect, test } from "bun:test";
import { isAbsolute, resolve } from "node:path";
import { loadEnv } from "../src/env";

// The sidecar root, computed from this test file's own location
// (test/ -> sidecar/). The default dbPath, once anchored, should live under
// this directory regardless of process.cwd().
const SIDECAR_DIR = resolve(import.meta.dir, "..");

describe("loadEnv default dbPath (P2 cwd-relative DB path)", () => {
  test("resolves to an absolute path, not a cwd-relative one", () => {
    const env = loadEnv({});
    expect(isAbsolute(env.dbPath)).toBe(true);
  });

  test("is anchored under the sidecar source directory", () => {
    const env = loadEnv({});
    expect(env.dbPath.startsWith(SIDECAR_DIR)).toBe(true);
    expect(env.dbPath.endsWith("opentype.sqlite3")).toBe(true);
  });

  test("is stable regardless of process.cwd()", () => {
    const originalCwd = process.cwd();
    try {
      process.chdir("/tmp");
      const fromTmp = loadEnv({}).dbPath;
      process.chdir(SIDECAR_DIR);
      const fromSidecar = loadEnv({}).dbPath;
      expect(fromTmp).toBe(fromSidecar);
      expect(isAbsolute(fromTmp)).toBe(true);
    } finally {
      process.chdir(originalCwd);
    }
  });

  test("still honors an explicit OPENTYPE_SIDECAR_DB_PATH override", () => {
    const env = loadEnv({ OPENTYPE_SIDECAR_DB_PATH: "/custom/db.sqlite3" });
    expect(env.dbPath).toBe("/custom/db.sqlite3");
  });
});
