/**
 * P1-7 (补), wiring half: the episodic-event seams must actually be connected
 * in the assembled app, not just exist.
 *
 * The whole reason P1-7 exists is that this repo grew a memory layer whose read
 * side had zero production callers — a seam nobody wired. `/asr/transcribe`'s
 * recorder is an OPTIONAL member of `AsrRouteDeps` (so pre-existing call sites
 * keep compiling), which means the route-level tests in
 * `test/asr/episodicEvent.test.ts` would pass just as happily if `buildApp`
 * forgot to pass it. This file closes that hole by driving the real assembled
 * router against a real `:memory:` store and asserting rows land, so "wired"
 * is a tested property rather than a hope.
 *
 * `/agent/run` is already wired (it takes the store directly and has recorded
 * events since the memory-v1 batch), so it is not re-covered here.
 */
import { describe, expect, test } from "bun:test";
import { join } from "node:path";
import { tmpdir } from "node:os";
import type { AgentChatFn } from "../../src/agent/loop";
import type { ToolSet } from "../../src/agent/toolSets";
import { openDatabase } from "../../src/memory/db";
import { MemoryStore } from "../../src/memory/MemoryStore";
import { ConversationStore } from "../../src/memory/conversations";
import { ProviderConfigStore } from "../../src/provider/configStore";
import { buildApp } from "../../src/server";

const emptyTools: ToolSet = {
  openAiTools: [],
  callTool: async (name) => {
    throw new Error(`Unknown tool: ${name}`);
  },
};

function assemble(answer: string, transcript: string) {
  const db = openDatabase(":memory:");
  const store = new MemoryStore(db);
  const conversations = new ConversationStore(db);
  const chat: AgentChatFn = async () => ({ content: answer });
  // A path that deliberately does not exist: ProviderConfigStore boots
  // unconfigured from an absent file, which is all this test needs.
  const providerConfigStore = new ProviderConfigStore(
    join(tmpdir(), `opentype-episodic-wiring-${crypto.randomUUID()}.json`)
  );
  const app = buildApp(
    store,
    conversations,
    chat,
    emptyTools,
    () => {},
    async () => answer,
    async () => transcript,
    providerConfigStore
  );
  return { app, store };
}

function events(store: MemoryStore): Array<Record<string, unknown>> {
  return store.db
    .query("SELECT * FROM episodic_events ORDER BY id ASC")
    .all() as Array<Record<string, unknown>>;
}

describe("buildApp wires episodic recording into every mode", () => {
  test("a transcription through the assembled app lands an episodic event", async () => {
    const { app, store } = assemble("unused", "帮我记一下这段话");

    const response = await app(
      new Request("http://sidecar/asr/transcribe", {
        method: "POST",
        body: JSON.stringify({ audioBase64: "aGk=" }),
      })
    );

    expect(response.status).toBe(200);
    const rows = events(store);
    expect(rows).toHaveLength(1);
    expect(rows[0]!.mode).toBe("transcribe");
    expect(rows[0]!.correctedTranscript).toBe("帮我记一下这段话");
  });

  test("an answered question through the assembled app lands an episodic event", async () => {
    const { app, store } = assemble("Four.", "unused");

    const response = await app(
      new Request("http://sidecar/oneshot/ask", {
        method: "POST",
        body: JSON.stringify({ question: "what is 2+2" }),
      })
    );

    expect(response.status).toBe(200);
    const rows = events(store);
    expect(rows).toHaveLength(1);
    expect(rows[0]!.mode).toBe("ask");
    expect(rows[0]!.result).toBe("Four.");
  });

  test("both modes feed the same consolidation gate", async () => {
    const { app, store } = assemble("Four.", "一段听写");

    // Three dictations and two questions: five unconsolidated events, none of
    // which came from `/agent/run`. Before P1-7 this count would be zero.
    for (let i = 0; i < 3; i++) {
      await app(
        new Request("http://sidecar/asr/transcribe", {
          method: "POST",
          body: JSON.stringify({ audioBase64: "aGk=" }),
        })
      );
    }
    for (let i = 0; i < 2; i++) {
      await app(
        new Request("http://sidecar/oneshot/ask", {
          method: "POST",
          body: JSON.stringify({ question: `question ${i}` }),
        })
      );
    }

    expect(store.unconsolidatedEventCount()).toBe(5);
  });
});
