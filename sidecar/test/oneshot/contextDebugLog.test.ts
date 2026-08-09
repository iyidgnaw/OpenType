import { describe, expect, test } from "bun:test";
import { existsSync, mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  createFileContextUsageLogWriter,
  formatContextUsageLogLine,
  logContextUsage,
} from "../../src/oneshot/contextDebugLog";
import type { EntityTerm } from "../../src/memory/MemoryStore";

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
    });

    expect(line).toContain("[agent]");
    expect(line).toContain("no context matched");
  });

  test("lists multiple matched terms in order", () => {
    const line = formatContextUsageLogLine({
      endpoint: "ask",
      inputText: "compare Zephyrus and Orion",
      matchedTerms: [makeTerm("Zephyrus"), makeTerm("Orion")],
    });

    expect(line).toContain("2 known term(s): Zephyrus, Orion");
  });

  test("truncates very long input text rather than logging it unbounded", () => {
    const longInput = "a".repeat(500);
    const line = formatContextUsageLogLine({
      endpoint: "ask",
      inputText: longInput,
      matchedTerms: [],
    });

    expect(line.length).toBeLessThan(longInput.length);
    expect(line).toContain("…");
  });
});

describe("logContextUsage", () => {
  test("passes the formatted line to the injected writer", () => {
    const written: string[] = [];
    logContextUsage(
      { endpoint: "ask", inputText: "hello", matchedTerms: [] },
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
