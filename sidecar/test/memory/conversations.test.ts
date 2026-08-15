import { describe, expect, test } from "bun:test";
import { openDatabase } from "../../src/memory/db";
import { ConversationStore } from "../../src/memory/conversations";

function makeStore(): ConversationStore {
  return new ConversationStore(openDatabase(":memory:"));
}

/** Directly rewrites a conversation's createdAt/updatedAt for order-sensitive
 * tests, the same "reach into the raw db to control time" pattern
 * `consolidator.test.ts` uses for `ranAt`. */
function setTimestamps(
  store: ConversationStore,
  conversationId: number,
  createdAt: number,
  updatedAt: number
): void {
  store.db.run(`UPDATE conversations SET createdAt = ?, updatedAt = ? WHERE id = ?`, [
    createdAt,
    updatedAt,
    conversationId,
  ]);
}

describe("ConversationStore", () => {
  describe("createConversation", () => {
    test("creates a conversation of the given kind and returns its id", () => {
      const store = makeStore();
      const id = store.createConversation("ask", "what is the weather today?");
      expect(typeof id).toBe("number");

      const conversation = store.getConversation(id);
      expect(conversation).not.toBeNull();
      expect(conversation!.kind).toBe("ask");
    });

    test("auto-titles from the first ~40 characters of the seed message", () => {
      const store = makeStore();
      const id = store.createConversation("ask", "short question");
      const conversation = store.getConversation(id);
      expect(conversation!.title).toBe("short question");
    });

    test("ellipsizes titles longer than 40 characters", () => {
      const store = makeStore();
      const longMessage =
        "this is a very long first message that definitely exceeds forty characters in length";
      const id = store.createConversation("ask", longMessage);
      const conversation = store.getConversation(id);
      expect(conversation!.title.length).toBeLessThanOrEqual(41); // 40 chars + ellipsis
      expect(conversation!.title.endsWith("…")).toBe(true);
      expect(longMessage.startsWith(conversation!.title.slice(0, -1))).toBe(true);
    });

    test("supports the 'agent' kind as well", () => {
      const store = makeStore();
      const id = store.createConversation("agent", "summarize my notes");
      const conversation = store.getConversation(id);
      expect(conversation!.kind).toBe("agent");
    });
  });

  describe("appendMessage", () => {
    test("appends a message and it shows up in the conversation's message list", () => {
      const store = makeStore();
      const id = store.createConversation("ask", "what is 2+2?");
      store.appendMessage(id, "user", "what is 2+2?");
      store.appendMessage(id, "assistant", "4");

      const conversation = store.getConversation(id);
      expect(conversation!.messages).toHaveLength(2);
      expect(conversation!.messages[0]).toMatchObject({ role: "user", content: "what is 2+2?" });
      expect(conversation!.messages[1]).toMatchObject({ role: "assistant", content: "4" });
    });

    test("messages come back in chronological (insertion) order", () => {
      const store = makeStore();
      const id = store.createConversation("ask", "first");
      store.appendMessage(id, "user", "first");
      store.appendMessage(id, "assistant", "second");
      store.appendMessage(id, "user", "third");

      const conversation = store.getConversation(id);
      expect(conversation!.messages.map((m) => m.content)).toEqual([
        "first",
        "second",
        "third",
      ]);
    });

    test("bumps the conversation's updatedAt to no earlier than before the append", () => {
      const store = makeStore();
      const id = store.createConversation("ask", "hello");
      setTimestamps(store, id, 1_000, 1_000);
      store.appendMessage(id, "user", "hello");
      const after = store.getConversation(id)!.updatedAt;
      expect(after).toBeGreaterThan(1_000);
    });
  });

  describe("listConversations", () => {
    test("lists conversations of a given kind, most-recent-first by updatedAt", () => {
      const store = makeStore();
      const first = store.createConversation("ask", "first conversation");
      const second = store.createConversation("ask", "second conversation");
      setTimestamps(store, first, 1_000, 1_000);
      setTimestamps(store, second, 2_000, 2_000);

      const list = store.listConversations("ask");
      expect(list.map((c) => c.id)).toEqual([second, first]);
    });

    test("only returns conversations of the requested kind", () => {
      const store = makeStore();
      const askId = store.createConversation("ask", "an ask conversation");
      store.createConversation("agent", "an agent conversation");

      const list = store.listConversations("ask");
      expect(list).toHaveLength(1);
      expect(list[0]?.id).toBe(askId);
    });

    test("returns an empty list when there are no conversations of that kind", () => {
      const store = makeStore();
      expect(store.listConversations("agent")).toEqual([]);
    });

    test("reflects appendMessage bumping updatedAt in the ordering", () => {
      const store = makeStore();
      const first = store.createConversation("ask", "first");
      const second = store.createConversation("ask", "second");
      setTimestamps(store, first, 1_000, 1_000);
      setTimestamps(store, second, 2_000, 2_000);
      // Touch `first` after `second` was created so it should now sort ahead.
      setTimestamps(store, first, 1_000, 3_000);

      const list = store.listConversations("ask");
      expect(list.map((c) => c.id)).toEqual([first, second]);
    });
  });

  describe("getConversation", () => {
    test("returns null for an unknown id", () => {
      const store = makeStore();
      expect(store.getConversation(999_999)).toBeNull();
    });

    test("returns the full conversation with its ordered message list", () => {
      const store = makeStore();
      const id = store.createConversation("agent", "summarize my notes");
      store.appendMessage(id, "user", "summarize my notes");
      store.appendMessage(id, "assistant", "done");

      const conversation = store.getConversation(id);
      expect(conversation).toMatchObject({
        id,
        kind: "agent",
        messages: [
          { role: "user", content: "summarize my notes" },
          { role: "assistant", content: "done" },
        ],
      });
    });
  });

  describe("deleteConversation", () => {
    test("deletes the conversation and returns true", () => {
      const store = makeStore();
      const id = store.createConversation("ask", "delete me");

      expect(store.deleteConversation(id)).toBe(true);
      expect(store.getConversation(id)).toBeNull();
    });

    test("returns false for an unknown id, leaving nothing to delete", () => {
      const store = makeStore();
      expect(store.deleteConversation(999_999)).toBe(false);
    });

    test("deletes the conversation's messages along with it", () => {
      const store = makeStore();
      const id = store.createConversation("ask", "what is 2+2?");
      store.appendMessage(id, "user", "what is 2+2?");
      store.appendMessage(id, "assistant", "4");

      store.deleteConversation(id);

      // Reach past the store's own read API (which already 404s on a missing
      // conversation) to confirm the messages row itself is gone, not just
      // unreachable through getConversation -- an orphaned row would still be
      // sitting in conversation_messages, invisible to the UI but still on
      // disk, which is exactly the bug a schema without ON DELETE enforcement
      // (bun:sqlite's `foreign_keys` pragma defaults off) would produce.
      const orphans = store.db
        .query("SELECT * FROM conversation_messages WHERE conversationId = ?")
        .all(id);
      expect(orphans).toEqual([]);
    });

    test("leaves other conversations and their messages untouched", () => {
      const store = makeStore();
      const keep = store.createConversation("ask", "keep me");
      store.appendMessage(keep, "user", "keep me");
      store.appendMessage(keep, "assistant", "kept");
      const doomed = store.createConversation("agent", "delete me");
      store.appendMessage(doomed, "user", "delete me");

      store.deleteConversation(doomed);

      const kept = store.getConversation(keep);
      expect(kept).not.toBeNull();
      expect(kept!.messages).toHaveLength(2);
    });

    test("does not touch unrelated tables (entity_terms, owner_facts)", () => {
      const store = makeStore();
      const id = store.createConversation("ask", "delete me");
      const now = Date.now();
      store.db.run(
        `INSERT INTO entity_terms (canonicalTerm, aliases, category, confidence, origin, sourceEventIds, createdAt, updatedAt)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
        ["Diyi", "[]", "person", 1.0, "owner", "[]", now, now]
      );
      store.db.run(
        `INSERT INTO owner_facts (content, createdAt, origin) VALUES (?, ?, ?)`,
        ["likes tea", now, "owner"]
      );

      store.deleteConversation(id);

      expect(store.db.query("SELECT * FROM entity_terms").all()).toHaveLength(1);
      expect(store.db.query("SELECT * FROM owner_facts").all()).toHaveLength(1);
    });
  });
});
