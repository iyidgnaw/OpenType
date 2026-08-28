import { describe, expect, test } from "bun:test";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { openDatabase } from "../../src/memory/db";
import { MemoryStore } from "../../src/memory/MemoryStore";
import { ConversationStore } from "../../src/memory/conversations";
import type { AgentChatFn, AgentChatMessage } from "../../src/agent/loop";
import type { McpToolSet } from "../../src/agent/mcpClient";
import { buildAgentRoutes } from "../../src/agent/routes";
import { createRouter } from "../../src/router";
import type { ContextUsageLogWriter } from "../../src/oneshot/contextDebugLog";
import { AGENT_SYSTEM_PROMPT } from "../../src/oneshot/prompts";
import type { AgentDefinition } from "../../src/agent/agentDefinitions";

function makeStore(): MemoryStore {
  return new MemoryStore(openDatabase(":memory:"));
}

function makeConversations(): ConversationStore {
  return new ConversationStore(openDatabase(":memory:"));
}

function noTools(): McpToolSet {
  return { openAiTools: [], callTool: async () => ({ content: "" }) };
}

function post(body: unknown): Request {
  return new Request("http://sidecar/agent/run", {
    method: "POST",
    body: JSON.stringify(body),
  });
}

function getProgress(runId: string): Request {
  return new Request(`http://sidecar/agent/progress/${runId}`, { method: "GET" });
}

function captureContextLog(): { writer: ContextUsageLogWriter; lines: string[] } {
  const lines: string[] = [];
  return { writer: (line) => lines.push(line), lines };
}

