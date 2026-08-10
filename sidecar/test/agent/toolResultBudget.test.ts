import { describe, expect, test } from "bun:test";
// Namespace import: `clampToolResult` does not exist yet, so importing it by
// name would be an ESM link error crashing the whole file (including the
// runAgentLoop integration test, which must fail for its OWN reason). A
// namespace import keeps a missing export as a plain `undefined`.
import * as loopModule from "../../src/agent/loop";
import { runAgentLoop } from "../../src/agent/loop";
import type { AgentChatFn, AgentChatMessage } from "../../src/agent/loop";
import type { McpToolSet } from "../../src/agent/mcpClient";

/**
 * Bug P2: `src/agent/loop.ts` appends an MCP tool result into the conversation
 * (`messages.push({ role: "tool", content: toolResultContent })`) with NO size
 * cap. A tool that returns a huge string therefore blows up the context fed
 * back into the next model call (and, pre-router-fix, produced an HTML 500).
 *
 * Desired fix, two complementary seams:
 *
 *   1. A pure, exported helper `clampToolResult(text: string, maxLen: number)`
 *      that returns `text` unchanged when it fits, and otherwise a truncated
 *      string bounded to roughly `maxLen` (a short truncation marker may be
 *      appended) that carries a visible truncation indicator.
 *
 *   2. `runAgentLoop` must apply that budget before pushing a tool result into
 *      `messages`, so an oversized tool result never reaches the next chat
 *      call at full size.
 */

const HUGE = "A".repeat(200_000);

describe("clampToolResult helper", () => {
  const clampToolResult = (
    loopModule as { clampToolResult?: (text: string, maxLen: number) => string }
  ).clampToolResult;

  test("is exported from agent/loop", () => {
    expect(typeof clampToolResult).toBe("function");
  });

  test("returns short input unchanged", () => {
    expect(clampToolResult!("hello world", 1000)).toBe("hello world");
  });

  test("returns input unchanged when exactly at the limit", () => {
    const exact = "x".repeat(50);
    expect(clampToolResult!(exact, 50)).toBe(exact);
  });

  test("truncates oversized input to a bounded length with a marker", () => {
    const maxLen = 500;
    const clamped = clampToolResult!(HUGE, maxLen);
    // Bounded: the clamped output is far smaller than the input, and does not
    // materially exceed maxLen (a small truncation marker is allowed).
    expect(clamped.length).toBeLessThan(HUGE.length);
    expect(clamped.length).toBeLessThanOrEqual(maxLen + 100);
    // Carries a visible truncation indicator so the model knows content was cut.
    expect(clamped.toLowerCase()).toContain("truncat");
  });
});

describe("runAgentLoop applies a tool-result budget", () => {
  test("an oversized tool result is truncated before it reaches the next chat call", async () => {
    let chatCalls = 0;
    const capturedMessages: AgentChatMessage[][] = [];
    const chat: AgentChatFn = async (messages) => {
      capturedMessages.push(messages.map((m) => ({ ...m })));
      chatCalls += 1;
      if (chatCalls === 1) {
        return {
          content: null,
          toolCalls: [
            {
              id: "call_1",
              type: "function",
              function: { name: "big__dump", arguments: "{}" },
            },
          ],
        };
      }
      return { content: "final answer" };
    };

    const tools: McpToolSet = {
      openAiTools: [{ type: "function", function: { name: "big__dump" } }],
      callTool: async () => ({ content: HUGE }),
    };

    const result = await runAgentLoop({ task: "dump everything" }, { chat, tools });
    expect(result.result).toBe("final answer");

    // The tool-role message handed to the SECOND chat call must be bounded,
    // not the full 200k-char blob.
    const secondCallMessages = capturedMessages[1] ?? [];
    const toolMessage = secondCallMessages.find((m) => m.role === "tool");
    expect(toolMessage).toBeDefined();
    const content = toolMessage?.content ?? "";
    expect(content.length).toBeLessThan(50_000);
    expect(content.length).toBeLessThan(HUGE.length);
    expect(content.toLowerCase()).toContain("truncat");
  });
});
