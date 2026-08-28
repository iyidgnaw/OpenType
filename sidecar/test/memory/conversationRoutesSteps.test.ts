import { describe, expect, test } from "bun:test";
import { openDatabase } from "../../src/memory/db";
import { ConversationStore } from "../../src/memory/conversations";
import { buildConversationRoutes } from "../../src/memory/conversationRoutes";
import { createRouter } from "../../src/router";

/**
 * Pipeline B (docs/superpowers/specs/2026-08-28-skill-agent-ui-and-step-log-persistence.md
 * §2): `GET /conversations/:id`'s messages must include the persisted
 * `steps` field -- present for a message that has them, absent/null
 * otherwise. This is the read side; the write side (agent/ask routes
 * actually populating `steps` on the assistant message) is covered in
 * `test/agent/agentRunStepsPersistence.test.ts` and
 * `test/oneshot/askStepsPersistence.test.ts`. Here the store is asked
 * directly to persist steps (via `ConversationStore.appendMessage`'s assumed
 * fourth argument -- see `test/memory/conversationsSteps.test.ts`'s header
 * comment for that assumption), isolating this file to just the route's
 * serialization of whatever the store already returns.
 */

function makeStore(): ConversationStore {
  return new ConversationStore(openDatabase(":memory:"));
}

const SAMPLE_STEPS = [
  { type: "tool_call", detail: "Calling opentype__web_search({...})" },
  { type: "tool_result", detail: "1. Atlantis wins the final" },
  { type: "done", detail: "Here is the answer." },
];

describe("GET /conversations/:id -- steps field (Pipeline B §2)", () => {
  test("an assistant message with steps includes them, deserialized, in the response", async () => {
    const store = makeStore();
    const id = store.createConversation("agent", "search something");
    store.appendMessage(id, "user", "search something");
    store.appendMessage(id, "assistant", "Here is the answer.", SAMPLE_STEPS);

    const router = createRouter(buildConversationRoutes(store));
    const response = await router(new Request(`http://sidecar/conversations/${id}`));

    expect(response.status).toBe(200);
    const body = (await response.json()) as {
      conversation: { messages: Array<{ role: string; content: string; steps?: unknown }> };
    };
    const assistantMessage = body.conversation.messages.find((m) => m.role === "assistant");
    expect(assistantMessage?.steps).toEqual(SAMPLE_STEPS);
  });

  test("a message with no steps has steps absent or null in the response -- true for both roles", async () => {
    const store = makeStore();
    const id = store.createConversation("ask", "what is 2+2?");
    store.appendMessage(id, "user", "what is 2+2?");
    store.appendMessage(id, "assistant", "4");

    const router = createRouter(buildConversationRoutes(store));
    const response = await router(new Request(`http://sidecar/conversations/${id}`));
    const body = (await response.json()) as {
      conversation: { messages: Array<{ role: string; steps?: unknown }> };
    };

    expect(body.conversation.messages).toHaveLength(2);
    for (const message of body.conversation.messages) {
      expect(message.steps ?? null).toBeNull();
    }
  });

  test("in a thread mixing both, only the assistant message with steps carries them", async () => {
    const store = makeStore();
    const id = store.createConversation("agent", "task one");
    store.appendMessage(id, "user", "task one");
    store.appendMessage(id, "assistant", "done one", SAMPLE_STEPS);
    store.appendMessage(id, "user", "task two");
    store.appendMessage(id, "assistant", "done two");

    const router = createRouter(buildConversationRoutes(store));
    const response = await router(new Request(`http://sidecar/conversations/${id}`));
    const body = (await response.json()) as {
      conversation: { messages: Array<{ role: string; content: string; steps?: unknown }> };
    };

    const withSteps = body.conversation.messages.find((m) => m.content === "done one");
    const withoutSteps = body.conversation.messages.find((m) => m.content === "done two");
    expect(withSteps?.steps).toEqual(SAMPLE_STEPS);
    expect(withoutSteps?.steps ?? null).toBeNull();
  });
});