describe("POST /agent/run", () => {
  test("happy path: runs the loop and returns result + steps", async () => {
    const chat: AgentChatFn = async () => ({ content: "The capital of France is Paris." });
    const store = makeStore();
    const router = createRouter(buildAgentRoutes(store, makeConversations(), chat, noTools(), captureContextLog().writer));

    const response = await router(
      post({ task: "What is the capital of France?", context: "some selected text" })
    );

    expect(response.status).toBe(200);
    const body = (await response.json()) as { result: string; steps: unknown[] };
    expect(body.result).toBe("The capital of France is Paris.");
    expect(Array.isArray(body.steps)).toBe(true);
    expect(body.steps.length).toBeGreaterThan(0);
  });

  // The two tests that used to live here ("records an episodic event with
  // origin 'agent' after running", "records selectedContext as null when no
  // context is provided") pinned `/agent/run`'s direct
  // `store.recordEpisodicEvent({...})` write -- removed by plan Task 3
  // (design §3.2): writing moved to the single `POST /memory/events`
  // endpoint that Swift calls at delivery time, so `/agent/run` no longer
  // touches `episodic_events` at all (see
  // `test/memory/episodicWiring.test.ts`'s "an agent run through the
  // assembled app leaves episodic_events empty"). The field-mapping rules
  // those two tests pinned (rawTranscript/correctedTranscript/effectiveInput
  // all equal to `task`, selectedContext equal to `context` or null when
  // omitted, origin "agent") moved to
  // `test/memory/routes.test.ts`'s "every field the caller sends round-trips
  // independently, including non-null effectiveInput and selectedContext".

  test("passes the connected tools' openAiTools through to the chat call", async () => {
    let capturedTools: unknown;
    const chat: AgentChatFn = async (_messages: AgentChatMessage[], options) => {
      capturedTools = options?.tools;
      return { content: "ok" };
    };
    const tools: McpToolSet = {
      openAiTools: [{ type: "function", function: { name: "server__tool" } }],
      callTool: async () => ({ content: "" }),
    };
    const store = makeStore();
    const router = createRouter(buildAgentRoutes(store, makeConversations(), chat, tools, captureContextLog().writer));

    await router(post({ task: "use a tool" }));

    // The connected tool still reaches the model unchanged. It is no longer
    // the WHOLE list: since T5 the agent also carries `opentype__ask_user`,
    // which is built per run and merged in here. That tool stays visible even
    // when a run has no way to ask (it then refuses immediately), so the tool
    // catalog does not change shape between requests and the reusable prompt
    // prefix stays stable.
    expect(capturedTools).toContainEqual({
      type: "function",
      function: { name: "server__tool" },
    });
    const names = (capturedTools as { function: { name: string } }[]).map(
      (tool) => tool.function.name
    );
    expect(names).toContain("opentype__ask_user");
  });

  test("logs context usage and injects matched known terms into the loop's prompt", async () => {
    const store = makeStore();
    const now = Date.now();
    store.db.run(
      `INSERT INTO entity_terms
        (canonicalTerm, aliases, category, confidence, origin, sourceEventIds, createdAt, updatedAt, supersedes)
       VALUES ('Zephyrus', '[]', 'project', 0.9, 'owner', '[]', ?, ?, NULL)`,
      [now, now]
    );
    let capturedMessages: AgentChatMessage[] | undefined;
    const chat: AgentChatFn = async (messages) => {
      capturedMessages = messages;
      return { content: "done" };
    };
    const { writer, lines } = captureContextLog();
    const router = createRouter(buildAgentRoutes(store, makeConversations(), chat, noTools(), writer));

    await router(post({ task: "give me an update on Zephyrus" }));

    expect(lines).toHaveLength(1);
    expect(lines[0]).toContain("[agent]");
    expect(lines[0]).toContain("Zephyrus");
    expect(capturedMessages![1].content).toContain("Zephyrus");
  });

  test("logs 'no context matched' honestly when the entity dictionary has no match", async () => {
    const chat: AgentChatFn = async () => ({ content: "done" });
    const { writer, lines } = captureContextLog();
    const router = createRouter(buildAgentRoutes(makeStore(), makeConversations(), chat, noTools(), writer));

    await router(post({ task: "just a task" }));

    expect(lines).toHaveLength(1);
    expect(lines[0]).toContain("no context matched");
  });

  test("includes all owner facts as context, and logs how many were included", async () => {
    const store = makeStore();
    store.recordOwnerFact("The owner's name is Diyi.");
    let capturedMessages: AgentChatMessage[] | undefined;
    const chat: AgentChatFn = async (messages) => {
      capturedMessages = messages;
      return { content: "done" };
    };
    const { writer, lines } = captureContextLog();
    const router = createRouter(buildAgentRoutes(store, makeConversations(), chat, noTools(), writer));

    await router(post({ task: "what is my name?" }));

    expect(capturedMessages![1].content).toContain("Diyi");
    expect(lines).toHaveLength(1);
    expect(lines[0]).toContain("1 owner fact(s) included");
  });

  test("logs 'no owner facts' honestly when none are recorded", async () => {
    const chat: AgentChatFn = async () => ({ content: "done" });
    const { writer, lines } = captureContextLog();
    const router = createRouter(buildAgentRoutes(makeStore(), makeConversations(), chat, noTools(), writer));

    await router(post({ task: "just a task" }));

    expect(lines[0]).toContain("no owner facts");
  });

  describe("conversation continuation", () => {
    test("without a conversationId, starts a new 'agent' conversation and returns its id", async () => {
      const conversations = makeConversations();
      const chat: AgentChatFn = async () => ({ content: "The capital of France is Paris." });
      const router = createRouter(
        buildAgentRoutes(makeStore(), conversations, chat, noTools(), captureContextLog().writer)
      );

      const response = await router(post({ task: "What is the capital of France?" }));

      expect(response.status).toBe(200);
      const body = (await response.json()) as { result: string; conversationId: number };
      expect(typeof body.conversationId).toBe("number");

      const conversation = conversations.getConversation(body.conversationId);
      expect(conversation?.kind).toBe("agent");
      expect(conversation?.messages).toEqual([
        expect.objectContaining({ role: "user", content: "What is the capital of France?" }),
        expect.objectContaining({ role: "assistant", content: "The capital of France is Paris." }),
      ]);
    });

    test("with a conversationId, appends to the existing conversation instead of creating a new one", async () => {
      const conversations = makeConversations();
      const existingId = conversations.createConversation("agent", "summarize my notes");
      conversations.appendMessage(existingId, "user", "summarize my notes");
      conversations.appendMessage(existingId, "assistant", "Here is a summary: ...");

      const chat: AgentChatFn = async () => ({ content: "Added the follow-up point." });
      const router = createRouter(
        buildAgentRoutes(makeStore(), conversations, chat, noTools(), captureContextLog().writer)
      );

      const response = await router(
        post({ task: "also mention the deadline", conversationId: existingId })
      );

      const body = (await response.json()) as { conversationId: number };
      expect(body.conversationId).toBe(existingId);

      const conversation = conversations.getConversation(existingId);
      expect(conversation?.messages).toHaveLength(4);
      expect(conversation?.messages[2]).toMatchObject({
        role: "user",
        content: "also mention the deadline",
      });
      expect(conversation?.messages[3]).toMatchObject({
        role: "assistant",
        content: "Added the follow-up point.",
      });
    });

    test("feeds a summary of the prior turn into the loop's prompt so the model has continuity", async () => {
      const conversations = makeConversations();
      const existingId = conversations.createConversation("agent", "summarize my notes");
      conversations.appendMessage(existingId, "user", "summarize my notes");
      conversations.appendMessage(existingId, "assistant", "Here is a summary: the project is on track.");

      let capturedMessages: AgentChatMessage[] | undefined;
      const chat: AgentChatFn = async (messages) => {
        capturedMessages = messages;
        return { content: "done" };
      };
      const router = createRouter(
        buildAgentRoutes(makeStore(), conversations, chat, noTools(), captureContextLog().writer)
      );

      await router(post({ task: "also mention the deadline", conversationId: existingId }));

      const userContent = capturedMessages!.find((m) => m.role === "user")?.content ?? "";
      expect(userContent).toContain("summarize my notes");
      expect(userContent).toContain("Here is a summary: the project is on track.");
      expect(userContent).toContain("also mention the deadline");
    });

    test("falls back to starting a new conversation when the given conversationId does not exist", async () => {
      const conversations = makeConversations();
      const chat: AgentChatFn = async () => ({ content: "done" });
      const router = createRouter(
        buildAgentRoutes(makeStore(), conversations, chat, noTools(), captureContextLog().writer)
      );

      const response = await router(post({ task: "just a task", conversationId: 999_999 }));

      expect(response.status).toBe(200);
      const body = (await response.json()) as { conversationId: number };
      expect(body.conversationId).not.toBe(999_999);
      expect(conversations.getConversation(body.conversationId)).not.toBeNull();
    });
  });
});

