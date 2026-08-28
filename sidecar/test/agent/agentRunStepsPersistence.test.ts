import { describe, expect, test } from "bun:test";
import { openDatabase } from "../../src/memory/db";
import { MemoryStore } from "../../src/memory/MemoryStore";
import { ConversationStore } from "../../src/memory/conversations";
import type { AgentChatFn } from "../../src/agent/loop";
import type { McpToolSet } from "../../src/agent/mcpClient";
import { buildAgentRoutes } from "../../src/agent/routes";
import { createRouter } from "../../src/router";
import type { ContextUsageLogWriter } from "../../src/oneshot/contextDebugLog";

/**
 * Pipeline B (docs/superpowers/specs/2026-08-28-skill-agent-ui-and-step-log-persistence.md
 * §2): "写入：agent run 落 assistant message 时带上该 run 的 steps" -- the
 * assistant message `handleAgentRun` appends after a run resolves
 * (`src/agent/routes.ts`, currently `conversations.appendMessage(conversationId,
 * "assistant", loopResult.result)` with no steps argument at all) must carry
 * that run's `AgentProgressEvent[]` log, the same array the HTTP response
 * already exposes as `steps`. The user message appended just before the run
 * starts (`conversations.appendMessage(conversationId, "user", task)`) must
 * never carry steps.
 *
 * This drives the exact seam `test/agent/routes.test.ts`'s existing "happy
 * path" test already exercises (`buildAgentRoutes` + a trivial `AgentChatFn`,
 * and its "run with runId: after the run resolves..." test for the
 * tool-calling variant) -- `handleAgentRun` is not otherwise unit-testable in
 * isolation without rebuilding that same harness, so this reuses it rather
 * than building a separate mock tower. The only new thing asserted here is
 * what got PERSISTED into the injected `ConversationStore`, not just what the
 * HTTP response returned.
 */

function makeStore(): MemoryStore {
  return new MemoryStore(openDatabase(":memory:"));
}

function makeConversations(): ConversationStore {
  return new ConversationStore(openDatabase(":memory:"));
}

function noTools(): McpToolSet {
  return { openAiTools: [], callTool: async () => ({ content: "" }) };
}

function post(body: unknown): Request {
  return new Request("http://sidecar/agent/run", {
    method: "POST",
    body: JSON.stringify(body),
  });
}

function captureContextLog(): { writer: ContextUsageLogWriter } {
  return { writer: (_line: string) => {} };
}

describe("POST /agent/run -- persists the run's steps onto the assistant message (Pipeline B §2)", () => {
  test("the persisted assistant message's steps equal the response's steps array; the user message has none", async () => {
    const chat: AgentChatFn = async () => ({ content: "The capital of France is Paris." });
    const conversations = makeConversations();
    const router = createRouter(
      buildAgentRoutes(makeStore(), conversations, chat, noTools(), captureContextLog().writer)
    );

    const response = await router(post({ task: "What is the capital of France?" }));
    expect(response.status).toBe(200);
    const body = (await response.json()) as {
      steps: Array<{ type: string; detail: string }>;
      conversationId: number;
    };
    expect(body.steps.length).toBeGreaterThan(0);

    const conversation = conversations.getConversation(body.conversationId);
    const userMessage = conversation!.messages.find((m) => m.role === "user");
    const assistantMessage = conversation!.messages.find((m) => m.role === "assistant");

    expect(assistantMessage?.steps).toEqual(body.steps);
    expect(userMessage?.steps ?? null).toBeNull();
  });

  test("a run that calls a tool persists the full multi-step log (thinking/tool_call/tool_result/done), not just the final answer", async () => {
    let calls = 0;
    const chat: AgentChatFn = async () => {
      calls += 1;
      if (calls === 1) {
        return {
          content: null,
          toolCalls: [
            {
              id: "call_1",
              type: "function",
              function: { name: "search__lookup", arguments: '{"query":"weather"}' },
            },
          ],
        };
      }
      return { content: "It is sunny." };
    };
    const tools: McpToolSet = {
      openAiTools: [{ type: "function", function: { name: "search__lookup" } }],
      callTool: async () => ({ content: "sunny, 75F" }),
    };
    const conversations = makeConversations();
    const router = createRouter(
      buildAgentRoutes(makeStore(), conversations, chat, tools, captureContextLog().writer)
    );

    const response = await router(post({ task: "What's the weather?" }));
    // `detail` is part of the type here even though only `type` is read below:
    // the runtime response always carries it (every `AgentProgressEvent`
    // variant requires `detail`, loop.ts:34-39), and the persisted assistant
    // message's `steps` is `ConversationStepRecord[]`, which requires it too --
    // narrowing this cast to `{ type: string }` was a type-only omission, not
    // a reflection of an actually-optional field.
    const body = (await response.json()) as {
      steps: Array<{ type: string; detail: string }>;
      conversationId: number;
    };
    expect(body.steps.map((s) => s.type)).toEqual(
      expect.arrayContaining(["thinking", "tool_call", "tool_result", "done"])
    );

    const conversation = conversations.getConversation(body.conversationId);
    const assistantMessage = conversation!.messages.find((m) => m.role === "assistant");
    expect(assistantMessage?.steps).toEqual(body.steps);
  });

  test("a follow-up turn in an existing conversation persists ITS OWN steps on the new assistant message, leaving the earlier turn's message untouched", async () => {
    const conversations = makeConversations();
    const existingId = conversations.createConversation("agent", "summarize my notes");
    conversations.appendMessage(existingId, "user", "summarize my notes");
    conversations.appendMessage(existingId, "assistant", "Here is a summary: ...", [
      { type: "done", detail: "Here is a summary: ..." },
    ]);

    const chat: AgentChatFn = async () => ({ content: "Also mentioned the deadline." });
    const router = createRouter(
      buildAgentRoutes(makeStore(), conversations, chat, noTools(), captureContextLog().writer)
    );

    const response = await router(
      post({ task: "also mention the deadline", conversationId: existingId })
    );
    const body = (await response.json()) as { steps: Array<{ type: string; detail: string }> };

    const conversation = conversations.getConversation(existingId);
    const assistantMessages = conversation!.messages.filter((m) => m.role === "assistant");
    expect(assistantMessages).toHaveLength(2);
    // The earlier turn's steps must be exactly what it was seeded with.
    expect(assistantMessages[0]?.steps).toEqual([
      { type: "done", detail: "Here is a summary: ..." },
    ]);
    // The new turn's steps must be this run's own steps, not the response
    // shape reused, an empty array, or a copy of the prior turn's.
    expect(assistantMessages[1]?.steps).toEqual(body.steps);
    expect(assistantMessages[1]?.steps).not.toEqual(assistantMessages[0]?.steps);
  });
});
