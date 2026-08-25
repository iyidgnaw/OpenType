/**
 * `opentype__read_history` (Task 11,
 * docs/superpowers/plans/2026-08-25-unified-memory-and-recent-context.md,
 * spec §3.6) is how the Agent expands one of the clipped entries the
 * "Recent activity" block (`buildRecentActivityContext`,
 * `src/memory/recentActivity.ts`) injects into its own context: the block
 * clips every field to `RECENT_ACTIVITY_FIELD_MAX` (120) characters and
 * shows only an `eventId` / `conversationId`, this tool is the other half
 * that turns that id back into the full record. Ask has no such tool — it
 * is one-turn Q&A with nothing to expand — and must never see it.
 *
 * ## The contract stage 3 must implement
 *
 * `src/agent/readHistoryTool.ts` exports:
 * - `READ_HISTORY_TOOL_NAME = "opentype__read_history"`
 * - `READ_HISTORY_TOOL_SCHEMA`, an OpenAI-function-shaped tool descriptor
 *   whose `function.parameters.properties` has exactly the keys `eventId`,
 *   `conversationId`, `limit` (none `required`) — chosen to be exactly the
 *   id keys `buildRecentActivityContext` emits, so the model can copy a
 *   context id straight into a tool call with no translation (see that
 *   file's doc comment).
 * - `handleReadHistory(args: { eventId?: number; conversationId?: number; limit?: number },
 *    deps: { store?: MemoryStore; conversations?: ConversationStore }): Promise<string>`
 *   — plain text, UNTRUNCATED (unlike the injected block). `store`/
 *   `conversations` are OPTIONAL on the deps object, matching
 *   `CoreToolsDeps`'s existing all-optional pattern: the tool is always
 *   listed in `openAiTools` regardless of whether memory is wired up, and
 *   when either dependency is absent the handler returns a readable
 *   explanation string rather than throwing.
 *
 *   Branches, in priority order:
 *     1. `eventId` given (wins if `conversationId` is also given) -> that
 *        one event's full record (raw text, source app). A transcribe row
 *        has no `result` by design; its full text and app are exactly
 *        what's worth expanding.
 *     2. Else `conversationId` given -> that thread's messages, in order,
 *        both roles. A conversation that exists but has no messages yet
 *        (reachable: `ConversationStore.createConversation` does not
 *        itself insert one) returns an explicit "no messages yet" string,
 *        not `""` -- an empty string is indistinguishable from a broken
 *        tool.
 *     3. Else the most recent `limit` events, untruncated. `limit`
 *        defaults to `RECENT_ACTIVITY_LIMIT` (the same constant
 *        `recentActivity.ts` uses for its own injected count) whenever it
 *        is not a positive integer (covers omitted, 0, negative, and
 *        non-integer), and is clamped to a ceiling of 50 otherwise. This
 *        clamp is a real guardrail, not pedantry: SQLite treats `LIMIT -1`
 *        as "no limit", so an unclamped negative `limit` would read the
 *        user's *entire* episodic-event history -- every dictation ever
 *        made -- back into the agent's context in one call.
 *   An id that matches nothing returns a readable "no such entry" string
 *   mentioning the id — it must NOT throw. A thrown tool error turns a
 *   cheap probe into a failed step the model has to recover from; a plain
 *   sentence lets it just move on.
 *
 * `coreTools.ts` registers `READ_HISTORY_TOOL_SCHEMA` in `openAiTools` and
 * wires `READ_HISTORY_TOOL_NAME -> handleReadHistory` into its handler map
 * (wrapping the plain-string return as `{ content: ... }` like every other
 * core tool). No exclusion logic is added for Ask: `ASK_TOOL_NAMES`
 * (`src/oneshot/routes.ts`, exported for this test) is an allowlist of
 * exactly `["opentype__web_search", "opentype__web_fetch"]` fed through
 * `filterToolSet`, so a tool that is simply never added to that list is
 * absent from Ask's set for free.
 */