/**
 * Stage-1 TDD (red) for the agent progress panel's sidecar half
 * (spec: docs/superpowers/specs/2026-08-13-agent-progress-panel-design.md §2).
 *
 * Contract picks (stage 3 implements these exactly):
 * - `POST /agent/run` accepts an optional client-generated `runId` string in
 *   the body. When present, the handler registers the run in the progress
 *   registry, wires `runAgentLoop`'s `onProgress` hook to append events, and
 *   marks the run done/failed when the loop resolves/throws. When absent,
 *   behavior and response shape are exactly as before and nothing is
 *   registered.
 * - New `GET /agent/progress/:runId` returns 200 with `{ status, events }`;
 *   an unknown id returns 200 with `{ status: "unknown", events: [] }` (not
 *   a 404 -- an unknown id is "nothing to show", not an error).
 * - The registry is owned inside `buildAgentRoutes` (its signature is
 *   unchanged), shared between the two routes; these tests drive it purely
 *   over HTTP through the router.
 * - Progress events are the DISPLAY feed: per-event detail is truncated
 *   (~400 chars + marker). The blocking `/agent/run` response's `steps`
 *   stays the untruncated durable log.
 *
 * Note for the red state: `GET /agent/progress/...` currently falls through
 * the router to `404 { error: "not_found" }`, so the `expect(200)` /
 * body-shape assertions below fail for the right reason (the endpoint does
 * not exist yet) rather than passing accidentally.
 */
describe("agent progress (runId + GET /agent/progress/:runId)", () => {
  interface ProgressBody {
    status: string;
    events: Array<{ type: string; detail: string }>;
  }

  /** Fake chat: first call requests one tool call, second call answers. */
  function oneToolThenAnswerChat(finalAnswer: string): AgentChatFn {
    let calls = 0;
    return async () => {
      calls += 1;
      if (calls === 1) {
        return {
          content: null,
          toolCalls: [
            {
              id: "call_1",
              type: "function",
              function: { name: "search__lookup", arguments: '{"query":"weather"}' },
            },
          ],
        };
      }
      return { content: finalAnswer };
    };
  }

  test("run with runId: after the run resolves, progress reports done with ordered events", async () => {
    const longToolResult = "R".repeat(1000);
    const tools: McpToolSet = {
      openAiTools: [{ type: "function", function: { name: "search__lookup" } }],
      callTool: async () => ({ content: longToolResult }),
    };
    const router = createRouter(
      buildAgentRoutes(
        makeStore(),
        makeConversations(),
        oneToolThenAnswerChat("It is sunny."),
        tools,
        captureContextLog().writer
      )
    );

    const runResponse = await router(post({ task: "What's the weather?", runId: "run-abc" }));

    // The blocking response is unchanged by runId: same three fields, and
    // `steps` stays the untruncated durable log.
    expect(runResponse.status).toBe(200);
    const runBody = (await runResponse.json()) as {
      result: string;
      steps: Array<{ type: string; detail: string }>;
      conversationId: number;
    };
    expect(Object.keys(runBody).sort()).toEqual(["conversationId", "result", "steps"]);
    expect(runBody.result).toBe("It is sunny.");
    const durableToolResult = runBody.steps.find((s) => s.type === "tool_result");
    expect(durableToolResult?.detail).toBe(longToolResult);

    const progressResponse = await router(getProgress("run-abc"));
    expect(progressResponse.status).toBe(200);
    const progress = (await progressResponse.json()) as ProgressBody;
    expect(progress.status).toBe("done");

    // At least one thinking, tool_call, tool_result, and done -- in order.
    const types = progress.events.map((e) => e.type);
    const firstThinking = types.indexOf("thinking");
    const firstToolCall = types.indexOf("tool_call");
    const firstToolResult = types.indexOf("tool_result");
    const firstDone = types.indexOf("done");
    expect(firstThinking).toBeGreaterThanOrEqual(0);
    expect(firstToolCall).toBeGreaterThan(firstThinking);
    expect(firstToolResult).toBeGreaterThan(firstToolCall);
    expect(firstDone).toBeGreaterThan(firstToolResult);

    // The progress feed's copy of the tool result is display-truncated.
    const progressToolResult = progress.events.find((e) => e.type === "tool_result");
    expect((progressToolResult?.detail ?? "").length).toBeLessThanOrEqual(450);
    expect(progressToolResult?.detail).toContain("truncated");
  });

  test("while the run is in flight, progress reports 'running' with the events so far", async () => {
    let releaseTool!: () => void;
    const toolGate = new Promise<void>((resolve) => {
      releaseTool = resolve;
    });
    let signalToolStarted!: () => void;
    const toolStarted = new Promise<void>((resolve) => {
      signalToolStarted = resolve;
    });
    const tools: McpToolSet = {
      openAiTools: [{ type: "function", function: { name: "search__lookup" } }],
      callTool: async () => {
        signalToolStarted();
        await toolGate;
        return { content: "sunny, 75F" };
      },
    };
    const router = createRouter(
      buildAgentRoutes(
        makeStore(),
        makeConversations(),
        oneToolThenAnswerChat("It is sunny."),
        tools,
        captureContextLog().writer
      )
    );

    const runPromise = router(post({ task: "What's the weather?", runId: "run-mid" }));
    try {
      await toolStarted;

      const progressResponse = await router(getProgress("run-mid"));
      expect(progressResponse.status).toBe(200);
      const progress = (await progressResponse.json()) as ProgressBody;
      expect(progress.status).toBe("running");
      const types = progress.events.map((e) => e.type);
      expect(types).toContain("thinking");
      expect(types).toContain("tool_call");
      expect(types).not.toContain("done");
    } finally {
      releaseTool();
      await runPromise.catch(() => {});
    }

    const finalResponse = await router(getProgress("run-mid"));
    const final = (await finalResponse.json()) as ProgressBody;
    expect(final.status).toBe("done");
  });

  test("a failing run with a runId is reported as 'failed'", async () => {
    const chat: AgentChatFn = async () => {
      throw new Error("provider exploded");
    };
    const router = createRouter(
      buildAgentRoutes(makeStore(), makeConversations(), chat, noTools(), captureContextLog().writer)
    );

    const runResponse = await router(post({ task: "doomed task", runId: "run-fail" }));
    expect(runResponse.status).toBe(500);

    const progressResponse = await router(getProgress("run-fail"));
    expect(progressResponse.status).toBe(200);
    const progress = (await progressResponse.json()) as ProgressBody;
    expect(progress.status).toBe("failed");
  });

  test("run WITHOUT runId: response unchanged and nothing registered", async () => {
    const chat: AgentChatFn = async () => ({ content: "done" });
    const router = createRouter(
      buildAgentRoutes(makeStore(), makeConversations(), chat, noTools(), captureContextLog().writer)
    );

    const runResponse = await router(post({ task: "plain task" }));
    expect(runResponse.status).toBe(200);
    const runBody = (await runResponse.json()) as Record<string, unknown>;
    expect(Object.keys(runBody).sort()).toEqual(["conversationId", "result", "steps"]);

    // No runId was sent, so no run was registered under any id.
    const progressResponse = await router(getProgress("some-id-nobody-registered"));
    expect(progressResponse.status).toBe(200);
    expect((await progressResponse.json()) as ProgressBody).toEqual({
      status: "unknown",
      events: [],
    });
  });

  test("GET /agent/progress/nonexistent returns 200 with { status: 'unknown', events: [] }", async () => {
    const chat: AgentChatFn = async () => ({ content: "done" });
    const router = createRouter(
      buildAgentRoutes(makeStore(), makeConversations(), chat, noTools(), captureContextLog().writer)
    );

    const response = await router(getProgress("nonexistent"));

    expect(response.status).toBe(200);
    expect((await response.json()) as ProgressBody).toEqual({ status: "unknown", events: [] });
  });
});

