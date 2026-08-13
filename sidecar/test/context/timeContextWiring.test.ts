import { describe, expect, test } from "bun:test";
import { openDatabase } from "../../src/memory/db";
import { MemoryStore } from "../../src/memory/MemoryStore";
import { ConversationStore } from "../../src/memory/conversations";
import type { AgentChatFn, AgentChatMessage } from "../../src/agent/loop";
import type { McpToolSet } from "../../src/agent/mcpClient";
import { buildAgentRoutes } from "../../src/agent/routes";
import { buildOneShotRoutes } from "../../src/oneshot/routes";
import type { OneShotChatFn } from "../../src/oneshot/client";
import { createRouter } from "../../src/router";
import type { ContextUsageLogWriter } from "../../src/oneshot/contextDebugLog";

/**
 * T4 wiring half (docs/superpowers/specs/2026-08-13-dsh-borrowings-plan.md §6):
 * the time anchor has to actually REACH the model on both LLM paths, and it
 * has to arrive in the user message rather than the system prompt — a
 * timestamp in the system prompt would invalidate the reusable request prefix
 * on every single call (docs/model-context-inventory.md §5).
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

function noopLog(): ContextUsageLogWriter {
  return () => {};
}

/** Captures the exact message array the route hands the model. */
function capturingChat(): { chat: AgentChatFn; seen: AgentChatMessage[][] } {
  const seen: AgentChatMessage[][] = [];
  const chat: AgentChatFn = async (messages) => {
    seen.push(messages.map((message) => ({ ...message })));
    return { content: "ok" };
  };
  return { chat, seen };
}

function systemContentOf(messages: AgentChatMessage[]): string {
  return messages
    .filter((message) => message.role === "system")
    .map((message) => message.content ?? "")
    .join("\n");
}

function userContentOf(messages: AgentChatMessage[]): string {
  return messages
    .filter((message) => message.role === "user")
    .map((message) => message.content ?? "")
    .join("\n");
}

describe("time context reaches the model", () => {
  test("/agent/run puts it in the user message, not the system prompt", async () => {
    const { chat, seen } = capturingChat();
    const router = createRouter(
      buildAgentRoutes(makeStore(), makeConversations(), chat, noTools(), noopLog())
    );

    const response = await router(
      new Request("http://sidecar/agent/run", {
        method: "POST",
        body: JSON.stringify({ task: "remind me tomorrow" }),
      })
    );
    expect(response.status).toBe(200);

    expect(seen.length).toBeGreaterThan(0);
    const messages = seen[0]!;
    expect(userContentOf(messages)).toContain("Current time:");
    expect(systemContentOf(messages)).not.toContain("Current time:");
  });

  test("/oneshot/ask puts it in the user message, not the system prompt", async () => {
    const { chat, seen } = capturingChat();
    const router = createRouter(
      buildOneShotRoutes(
        makeStore(),
        makeConversations(),
        chat as unknown as OneShotChatFn,
        noopLog()
      )
    );

    const response = await router(
      new Request("http://sidecar/oneshot/ask", {
        method: "POST",
        body: JSON.stringify({ question: "what day is it next Wednesday?" }),
      })
    );
    expect(response.status).toBe(200);

    expect(seen.length).toBeGreaterThan(0);
    const messages = seen[0]!;
    expect(userContentOf(messages)).toContain("Current time:");
    expect(systemContentOf(messages)).not.toContain("Current time:");
  });
});