import { describe, expect, test } from "bun:test";
import { openDatabase } from "../../src/memory/db";
import {
  MemoryStore,
  type RecordEpisodicEventInput,
} from "../../src/memory/MemoryStore";
import { ConversationStore } from "../../src/memory/conversations";
import {
  buildRecentActivityContext,
  RECENT_ACTIVITY_LIMIT,
} from "../../src/memory/recentActivity";
import { createCoreTools } from "../../src/agent/coreTools";
import { filterToolSet } from "../../src/agent/toolSets";
import { ASK_TOOL_NAMES } from "../../src/oneshot/routes";
import {
  handleReadHistory,
  READ_HISTORY_TOOL_NAME,
} from "../../src/agent/readHistoryTool";

function makeStore(): MemoryStore {
  return new MemoryStore(openDatabase(":memory:"));
}

function makeConversations(): ConversationStore {
  return new ConversationStore(openDatabase(":memory:"));
}

function base(patch: Partial<RecordEpisodicEventInput>): RecordEpisodicEventInput {
  return {
    mode: "transcribe",
    rawTranscript: "raw",
    correctedTranscript: "corrected",
    effectiveInput: "corrected",
    selectedContext: null,
    result: null,
    applicationName: "TestApp",
    ...patch,
  };
}

function toolNames(openAiTools: unknown[]): string[] {
  return (openAiTools as Array<{ function: { name: string } }>).map(
    (t) => t.function.name
  );
}

/** `>120` chars: proves the tool returns untruncated text, unlike the
 * injected block's `RECENT_ACTIVITY_FIELD_MAX`-clipped fields. */
function markerFor(i: number): string {
  return `EVENT_MARKER_${i}_` + "字".repeat(150);
}

/** How many of `0..total-1` distinct markers actually appear in `out`. */
function countPresentMarkers(out: string, total: number): number {
  let count = 0;
  for (let i = 0; i < total; i++) {
    if (out.includes(markerFor(i))) count++;
  }
  return count;
}

describe("handleReadHistory: eventId branch", () => {
  test("returns that turn's untruncated full text and source app", async () => {
    const store = makeStore();
    const conversations = makeConversations();
    const long = "字".repeat(500); // well over the 120-char injected-block clip
    const id = store.recordEpisodicEvent(
      base({ mode: "transcribe", correctedTranscript: long, applicationName: "WeChat" })
    );

    const out = await handleReadHistory({ eventId: id }, { store, conversations });

    expect(out).toContain(long);
    expect(out).toContain("WeChat");
  });

  test("nonexistent eventId returns a readable explanation mentioning the id, not a thrown error", async () => {
    const store = makeStore();
    const conversations = makeConversations();

    let out: string | undefined;
    let threw = false;
    try {
      out = await handleReadHistory({ eventId: 99999 }, { store, conversations });
    } catch {
      threw = true;
    }

    expect(threw).toBe(false);
    expect(out).toContain("99999");
  });

  test("when both eventId and conversationId are given, eventId wins", async () => {
    const store = makeStore();
    const conversations = makeConversations();
    const id = store.recordEpisodicEvent(
      base({ correctedTranscript: "EVENT_TEXT_MARKER", applicationName: "EventApp" })
    );
    const convId = conversations.createConversation("ask", "convo seed");
    conversations.appendMessage(convId, "user", "CONVO_TEXT_MARKER");

    const out = await handleReadHistory(
      { eventId: id, conversationId: convId },
      { store, conversations }
    );

    expect(out).toContain("EVENT_TEXT_MARKER");
    expect(out).not.toContain("CONVO_TEXT_MARKER");
  });
});

