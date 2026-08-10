import { describe, expect, test } from "bun:test";
import { openDatabase } from "../src/memory/db";
import { MemoryStore } from "../src/memory/MemoryStore";
import { ConversationStore } from "../src/memory/conversations";
import type { AgentChatFn } from "../src/agent/loop";
import type { McpToolSet } from "../src/agent/mcpClient";
import { buildAgentRoutes } from "../src/agent/routes";
import type { OneShotChatFn } from "../src/oneshot/client";
import { buildOneShotRoutes } from "../src/oneshot/routes";
import { createRouter } from "../src/router";
import type { ContextUsageLogWriter } from "../src/oneshot/contextDebugLog";

// --- shared minimal deps -------------------------------------------------

function makeStore(): MemoryStore {
  return new MemoryStore(openDatabase(":memory:"));
}

function makeConversations(): ConversationStore {
  return new ConversationStore(openDatabase(":memory:"));
}

function noTools(): McpToolSet {
  return { openAiTools: [], callTool: async () => ({ content: "" }) };
}

function noopContextLog(): ContextUsageLogWriter {
  return () => {};
}

/**
 * A chat mock that records whether it was ever invoked. A correctly-validating
 * route must reject an empty/missing required field with a 400 *before* it ever
 * reaches the LLM call, so `called` must stay false for every invalid input.
 */
function trackedAgentChat(): { chat: AgentChatFn; wasCalled: () => boolean } {
  let called = false;
  const chat: AgentChatFn = async () => {
    called = true;
    return { content: "SHOULD NOT HAVE BEEN CALLED" };
  };
  return { chat, wasCalled: () => called };
}

function trackedOneShotChat(): { chat: OneShotChatFn; wasCalled: () => boolean } {
  let called = false;
  const chat: OneShotChatFn = async () => {
    called = true;
    return { content: "SHOULD NOT HAVE BEEN CALLED" };
  };
  return { chat, wasCalled: () => called };
}

function agentPost(body: unknown): Request {
  return new Request("http://sidecar/agent/run", {
    method: "POST",
    body: JSON.stringify(body),
  });
}

function askPost(body: unknown): Request {
  return new Request("http://sidecar/oneshot/ask", {
    method: "POST",
    body: JSON.stringify(body),
  });
}

// --- POST /agent/run: required `task` ------------------------------------

describe("POST /agent/run required-field validation", () => {
  test("a missing `task` returns 400 with a JSON error and never calls the LLM", async () => {
    const { chat, wasCalled } = trackedAgentChat();
    const router = createRouter(
      buildAgentRoutes(makeStore(), makeConversations(), chat, noTools(), noopContextLog())
    );

    const response = await router(agentPost({ context: "some selected text" }));

    expect(response.status).toBe(400);

    const contentType = response.headers.get("content-type") ?? "";
    expect(contentType).toContain("application/json");

    const body = (await response.json()) as { error?: unknown };
    expect(body.error).toBeDefined();
    expect(typeof body.error).toBe("string");

    // Must reject before running the agent loop on empty input.
    expect(wasCalled()).toBe(false);
  });

  test("an empty-string `task` returns 400 and never calls the LLM", async () => {
    const { chat, wasCalled } = trackedAgentChat();
    const router = createRouter(
      buildAgentRoutes(makeStore(), makeConversations(), chat, noTools(), noopContextLog())
    );

    const response = await router(agentPost({ task: "" }));

    expect(response.status).toBe(400);
    const body = (await response.json()) as { error?: unknown };
    expect(body.error).toBeDefined();
    expect(wasCalled()).toBe(false);
  });

  test("a whitespace-only `task` returns 400 and never calls the LLM", async () => {
    const { chat, wasCalled } = trackedAgentChat();
    const router = createRouter(
      buildAgentRoutes(makeStore(), makeConversations(), chat, noTools(), noopContextLog())
    );

    const response = await router(agentPost({ task: "   \n\t  " }));

    expect(response.status).toBe(400);
    const body = (await response.json()) as { error?: unknown };
    expect(body.error).toBeDefined();
    expect(wasCalled()).toBe(false);
  });

  test("a missing `task` does not write an episodic event", async () => {
    const { chat } = trackedAgentChat();
    const store = makeStore();
    const router = createRouter(
      buildAgentRoutes(store, makeConversations(), chat, noTools(), noopContextLog())
    );

    await router(agentPost({ context: "some selected text" }));

    const rows = store.db.query("SELECT * FROM episodic_events").all() as unknown[];
    expect(rows).toHaveLength(0);
  });

  test("a valid `task` still succeeds (validation does not break the happy path)", async () => {
    const chat: AgentChatFn = async () => ({ content: "done" });
    const router = createRouter(
      buildAgentRoutes(makeStore(), makeConversations(), chat, noTools(), noopContextLog())
    );

    const response = await router(agentPost({ task: "summarize my notes" }));

    expect(response.status).toBe(200);
  });
});

// --- POST /oneshot/ask: required `question` ------------------------------

describe("POST /oneshot/ask required-field validation", () => {
  test("a missing `question` returns 400 with a JSON error and never calls the LLM", async () => {
    const { chat, wasCalled } = trackedOneShotChat();
    const router = createRouter(
      buildOneShotRoutes(makeStore(), makeConversations(), chat, noopContextLog())
    );

    const response = await router(askPost({}));

    expect(response.status).toBe(400);

    const contentType = response.headers.get("content-type") ?? "";
    expect(contentType).toContain("application/json");

    const body = (await response.json()) as { error?: unknown };
    expect(body.error).toBeDefined();
    expect(typeof body.error).toBe("string");

    expect(wasCalled()).toBe(false);
  });

  test("an empty-string `question` returns 400 and never calls the LLM", async () => {
    const { chat, wasCalled } = trackedOneShotChat();
    const router = createRouter(
      buildOneShotRoutes(makeStore(), makeConversations(), chat, noopContextLog())
    );

    const response = await router(askPost({ question: "" }));

    expect(response.status).toBe(400);
    const body = (await response.json()) as { error?: unknown };
    expect(body.error).toBeDefined();
    expect(wasCalled()).toBe(false);
  });

  test("a whitespace-only `question` returns 400 and never calls the LLM", async () => {
    const { chat, wasCalled } = trackedOneShotChat();
    const router = createRouter(
      buildOneShotRoutes(makeStore(), makeConversations(), chat, noopContextLog())
    );

    const response = await router(askPost({ question: "   \n\t  " }));

    expect(response.status).toBe(400);
    const body = (await response.json()) as { error?: unknown };
    expect(body.error).toBeDefined();
    expect(wasCalled()).toBe(false);
  });

  test("a valid `question` still succeeds (validation does not break the happy path)", async () => {
    const chat: OneShotChatFn = async () => ({ content: "Four." });
    const router = createRouter(
      buildOneShotRoutes(makeStore(), makeConversations(), chat, noopContextLog())
    );

    const response = await router(askPost({ question: "what is 2+2?" }));

    expect(response.status).toBe(200);
  });
});
