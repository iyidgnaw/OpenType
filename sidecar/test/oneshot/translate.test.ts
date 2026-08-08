import { describe, expect, test } from "bun:test";
import { openDatabase } from "../../src/memory/db";
import { MemoryStore } from "../../src/memory/MemoryStore";
import type { OneShotChatFn } from "../../src/oneshot/client";
import { buildOneShotRoutes } from "../../src/oneshot/routes";
import { createRouter } from "../../src/router";

function makeStore(): MemoryStore {
  return new MemoryStore(openDatabase(":memory:"));
}

function post(body: unknown): Request {
  return new Request("http://sidecar/oneshot/translate", {
    method: "POST",
    body: JSON.stringify(body),
  });
}

describe("POST /oneshot/translate", () => {
  test("happy path: a fidelity-passing translation is returned and the model is called exactly once", async () => {
    let callCount = 0;
    const chat: OneShotChatFn = async () => {
      callCount += 1;
      return { content: "Can you send me the report by tomorrow?" };
    };
    const router = createRouter(buildOneShotRoutes(makeStore(), chat));

    const response = await router(post({ transcript: "你能明天把报告发给我吗？" }));

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({
      result: "Can you send me the report by tomorrow?",
    });
    expect(callCount).toBe(1);
  });

  test("retries once with a stricter prompt when the first attempt leaves Han characters, then succeeds", async () => {
    let callCount = 0;
    const chat: OneShotChatFn = async (messages) => {
      callCount += 1;
      if (callCount === 1) {
        // Leftover 报告 (Han characters) should fail fidelity.
        return { content: "Can you send me the 报告 by tomorrow?" };
      }
      // Second call should use the strict retry addendum.
      expect(messages[0].content).toContain("strict translation only");
      return { content: "Can you send me the report by tomorrow?" };
    };
    const router = createRouter(buildOneShotRoutes(makeStore(), chat));

    const response = await router(post({ transcript: "你能明天把报告发给我吗？" }));

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({
      result: "Can you send me the report by tomorrow?",
    });
    expect(callCount).toBe(2);
  });

  test("returns 422 translation_fidelity_failed when both attempts fail fidelity, calling the model exactly twice", async () => {
    let callCount = 0;
    const chat: OneShotChatFn = async () => {
      callCount += 1;
      // Always leaves Han characters in, so it always fails fidelity.
      return { content: "Can you send me the 报告 by tomorrow?" };
    };
    const router = createRouter(buildOneShotRoutes(makeStore(), chat));

    const response = await router(post({ transcript: "你能明天把报告发给我吗？" }));

    expect(response.status).toBe(422);
    expect(await response.json()).toEqual({ error: "translation_fidelity_failed" });
    expect(callCount).toBe(2);
  });

  test("rejects a candidate that answers a source question instead of translating it", async () => {
    let callCount = 0;
    const chat: OneShotChatFn = async () => {
      callCount += 1;
      // The source asks a question; answering it (not translating it) must fail.
      return { content: "Yes, I will send it tomorrow." };
    };
    const router = createRouter(buildOneShotRoutes(makeStore(), chat));

    const response = await router(post({ transcript: "你能明天把报告发给我吗？" }));

    expect(response.status).toBe(422);
    expect(callCount).toBe(2);
  });

  test("rejects a candidate that executes a request instead of translating it (speech-act drift)", async () => {
    const chat: OneShotChatFn = async () => {
      // "帮我写一封邮件" (help me write an email) must remain a request in
      // English, not become the finished email itself.
      return {
        content: "Dear Sir or Madam, I am writing to inform you of the project status.",
      };
    };
    const router = createRouter(buildOneShotRoutes(makeStore(), chat));

    const response = await router(post({ transcript: "帮我写一封邮件" }));

    expect(response.status).toBe(422);
    expect(await response.json()).toEqual({ error: "translation_fidelity_failed" });
  });

  test("includes matching known memory terms as light context in the prompt", async () => {
    const store = makeStore();
    const now = Date.now();
    store.db.run(
      `INSERT INTO entity_terms
        (canonicalTerm, aliases, category, confidence, origin, sourceEventIds, createdAt, updatedAt, supersedes)
       VALUES ('Zephyrus', '[]', 'project', 0.9, 'owner', '[]', ?, ?, NULL)`,
      [now, now]
    );
    let capturedUserContent = "";
    const chat: OneShotChatFn = async (messages) => {
      capturedUserContent = messages[1].content;
      return { content: "Ship Zephyrus tomorrow." };
    };
    const router = createRouter(buildOneShotRoutes(store, chat));

    await router(post({ transcript: "明天上线 Zephyrus" }));

    expect(capturedUserContent).toContain("Zephyrus");
  });
});
