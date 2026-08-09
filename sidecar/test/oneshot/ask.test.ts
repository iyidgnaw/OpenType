import { describe, expect, test } from "bun:test";
import { openDatabase } from "../../src/memory/db";
import { MemoryStore } from "../../src/memory/MemoryStore";
import type { OneShotChatFn, OneShotChatMessage } from "../../src/oneshot/client";
import { buildOneShotRoutes } from "../../src/oneshot/routes";
import { createRouter } from "../../src/router";
import type { ContextUsageLogWriter } from "../../src/oneshot/contextDebugLog";

function makeStore(): MemoryStore {
  return new MemoryStore(openDatabase(":memory:"));
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
    const router = createRouter(buildOneShotRoutes(makeStore(), chat, captureContextLog().writer));

    const response = await router(post({ question: "what is 2+2, answer in one word" }));

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ result: "Four." });
    expect(capturedMessages![1].content).toContain("what is 2+2, answer in one word");
  });

  test("no fidelity validation is applied: an answer is returned even though it would fail the translate-style checks", async () => {
    const chat: OneShotChatFn = async () => ({
      content: "这是一个很长的回答，包含中文字符，远远超过原始问题的长度，用于验证 Ask 模式不做保真度校验。",
    });
    const router = createRouter(buildOneShotRoutes(makeStore(), chat, captureContextLog().writer));

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
    const router = createRouter(buildOneShotRoutes(store, chat, captureContextLog().writer));

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
    const router = createRouter(buildOneShotRoutes(store, chat, writer));

    await router(post({ question: "what is the status of Zephyrus?" }));

    expect(lines).toHaveLength(1);
    expect(lines[0]).toContain("[ask]");
    expect(lines[0]).toContain("Zephyrus");
    expect(lines[0]).toContain("what is the status of Zephyrus?");
  });

  test("logs 'no context matched' honestly when the entity dictionary has no match", async () => {
    const chat: OneShotChatFn = async () => ({ content: "answer" });
    const { writer, lines } = captureContextLog();
    const router = createRouter(buildOneShotRoutes(makeStore(), chat, writer));

    await router(post({ question: "what time is it?" }));

    expect(lines).toHaveLength(1);
    expect(lines[0]).toContain("no context matched");
  });
});