/**
 * Task 10 (design §3.5): the last `RECENT_ACTIVITY_LIMIT` episodic events,
 * across ALL THREE modes (no excluded mode --
 * `RECENT_ACTIVITY_EXCLUDED_MODES` is empty on purpose, spec §六), rendered
 * by `buildRecentActivityContext` and injected into the loop's final user
 * message. Agent gets `includeIds: true` -- unlike ask, it carries
 * `opentype__read_history` (registered in `agent/coreTools.ts`), so it can
 * expand any `eventId`/`conversationId` it sees here.
 */
describe("recent activity injection (Task 10, design §3.5)", () => {
  test("injects recent activity into the user message, with eventId present", async () => {
    const store = makeStore();
    store.recordEpisodicEvent({
      mode: "transcribe",
      rawTranscript: "明天去深圳",
      correctedTranscript: "明天去深圳",
      effectiveInput: null,
      selectedContext: null,
      result: null,
      applicationName: "WeChat",
    });
    store.recordEpisodicEvent({
      mode: "ask",
      rawTranscript: "上个月去了哪里",
      correctedTranscript: "上个月去了哪里出差",
      effectiveInput: null,
      selectedContext: null,
      result: "上个月去了上海出差",
      applicationName: "OpenType",
    });

    let capturedMessages: AgentChatMessage[] | undefined;
    const chat: AgentChatFn = async (messages) => {
      capturedMessages = messages;
      return { content: "done" };
    };
    const router = createRouter(
      buildAgentRoutes(store, makeConversations(), chat, noTools(), captureContextLog().writer)
    );

    await router(post({ task: "帮我订票" }));

    const userMessage = capturedMessages!.find((m) => m.role === "user");
    expect(userMessage?.content).toContain("明天去深圳");
    expect(userMessage?.content).toContain("eventId");
  });

  // The product decision this whole batch exists for (spec §六): a plain
  // dictation, which never itself reached a model, still shows up in the
  // context of a LATER ask/agent turn. Pinned as its own test, isolated from
  // the multi-mode test above, because this is exactly the assertion someone
  // would quietly weaken later (e.g. by re-adding "transcribe" to
  // `RECENT_ACTIVITY_EXCLUDED_MODES`).
  test("a dictation-only (transcribe) event reaches agent's injected context", async () => {
    const store = makeStore();
    store.recordEpisodicEvent({
      mode: "transcribe",
      rawTranscript: "帮我记一下会议纪要",
      correctedTranscript: "帮我记一下会议纪要",
      effectiveInput: null,
      selectedContext: null,
      result: null,
      applicationName: "Notes",
    });

    let capturedMessages: AgentChatMessage[] | undefined;
    const chat: AgentChatFn = async (messages) => {
      capturedMessages = messages;
      return { content: "done" };
    };
    const router = createRouter(
      buildAgentRoutes(store, makeConversations(), chat, noTools(), captureContextLog().writer)
    );

    await router(post({ task: "刚才记的纪要整理成待办" }));

    const userMessage = capturedMessages!.find((m) => m.role === "user");
    expect(userMessage?.content).toContain("帮我记一下会议纪要");
  });

  test("an empty store injects nothing -- no stray header, no empty block", async () => {
    const store = makeStore();
    let capturedMessages: AgentChatMessage[] | undefined;
    const chat: AgentChatFn = async (messages) => {
      capturedMessages = messages;
      return { content: "done" };
    };
    const router = createRouter(
      buildAgentRoutes(store, makeConversations(), chat, noTools(), captureContextLog().writer)
    );

    await router(post({ task: "just a task" }));

    const userMessage = capturedMessages!.find((m) => m.role === "user");
    expect(userMessage?.content).not.toContain("Recent activity");
  });

  // Since plan Task 3, the sidecar routes write no episodic event at all
  // (writing moved to Swift's single write point, POST /memory/events, fired
  // only after delivery). So the current turn's own task structurally cannot
  // appear in `recentEvents()` -- it isn't in the store yet when this
  // handler reads it. That invariant's real enforcement now lives on the
  // Swift side (plan Task 5). This test is cheap insurance here: it catches
  // anyone who later re-adds a write at this route's entry point before the
  // recentEvents read.
  test("the current turn's own task is not present in its own injected context", async () => {
    const store = makeStore();
    let capturedMessages: AgentChatMessage[] | undefined;
    const chat: AgentChatFn = async (messages) => {
      capturedMessages = messages;
      return { content: "done" };
    };
    const router = createRouter(
      buildAgentRoutes(store, makeConversations(), chat, noTools(), captureContextLog().writer)
    );

    await router(post({ task: "这是当前这一轮不应该出现在自己的上下文里" }));

    const userMessage = capturedMessages!.find((m) => m.role === "user");
    expect(userMessage?.content).not.toContain("Recent activity");
    expect(store.recentEvents(10)).toHaveLength(0);
  });
});

