import { describe, expect, test } from "bun:test";
import {
  buildRecentActivityContext,
  RECENT_ACTIVITY_EXCLUDED_MODES,
  RECENT_ACTIVITY_FIELD_MAX,
  RECENT_ACTIVITY_LIMIT,
} from "../../src/memory/recentActivity";
import type { EpisodicEventRow } from "../../src/memory/MemoryStore";

/**
 * The rendered text of `buildRecentActivityContext` is injected verbatim
 * into the model's user message, and its key names deliberately match the
 * parameter names of the `opentype__read_history` tool so the model can
 * copy an id straight from context into a tool call with no translation
 * (spec §3.5). These tests assert on PARSED objects wherever the point is
 * "is this field present/absent/correctly named", not on substrings of the
 * rendered text -- a substring match would pass malformed JSON.
 */

function row(patch: Partial<EpisodicEventRow>): EpisodicEventRow {
  return {
    id: 1,
    createdAt: 1,
    mode: "ask",
    rawTranscript: "r",
    correctedTranscript: "c",
    effectiveInput: null,
    selectedContext: null,
    result: null,
    applicationName: "App",
    origin: "owner",
    conversationId: null,
    consolidatedAt: null,
    ...patch,
  };
}

/**
 * Splits the header off and parses every remaining line as one standalone
 * JSON object. Asserts the header is actually there rather than blindly
 * discarding line 0 -- an implementation that stopped emitting a header
 * entirely would shift a real entry into that slot, and `JSON.parse(header)`
 * not throwing (or too few lines) is what catches that instead of this
 * helper silently swallowing it.
 */
function parseLines(out: string): unknown[] {
  const lines = out.trim().split("\n");
  const [header, ...entries] = lines;
  expect(header).toBeTruthy();
  expect(() => JSON.parse(header)).toThrow();
  return entries.map((line) => JSON.parse(line));
}

