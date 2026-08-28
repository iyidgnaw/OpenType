import { describe, expect, test } from "bun:test";
import { openDatabase } from "../../src/memory/db";
import { ConversationStore } from "../../src/memory/conversations";

/**
 * Pipeline B (docs/superpowers/specs/2026-08-28-skill-agent-ui-and-step-log-persistence.md
 * §2): `ConversationStore.appendMessage` gains a fourth, optional `steps`
 * argument, and `getConversation` deserializes it back out. This is an
 * ASSUMED call shape -- `appendMessage(conversationId, role, content, steps?)`
 * -- chosen as the smallest addition to the existing three-positional-arg
 * signature (see `src/memory/conversations.ts`), consistent with how this
 * codebase adds one new optional field to an existing narrow function (e.g.
 * `buildOneShotRoutes`'s trailing optional `tools` param) rather than always
 * reaching for a trailing options object. If stage 3 picks a different shape
 * (e.g. an options object), only the call sites in this file need to change
 * -- the behavioral assertions below (round-trip, null-when-omitted) are the
 * real coverage and do not depend on which shape wins.
 *
 * `ConversationStore` itself is treated as agnostic to `role` here -- it is
 * simply asked to persist and return back whatever `steps` a caller passes.
 * The actual product invariant "a user message never carries steps" is a
 * property of the CALL SITES (`agent/routes.ts`, `oneshot/routes.ts` never
 * pass steps when appending the user's own task/question), and is covered at
 * that seam instead: see
 * `test/agent/agentRunStepsPersistence.test.ts` and
 * `test/oneshot/askStepsPersistence.test.ts`.
 */

function makeStore(): ConversationStore {
  return new ConversationStore(openDatabase(":memory:"));
}

/**
 * Realistic fixture: the same shape `/agent/run`'s response carries in its
 * `steps` field (`AgentProgressEvent[]` in `src/agent/loop.ts` --
 * `{ type: "thinking" | "tool_call" | "tool_result" | "done" | "error";
 * detail: string }`), copied here as plain objects rather than importing the
 * type, since this memory-layer test only cares about the JSON shape once
 * persisted, not about taking on a compile-time dependency on the agent
 * module.
 */
const SAMPLE_STEPS = [
  { type: "thinking", detail: "Thinking (step 1/10)..." },
  { type: "tool_call", detail: 'Calling opentype__bash({"command":"ls"})' },
  { type: "tool_result", detail: "file1.txt\nfile2.txt" },
  { type: "done", detail: "Found two files." },
];

describe("ConversationStore -- step-log persistence (Pipeline B §2)", () => {
  test("appendMessage accepts an optional steps array and getConversation returns it deserialized", () => {
    const store = makeStore();
    const id = store.createConversation("agent", "list the files");
    store.appendMessage(id, "user", "list the files");
    store.appendMessage(id, "assistant", "Found two files.", SAMPLE_STEPS);

    const conversation = store.getConversation(id);
    const assistantMessage = conversation!.messages.find((m) => m.role === "assistant");
    expect(assistantMessage?.steps).toEqual(SAMPLE_STEPS);
  });

  test("a message appended without a steps argument comes back with steps null or undefined", () => {
    const store = makeStore();
    const id = store.createConversation("ask", "what is 2+2?");
    store.appendMessage(id, "user", "what is 2+2?");
    store.appendMessage(id, "assistant", "4");

    const conversation = store.getConversation(id);
    const assistantMessage = conversation!.messages.find((m) => m.role === "assistant");
    expect(assistantMessage?.steps ?? null).toBeNull();
  });

  test("passing an explicit null steps argument round-trips the same as omitting it", () => {
    const store = makeStore();
    const id = store.createConversation("ask", "what is 2+2?");
    store.appendMessage(id, "assistant", "4", null);

    const conversation = store.getConversation(id);
    expect(conversation!.messages[0]?.steps ?? null).toBeNull();
  });

  test("a user-role message's steps stays null even across multiple appends in the same conversation", () => {
    const store = makeStore();
    const id = store.createConversation("agent", "task one");
    store.appendMessage(id, "user", "task one");
    store.appendMessage(id, "assistant", "done one", SAMPLE_STEPS);
    store.appendMessage(id, "user", "task two");
    store.appendMessage(id, "assistant", "done two", SAMPLE_STEPS);

    const conversation = store.getConversation(id);
    const userMessages = conversation!.messages.filter((m) => m.role === "user");
    const assistantMessages = conversation!.messages.filter((m) => m.role === "assistant");
    expect(userMessages.every((m) => (m.steps ?? null) === null)).toBe(true);
    expect(assistantMessages.every((m) => Array.isArray(m.steps))).toBe(true);
  });

  test("steps survive round-tripping through the underlying JSON column with nested structure intact", () => {
    const store = makeStore();
    const id = store.createConversation("agent", "task");
    store.appendMessage(id, "assistant", "done", SAMPLE_STEPS);

    const reread = store.getConversation(id);
    const steps = reread!.messages[0]?.steps as typeof SAMPLE_STEPS | undefined;
    expect(steps).toHaveLength(SAMPLE_STEPS.length);
    expect(steps?.[1]).toEqual({
      type: "tool_call",
      detail: 'Calling opentype__bash({"command":"ls"})',
    });
  });

  test("an empty steps array round-trips as an empty array, not null", () => {
    const store = makeStore();
    const id = store.createConversation("agent", "task");
    store.appendMessage(id, "assistant", "done", []);

    const conversation = store.getConversation(id);
    expect(conversation!.messages[0]?.steps).toEqual([]);
  });
});