/**
 * Agent-definition route wiring (design §4.4/§4.5,
 * docs/superpowers/specs/2026-08-28-first-party-tools-skills-and-agents-design.md).
 *
 * `buildAgentRoutes` grows one new trailing parameter to carry this: an
 * `agentSupport` options object shaped `{ agentDefinitions?: {
 * list(): AgentDefinition[]; globalInstructions(): string | undefined } }`.
 * This is a DELIBERATE CHOICE made here, not dictated by the design doc --
 * flagged as a coordination point in the stage-1 report, since the same
 * batch's skill-index-injection and approval-mode work (design §3.4, §2.1)
 * also extend this same function's signature. Whoever implements this
 * (stage 3) should reconcile all pending `routes.ts` signature changes into
 * one coherent parameter list rather than stacking unrelated positional
 * params independently.
 *
 * Every test below passes an in-memory fake for `agentDefinitions` (a plain
 * object matching the shape above) -- none of them touch real files or real
 * discovery roots; `agentDefinitions.test.ts` covers discovery/composition
 * as pure units.
 *
 * RED-STATE NOTE: as of this stage, `buildAgentRoutes` does not accept this
 * parameter and `/agent/run` does not read `body.agentName` at all, and
 * `GET /agent/definitions` does not exist (falls through the router to the
 * same 404 `{ error: "not_found" }` the progress-route tests' comment
 * documents for an unbuilt route). So passing the extra constructor argument
 * is harmless no-op JS (bun strips types, extra args are ignored) and every
 * assertion below that depends on the new behavior fails for the right
 * reason: the feature is simply not there yet.
 */