describe("handleReadHistory: conversationId branch", () => {
  test("returns the thread's full message sequence, in order, both roles", async () => {
    const store = makeStore();
    const conversations = makeConversations();
    const convId = conversations.createConversation("ask", "天气");
    conversations.appendMessage(convId, "user", "明天那边天气怎么样");
    conversations.appendMessage(convId, "assistant", "多云转晴");

    const out = await handleReadHistory({ conversationId: convId }, { store, conversations });

    expect(out).toContain("明天那边天气怎么样");
    expect(out).toContain("多云转晴");
    // Order matters: the user's question must read before the answer.
    expect(out.indexOf("明天那边天气怎么样")).toBeLessThan(out.indexOf("多云转晴"));
  });

  test("nonexistent conversationId returns a readable explanation mentioning the id, not a thrown error", async () => {
    const store = makeStore();
    const conversations = makeConversations();

    let out: string | undefined;
    let threw = false;
    try {
      out = await handleReadHistory({ conversationId: 424242 }, { store, conversations });
    } catch {
      threw = true;
    }

    expect(threw).toBe(false);
    expect(out).toContain("424242");
  });

  test("a conversation that exists but has no messages yet returns an explicit explanation, not an empty string", async () => {
    const store = makeStore();
    const conversations = makeConversations();
    const convId = conversations.createConversation("ask", "empty thread");
    // Deliberately no appendMessage call: createConversation alone leaves a
    // real, id-bearing conversation with zero messages -- a reachable state
    // per ConversationStore's own contract.

    const out = await handleReadHistory({ conversationId: convId }, { store, conversations });

    expect(out.length).toBeGreaterThan(0);
    expect(out.toLowerCase()).toContain("no messages");
  });
});

describe("handleReadHistory: neither id given", () => {
  test("defaults to the RECENT_ACTIVITY_LIMIT most recent turns, untruncated", async () => {
    const store = makeStore();
    const conversations = makeConversations();
    const total = RECENT_ACTIVITY_LIMIT + 5;
    for (let i = 0; i < total; i++) {
      store.recordEpisodicEvent(base({ correctedTranscript: markerFor(i) }));
    }

    const out = await handleReadHistory({}, { store, conversations });

    // The oldest 5 fall outside the default window.
    for (let i = 0; i < 5; i++) {
      expect(out).not.toContain(markerFor(i));
    }
    // The most recent RECENT_ACTIVITY_LIMIT are present, in full (untruncated).
    for (let i = 5; i < total; i++) {
      expect(out).toContain(markerFor(i));
    }
    expect(countPresentMarkers(out, total)).toBe(RECENT_ACTIVITY_LIMIT);
  });

  test("an explicit in-range limit overrides the default", async () => {
    const store = makeStore();
    const conversations = makeConversations();
    for (let i = 0; i < 8; i++) {
      store.recordEpisodicEvent(base({ correctedTranscript: markerFor(i) }));
    }

    const out = await handleReadHistory({ limit: 3 }, { store, conversations });

    for (let i = 0; i < 5; i++) {
      expect(out).not.toContain(markerFor(i));
    }
    for (let i = 5; i < 8; i++) {
      expect(out).toContain(markerFor(i));
    }
    expect(countPresentMarkers(out, 8)).toBe(3);
  });

  describe("limit clamping (the SQLite `LIMIT -1` = unbounded hazard)", () => {
    /**
     * Well past both the default (RECENT_ACTIVITY_LIMIT) and the ceiling
     * (50), so a test can tell "clamped to default", "clamped to 50", and
     * "unclamped, returned everything" apart by count alone.
     */
    const total = 60;

    async function withEvents(): Promise<{ store: MemoryStore; conversations: ConversationStore }> {
      const store = makeStore();
      const conversations = makeConversations();
      for (let i = 0; i < total; i++) {
        store.recordEpisodicEvent(base({ correctedTranscript: markerFor(i) }));
      }
      return { store, conversations };
    }

    test("limit: -1 falls back to the default, not SQLite's 'unbounded'", async () => {
      const { store, conversations } = await withEvents();

      const out = await handleReadHistory({ limit: -1 }, { store, conversations });

      expect(countPresentMarkers(out, total)).toBe(RECENT_ACTIVITY_LIMIT);
    });

    test("limit: 0 falls back to the default", async () => {
      const { store, conversations } = await withEvents();

      const out = await handleReadHistory({ limit: 0 }, { store, conversations });

      expect(countPresentMarkers(out, total)).toBe(RECENT_ACTIVITY_LIMIT);
    });

    test("limit: 1.5 (non-integer) falls back to the default", async () => {
      const { store, conversations } = await withEvents();

      const out = await handleReadHistory({ limit: 1.5 }, { store, conversations });

      expect(countPresentMarkers(out, total)).toBe(RECENT_ACTIVITY_LIMIT);
    });

    test("limit: 10000 clamps to the ceiling of 50, not the whole table", async () => {
      const { store, conversations } = await withEvents();

      const out = await handleReadHistory({ limit: 10000 }, { store, conversations });

      expect(countPresentMarkers(out, total)).toBe(50);
    });
  });
});

