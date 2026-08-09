import { describe, expect, test } from "bun:test";
import { openDatabase } from "../../src/memory/db";
import { MemoryStore } from "../../src/memory/MemoryStore";
import { ConversationStore } from "../../src/memory/conversations";
import type { AgentChatFn, AgentChatMessage } from "../../src/agent/loop";
import type { McpToolSet } from "../../src/agent/mcpClient";
import { buildAgentRoutes } from "../../src/agent/routes";
import { createRouter } from "../../src/router";
import type { ContextUsageLogWriter } from "../../src/oneshot/contextDebugLog";

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

function captureContextLog(): { writer: ContextUsageLogWriter; lines: string[] } {
  const lines: string[] = [];
  return { writer: (line) => lines.push(line), lines };
}

describe("POST /agent/run", () => {
  test("happy path: runs the loop and returns result + steps", async () => {
    const chat: AgentChatFn = async () => ({ content: "The capital of France is Paris." });
    const store = makeStore();
    const router = createRouter(buildAgentRoutes(store, makeConversations(), chat, noTools(), captureContextLog().writer));

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
    const router = createRouter(buildAgentRoutes(store, makeConversations(), chat, noTools(), captureContextLog().writer));

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
    const router = createRouter(buildAgentRoutes(store, makeConversations(), chat, noTools(), captureContextLog().writer));

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
    const router = createRouter(buildAgentRoutes(store, makeConversations(), chat, tools, captureContextLog().writer));

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
    const router = createRouter(buildAgentRoutes(store, makeConversations(), chat, noTools(), writer));

    await router(post({ task: "give me an update on Zephyrus" }));

    expect(lines).toHaveLength(1);
    expect(lines[0]).toContain("[agent]");
    expect(lines[0]).toContain("Zephyrus");
    expect(capturedMessages![1].content).toContain("Zephyrus");
  });

  test("logs 'no context matched' honestly when the entity dictionary has no match", async () => {
    const chat: AgentChatFn = async () => ({ content: "done" });
    const { writer, lines } = captureContextLog();
    const router = createRouter(buildAgentRoutes(makeStore(), makeConversations(), chat, noTools(), writer));

    await router(post({ task: "just a task" }));

    expect(lines).toHaveLength(1);
    expect(lines[0]).toContain("no context matched");
  });

  test("includes all owner facts as context, and logs how many were included", async () => {
    const store = makeStore();
    store.recordOwnerFact("The owner's name is Diyi.");
    let capturedMessages: AgentChatMessage[] | undefined;
    const chat: AgentChatFn = async (messages) => {
      capturedMessages = messages;
      return { content: "done" };
    };
    const { writer, lines } = captureContextLog();
    const router = createRouter(buildAgentRoutes(store, makeConversations(), chat, noTools(), writer));

    await router(post({ task: "what is my name?" }));

    expect(capturedMessages![1].content).toContain("Diyi");
    expect(lines).toHaveLength(1);
    expect(lines[0]).toContain("1 owner fact(s) included");
  });

  test("logs 'no owner facts' honestly when none are recorded", async () => {
    const chat: AgentChatFn = async () => ({ content: "done" });
    const { writer, lines } = captureContextLog();
    const router = createRouter(buildAgentRoutes(makeStore(), makeConversations(), chat, noTools(), writer));

    await router(post({ task: "just a task" }));

    expect(lines[0]).toContain("no owner facts");
  });

  describe("conversation continuation", () => {
    test("without a conversationId, starts a new 'agent' conversation and returns its id", async () => {
      const conversations = makeConversations();
      const chat: AgentChatFn = async () => ({ content: "The capital of France is Paris." });
      const router = createRouter(
        buildAgentRoutes(makeStore(), conversations, chat, noTools(), captureContextLog().writer)
      );

      const response = await router(post({ task: "What is the capital of France?" }));

      expect(response.status).toBe(200);
      const body = (await response.json()) as { result: string; conversationId: number };
      expect(typeof body.conversationId).toBe("number");

      const conversation = conversations.getConversation(body.conversationId);
      expect(conversation?.kind).toBe("agent");
      expect(conversation?.messages).toEqual([
        expect.objectContaining({ role: "user", content: "What is the capital of France?" }),
        expect.objectContaining({ role: "assistant", content: "The capital of France is Paris." }),
      ]);
    });

    test("with a conversationId, appends to the existing conversation instead of creating a new one", async () => {
      const conversations = makeConversations();
      const existingId = conversations.createConversation("agent", "summarize my notes");
      conversations.appendMessage(existingId, "user", "summarize my notes");
      conversations.appendMessage(existingId, "assistant", "Here is a summary: ...");

      const chat: AgentChatFn = async () => ({ content: "Added the follow-up point." });
      const router = createRouter(
        buildAgentRoutes(makeStore(), conversations, chat, noTools(), captureContextLog().writer)
      );

      const response = await router(
        post({ task: "also mention the deadline", conversationId: existingId })
      );

      const body = (await response.json()) as { conversationId: number };
      expect(body.conversationId).toBe(existingId);

      const conversation = conversations.getConversation(existingId);
      expect(conversation?.messages).toHaveLength(4);
      expect(conversation?.messages[2]).toMatchObject({
        role: "user",
        content: "also mention the deadline",
      });
      expect(conversation?.messages[3]).toMatchObject({
        role: "assistant",
        content: "Added the follow-up point.",
      });
    });

    test("feeds a summary of the prior turn into the loop's prompt so the model has continuity", async () => {
      const conversations = makeConversations();
      const existingId = conversations.createConversation("agent", "summarize my notes");
      conversations.appendMessage(existingId, "user", "summarize my notes");
      conversations.appendMessage(existingId, "assistant", "Here is a summary: the project is on track.");

      let capturedMessages: AgentChatMessage[] | undefined;
      const chat: AgentChatFn = async (messages) => {
        capturedMessages = messages;
        return { content: "done" };
      };
      const router = createRouter(
        buildAgentRoutes(makeStore(), conversations, chat, noTools(), captureContextLog().writer)
      );

      await router(post({ task: "also mention the deadline", conversationId: existingId }));

      const userContent = capturedMessages!.find((m) => m.role === "user")?.content ?? "";
      expect(userContent).toContain("summarize my notes");
      expect(userContent).toContain("Here is a summary: the project is on track.");
      expect(userContent).toContain("also mention the deadline");
    });

    test("falls back to starting a new conversation when the given conversationId does not exist", async () => {
      const conversations = makeConversations();
      const chat: AgentChatFn = async () => ({ content: "done" });
      const router = createRouter(
        buildAgentRoutes(makeStore(), conversations, chat, noTools(), captureContextLog().writer)
      );

      const response = await router(post({ task: "just a task", conversationId: 999_999 }));

      expect(response.status).toBe(200);
      const body = (await response.json()) as { conversationId: number };
      expect(body.conversationId).not.toBe(999_999);
      expect(conversations.getConversation(body.conversationId)).not.toBeNull();
    });
  });
});