describe("agent definitions: agentName + GET /agent/definitions (design §4.4)", () => {
  interface FakeAgentDefinitionsProvider {
    list(): AgentDefinition[];
    globalInstructions(): string | undefined;
  }

  function fakeProvider(
    definitions: AgentDefinition[],
    globalInstructions?: string
  ): FakeAgentDefinitionsProvider {
    return {
      list: () => definitions,
      globalInstructions: () => globalInstructions,
    };
  }

  function agentDef(overrides: Partial<AgentDefinition>): AgentDefinition {
    return {
      name: "agent",
      description: "d",
      body: "body",
      root: "/agents",
      path: "/agents/agent.md",
      ...overrides,
    };
  }

  test("agentName selects a definition: its body is composed onto the base system prompt", async () => {
    let capturedMessages: AgentChatMessage[] | undefined;
    const chat: AgentChatFn = async (messages) => {
      capturedMessages = messages;
      return { content: "done" };
    };
    const writer = agentDef({ name: "writer", description: "d", body: "You write warm, concise emails." });
    const router = createRouter(
      buildAgentRoutes(
        makeStore(),
        makeConversations(),
        chat,
        noTools(),
        captureContextLog().writer,
        undefined,
        undefined,
        { agentDefinitions: fakeProvider([writer]) }
      )
    );

    const response = await router(post({ task: "write an email to my landlord", agentName: "writer" }));

    expect(response.status).toBe(200);
    const systemMessage = capturedMessages!.find((m) => m.role === "system");
    expect(systemMessage?.content).toContain("You write warm, concise emails.");
    // Composition appends, never replaces (see agentDefinitions.test.ts's
    // dedicated security test for the full argument) -- the base prompt must
    // still be present in full and first.
    expect(systemMessage?.content?.startsWith(AGENT_SYSTEM_PROMPT)).toBe(true);
  });

  test("agentName takes precedence over a voice prefix present in the task", async () => {
    let capturedMessages: AgentChatMessage[] | undefined;
    const chat: AgentChatFn = async (messages) => {
      capturedMessages = messages;
      return { content: "done" };
    };
    const writer = agentDef({ name: "writer", description: "d", body: "WRITER BODY" });
    const researcher = agentDef({
      name: "researcher",
      displayName: "研究员",
      description: "d",
      body: "RESEARCHER BODY",
    });
    const router = createRouter(
      buildAgentRoutes(
        makeStore(),
        makeConversations(),
        chat,
        noTools(),
        captureContextLog().writer,
        undefined,
        undefined,
        { agentDefinitions: fakeProvider([writer, researcher]) }
      )
    );

    // The task's own leading text would, on its own, voice-match "researcher"
    // -- but an explicit agentName of "writer" must win outright.
    await router(post({ task: "用研究员查一下天气", agentName: "writer" }));

    const systemMessage = capturedMessages!.find((m) => m.role === "system");
    expect(systemMessage?.content).toContain("WRITER BODY");
    expect(systemMessage?.content).not.toContain("RESEARCHER BODY");
    // DECIDED (design owner adjudication, 2026-08-28 -- no longer an
    // assumption): stripping is task hygiene scoped to the agent that was
    // actually addressed, not a side effect of `agentName` selection itself.
    // The task here addresses "研究员" (a DIFFERENT agent than the one
    // explicitly named), so nothing is stripped -- leaving "用研究员" in
    // would be wrong too, but for a different reason than leaving it in
    // would be for the same-agent case below: here it's simply not a prefix
    // ADDRESSING "writer" at all, so there is nothing for writer's resolution
    // to strip. See the next test for the same-agent case, where stripping
    // DOES still happen despite agentName being explicit.
    const userMessage = capturedMessages!.find((m) => m.role === "user");
    expect(userMessage?.content).toContain("用研究员查一下天气");
  });

  test("agentName explicit AND the task's own prefix addresses that SAME agent: the prefix is still stripped", async () => {
    // Design owner adjudication (2026-08-28, revising the earlier
    // no-stripping-when-explicit assumption): explicit agentName decides
    // WHICH agent runs, but stripping is a separate, orthogonal step that
    // still happens whenever the task's leading text addresses the agent
    // that ends up running -- named explicitly or found by voice-prefix
    // alike. Rationale: leaving "用写作助手" in the task hands the model a
    // task addressed to someone else, which is a correctness bug regardless
    // of how the agent was selected. Scoping the strip to the *actually
    // selected* agent (not "strip any recognized agent-address") is what
    // keeps this from damaging an unrelated task that merely starts with a
    // phrase addressing some OTHER agent -- see the previous test.
    let capturedMessages: AgentChatMessage[] | undefined;
    const chat: AgentChatFn = async (messages) => {
      capturedMessages = messages;
      return { content: "done" };
    };
    const writer = agentDef({ name: "writer", displayName: "写作助手", description: "d", body: "WRITER BODY" });
    const router = createRouter(
      buildAgentRoutes(
        makeStore(),
        makeConversations(),
        chat,
        noTools(),
        captureContextLog().writer,
        undefined,
        undefined,
        { agentDefinitions: fakeProvider([writer]) }
      )
    );

    await router(post({ task: "用写作助手帮我写封邮件", agentName: "writer" }));

    const userMessage = capturedMessages!.find((m) => m.role === "user");
    expect(userMessage?.content).toContain("帮我写封邮件");
    expect(userMessage?.content).not.toContain("用写作助手");
  });

  test("an unknown agentName is a 400 with a readable message", async () => {
    const chat: AgentChatFn = async () => ({ content: "done" });
    const router = createRouter(
      buildAgentRoutes(
        makeStore(),
        makeConversations(),
        chat,
        noTools(),
        captureContextLog().writer,
        undefined,
        undefined,
        { agentDefinitions: fakeProvider([]) }
      )
    );

    const response = await router(post({ task: "do something", agentName: "does-not-exist" }));

    // An explicitly named agent that doesn't exist is a CALLER error (400),
    // unlike a voice prefix that simply fails to match anything (which is
    // just "no agent selected", not an error at all).
    expect(response.status).toBe(400);
    const body = (await response.json()) as { error: string };
    expect(body.error).toContain("does-not-exist");
  });

  test("with neither agentName nor a matching voice prefix, the system message is byte-identical to today", async () => {
    let capturedMessages: AgentChatMessage[] | undefined;
    const chat: AgentChatFn = async (messages) => {
      capturedMessages = messages;
      return { content: "done" };
    };
    const writer = agentDef({ name: "writer", description: "d", body: "WRITER BODY" });
    const router = createRouter(
      buildAgentRoutes(
        makeStore(),
        makeConversations(),
        chat,
        noTools(),
        captureContextLog().writer,
        undefined,
        undefined,
        { agentDefinitions: fakeProvider([writer]) }
      )
    );

    await router(post({ task: "just a normal task with no agent mentioned" }));

    const systemMessage = capturedMessages!.find((m) => m.role === "system");
    expect(systemMessage?.content).toBe(AGENT_SYSTEM_PROMPT);
  });

  test("GET /agent/definitions returns name/description/source-root/tools for each discovered agent", async () => {
    const chat: AgentChatFn = async () => ({ content: "done" });
    const writer = agentDef({
      name: "writer",
      description: "Writes emails",
      tools: "bash, read_file",
      root: "/agents/builtin",
      path: "/agents/builtin/writer.md",
    });
    const plain = agentDef({
      name: "plain",
      description: "No tool restriction",
      root: "/agents/user",
      path: "/agents/user/plain.md",
    });
    const router = createRouter(
      buildAgentRoutes(
        makeStore(),
        makeConversations(),
        chat,
        noTools(),
        captureContextLog().writer,
        undefined,
        undefined,
        { agentDefinitions: fakeProvider([writer, plain]) }
      )
    );

    const response = await router(new Request("http://sidecar/agent/definitions", { method: "GET" }));

    expect(response.status).toBe(200);
    const body = (await response.json()) as Array<{
      name: string;
      description: string;
      root: string;
      tools?: string;
    }>;
    const byName = Object.fromEntries(body.map((entry) => [entry.name, entry]));
    expect(byName.writer).toMatchObject({
      name: "writer",
      description: "Writes emails",
      root: "/agents/builtin",
      tools: "bash, read_file",
    });
    expect(byName.plain).toMatchObject({
      name: "plain",
      description: "No tool restriction",
      root: "/agents/user",
    });
  });

  test("the resolved agent's tools allowlist narrows what reaches the chat call (end-to-end wiring check)", async () => {
    let capturedTools: unknown;
    const chat: AgentChatFn = async (_messages, options) => {
      capturedTools = options?.tools;
      return { content: "done" };
    };
    const tools: McpToolSet = {
      openAiTools: [
        { type: "function", function: { name: "opentype__bash" } },
        { type: "function", function: { name: "opentype__grep" } },
      ],
      callTool: async () => ({ content: "" }),
    };
    const writer = agentDef({ name: "writer", description: "d", body: "b", tools: "bash" });
    const router = createRouter(
      buildAgentRoutes(
        makeStore(),
        makeConversations(),
        chat,
        tools,
        captureContextLog().writer,
        undefined,
        undefined,
        { agentDefinitions: fakeProvider([writer]) }
      )
    );

    await router(post({ task: "do a thing", agentName: "writer" }));

    const names = (capturedTools as { function: { name: string } }[]).map((tool) => tool.function.name);
    expect(names).toContain("opentype__bash");
    expect(names).not.toContain("opentype__grep");
  });
});

