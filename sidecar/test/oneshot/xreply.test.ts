import { describe, expect, test } from "bun:test";
import { openDatabase } from "../../src/memory/db";
import { MemoryStore } from "../../src/memory/MemoryStore";
import type { OneShotChatFn, OneShotChatMessage } from "../../src/oneshot/client";
import { buildOneShotRoutes } from "../../src/oneshot/routes";
import { createRouter } from "../../src/router";

function makeStore(): MemoryStore {
  return new MemoryStore(openDatabase(":memory:"));
}

function post(body: unknown): Request {
  return new Request("http://sidecar/oneshot/xreply", {
    method: "POST",
    body: JSON.stringify(body),
  });
}

describe("POST /oneshot/xreply", () => {
  test("happy path with a viewpoint: system prompt carries the contract style rules, user content carries post + viewpoint", async () => {
    let capturedMessages: OneShotChatMessage[] | undefined;
    const chat: OneShotChatFn = async (messages) => {
      capturedMessages = messages;
      return { content: "the interesting part is what happens after adoption, not before" };
    };
    const router = createRouter(buildOneShotRoutes(makeStore(), chat));

    const response = await router(
      post({
        originalPost: "Everyone's excited about AI adoption numbers this year.",
        viewpoint: "the real story is retention after the first month",
      })
    );

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({
      result: "the interesting part is what happens after adoption, not before",
    });

    const systemPrompt = capturedMessages![0].content;
    expect(systemPrompt).toMatch(/hashtags/i);
    expect(systemPrompt).toMatch(/emoji/i);
    expect(systemPrompt).toMatch(/em dashes/i);
    expect(systemPrompt).toMatch(/engagement bait/i);

    const userContent = capturedMessages![1].content;
    expect(userContent).toContain("Everyone's excited about AI adoption numbers this year.");
    expect(userContent).toContain("the real story is retention after the first month");
  });

  test("null viewpoint: still produces exactly one reply, prompt asks the model to find its own angle", async () => {
    let capturedMessages: OneShotChatMessage[] | undefined;
    const chat: OneShotChatFn = async (messages) => {
      capturedMessages = messages;
      return { content: "curious how this holds up once the free trial ends" };
    };
    const router = createRouter(buildOneShotRoutes(makeStore(), chat));

    const response = await router(
      post({ originalPost: "Everyone's excited about AI adoption numbers this year.", viewpoint: null })
    );

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({
      result: "curious how this holds up once the free trial ends",
    });

    const userContent = capturedMessages![1].content;
    expect(userContent.toLowerCase()).toContain("no spoken viewpoint");
  });

  test("empty-string viewpoint is treated the same as null", async () => {
    let capturedMessages: OneShotChatMessage[] | undefined;
    const chat: OneShotChatFn = async (messages) => {
      capturedMessages = messages;
      return { content: "one reply" };
    };
    const router = createRouter(buildOneShotRoutes(makeStore(), chat));

    await router(post({ originalPost: "some post", viewpoint: "   " }));

    const userContent = capturedMessages![1].content;
    expect(userContent.toLowerCase()).toContain("no spoken viewpoint");
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
      return { content: "reply" };
    };
    const router = createRouter(buildOneShotRoutes(store, chat));

    await router(post({ originalPost: "Shipping Zephyrus next week", viewpoint: null }));

    expect(capturedMessages![1].content).toContain("Zephyrus");
  });
});
