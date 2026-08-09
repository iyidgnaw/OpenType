import { describe, expect, test } from "bun:test";
import { openDatabase } from "../../src/memory/db";
import { ConversationStore } from "../../src/memory/conversations";
import { buildConversationRoutes } from "../../src/memory/conversationRoutes";
import { createRouter } from "../../src/router";

function makeStore(): ConversationStore {
  return new ConversationStore(openDatabase(":memory:"));
}

describe("GET /conversations", () => {
  test("lists conversations of the requested kind, most-recent-first", async () => {
    const store = makeStore();
    const first = store.createConversation("ask", "first");
    const second = store.createConversation("ask", "second");
    store.db.run(`UPDATE conversations SET updatedAt = 1000 WHERE id = ?`, [first]);
    store.db.run(`UPDATE conversations SET updatedAt = 2000 WHERE id = ?`, [second]);
    store.createConversation("agent", "an agent conversation");

    const router = createRouter(buildConversationRoutes(store));
    const response = await router(
      new Request("http://sidecar/conversations?kind=ask")
    );

    expect(response.status).toBe(200);
    const body = (await response.json()) as { conversations: Array<{ id: number }> };
    expect(body.conversations.map((c) => c.id)).toEqual([second, first]);
  });

  test("returns an empty list for a kind with no conversations", async () => {
    const store = makeStore();
    const router = createRouter(buildConversationRoutes(store));

    const response = await router(
      new Request("http://sidecar/conversations?kind=agent")
    );

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ conversations: [] });
  });

  test("400s when kind is missing or invalid", async () => {
    const store = makeStore();
    const router = createRouter(buildConversationRoutes(store));

    const missing = await router(new Request("http://sidecar/conversations"));
    expect(missing.status).toBe(400);

    const invalid = await router(
      new Request("http://sidecar/conversations?kind=bogus")
    );
    expect(invalid.status).toBe(400);
  });
});

describe("GET /conversations/:id", () => {
  test("returns the full conversation with its ordered messages", async () => {
    const store = makeStore();
    const id = store.createConversation("ask", "what is 2+2?");
    store.appendMessage(id, "user", "what is 2+2?");
    store.appendMessage(id, "assistant", "4");

    const router = createRouter(buildConversationRoutes(store));
    const response = await router(new Request(`http://sidecar/conversations/${id}`));

    expect(response.status).toBe(200);
    const body = (await response.json()) as {
      conversation: { id: number; kind: string; messages: Array<{ role: string; content: string }> };
    };
    expect(body.conversation.id).toBe(id);
    expect(body.conversation.kind).toBe("ask");
    expect(body.conversation.messages).toEqual([
      expect.objectContaining({ role: "user", content: "what is 2+2?" }),
      expect.objectContaining({ role: "assistant", content: "4" }),
    ]);
  });

  test("404s for an unknown conversation id", async () => {
    const store = makeStore();
    const router = createRouter(buildConversationRoutes(store));

    const response = await router(new Request("http://sidecar/conversations/999999"));

    expect(response.status).toBe(404);
  });
});