/**
 * AGENTS.md global instructions (design §4.5) -- a separate mechanism from
 * the named-agent selection above: it applies REGARDLESS of whether an
 * agentName/voice-prefix match happened, because it represents the owner's
 * standing instructions rather than a specific agent's persona.
 */
describe("AGENTS.md global instructions (design §4.5)", () => {
  test("global instructions are appended after the agent body, and apply even with no agent selected", async () => {
    let capturedMessages: AgentChatMessage[] | undefined;
    const chat: AgentChatFn = async (messages) => {
      capturedMessages = messages;
      return { content: "done" };
    };
    const writer: AgentDefinition = {
      name: "writer",
      description: "d",
      body: "WRITER BODY",
      root: "/agents",
      path: "/agents/writer.md",
    };
    const provider = {
      list: () => [writer],
      globalInstructions: () => "Always sign off with the owner's name, Diyi.",
    };
    const router = createRouter(
      buildAgentRoutes(
        makeStore(),
        makeConversations(),
        chat,
        noTools(),
        captureContextLog().writer,
        undefined,
        undefined,
        { agentDefinitions: provider }
      )
    );

    // No agentName, no voice prefix -- global instructions must still apply.
    await router(post({ task: "just a normal task" }));
    let systemMessage = capturedMessages!.find((m) => m.role === "system");
    expect(systemMessage?.content).toContain("Always sign off with the owner's name, Diyi.");
    expect(systemMessage?.content?.startsWith(AGENT_SYSTEM_PROMPT)).toBe(true);

    // With an agent selected, the order is base -> agent body -> global
    // instructions (never base -> global -> body).
    await router(post({ task: "write something", agentName: "writer" }));
    systemMessage = capturedMessages!.find((m) => m.role === "system");
    const bodyIndex = systemMessage!.content!.indexOf("WRITER BODY");
    const globalIndex = systemMessage!.content!.indexOf("Always sign off with the owner's name, Diyi.");
    expect(bodyIndex).toBeGreaterThan(-1);
    expect(globalIndex).toBeGreaterThan(bodyIndex);
  });
});

/**
 * Run-start resolution of a PROJECT AGENTS.md (design §10.1/§10.4,
 * docs/superpowers/specs/2026-08-28-first-party-tools-skills-and-agents-design.md)
 * -- distinct from the §4.5/§10.3 GLOBAL `INSTRUCTIONS.md` mechanism covered
 * above and in `agentDefinitions.test.ts`. `POST /agent/run` grows an
 * optional `workingDirectory` field; when it names a directory under a
 * project with an `AGENTS.md`, that content must reach the model in the
 * FINAL USER MESSAGE, and the SYSTEM message must stay byte-identical to
 * what it is without it -- §10.4's "逐请求变化的内容绝不能进 system message"
 * rule (this is a KV-cache-prefix-stability requirement, not a style
 * choice; see `docs/model-context-inventory.md` §5).
 *
 * Coordination note (this batch's own choice, not dictated by the design
 * doc, flagged in the report the same way the agentDefinitions/skills
 * options were flagged in earlier stages of this same batch): resolving a
 * project's AGENTS.md needs a `homeDir` boundary (§10.2's "stop at homeDir
 * inclusive" rule), so `AgentRouteOptions` gains one more optional field,
 * `homeDir?: string`, alongside `approvalMode`/`skills`/`agentDefinitions`.
 * Every test below injects a temp dir as `homeDir` -- never the real `~`.
 */
