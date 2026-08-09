import { describe, expect, test } from "bun:test";
import { openDatabase } from "../../src/memory/db";
import { MemoryStore } from "../../src/memory/MemoryStore";
import type { AgentChatFn, AgentChatMessage } from "../../src/agent/loop";
import type { McpToolSet } from "../../src/agent/mcpClient";
import { buildAgentRoutes } from "../../src/agent/routes";
import { createRouter } from "../../src/router";
import type { ContextUsageLogWriter } from "../../src/oneshot/contextDebugLog";

function makeStore(): MemoryStore {
  return new MemoryStore(openDatabase(":memory:"));
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

function captureContextLog(): { writer: ContextUsageLogWriter; lines: string[] } {
  const lines: string[] = [];
  return { writer: (line) => lines.push(line), lines };
}

describe("POST /agent/run", () => {
  test("happy path: runs the loop and returns result + steps", async () => {
    const chat: AgentChatFn = async () => ({ content: "The capital of France is Paris." });
    const store = makeStore();
    const router = createRouter(buildAgentRoutes(store, chat, noTools(), captureContextLog().writer));

    const response = await router(
      post({ task: "What is the capital of France?", context: "some selected text" })
    );

    expect(response.status).toBe(200);
    const body = (await response.json()) as { result: string; steps: unknown[] };
    expect(body.result).toBe("The capital of France is Paris.");
    expect(Array.isArray(body.steps)).toBe(true);
    expect(body.steps.length).toBeGreaterThan(0);
  });

  test("records an episodic event with origin 'agent' after running", async () => {
    const chat: AgentChatFn = async () => ({ content: "done" });
    const store = makeStore();
    const router = createRouter(buildAgentRoutes(store, chat, noTools(), captureContextLog().writer));

    await router(post({ task: "summarize my notes", context: "note text here" }));

    const rows = store.db.query("SELECT * FROM episodic_events").all() as Array<
      Record<string, unknown>
    >;
    expect(rows).toHaveLength(1);
    expect(rows[0]?.mode).toBe("agent");
    expect(rows[0]?.origin).toBe("agent");
    expect(rows[0]?.rawTranscript).toBe("summarize my notes");
    expect(rows[0]?.correctedTranscript).toBe("summarize my notes");
    expect(rows[0]?.effectiveInput).toBe("summarize my notes");
    expect(rows[0]?.selectedContext).toBe("note text here");
    expect(rows[0]?.result).toBe("done");
    expect(rows[0]?.applicationName).toBe("OpenType Agent");
  });

  test("records selectedContext as null when no context is provided", async () => {
    const chat: AgentChatFn = async () => ({ content: "done" });
    const store = makeStore();
    const router = createRouter(buildAgentRoutes(store, chat, noTools(), captureContextLog().writer));

    await router(post({ task: "just a task" }));

    const rows = store.db.query("SELECT * FROM episodic_events").all() as Array<
      Record<string, unknown>
    >;
    expect(rows[0]?.selectedContext).toBeNull();
  });

  test("passes the connected tools' openAiTools through to the chat call", async () => {
    let capturedTools: unknown;
    const chat: AgentChatFn = async (_messages: AgentChatMessage[], options) => {
      capturedTools = options?.tools;
      return { content: "ok" };
    };
    const tools: McpToolSet = {
      openAiTools: [{ type: "function", function: { name: "server__tool" } }],
      callTool: async () => ({ content: "" }),
    };
    const store = makeStore();
    const router = createRouter(buildAgentRoutes(store, chat, tools, captureContextLog().writer));

    await router(post({ task: "use a tool" }));

    expect(capturedTools).toEqual([{ type: "function", function: { name: "server__tool" } }]);
  });

  test("logs context usage and injects matched known terms into the loop's prompt", async () => {
    const store = makeStore();
    const now = Date.now();
    store.db.run(
      `INSERT INTO entity_terms
        (canonicalTerm, aliases, category, confidence, origin, sourceEventIds, createdAt, updatedAt, supersedes)
       VALUES ('Zephyrus', '[]', 'project', 0.9, 'owner', '[]', ?, ?, NULL)`,
      [now, now]
    );
    let capturedMessages: AgentChatMessage[] | undefined;
    const chat: AgentChatFn = async (messages) => {
      capturedMessages = messages;
      return { content: "done" };
    };
    const { writer, lines } = captureContextLog();
    const router = createRouter(buildAgentRoutes(store, chat, noTools(), writer));

    await router(post({ task: "give me an update on Zephyrus" }));

    expect(lines).toHaveLength(1);
    expect(lines[0]).toContain("[agent]");
    expect(lines[0]).toContain("Zephyrus");
    expect(capturedMessages![1].content).toContain("Zephyrus");
  });

  test("logs 'no context matched' honestly when the entity dictionary has no match", async () => {
    const chat: AgentChatFn = async () => ({ content: "done" });
    const { writer, lines } = captureContextLog();
    const router = createRouter(buildAgentRoutes(makeStore(), chat, noTools(), writer));

    await router(post({ task: "just a task" }));

    expect(lines).toHaveLength(1);
    expect(lines[0]).toContain("no context matched");
  });
});
