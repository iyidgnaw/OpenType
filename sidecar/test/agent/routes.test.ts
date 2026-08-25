import { describe, expect, test } from "bun:test";
import { openDatabase } from "../../src/memory/db";
import { MemoryStore } from "../../src/memory/MemoryStore";
import { ConversationStore } from "../../src/memory/conversations";
import type { AgentChatFn, AgentChatMessage } from "../../src/agent/loop";
import type { McpToolSet } from "../../src/agent/mcpClient";
import { buildAgentRoutes } from "../../src/agent/routes";
import { createRouter } from "../../src/router";
import type { ContextUsageLogWriter } from "../../src/oneshot/contextDebugLog";

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
