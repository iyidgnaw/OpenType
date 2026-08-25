/**
 * P1-7 (补), wiring half -- INVERTED for plan Task 3 (design §3.2).
 *
 * ## What this file used to pin
 *
 * Before Task 3, `/asr/transcribe`, `/oneshot/ask` and `/agent/run` were each
 * their own writer of `episodic_events`, and this file drove the real
 * assembled router (via `buildApp`) against a real `:memory:` store to prove
 * all three were actually wired up -- not just that `buildAsrRoutes` etc.
 * individually accepted a `recordEpisodicEvent` callback, which the
 * route-level tests already covered, but that `buildApp` actually passed one
 * through. "wired" was the property under test, and every assertion checked
 * that a row landed after exercising a route.
 *
 * ## What this file pins now
 *
 * The single-write-point redesign (design §3.2) moves that responsibility
 * out of the sidecar entirely: Swift now calls `POST /memory/events` itself,
 * at delivery time, once it knows the mode, the frontmost app, and the final
 * delivered text -- facts no sidecar route can reconstruct on its own (see
 * `test/memory/routes.test.ts`'s "POST /memory/events" suite for that new
 * write path). The three old writers are removed, not merely made harder to
 * reach, so this file now proves the opposite of what it proved before: that
 * exercising each of the three routes through the same assembled `buildApp`
 * leaves `episodic_events` untouched. This is the same invariant --
 * "is the episodic-event seam wired the way the current design says it
 * should be" -- read from its other side, which is why the file keeps its
 * name and its harness rather than being replaced outright.
 *
 * The harness (the `assemble` helper, the `emptyTools` stub, the `events`
 * raw-SQL reader) is unchanged from before; only the assertions invert. An
 * `/agent/run` case is added here for the first time -- previously out of
 * scope for this file ("already wired... not re-covered here") because
 * `/agent/run` wrote directly via `store.recordEpisodicEvent` rather than
 * through an optional deps seam, so there was nothing "wiring"-shaped left
 * to prove about it. Now that all three routes are supposed to write
 * *nothing*, leaving it out would mean the third of three writers is
 * untested here.
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

describe("buildApp no longer writes episodic events from any route -- writing moved to POST /memory/events", () => {
  test("a transcription through the assembled app leaves episodic_events empty", async () => {
    const { app, store } = assemble("unused", "帮我记一下这段话");

    const response = await app(
      new Request("http://sidecar/asr/transcribe", {
        method: "POST",
        body: JSON.stringify({ audioBase64: "aGk=" }),
      })
    );

    expect(response.status).toBe(200);
    // Before Task 3 this was `toHaveLength(1)` with `mode: "transcribe"`.
    // Recording now happens only when Swift POSTs to `/memory/events`, which
    // this request never does.
    expect(events(store)).toHaveLength(0);
  });

  test("an answered question through the assembled app leaves episodic_events empty", async () => {
    const { app, store } = assemble("Four.", "unused");

    const response = await app(
      new Request("http://sidecar/oneshot/ask", {
        method: "POST",
        body: JSON.stringify({ question: "what is 2+2" }),
      })
    );

    expect(response.status).toBe(200);
    // Before Task 3 this was `toHaveLength(1)` with `mode: "ask"` and
    // `result: "Four."`. `/oneshot/ask` no longer knows the frontmost app
    // (it hardcoded "OpenType Ask") and is exactly the kind of half-truth
    // write §3.2 removes.
    expect(events(store)).toHaveLength(0);
  });

  test("an agent run through the assembled app leaves episodic_events empty", async () => {
    const { app, store } = assemble("done", "unused");

    const response = await app(
      new Request("http://sidecar/agent/run", {
        method: "POST",
        body: JSON.stringify({ task: "summarize my notes", context: "note text here" }),
      })
    );

    expect(response.status).toBe(200);
    // `/agent/run` wrote directly via `store.recordEpisodicEvent` (no
    // optional deps seam to omit), so before Task 3 this route was not even
    // covered by this file -- it needed no "is it wired" test. It is
    // included now because all three writers are gone, not just the two
    // that went through an optional callback.
    expect(events(store)).toHaveLength(0);
  });

  test("none of the three modes feed the consolidation gate on their own anymore", async () => {
    const { app, store } = assemble("Four.", "一段听写");

    // Same shape of exercise as the pre-Task-3 version of this test (three
    // dictations, two questions) -- before Task 3 this asserted
    // `unconsolidatedEventCount() === 5`. With every writer removed, running
    // the same five requests now produces zero unconsolidated events, because
    // there is nothing in `episodic_events` at all until Swift starts calling
    // `POST /memory/events` at delivery time.
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

    expect(store.unconsolidatedEventCount()).toBe(0);
  });
});