describe("buildRecentActivityContext", () => {
  test("renders one JSON object per line, keyed exactly like opentype__read_history's params", () => {
    const out = buildRecentActivityContext(
      [
        row({
          id: 43,
          mode: "ask",
          correctedTranscript: "天气怎么样",
          result: "多云转晴",
          conversationId: 17,
          applicationName: "Safari",
        }),
      ],
      { includeIds: true }
    );

    const lines = out.trim().split("\n");
    expect(lines).toHaveLength(2); // header + one entry
    expect(lines[0]).toContain("opentype__read_history");

    // The entry line itself must be nothing but a single valid JSON object --
    // no trailing junk, no multiple objects smashed onto one line.
    expect(() => JSON.parse(lines[1])).not.toThrow();
    expect(JSON.parse(lines[1])).toEqual({
      eventId: 43,
      mode: "ask",
      app: "Safari",
      conversationId: 17,
      input: "天气怎么样",
      result: "多云转晴",
    });
  });

  test("keys with no value are omitted entirely, never written as null", () => {
    // Confirmed independently: JSON.stringify on an object that has
    // `entry.result = undefined` explicitly assigned already drops that
    // key from the rendered text (`JSON.stringify({a:1,b:undefined})` ===
    // `'{"a":1}'`), so a round trip through JSON.parse can't distinguish
    // "key never set" from "key set to undefined" -- both come back with
    // the key simply missing. The bug this guards against is a DIFFERENT
    // naive shape: writing an explicit `result: null` instead of omitting
    // the key, which *does* survive the string round trip as `"result":null`.
    // `"result" in obj` catches that; `toBeUndefined()` would too by luck
    // (an absent key reads as undefined via property access) but doesn't
    // pin the actual invariant -- "the key is absent from the object" --
    // as directly.
    const out = buildRecentActivityContext(
      [
        row({
          id: 42,
          mode: "transcribe",
          correctedTranscript: "明天开会",
          result: null,
          conversationId: null,
          applicationName: "WeChat",
        }),
      ],
      { includeIds: true }
    );

    const obj = JSON.parse(out.trim().split("\n")[1]) as Record<string, unknown>;
    expect(obj).toEqual({ eventId: 42, mode: "transcribe", app: "WeChat", input: "明天开会" });
    expect("result" in obj).toBe(false);
    expect("conversationId" in obj).toBe(false);
  });

  test("a whitespace-only result is omitted, not emitted as an empty string", () => {
    // Guards `r.result != null && r.result.trim() !== ""` specifically --
    // a regression to a bare `result != null` check would let `"   "`
    // through and render `"result":""`, which passes a plain null check
    // but is exactly the kind of empty-but-present junk the omission rule
    // exists to avoid.
    const out = buildRecentActivityContext(
      [row({ id: 1, mode: "transcribe", correctedTranscript: "明天开会", result: "   ", applicationName: "WeChat" })],
      { includeIds: true }
    );

    const obj = JSON.parse(out.trim().split("\n")[1]) as Record<string, unknown>;
    expect("result" in obj).toBe(false);
  });

  test("includeIds: false omits both ids and the read_history mention -- ask has no such tool", () => {
    // Digit-bearing fixture on purpose: real dictation is full of digits
    // (times, counts, prices, phone numbers), so proving "no id keys" on a
    // digit-free fixture would hold by accident. Proving it via key absence
    // -- not "no digit appears anywhere" -- is the real invariant, since a
    // correct implementation must still pass a row like this one through.
    const out = buildRecentActivityContext(
      [
        row({
          id: 43,
          mode: "ask",
          correctedTranscript: "明天下午3点开会",
          result: "好的，3点提醒你",
          conversationId: 17,
          applicationName: "App",
        }),
      ],
      { includeIds: false }
    );

    const obj = JSON.parse(out.trim().split("\n")[1]) as Record<string, unknown>;
    expect(obj).toEqual({ mode: "ask", app: "App", input: "明天下午3点开会", result: "好的，3点提醒你" });
    expect("eventId" in obj).toBe(false);
    expect("conversationId" in obj).toBe(false);

    // No mention of the tool the model can't call from this surface.
    expect(out).not.toContain("opentype__read_history");
  });

  test("truncates input/result at RECENT_ACTIVITY_FIELD_MAX with a trailing ellipsis", () => {
    expect(RECENT_ACTIVITY_FIELD_MAX).toBe(120);
    const long = "字".repeat(200);
    const longApp = "A".repeat(200);
    const out = buildRecentActivityContext(
      [row({ correctedTranscript: long, result: long, applicationName: longApp })],
      { includeIds: true }
    );

    const obj = JSON.parse(out.trim().split("\n")[1]) as { input: string; result: string; app: string };
    expect(obj.input).toHaveLength(RECENT_ACTIVITY_FIELD_MAX + 1); // 120 + "…"
    expect(obj.input.endsWith("…")).toBe(true);
    expect(obj.input.slice(0, RECENT_ACTIVITY_FIELD_MAX)).toBe(long.slice(0, RECENT_ACTIVITY_FIELD_MAX));

    expect(obj.result).toHaveLength(RECENT_ACTIVITY_FIELD_MAX + 1);
    expect(obj.result.endsWith("…")).toBe(true);

    // `clip()` must be scoped to input/result only -- app is not a field
    // the truncation rule mentions, and it stays untouched at any length.
    expect(obj.app).toBe(longApp);
  });

  test("does not truncate a field that is exactly at the limit", () => {
    const exact = "字".repeat(RECENT_ACTIVITY_FIELD_MAX);
    const out = buildRecentActivityContext([row({ correctedTranscript: exact })], {
      includeIds: true,
    });
    const obj = JSON.parse(out.trim().split("\n")[1]) as { input: string };
    expect(obj.input).toBe(exact);
    expect(obj.input.endsWith("…")).toBe(false);
  });

  test("collapses embedded whitespace/newlines so one row stays one JSONL line", () => {
    const out = buildRecentActivityContext(
      [
        row({
          id: 1,
          correctedTranscript: "第一行\n第二行\n\n  第三行  ",
          result: "结果第一行\n结果第二行",
        }),
      ],
      { includeIds: true }
    );

    const lines = out.trim().split("\n");
    // header + exactly one entry line -- the embedded newlines must not have
    // split the row across multiple lines and broken the JSONL contract.
    expect(lines).toHaveLength(2);

    const obj = JSON.parse(lines[1]) as { input: string; result: string };
    expect(obj.input).toBe("第一行 第二行 第三行");
    expect(obj.result).toBe("结果第一行 结果第二行");
    expect(obj.input).not.toContain("\n");
    expect(obj.result).not.toContain("\n");
  });

  test("an empty row list renders the empty string, not a lone header", () => {
    expect(buildRecentActivityContext([], { includeIds: true })).toBe("");
    expect(buildRecentActivityContext([], { includeIds: false })).toBe("");
  });

  test("preserves the caller's row order (oldest first)", () => {
    const out = buildRecentActivityContext(
      [
        row({ id: 1, correctedTranscript: "一" }),
        row({ id: 2, correctedTranscript: "二" }),
        row({ id: 3, correctedTranscript: "三" }),
      ],
      { includeIds: true }
    );

    const objs = parseLines(out) as { eventId: number; input: string }[];
    expect(objs.map((o) => o.input)).toEqual(["一", "二", "三"]);
    expect(objs.map((o) => o.eventId)).toEqual([1, 2, 3]);
  });

  test("every non-header line is independently valid JSON across multiple rows", () => {
    const out = buildRecentActivityContext(
      [
        row({ id: 1, mode: "transcribe", correctedTranscript: "听写", result: null, applicationName: "WeChat" }),
        row({ id: 2, mode: "ask", correctedTranscript: "问题", result: "答案", conversationId: 5, applicationName: "Safari" }),
        row({ id: 3, mode: "agent", correctedTranscript: "任务", result: "完成", conversationId: 6, applicationName: "Terminal" }),
      ],
      { includeIds: true }
    );

    const lines = out.trim().split("\n");
    expect(lines).toHaveLength(4); // header + 3 entries
    for (const line of lines.slice(1)) {
      expect(() => JSON.parse(line)).not.toThrow();
    }
  });
});

describe("RECENT_ACTIVITY_LIMIT", () => {
  test("is 10", () => {
    expect(RECENT_ACTIVITY_LIMIT).toBe(10);
  });
});

describe("RECENT_ACTIVITY_EXCLUDED_MODES", () => {
  test("is empty -- all three modes feed the context, no opt-out (product decision, spec §3.5/§六)", () => {
    expect(RECENT_ACTIVITY_EXCLUDED_MODES).toEqual([]);
  });
});
