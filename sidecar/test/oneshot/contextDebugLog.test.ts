import { describe, expect, test } from "bun:test";
import {
  existsSync,
  mkdtempSync,
  readdirSync,
  readFileSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  CONTEXT_LOG_MAX_BYTES,
  clearContextUsageLog,
  createFileContextUsageLogWriter,
  formatContextUsageLogLine,
  logContextUsage,
} from "../../src/oneshot/contextDebugLog";
import type { EntityTerm } from "../../src/memory/MemoryStore";

/** Fresh temp dir per test, cleaned up by the caller via `rmSync`. Mirrors
 * the existing `createFileContextUsageLogWriter` test above, factored out
 * because every new describe block below needs its own real directory. */
function makeTempLogDir(): string {
  return mkdtempSync(join(tmpdir(), "opentype-context-log-"));
}

let nextTermId = 1;

function makeTerm(canonicalTerm: string): EntityTerm {
  return {
    id: nextTermId++,
    canonicalTerm,
    aliases: [],
    category: "project",
    confidence: 0.9,
    origin: "owner",
    sourceEventIds: [],
    createdAt: Date.now(),
    updatedAt: Date.now(),
    supersedes: null,
  };
}

describe("formatContextUsageLogLine", () => {
  test("includes timestamp, endpoint, input text, and matched term names when terms matched", () => {
    const line = formatContextUsageLogLine(
      {
        endpoint: "ask",
        inputText: "what is the status of Zephyrus?",
        matchedTerms: [makeTerm("Zephyrus")],
        ownerFactsCount: 0,
      },
      new Date("2026-08-09T00:00:00.000Z")
    );

    expect(line).toContain("2026-08-09T00:00:00.000Z");
    expect(line).toContain("[ask]");
    expect(line).toContain("what is the status of Zephyrus?");
    expect(line).toContain("1 known term(s): Zephyrus");
    expect(line.endsWith("\n")).toBe(true);
  });

  test("honestly reports 'no context matched' rather than fabricating a match", () => {
    const line = formatContextUsageLogLine({
      endpoint: "agent",
      inputText: "summarize my notes",
      matchedTerms: [],
      ownerFactsCount: 0,
    });

    expect(line).toContain("[agent]");
    expect(line).toContain("no context matched");
  });

  test("lists multiple matched terms in order", () => {
    const line = formatContextUsageLogLine({
      endpoint: "ask",
      inputText: "compare Zephyrus and Orion",
      matchedTerms: [makeTerm("Zephyrus"), makeTerm("Orion")],
      ownerFactsCount: 0,
    });

    expect(line).toContain("2 known term(s): Zephyrus, Orion");
  });

  test("truncates very long input text rather than logging it unbounded", () => {
    const longInput = "a".repeat(500);
    const line = formatContextUsageLogLine({
      endpoint: "ask",
      inputText: longInput,
      matchedTerms: [],
      ownerFactsCount: 0,
    });

    expect(line.length).toBeLessThan(longInput.length);
    expect(line).toContain("…");
  });

  test("reports the owner facts count when facts were included", () => {
    const line = formatContextUsageLogLine({
      endpoint: "ask",
      inputText: "what is my name?",
      matchedTerms: [],
      ownerFactsCount: 2,
    });

    expect(line).toContain("2 owner fact(s) included");
  });

  test("honestly reports 'no owner facts' rather than fabricating a count", () => {
    const line = formatContextUsageLogLine({
      endpoint: "ask",
      inputText: "what time is it?",
      matchedTerms: [],
      ownerFactsCount: 0,
    });

    expect(line).toContain("no owner facts");
  });
});

describe("logContextUsage", () => {
  test("passes the formatted line to the injected writer", () => {
    const written: string[] = [];
    logContextUsage(
      { endpoint: "ask", inputText: "hello", matchedTerms: [], ownerFactsCount: 0 },
      (line) => written.push(line)
    );

    expect(written).toHaveLength(1);
    expect(written[0]).toContain("[ask]");
    expect(written[0]).toContain("no context matched");
  });
});

