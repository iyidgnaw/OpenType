/**
 * Tests for `POST /oneshot/ask`.
 *
 * ## Ask-mode web loop contract (B2 open-file + ask-web design §2,
 * docs/superpowers/specs/2026-08-13-b2-open-file-and-ask-web-design.md) --
 * the injection contract stage 3 must implement:
 *
 * Ask switches from a single chat call to `runAgentLoop` with a web-only
 * toolset. `buildOneShotRoutes` gains a FIFTH, optional parameter, appended
 * after the existing four so every pre-existing 4-arg call site keeps
 * working unchanged (least-invasive, and consistent with `buildAgentRoutes`
 * receiving its ToolSet positionally):
 *
 *   buildOneShotRoutes(store, conversations, chat, contextLogWriter,
 *                      tools?: ToolSet)
 *
 * - `tools` is the same server-level ToolSet `buildAgentRoutes` receives
 *   (already merged and `withApproval(yolo)`-wrapped in server.ts). The ask
 *   handler narrows it itself via
 *   `filterToolSet(tools, ["opentype__web_search", "opentype__web_fetch"])`
 *   -- so Ask = web only is a property of the ask route, not of the wiring.
 * - When `tools` is omitted (legacy call sites -- the older tests in this
 *   file), ask runs the loop with an empty toolset: no tool descriptors are
 *   offered, so a plain-answer chat behaves exactly as before.
 * - Prior turns are still replayed as real message history (loop
 *   `priorMessages`, between system and the new question), NOT the
 *   agent-route-style squashed summary.
 * - The ask-specific iteration cap is 6 (spec §2: an answer should need at
 *   most a few searches).
 * - The response wire shape is UNCHANGED: `{ result, conversationId }`, the
 *   as-built field names asserted by every pre-existing test below and read
 *   by the Swift client (the design doc's §2 "Response contract" says the
 *   same after its 2026-08-13 correction from an earlier `answer` draft).
 * - No pre-existing test here asserted "chat called exactly once with no
 *   tools", so none needed updating for the new contract; everything above
 *   the "ask-mode web loop" describe is untouched.
 */
import { describe, expect, test } from "bun:test";
import { openDatabase } from "../../src/memory/db";
import { MemoryStore } from "../../src/memory/MemoryStore";
import { ConversationStore } from "../../src/memory/conversations";
import type { OneShotChatFn, OneShotChatMessage } from "../../src/oneshot/client";
import { buildOneShotRoutes } from "../../src/oneshot/routes";
import { createRouter } from "../../src/router";
import type { ContextUsageLogWriter } from "../../src/oneshot/contextDebugLog";
import type { ToolSet } from "../../src/agent/toolSets";

function makeStore(): MemoryStore {
  return new MemoryStore(openDatabase(":memory:"));
}

function makeConversations(db = openDatabase(":memory:")): ConversationStore {
  return new ConversationStore(db);
}

function post(body: unknown): Request {
  return new Request("http://sidecar/oneshot/ask", {
    method: "POST",
    body: JSON.stringify(body),
  });
}

function captureContextLog(): { writer: ContextUsageLogWriter; lines: string[] } {
  const lines: string[] = [];
  return { writer: (line) => lines.push(line), lines };
}