describe("project AGENTS.md at run start via workingDirectory (design §10.1/§10.4)", () => {
  function mkTempDir(): string {
    return fs.mkdtempSync(path.join(os.tmpdir(), "opentype-routes-projectagentsmd-"));
  }

  test("a workingDirectory under a project with AGENTS.md: content reaches the FINAL USER MESSAGE, source path included", async () => {
    const homeDir = mkTempDir();
    const projectRoot = path.join(homeDir, "myproject");
    fs.mkdirSync(projectRoot, { recursive: true });
    const agentsMdPath = path.join(projectRoot, "AGENTS.md");
    fs.writeFileSync(agentsMdPath, "PROJECT CONVENTIONS: always use tabs, never spaces.");
    const workingDirectory = path.join(projectRoot, "src");
    fs.mkdirSync(workingDirectory, { recursive: true });

    let capturedMessages: AgentChatMessage[] | undefined;
    const chat: AgentChatFn = async (messages) => {
      capturedMessages = messages;
      return { content: "done" };
    };
    const router = createRouter(
      buildAgentRoutes(
        makeStore(),
        makeConversations(),
        chat,
        noTools(),
        captureContextLog().writer,
        undefined,
        undefined,
        { homeDir }
      )
    );

    const response = await router(post({ task: "fix the failing test", workingDirectory }));

    expect(response.status).toBe(200);
    const userMessage = capturedMessages!.find((m) => m.role === "user");
    expect(userMessage?.content).toContain("PROJECT CONVENTIONS: always use tabs, never spaces.");
    // Provenance: the resolved AGENTS.md's own path must be traceable in
    // what the model sees, per §10.5.
    expect(userMessage?.content).toContain(agentsMdPath);
  });

  test("the SYSTEM message stays byte-identical to AGENT_SYSTEM_PROMPT regardless of a resolved project AGENTS.md", async () => {
    const homeDir = mkTempDir();
    const projectRoot = path.join(homeDir, "myproject");
    fs.mkdirSync(projectRoot, { recursive: true });
    fs.writeFileSync(path.join(projectRoot, "AGENTS.md"), "SOME PROJECT CONVENTIONS");

    let capturedMessages: AgentChatMessage[] | undefined;
    const chat: AgentChatFn = async (messages) => {
      capturedMessages = messages;
      return { content: "done" };
    };
    const router = createRouter(
      buildAgentRoutes(
        makeStore(),
        makeConversations(),
        chat,
        noTools(),
        captureContextLog().writer,
        undefined,
        undefined,
        { homeDir }
      )
    );

    await router(post({ task: "do a thing", workingDirectory: projectRoot }));

    const systemMessage = capturedMessages!.find((m) => m.role === "system");
    // Per-request-varying content (the project's own path/content) must
    // NEVER land here -- doing so would invalidate the KV-cache prefix on
    // every single call that names a different workingDirectory.
    expect(systemMessage?.content).toBe(AGENT_SYSTEM_PROMPT);
    expect(systemMessage?.content).not.toContain("SOME PROJECT CONVENTIONS");
  });

  test("omitting workingDirectory produces today's behaviour exactly, even when a homeDir option is configured", async () => {
    // §10.1 says workingDirectory defaults to `~` -- but a bare home
    // directory essentially never has its own AGENTS.md in practice, so a
    // caller (Swift) that never sends this new field at all must see
    // EXACTLY the same request/response shape as before this feature
    // existed. `homeDir` here deliberately has no AGENTS.md, modelling that
    // common case.
    const homeDir = mkTempDir(); // no AGENTS.md anywhere in it

    let capturedMessages: AgentChatMessage[] | undefined;
    const chat: AgentChatFn = async (messages) => {
      capturedMessages = messages;
      return { content: "done" };
    };
    const routerWithHomeDir = createRouter(
      buildAgentRoutes(
        makeStore(),
        makeConversations(),
        chat,
        noTools(),
        captureContextLog().writer,
        undefined,
        undefined,
        { homeDir }
      )
    );
    const routerWithoutOptions = createRouter(
      buildAgentRoutes(makeStore(), makeConversations(), chat, noTools(), captureContextLog().writer)
    );

    await routerWithHomeDir(post({ task: "just a normal task" }));
    const withHomeDirUserMessage = capturedMessages!.find((m) => m.role === "user")?.content;

    await routerWithoutOptions(post({ task: "just a normal task" }));
    const withoutOptionsUserMessage = capturedMessages!.find((m) => m.role === "user")?.content;

    // Byte-identical to a call with no options object at all (every
    // pre-existing call site) -- not pinned to a literal string, since the
    // user message already carries other per-request content today (e.g.
    // `buildTimeContext()`'s "Current time: ..." line) unrelated to this
    // feature; what matters is that adding a `homeDir` option with nothing
    // to resolve changes NOTHING about it.
    expect(withHomeDirUserMessage).toBe(withoutOptionsUserMessage);
    expect(withHomeDirUserMessage).toContain("TASK:\njust a normal task");
    expect(withHomeDirUserMessage).not.toContain("AGENTS.md");
  });

  // Design owner review, adjudication #3: the test above only pins the
  // NEGATIVE case (a homeDir with no AGENTS.md in it). §10.2's boundary is
  // "user home directory INCLUSIVE" -- an AGENTS.md placed directly at
  // homeDir IS supposed to be found, not just tolerated as absent. Without
  // this positive case, nothing distinguishes an implementation that
  // correctly stops the upward walk AT homeDir (inclusive) from one that
  // stops one level ABOVE it (exclusive, and so would never find this
  // file) -- both would pass the test above identically.
  test("no workingDirectory given, but homeDir itself HAS an AGENTS.md: it IS found and reaches the model (design §10.1 default ~, §10.2 inclusive boundary)", async () => {
    const homeDir = mkTempDir();
    const agentsMdPath = path.join(homeDir, "AGENTS.md");
    fs.writeFileSync(agentsMdPath, "HOME-LEVEL CONVENTIONS -- FOUND VIA THE DEFAULT ~ WORKING DIRECTORY");

    let capturedMessages: AgentChatMessage[] | undefined;
    const chat: AgentChatFn = async (messages) => {
      capturedMessages = messages;
      return { content: "done" };
    };
    const router = createRouter(
      buildAgentRoutes(
        makeStore(),
        makeConversations(),
        chat,
        noTools(),
        captureContextLog().writer,
        undefined,
        undefined,
        { homeDir }
      )
    );

    await router(post({ task: "just a normal task" }));

    const userMessage = capturedMessages!.find((m) => m.role === "user")?.content;
    expect(userMessage).toContain("HOME-LEVEL CONVENTIONS -- FOUND VIA THE DEFAULT ~ WORKING DIRECTORY");
    expect(userMessage).toContain(agentsMdPath);
  });
});
