import { describe, expect, test } from "bun:test";
import { openDatabase } from "../../src/memory/db";
import { MemoryStore } from "../../src/memory/MemoryStore";
import type { OneShotChatFn, OneShotChatMessage } from "../../src/oneshot/client";
import { buildOneShotRoutes } from "../../src/oneshot/routes";
import { createRouter } from "../../src/router";

function makeStore(): MemoryStore {
  return new MemoryStore(openDatabase(":memory:"));
}

function insertTerm(store: MemoryStore, canonicalTerm: string): void {
  const now = Date.now();
  store.db.run(
    `INSERT INTO entity_terms
      (canonicalTerm, aliases, category, confidence, origin, sourceEventIds, createdAt, updatedAt, supersedes)
     VALUES (?, '[]', 'project', 0.9, 'owner', '[]', ?, ?, NULL)`,
    [canonicalTerm, now, now]
  );
}

function post(body: unknown): Request {
  return new Request("http://sidecar/oneshot/polish", {
    method: "POST",
    body: JSON.stringify(body),
  });
}

describe("POST /oneshot/polish", () => {
  test("happy path: calls the model with the selected text and instruction clearly labeled, returns its result", async () => {
    let capturedMessages: OneShotChatMessage[] | undefined;
    const chat: OneShotChatFn = async (messages) => {
      capturedMessages = messages;
      return { content: "Dear team, please review the attached report." };
    };
    const router = createRouter(buildOneShotRoutes(makeStore(), chat));

    const response = await router(
      post({ selectedText: "hey guys check this report", instruction: "make it sound formal" })
    );

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({
      result: "Dear team, please review the attached report.",
    });

    expect(capturedMessages).toBeDefined();
    expect(capturedMessages![0].role).toBe("system");
    const userMessage = capturedMessages![1].content;
    expect(userMessage).toContain("hey guys check this report");
    expect(userMessage).toContain("make it sound formal");
    // Selection and instruction must be labeled as separate fields, not
    // concatenated ambiguously, so the model can't confuse one for the other.
    expect(userMessage).toMatch(/SELECTED TEXT/i);
    expect(userMessage).toMatch(/INSTRUCTION/i);
  });

  test("missing instruction returns 422 without ever calling the model", async () => {
    let called = false;
    const chat: OneShotChatFn = async () => {
      called = true;
      return { content: "should not happen" };
    };
    const router = createRouter(buildOneShotRoutes(makeStore(), chat));

    const response = await router(post({ selectedText: "some text", instruction: "" }));

    expect(response.status).toBe(422);
    expect(await response.json()).toEqual({ error: "missing_instruction" });
    expect(called).toBe(false);
  });

  test("whitespace-only instruction also short-circuits with 422", async () => {
    let called = false;
    const chat: OneShotChatFn = async () => {
      called = true;
      return { content: "should not happen" };
    };
    const router = createRouter(buildOneShotRoutes(makeStore(), chat));

    const response = await router(post({ selectedText: "some text", instruction: "   \n\t " }));

    expect(response.status).toBe(422);
    expect(await response.json()).toEqual({ error: "missing_instruction" });
    expect(called).toBe(false);
  });

  test("includes matching known memory terms as light context", async () => {
    const store = makeStore();
    insertTerm(store, "Zephyrus");
    let capturedMessages: OneShotChatMessage[] | undefined;
    const chat: OneShotChatFn = async (messages) => {
      capturedMessages = messages;
      return { content: "ok" };
    };
    const router = createRouter(buildOneShotRoutes(store, chat));

    await router(post({ selectedText: "working on Zephyrus today", instruction: "shorten it" }));

    expect(capturedMessages![1].content).toContain("Zephyrus");
  });
});
