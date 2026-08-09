import { describe, expect, test } from "bun:test";
import { openDatabase } from "../../src/memory/db";
import { MemoryStore } from "../../src/memory/MemoryStore";
import { ConversationStore } from "../../src/memory/conversations";
import type { OneShotChatFn, OneShotChatMessage } from "../../src/oneshot/client";
import { buildOneShotRoutes } from "../../src/oneshot/routes";
import { createRouter } from "../../src/router";
import type { ContextUsageLogWriter } from "../../src/oneshot/contextDebugLog";

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
});
