import { describe, expect, test } from "bun:test";
import { openDatabase } from "../../src/memory/db";
import { MemoryStore } from "../../src/memory/MemoryStore";
import { ConversationStore } from "../../src/memory/conversations";
import type { OneShotChatFn } from "../../src/oneshot/client";
import { buildOneShotRoutes } from "../../src/oneshot/routes";
import { createRouter } from "../../src/router";
import type { ContextUsageLogWriter } from "../../src/oneshot/contextDebugLog";
import type { ToolSet } from "../../src/agent/toolSets";

/**
 * Pipeline B (docs/superpowers/specs/2026-08-28-skill-agent-ui-and-step-log-persistence.md
 * §2): "写入：... ask run 若产生 steps（web 工具）同样存". `handleAsk`
 * (`src/oneshot/routes.ts`) already runs the same `runAgentLoop` the agent
 * route uses, over a web-only toolset (see `test/oneshot/ask.test.ts`'s
 * "ask-mode web loop" describe block) -- its `loopResult.steps` exists today,
 * it is simply never passed to `conversations.appendMessage(conversationId,
 * "assistant", result)` (no fourth argument at all).
 *
 * Unlike `/agent/run`, ask's HTTP response never exposed `steps` -- the
 * file-header comment on `test/oneshot/ask.test.ts` pins `{ result,
 * conversationId }` as the unchanged wire shape, and that pin is NOT touched
 * here. So this can only assert against the injected `ConversationStore`
 * directly; there is no response field to compare it to the way the agent
 * write-path test compares against `body.steps`.
 */

function makeStore(): MemoryStore {
  return new MemoryStore(openDatabase(":memory:"));
}

function makeConversations(): ConversationStore {
  return new ConversationStore(openDatabase(":memory:"));
}

function post(body: unknown): Request {
  return new Request("http://sidecar/oneshot/ask", {
    method: "POST",
    body: JSON.stringify(body),
  });
}

function captureContextLog(): { writer: ContextUsageLogWriter } {
  return { writer: (_line: string) => {} };
}

const WEB_SEARCH = "opentype__web_search";
const WEB_FETCH = "opentype__web_fetch";

/**
 * Same shape as `test/oneshot/ask.test.ts`'s `fakeMergedToolSet`, trimmed to
 * just what this file needs: a decoy-free two-web-tool set whose `callTool`
 * returns canned content, no real network.
 */
function fakeWebToolSet(): ToolSet {
  return {
    openAiTools: [
      { type: "function", function: { name: WEB_SEARCH } },
      { type: "function", function: { name: WEB_FETCH } },
    ],
    callTool: async () => ({
      content: "1. Atlantis wins the final\n   https://example.com/final",
    }),
  };
}

describe("POST /oneshot/ask -- persists the loop's steps onto the assistant message (Pipeline B §2)", () => {
  test("a question answered via a web_search tool call persists that tool call in the assistant message's steps; the user message has none", async () => {
    let chatCalls = 0;
    const chat: OneShotChatFn = async () => {
      chatCalls += 1;
      if (chatCalls === 1) {
        return {
          content: null,
          toolCalls: [
            {
              id: "call_1",
              type: "function",
              function: { name: WEB_SEARCH, arguments: '{"query":"2026 world cup winner"}' },
            },
          ],
        };
      }
      return { content: "According to the sources, Atlantis won." };
    };
    const conversations = makeConversations();
    const router = createRouter(
      buildOneShotRoutes(
        makeStore(),
        conversations,
        chat,
        captureContextLog().writer,
        fakeWebToolSet()
      )
    );

    const response = await router(post({ question: "who won the 2026 world cup?" }));
    expect(response.status).toBe(200);
    const body = (await response.json()) as { conversationId: number };

    const conversation = conversations.getConversation(body.conversationId);
    const userMessage = conversation!.messages.find((m) => m.role === "user");
    const assistantMessage = conversation!.messages.find((m) => m.role === "assistant");

    expect(userMessage?.steps ?? null).toBeNull();
    expect(Array.isArray(assistantMessage?.steps)).toBe(true);

    const steps = (assistantMessage?.steps ?? []) as Array<{ type: string; detail: string }>;
    expect(steps.map((s) => s.type)).toEqual(
      expect.arrayContaining(["tool_call", "tool_result", "done"])
    );
    const toolCallStep = steps.find((s) => s.type === "tool_call");
    expect(toolCallStep?.detail).toContain(WEB_SEARCH);
  });

  test("a plain answer with no tool calls still persists its (non-empty) step log, not null", async () => {
    const chat: OneShotChatFn = async () => ({ content: "Four." });
    const conversations = makeConversations();
    const router = createRouter(
      buildOneShotRoutes(makeStore(), conversations, chat, captureContextLog().writer)
    );

    const response = await router(post({ question: "what is 2+2?" }));
    const body = (await response.json()) as { conversationId: number };

    const conversation = conversations.getConversation(body.conversationId);
    const assistantMessage = conversation!.messages.find((m) => m.role === "assistant");
    // `runAgentLoop` always emits at least a "thinking" + "done" pair, tools
    // or not (`src/agent/loop.ts`), so ask's step log is never empty even
    // when no web tool ran -- this guards against an implementation that
    // only wires steps through on the tool-calling path.
    expect(Array.isArray(assistantMessage?.steps)).toBe(true);
    expect((assistantMessage?.steps as unknown[]).length).toBeGreaterThan(0);
  });
});