describe("POST /oneshot/ask", () => {
  test("happy path: the model's answer is returned as-is", async () => {
    let capturedMessages: OneShotChatMessage[] | undefined;
    const chat: OneShotChatFn = async (messages) => {
      capturedMessages = messages;
      return { content: "Four." };
    };
    const router = createRouter(buildOneShotRoutes(makeStore(), makeConversations(), chat, captureContextLog().writer));

    const response = await router(post({ question: "what is 2+2, answer in one word" }));

    expect(response.status).toBe(200);
    const body = (await response.json()) as { result: string; conversationId: number };
    expect(body.result).toBe("Four.");
    expect(typeof body.conversationId).toBe("number");
    expect(capturedMessages![1].content).toContain("what is 2+2, answer in one word");
  });

  test("no fidelity validation is applied: an answer is returned even though it would fail the translate-style checks", async () => {
    const chat: OneShotChatFn = async () => ({
      content: "这是一个很长的回答，包含中文字符，远远超过原始问题的长度，用于验证 Ask 模式不做保真度校验。",
    });
    const router = createRouter(buildOneShotRoutes(makeStore(), makeConversations(), chat, captureContextLog().writer));

    const response = await router(post({ question: "what language do you speak?" }));

    expect(response.status).toBe(200);
    const body = (await response.json()) as { result: string };
    expect(body.result.length).toBeGreaterThan(0);
  });

  test("includes matching known memory terms as light context", async () => {
    const store = makeStore();
    const now = Date.now();
    store.db.run(
      `INSERT INTO entity_terms
        (canonicalTerm, aliases, category, confidence, origin, sourceEventIds, createdAt, updatedAt, supersedes)
       VALUES ('Zephyrus', '[]', 'project', 0.9, 'owner', '[]', ?, ?, NULL)`,
      [now, now]
    );
    let capturedMessages: OneShotChatMessage[] | undefined;
    const chat: OneShotChatFn = async (messages) => {
      capturedMessages = messages;
      return { content: "answer" };
    };
    const router = createRouter(buildOneShotRoutes(store, makeConversations(), chat, captureContextLog().writer));

    await router(post({ question: "what is the status of Zephyrus?" }));

    expect(capturedMessages![1].content).toContain("Zephyrus");
  });

  test("logs context usage (endpoint, input, and the matched term) via the injected writer", async () => {
    const store = makeStore();
    const now = Date.now();
    store.db.run(
      `INSERT INTO entity_terms
        (canonicalTerm, aliases, category, confidence, origin, sourceEventIds, createdAt, updatedAt, supersedes)
       VALUES ('Zephyrus', '[]', 'project', 0.9, 'owner', '[]', ?, ?, NULL)`,
      [now, now]
    );
    const chat: OneShotChatFn = async () => ({ content: "answer" });
    const { writer, lines } = captureContextLog();
    const router = createRouter(buildOneShotRoutes(store, makeConversations(), chat, writer));

    await router(post({ question: "what is the status of Zephyrus?" }));

    expect(lines).toHaveLength(1);
    expect(lines[0]).toContain("[ask]");
    expect(lines[0]).toContain("Zephyrus");
    expect(lines[0]).toContain("what is the status of Zephyrus?");
  });

  test("logs 'no context matched' honestly when the entity dictionary has no match", async () => {
    const chat: OneShotChatFn = async () => ({ content: "answer" });
    const { writer, lines } = captureContextLog();
    const router = createRouter(buildOneShotRoutes(makeStore(), makeConversations(), chat, writer));

    await router(post({ question: "what time is it?" }));

    expect(lines).toHaveLength(1);
    expect(lines[0]).toContain("no context matched");
  });

  test("includes all owner facts as context, and logs how many were included", async () => {
    const store = makeStore();
    store.recordOwnerFact("The owner's name is Diyi.");
    let capturedMessages: OneShotChatMessage[] | undefined;
    const chat: OneShotChatFn = async (messages) => {
      capturedMessages = messages;
      return { content: "answer" };
    };
    const { writer, lines } = captureContextLog();
    const router = createRouter(buildOneShotRoutes(store, makeConversations(), chat, writer));

    await router(post({ question: "what is my name?" }));

    expect(capturedMessages![1].content).toContain("Diyi");
    expect(lines).toHaveLength(1);
    expect(lines[0]).toContain("1 owner fact(s) included");
  });

  test("logs 'no owner facts' honestly when none are recorded", async () => {
    const chat: OneShotChatFn = async () => ({ content: "answer" });
    const { writer, lines } = captureContextLog();
    const router = createRouter(buildOneShotRoutes(makeStore(), makeConversations(), chat, writer));

    await router(post({ question: "what time is it?" }));

    expect(lines[0]).toContain("no owner facts");
  });

  describe("conversation continuation", () => {
    test("without a conversationId, starts a new 'ask' conversation and returns its id", async () => {
      const conversations = makeConversations();
      const chat: OneShotChatFn = async () => ({ content: "Four." });
      const router = createRouter(
        buildOneShotRoutes(makeStore(), conversations, chat, captureContextLog().writer)
      );

      const response = await router(post({ question: "what is 2+2?" }));

      expect(response.status).toBe(200);
      const body = (await response.json()) as { result: string; conversationId: number };
      expect(typeof body.conversationId).toBe("number");

      const conversation = conversations.getConversation(body.conversationId);
      expect(conversation?.kind).toBe("ask");
      expect(conversation?.messages).toEqual([
        expect.objectContaining({ role: "user", content: "what is 2+2?" }),
        expect.objectContaining({ role: "assistant", content: "Four." }),
      ]);
    });

    test("with a conversationId, appends to the existing conversation instead of creating a new one", async () => {
      const conversations = makeConversations();
      const existingId = conversations.createConversation("ask", "what is 2+2?");
      conversations.appendMessage(existingId, "user", "what is 2+2?");
      conversations.appendMessage(existingId, "assistant", "4");

      const chat: OneShotChatFn = async () => ({ content: "6" });
      const router = createRouter(
        buildOneShotRoutes(makeStore(), conversations, chat, captureContextLog().writer)
      );

      const response = await router(post({ question: "and 2+4?", conversationId: existingId }));

      const body = (await response.json()) as { result: string; conversationId: number };
      expect(body.conversationId).toBe(existingId);

      const conversation = conversations.getConversation(existingId);
      expect(conversation?.messages).toHaveLength(4);
      expect(conversation?.messages[2]).toMatchObject({ role: "user", content: "and 2+4?" });
      expect(conversation?.messages[3]).toMatchObject({ role: "assistant", content: "6" });
    });

    test("passes the prior conversation turns to the chat call as real message history", async () => {
      const conversations = makeConversations();
      const existingId = conversations.createConversation("ask", "who is the CEO of Acme?");
      conversations.appendMessage(existingId, "user", "who is the CEO of Acme?");
      conversations.appendMessage(existingId, "assistant", "Jane Doe is the CEO of Acme.");

      let capturedMessages: OneShotChatMessage[] | undefined;
      const chat: OneShotChatFn = async (messages) => {
        capturedMessages = messages;
        return { content: "She has been CEO since 2019." };
      };
      const router = createRouter(
        buildOneShotRoutes(makeStore(), conversations, chat, captureContextLog().writer)
      );

      await router(post({ question: "since when?", conversationId: existingId }));

      expect(capturedMessages).toBeDefined();
      const roles = capturedMessages!.map((m) => m.role);
      const contents = capturedMessages!.map((m) => m.content);
      expect(roles).toContain("user");
      expect(contents).toContain("who is the CEO of Acme?");
      expect(contents).toContain("Jane Doe is the CEO of Acme.");
      expect(contents[contents.length - 1]).toContain("since when?");
    });

    test("falls back to starting a new conversation when the given conversationId does not exist", async () => {
      const conversations = makeConversations();
      const chat: OneShotChatFn = async () => ({ content: "answer" });
      const router = createRouter(
        buildOneShotRoutes(makeStore(), conversations, chat, captureContextLog().writer)
      );

      const response = await router(post({ question: "hello", conversationId: 999_999 }));

      expect(response.status).toBe(200);
      const body = (await response.json()) as { conversationId: number };
      expect(body.conversationId).not.toBe(999_999);
      expect(conversations.getConversation(body.conversationId)).not.toBeNull();
    });
  });

  // See the file-header comment for the full injection contract these pin.
  describe("ask-mode web loop (B2 open-file + ask-web design §2)", () => {
    const WEB_SEARCH = "opentype__web_search";
    const WEB_FETCH = "opentype__web_fetch";

    function toolDescriptor(name: string): unknown {
      return { type: "function", function: { name } };
    }

    /**
     * Stands in for the server's merged, approval-wrapped ToolSet. It
     * deliberately contains a NON-web decoy tool (bash) ahead of the two web
     * tools, so asserting "chat sees exactly [web_search, web_fetch]" proves
     * the ask route narrows the set itself rather than passing it through.
     * `callTool` records invocations and serves canned content -- no real
     * network, no real processes.
     */
    function fakeMergedToolSet(onCall?: (name: string, args: unknown) => string): {
      tools: ToolSet;
      invocations: Array<{ name: string; args: unknown }>;
    } {
      const invocations: Array<{ name: string; args: unknown }> = [];
      const tools: ToolSet = {
        openAiTools: [
          toolDescriptor("opentype__bash"),
          toolDescriptor(WEB_SEARCH),
          toolDescriptor(WEB_FETCH),
        ],
        callTool: async (name, args) => {
          invocations.push({ name, args });
          return { content: onCall ? onCall(name, args) : `fake ${name} result` };
        },
      };
      return { tools, invocations };
    }

    test("chat is offered exactly the two web tool descriptors, filtered from the injected set", async () => {
      let capturedTools: unknown[] | undefined;
      const chat: OneShotChatFn = async (_messages, options) => {
        capturedTools = options?.tools;
        return { content: "no tools needed for this one" };
      };
      const { tools } = fakeMergedToolSet();
      const router = createRouter(
        buildOneShotRoutes(makeStore(), makeConversations(), chat, captureContextLog().writer, tools)
      );

      const response = await router(post({ question: "who won the 2026 world cup?" }));

      expect(response.status).toBe(200);
      const names = (capturedTools ?? []).map(
        (t) => (t as { function: { name: string } }).function.name
      );
      expect(names).toEqual([WEB_SEARCH, WEB_FETCH]);
    });

    test("executes a requested web_search via the injected toolset and returns the model's final text", async () => {
      let chatCalls = 0;
      const perCallMessages: OneShotChatMessage[][] = [];
      const chat: OneShotChatFn = async (messages) => {
        perCallMessages.push([...messages]);
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
      const { tools, invocations } = fakeMergedToolSet(
        () => "1. Atlantis wins the final\n   https://example.com/final"
      );
      const router = createRouter(
        buildOneShotRoutes(makeStore(), makeConversations(), chat, captureContextLog().writer, tools)
      );

      const response = await router(post({ question: "who won the 2026 world cup?" }));

      expect(response.status).toBe(200);
      const body = (await response.json()) as { result: string; conversationId: number };
      // Response shape unchanged: same `result` + `conversationId` fields,
      // now carrying the loop's final answer.
      expect(body.result).toBe("According to the sources, Atlantis won.");
      expect(typeof body.conversationId).toBe("number");
      expect(chatCalls).toBe(2);
      expect(invocations).toEqual([
        { name: WEB_SEARCH, args: { query: "2026 world cup winner" } },
      ]);

      // The tool's result is fed back as a tool-role message on the second
      // chat call, per OpenAI tool-calling conventions.
      const secondCall = perCallMessages[1] ?? [];
      const toolMessage = secondCall.find((m) => m.role === "tool");
      expect(toolMessage?.content).toContain("Atlantis wins the final");
    });

    test("replays prior turns as real chat history between system and the new question", async () => {
      // Guard, green before and after the rework: the loop's `priorMessages`
      // must preserve today's message-array replay semantics exactly --
      // system first, the stored turns unmodified and in order, the new
      // question last.
      const conversations = makeConversations();
      const existingId = conversations.createConversation("ask", "who is the CEO of Acme?");
      conversations.appendMessage(existingId, "user", "who is the CEO of Acme?");
      conversations.appendMessage(existingId, "assistant", "Jane Doe is the CEO of Acme.");

      let capturedMessages: OneShotChatMessage[] | undefined;
      const chat: OneShotChatFn = async (messages) => {
        capturedMessages = messages;
        return { content: "She has been CEO since 2019." };
      };
      const { tools } = fakeMergedToolSet();
      const router = createRouter(
        buildOneShotRoutes(makeStore(), conversations, chat, captureContextLog().writer, tools)
      );

      await router(post({ question: "since when?", conversationId: existingId }));

      expect(capturedMessages).toHaveLength(4);
      expect(capturedMessages![0]?.role).toBe("system");
      expect(capturedMessages![1]).toMatchObject({
        role: "user",
        content: "who is the CEO of Acme?",
      });
      expect(capturedMessages![2]).toMatchObject({
        role: "assistant",
        content: "Jane Doe is the CEO of Acme.",
      });
      expect(capturedMessages![3]?.role).toBe("user");
      expect(capturedMessages![3]?.content).toContain("since when?");
    });

    test("terminates after the ask-specific cap of 6 iterations when the model keeps requesting tools", async () => {
      let chatCalls = 0;
      const chat: OneShotChatFn = async () => {
        chatCalls += 1;
        return {
          content: null,
          toolCalls: [
            {
              id: `call_${chatCalls}`,
              type: "function",
              function: { name: WEB_SEARCH, arguments: "{}" },
            },
          ],
        };
      };
      const { tools, invocations } = fakeMergedToolSet(() => "yet more results");
      const router = createRouter(
        buildOneShotRoutes(makeStore(), makeConversations(), chat, captureContextLog().writer, tools)
      );

      const response = await router(post({ question: "an endless research question" }));

      // No hang, a well-formed response, and exactly 6 model calls (spec §2:
      // the ask cap is 6, not the agent loop's default 10).
      expect(response.status).toBe(200);
      const body = (await response.json()) as { result: string; conversationId: number };
      expect(chatCalls).toBe(6);
      expect(invocations).toHaveLength(6);
      expect(typeof body.result).toBe("string");
    });
  });
});
