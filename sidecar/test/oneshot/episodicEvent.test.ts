/**
 * P1-7 (补): `/oneshot/ask` must contribute episodic events too.
 *
 * Same motivation as `test/asr/episodicEvent.test.ts`: before P1-7 only
 * `/agent/run` wrote `episodic_events`, so Q&A never fed consolidation even
 * though a question is exactly where a project/person/term the owner cares
 * about tends to get named for the first time.
 *
 * ## The contract stage 3 must implement
 *
 * No signature change: `buildOneShotRoutes` already receives the real
 * `MemoryStore` as its first argument (it reads the dictionary and owner facts
 * from it). The handler records the event after the answer is produced, in the
 * same place `/agent/run` does — after the assistant message is appended, so
 * an event only exists for a turn that actually completed.
 *
 * ### Field mapping, pinned here
 *
 * - `mode: "ask"` — matches Swift's `InputMode.ask` rawValue.
 * - `rawTranscript` = `correctedTranscript` = `effectiveInput` = the question.
 *   Unlike `/asr/transcribe`, this route never sees a pre-correction form: by
 *   the time Swift posts here the text is already transcribed, so raw and
 *   corrected genuinely are the same string. This mirrors exactly what
 *   `/agent/run` does with its `task`, and keeping the two modes' shapes
 *   identical is the point — consolidation reads them through one prompt.
 * - `selectedContext: null` — the ask body is `{ question, conversationId }`;
 *   ask deliberately needs no selection (that is the documented difference
 *   from the old selection-based modes).
 * - `result` = the answer as returned to the user (trimmed, same string the
 *   response body carries and the conversation stores).
 * - `applicationName: "OpenType Ask"` — placeholder, for the same reason the
 *   agent route uses `"OpenType Agent"`: nothing on the wire tells the sidecar
 *   the frontmost app. See the longer note in `test/asr/episodicEvent.test.ts`.
 * - `origin: "agent"` — matching `/agent/run`. Since the 2026-08-13 ask-web
 *   batch, Ask *is* `runAgentLoop` with a web-only toolset, and its `result`
 *   half is machine-produced text that may quote fetched web pages. Recording
 *   it as `"owner"` would let model output — and by extension whatever a
 *   fetched page said — flow into consolidation labelled as the owner's own
 *   words, which is the exact provenance confusion `EventOrigin` exists to
 *   prevent (see `test/memory/poisoning.test.ts`).
 *
 * ### Best-effort
 *
 * A memory write that throws must never turn a successfully answered question
 * into an error response. The answer is the product; the episodic row is
 * bookkeeping.
 */
import { describe, expect, test } from "bun:test";
import { openDatabase } from "../../src/memory/db";
import { MemoryStore } from "../../src/memory/MemoryStore";
import { ConversationStore } from "../../src/memory/conversations";
import type { OneShotChatFn } from "../../src/oneshot/client";
import { buildOneShotRoutes } from "../../src/oneshot/routes";
import { createRouter } from "../../src/router";
import type { ContextUsageLogWriter } from "../../src/oneshot/contextDebugLog";

function makeStore(): MemoryStore {
  return new MemoryStore(openDatabase(":memory:"));
}

function makeConversations(): ConversationStore {
  return new ConversationStore(openDatabase(":memory:"));
}

const noopLog: ContextUsageLogWriter = () => {};

function post(body: unknown): Request {
  return new Request("http://sidecar/oneshot/ask", {
    method: "POST",
    body: JSON.stringify(body),
  });
}

function events(store: MemoryStore): Array<Record<string, unknown>> {
  return store.db
    .query("SELECT * FROM episodic_events ORDER BY id ASC")
    .all() as Array<Record<string, unknown>>;
}

function answering(answer: string): OneShotChatFn {
  return async () => ({ content: answer });
}

describe("POST /oneshot/ask records an episodic event", () => {
  test("records one event, in ask mode, on a successful answer", async () => {
    const store = makeStore();
    const router = createRouter(
      buildOneShotRoutes(store, makeConversations(), answering("Four."), noopLog)
    );

    const response = await router(post({ question: "what is 2+2" }));

    expect(response.status).toBe(200);
    const rows = events(store);
    expect(rows).toHaveLength(1);
    expect(rows[0]!.mode).toBe("ask");
  });

  test("stores the question in all three transcript columns and the answer as the result", async () => {
    const store = makeStore();
    const router = createRouter(
      buildOneShotRoutes(store, makeConversations(), answering("  Four.  "), noopLog)
    );

    await router(post({ question: "what is 2+2" }));

    const row = events(store)[0]!;
    expect(row.rawTranscript).toBe("what is 2+2");
    expect(row.correctedTranscript).toBe("what is 2+2");
    expect(row.effectiveInput).toBe("what is 2+2");
    expect(row.selectedContext).toBeNull();
    // The trimmed answer, i.e. the same string the response body carries.
    expect(row.result).toBe("Four.");
  });

  test("records the sidecar-side placeholder application name and agent provenance", async () => {
    const store = makeStore();
    const router = createRouter(
      buildOneShotRoutes(store, makeConversations(), answering("Four."), noopLog)
    );

    await router(post({ question: "what is 2+2" }));

    const row = events(store)[0]!;
    expect(row.applicationName).toBe("OpenType Ask");
    expect(row.origin).toBe("agent");
  });

  test("records nothing when the question is rejected", async () => {
    const store = makeStore();
    const router = createRouter(
      buildOneShotRoutes(store, makeConversations(), answering("unused"), noopLog)
    );

    const response = await router(post({ question: "   " }));

    expect(response.status).toBe(400);
    expect(events(store)).toEqual([]);
  });

  test("records nothing when the model call fails", async () => {
    const store = makeStore();
    const failing: OneShotChatFn = async () => {
      throw new Error("provider is down");
    };
    const router = createRouter(
      buildOneShotRoutes(store, makeConversations(), failing, noopLog)
    );

    const response = await router(post({ question: "what is 2+2" }));

    expect(response.status).toBe(500);
    expect(events(store)).toEqual([]);
  });

  test("records one event per turn, so a continued conversation accumulates them", async () => {
    const store = makeStore();
    const conversations = makeConversations();
    const router = createRouter(
      buildOneShotRoutes(store, conversations, answering("Four."), noopLog)
    );

    const first = await router(post({ question: "what is 2+2" }));
    const { conversationId } = (await first.json()) as { conversationId: number };
    await router(post({ question: "and 3+3", conversationId }));

    const rows = events(store);
    expect(rows).toHaveLength(2);
    expect(rows.map((r) => r.rawTranscript)).toEqual(["what is 2+2", "and 3+3"]);
  });

  test("a failing episodic write never fails the answer", async () => {
    const store = makeStore();
    let attempted = 0;
    store.recordEpisodicEvent = () => {
      attempted++;
      throw new Error("database is locked");
    };
    const router = createRouter(
      buildOneShotRoutes(store, makeConversations(), answering("Four."), noopLog)
    );

    const response = await router(post({ question: "what is 2+2" }));

    // The write was attempted through the store's own API — the same one
    // `/agent/run` uses — and blew up. Without this the test would pass
    // vacuously against an implementation that bypassed `recordEpisodicEvent`
    // with its own INSERT, which is exactly the swallow-nothing shape this
    // test exists to rule out.
    expect(attempted).toBe(1);
    // ...and the user still got their answer, with a normal 200.
    expect(response.status).toBe(200);
    const body = (await response.json()) as { result: string; conversationId: number };
    expect(body.result).toBe("Four.");
    expect(typeof body.conversationId).toBe("number");
  });
});