describe("handleReadHistory with no memory wired", () => {
  test("store/conversations both absent returns a readable explanation, not a throw", async () => {
    let out: string | undefined;
    let threw = false;
    try {
      out = await handleReadHistory({}, {});
    } catch {
      threw = true;
    }

    expect(threw).toBe(false);
    expect(out).toBeTruthy();
    expect(typeof out).toBe("string");
  });
});

describe("opentype__read_history is absent from Ask's toolset", () => {
  test("present in the full core tool set, filtered out by Ask's real web-only allowlist", () => {
    const core = createCoreTools({});
    // First prove it's actually there to begin with -- otherwise "absent
    // after filtering" would be true for the wrong reason (never added).
    expect(toolNames(core.openAiTools)).toContain(READ_HISTORY_TOOL_NAME);

    // ASK_TOOL_NAMES is imported from the real oneshot route, not a
    // hand-copied allowlist: if someone later adds read_history to the
    // actual list, this test goes red instead of staying falsely green.
    const askTools = filterToolSet(core, ASK_TOOL_NAMES);

    expect(toolNames(askTools.openAiTools)).not.toContain(READ_HISTORY_TOOL_NAME);
  });

  test("calling it through Ask's filtered set throws Unknown tool, same as any never-added name", async () => {
    const core = createCoreTools({});
    const askTools = filterToolSet(core, ASK_TOOL_NAMES);

    await expect(askTools.callTool(READ_HISTORY_TOOL_NAME, {})).rejects.toThrow();
  });

  test("createCoreTools({}) with no memory wired still lists and calls it without throwing", async () => {
    const core = createCoreTools({});

    let result: { content: string } | undefined;
    let threw = false;
    try {
      result = await core.callTool(READ_HISTORY_TOOL_NAME, {});
    } catch {
      threw = true;
    }

    expect(threw).toBe(false);
    expect(typeof result?.content).toBe("string");
    expect(result?.content.length ?? 0).toBeGreaterThan(0);
  });
});

describe("opentype__read_history's declared schema", () => {
  function schemaFor(openAiTools: unknown[]): {
    function: { parameters: { properties: Record<string, unknown>; required?: string[] } };
  } {
    const tool = (
      openAiTools as Array<{ function: { name: string; parameters: unknown } }>
    ).find((t) => t.function.name === READ_HISTORY_TOOL_NAME);
    expect(tool).toBeTruthy();
    return tool as never;
  }

  test("exposes exactly eventId, conversationId, limit as parameters, none required", () => {
    const core = createCoreTools({});
    const schema = schemaFor(core.openAiTools);

    expect(Object.keys(schema.function.parameters.properties).sort()).toEqual(
      ["conversationId", "eventId", "limit"].sort()
    );
    expect(schema.function.parameters.required ?? []).toEqual([]);
  });

  test("eventId/conversationId param names match the keys buildRecentActivityContext emits", async () => {
    const store = makeStore();
    const id = store.recordEpisodicEvent(
      base({ mode: "ask", correctedTranscript: "天气怎么样", result: "多云转晴", conversationId: 17 })
    );
    const [row] = store.recentEvents(1);
    expect(row!.id).toBe(id);

    const rendered = buildRecentActivityContext([row!], { includeIds: true });
    const entryLine = rendered.trim().split("\n")[1]!;
    const entry = JSON.parse(entryLine) as Record<string, unknown>;

    // The whole point of the JSONL rendering (see recentActivity.ts's doc
    // comment): these keys must map straight onto tool argument names with
    // no translation step.
    expect(entry).toHaveProperty("eventId");
    expect(entry).toHaveProperty("conversationId");

    const core = createCoreTools({});
    const schema = schemaFor(core.openAiTools);
    const paramNames = Object.keys(schema.function.parameters.properties);
    expect(paramNames).toContain("eventId");
    expect(paramNames).toContain("conversationId");
  });
});
