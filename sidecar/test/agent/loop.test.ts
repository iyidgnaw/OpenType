import { describe, expect, test } from "bun:test";
import { runAgentLoop, type AgentChatFn, type AgentChatMessage } from "../../src/agent/loop";
import type { McpToolSet } from "../../src/agent/mcpClient";

function noTools(): McpToolSet {
  return {
    openAiTools: [],
    callTool: async () => {
      throw new Error("callTool should not be invoked in this test");
    },
  };
}

describe("runAgentLoop", () => {
  test("zero-tool-calls happy path: one chat call, immediate answer", async () => {
    let chatCalls = 0;
    const chat: AgentChatFn = async () => {
      chatCalls += 1;
      return { content: "Paris" };
    };

    const result = await runAgentLoop(
      { task: "What is the capital of France?" },
      { chat, tools: noTools() }
    );

    expect(chatCalls).toBe(1);
    expect(result.result).toBe("Paris");
    expect(result.steps.map((s) => s.type)).toEqual(["thinking", "done"]);
  });

  test("one tool call then final answer: two chat calls, tool executed once", async () => {
    let chatCalls = 0;
    const capturedMessages: AgentChatMessage[][] = [];
    const chat: AgentChatFn = async (messages) => {
      capturedMessages.push(messages);
      chatCalls += 1;
      if (chatCalls === 1) {
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

    let callToolInvocations: Array<{ name: string; args: unknown }> = [];
    const tools: McpToolSet = {
      openAiTools: [{ type: "function", function: { name: "search__lookup" } }],
      callTool: async (name, args) => {
        callToolInvocations.push({ name, args });
        return { content: "sunny, 75F" };
      },
    };

    const result = await runAgentLoop(
      { task: "What's the weather?" },
      { chat, tools }
    );

    expect(chatCalls).toBe(2);
    expect(callToolInvocations).toEqual([{ name: "search__lookup", args: { query: "weather" } }]);
    expect(result.result).toBe("It is sunny.");

    // Second chat call must have the assistant tool-call message and the
    // tool-role result message appended, per OpenAI tool-calling conventions.
    const secondCallMessages = capturedMessages[1] ?? [];
    const assistantToolCallMessage = secondCallMessages.find(
      (m) => m.role === "assistant" && m.tool_calls
    );
    const toolResultMessage = secondCallMessages.find((m) => m.role === "tool");
    expect(assistantToolCallMessage?.tool_calls).toEqual([
      {
        id: "call_1",
        type: "function",
        function: { name: "search__lookup", arguments: '{"query":"weather"}' },
      },
    ]);
    expect(toolResultMessage?.tool_call_id).toBe("call_1");
    expect(toolResultMessage?.content).toBe("sunny, 75F");

    expect(result.steps.map((s) => s.type)).toEqual([
      "thinking",
      "tool_call",
      "tool_result",
      "thinking",
      "done",
    ]);
  });

  test("hits the iteration cap when chat always requests another tool call", async () => {
    let chatCalls = 0;
    const chat: AgentChatFn = async () => {
      chatCalls += 1;
      return {
        content: null,
        toolCalls: [
          {
            id: `call_${chatCalls}`,
            type: "function",
            function: { name: "search__lookup", arguments: "{}" },
          },
        ],
      };
    };

    let callToolCalls = 0;
    const tools: McpToolSet = {
      openAiTools: [{ type: "function", function: { name: "search__lookup" } }],
      callTool: async () => {
        callToolCalls += 1;
        return { content: "more data" };
      },
    };

    const result = await runAgentLoop({ task: "loop forever" }, { chat, tools });

    expect(chatCalls).toBe(10);
    expect(callToolCalls).toBe(10);
    expect(typeof result.result).toBe("string");
    expect(result.result.length).toBeGreaterThan(0);
  });

  test("emits progress events via onProgress in order as the loop runs", async () => {
    let chatCalls = 0;
    const chat: AgentChatFn = async () => {
      chatCalls += 1;
      if (chatCalls === 1) {
        return {
          content: null,
          toolCalls: [
            { id: "call_1", type: "function", function: { name: "t__x", arguments: "{}" } },
          ],
        };
      }
      return { content: "done answer" };
    };
    const tools: McpToolSet = {
      openAiTools: [],
      callTool: async () => ({ content: "result" }),
    };

    const observed: string[] = [];
    const result = await runAgentLoop(
      { task: "do a thing" },
      { chat, tools, onProgress: (event) => observed.push(event.type) }
    );

    expect(observed).toEqual(result.steps.map((s) => s.type));
    expect(observed).toEqual(["thinking", "tool_call", "tool_result", "thinking", "done"]);
  });

  test("includes context and knownTerms in the initial user message when present", async () => {
    let capturedMessages: AgentChatMessage[] = [];
    const chat: AgentChatFn = async (messages) => {
      capturedMessages = messages;
      return { content: "ok" };
    };

    await runAgentLoop(
      { task: "summarize this", context: "some selected text", knownTerms: "Known terms: Foo" },
      { chat, tools: noTools() }
    );

    const userMessage = capturedMessages.find((m) => m.role === "user");
    expect(userMessage?.content).toContain("summarize this");
    expect(userMessage?.content).toContain("some selected text");
    expect(userMessage?.content).toContain("Known terms: Foo");

    const systemMessage = capturedMessages.find((m) => m.role === "system");
    expect(systemMessage?.content).toBeTruthy();
  });
});