describe("createFileContextUsageLogWriter", () => {
  test("appends to a real file, creating its parent directory if needed", () => {
    const dir = mkdtempSync(join(tmpdir(), "opentype-context-log-"));
    const path = join(dir, "nested", "context-debug.log");
    try {
      const writer = createFileContextUsageLogWriter(path);
      writer("first line\n");
      writer("second line\n");

      expect(existsSync(path)).toBe(true);
      const contents = readFileSync(path, "utf8");
      expect(contents).toBe("first line\nsecond line\n");
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});

// The gap this pins: `context-debug.log` carries the first ~200 chars of
// every ask/agent input (see the doc comment atop this module) and today has
// no governance at all -- created with the default umask (world-readable),
// so any other local account can read it. This is docs/superpowers/specs/
// 2026-08-09-current-system-state.md §11's "context-debug.log has no
// governance" gap, permissions half.
describe("createFileContextUsageLogWriter file permissions", () => {
  test("creates a brand-new log file at mode 0600", () => {
    const dir = makeTempLogDir();
    const path = join(dir, "context-debug.log");
    try {
      const writer = createFileContextUsageLogWriter(path);
      writer("first line\n");

      expect(statSync(path).mode & 0o777).toBe(0o600);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test("tightens an existing world-readable log file to 0600 rather than leaving it alone", () => {
    const dir = makeTempLogDir();
    const path = join(dir, "context-debug.log");
    try {
      // Simulates a log file created before this governance fix shipped --
      // world-readable, the default-umask outcome the gap description names.
      writeFileSync(path, "pre-existing line\n", { mode: 0o644 });
      expect(statSync(path).mode & 0o777).toBe(0o644); // precondition

      const writer = createFileContextUsageLogWriter(path);
      writer("new line\n");

      expect(statSync(path).mode & 0o777).toBe(0o600);
      // Tightening permissions must not be destructive: the pre-existing
      // line has to survive, with the new line appended after it.
      expect(readFileSync(path, "utf8")).toBe("pre-existing line\nnew line\n");
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});

// The gap this pins: rotation (the second governance half named in §11 --
// "it is not rotated"). Deliberately drives the file to `CONTEXT_LOG_MAX_BYTES`
// via a direct `writeFileSync`, not by looping the writer thousands of times,
// per the stage-1 brief ("read the file first and pick a test strategy that
// does not depend on the exact number the implementation chooses"). Any
// finite positive value of the constant makes these tests meaningful.
describe("createFileContextUsageLogWriter rotation", () => {
  test("does not rotate while the log is under the size cap", () => {
    const dir = makeTempLogDir();
    const path = join(dir, "context-debug.log");
    const rotatedPath = `${path}.1`;
    try {
      writeFileSync(path, "short\n");
      const writer = createFileContextUsageLogWriter(path);
      writer("appended\n");

      expect(readFileSync(path, "utf8")).toBe("short\nappended\n");
      expect(existsSync(rotatedPath)).toBe(false);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test("rotates the current file to <path>.1 and continues into a fresh file once the cap is reached", () => {
    const dir = makeTempLogDir();
    const path = join(dir, "context-debug.log");
    const rotatedPath = `${path}.1`;
    try {
      const oldContent = "x".repeat(CONTEXT_LOG_MAX_BYTES);
      writeFileSync(path, oldContent);

      const writer = createFileContextUsageLogWriter(path);
      writer("fresh line\n");

      // The whole prior file moved to .1 -- not appended-then-rotated, so it
      // must contain exactly the old content with nothing new mixed in.
      expect(readFileSync(rotatedPath, "utf8")).toBe(oldContent);
      // The active path is a fresh file: only the post-rotation line, not the
      // old content plus the new line.
      expect(readFileSync(path, "utf8")).toBe("fresh line\n");
      expect(statSync(path).mode & 0o777).toBe(0o600);
      expect(statSync(rotatedPath).mode & 0o777).toBe(0o600);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test("replaces a pre-existing .1 rather than accumulating it", () => {
    const dir = makeTempLogDir();
    const path = join(dir, "context-debug.log");
    const rotatedPath = `${path}.1`;
    try {
      writeFileSync(rotatedPath, "ancient generation, must not survive\n");
      const oldContent = "y".repeat(CONTEXT_LOG_MAX_BYTES);
      writeFileSync(path, oldContent);

      const writer = createFileContextUsageLogWriter(path);
      writer("newest line\n");

      const rotated = readFileSync(rotatedPath, "utf8");
      expect(rotated).toBe(oldContent);
      expect(rotated).not.toContain("ancient generation");
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test("keeps exactly one retained generation -- a second rotation replaces .1, never produces a .2", () => {
    const dir = makeTempLogDir();
    const path = join(dir, "context-debug.log");
    const rotatedPath = `${path}.1`;
    try {
      const writer = createFileContextUsageLogWriter(path);

      writeFileSync(path, "a".repeat(CONTEXT_LOG_MAX_BYTES));
      writer("gen2 marker\n"); // first rotation: .1 becomes the "a..." file

      writeFileSync(path, "b".repeat(CONTEXT_LOG_MAX_BYTES));
      writer("gen3 marker\n"); // second rotation: .1 must become the "b..." file, not a .2

      const files = readdirSync(dir);
      expect(files.some((name) => name.endsWith(".2"))).toBe(false);
      expect(readFileSync(rotatedPath, "utf8")).toBe("b".repeat(CONTEXT_LOG_MAX_BYTES));
      expect(readFileSync(path, "utf8")).toBe("gen3 marker\n");
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});

// The gap this pins: the third governance half named in §11 -- "reset input
// history" today does not clear this log at all. `clearContextUsageLog` is
// the primitive the new `DELETE /memory/context-log` route (tested in
// `test/memory/routes.test.ts`) is built on.
describe("clearContextUsageLog", () => {
  test("deletes both the log and its rotated generation", () => {
    const dir = makeTempLogDir();
    const path = join(dir, "context-debug.log");
    const rotatedPath = `${path}.1`;
    try {
      writeFileSync(path, "current\n");
      writeFileSync(rotatedPath, "rotated\n");

      clearContextUsageLog(path);

      expect(existsSync(path)).toBe(false);
      expect(existsSync(rotatedPath)).toBe(false);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test("is a no-op, not a throw, when neither file exists", () => {
    const dir = makeTempLogDir();
    const path = join(dir, "context-debug.log");
    try {
      expect(() => clearContextUsageLog(path)).not.toThrow();
      expect(existsSync(path)).toBe(false);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test("is a no-op, not a throw, when only the rotated generation exists", () => {
    const dir = makeTempLogDir();
    const path = join(dir, "context-debug.log");
    const rotatedPath = `${path}.1`;
    try {
      writeFileSync(rotatedPath, "rotated only\n");

      expect(() => clearContextUsageLog(path)).not.toThrow();
      expect(existsSync(rotatedPath)).toBe(false);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test("a writer used again after a clear recreates the file cleanly at mode 0600", () => {
    const dir = makeTempLogDir();
    const path = join(dir, "context-debug.log");
    try {
      const writer = createFileContextUsageLogWriter(path);
      writer("before clear\n");

      clearContextUsageLog(path);
      expect(existsSync(path)).toBe(false);

      writer("after clear\n");

      expect(readFileSync(path, "utf8")).toBe("after clear\n");
      expect(statSync(path).mode & 0o777).toBe(0o600);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  // Pins the specific hazard the stage-1 brief called out: rotation must be
  // checked against the real file on disk on every call (a `statSync`-class
  // syscall per append, per the design decision), never a byte counter
  // cached in the writer's closure. `clearContextUsageLog` -- and the
  // `DELETE /memory/context-log` route built on it -- can delete the file
  // out from under a writer that is still in scope, and a cached counter
  // would not know that happened.
  //
  // This drives the SAME writer instance close to the cap first (so a
  // cached-at-creation-time counter would have primed itself near
  // `CONTEXT_LOG_MAX_BYTES`), clears out from under it, then writes a small
  // line through that same instance. A per-call `statSync` implementation
  // sees the real (now nonexistent -> freshly tiny) file and does not
  // rotate. A cached-counter implementation would still think it is near
  // the cap and would spuriously rotate the tiny post-clear content into
  // `.1`, which this test would catch via the `existsSync(rotatedPath)`
  // assertion.
  test("does not spuriously rotate after an external clear, even once the same writer had grown close to the cap", () => {
    const dir = makeTempLogDir();
    const path = join(dir, "context-debug.log");
    const rotatedPath = `${path}.1`;
    try {
      const writer = createFileContextUsageLogWriter(path);
      writer("x".repeat(CONTEXT_LOG_MAX_BYTES));

      clearContextUsageLog(path);
      expect(existsSync(path)).toBe(false);

      writer("small line after external clear\n");

      expect(readFileSync(path, "utf8")).toBe("small line after external clear\n");
      expect(existsSync(rotatedPath)).toBe(false);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});
