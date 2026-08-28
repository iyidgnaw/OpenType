import { describe, expect, test } from "bun:test";
import { runAgentLoop, type AgentChatFn, type AgentChatMessage } from "../../src/agent/loop";
import type { McpToolSet } from "../../src/agent/mcpClient";
import { AGENT_SYSTEM_PROMPT } from "../../src/oneshot/prompts";

function noTools(): McpToolSet {
  return {
    openAiTools: [],
    callTool: async () => {
      throw new Error("callTool should not be invoked in this test");
    },
  };
}

describe("runAgentLoop", () => {
  test("zero-tool-calls happy path: one chat call, immediate answer", async () => {
    let chatCalls = 0;
    const chat: AgentChatFn = async () => {
      chatCalls += 1;
      return { content: "Paris" };
    };

    const result = await runAgentLoop(
      { task: "What is the capital of France?" },
      { chat, tools: noTools() }
    );

    expect(chatCalls).toBe(1);
    expect(result.result).toBe("Paris");
    expect(result.steps.map((s) => s.type)).toEqual(["thinking", "done"]);
  });

  test("one tool call then final answer: two chat calls, tool executed once", async () => {
    let chatCalls = 0;
    const capturedMessages: AgentChatMessage[][] = [];
    const chat: AgentChatFn = async (messages) => {
      capturedMessages.push(messages);
      chatCalls += 1;
      if (chatCalls === 1) {
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
      return { content: "It is sunny." };
    };

    let callToolInvocations: Array<{ name: string; args: unknown }> = [];
    const tools: McpToolSet = {
      openAiTools: [{ type: "function", function: { name: "search__lookup" } }],
      callTool: async (name, args) => {
        callToolInvocations.push({ name, args });
        return { content: "sunny, 75F" };
      },
    };

    const result = await runAgentLoop(
      { task: "What's the weather?" },
      { chat, tools }
    );

    expect(chatCalls).toBe(2);
    expect(callToolInvocations).toEqual([{ name: "search__lookup", args: { query: "weather" } }]);
    expect(result.result).toBe("It is sunny.");

    // Second chat call must have the assistant tool-call message and the
    // tool-role result message appended, per OpenAI tool-calling conventions.
    const secondCallMessages = capturedMessages[1] ?? [];
    const assistantToolCallMessage = secondCallMessages.find(
      (m) => m.role === "assistant" && m.tool_calls
    );
    const toolResultMessage = secondCallMessages.find((m) => m.role === "tool");
    expect(assistantToolCallMessage?.tool_calls).toEqual([
      {
        id: "call_1",
        type: "function",
        function: { name: "search__lookup", arguments: '{"query":"weather"}' },
      },
    ]);
    expect(toolResultMessage?.tool_call_id).toBe("call_1");
    expect(toolResultMessage?.content).toBe("sunny, 75F");

    expect(result.steps.map((s) => s.type)).toEqual([
      "thinking",
      "tool_call",
      "tool_result",
      "thinking",
      "done",
    ]);
  });

  test("hits the iteration cap when chat always requests another tool call", async () => {
    let chatCalls = 0;
    const chat: AgentChatFn = async () => {
      chatCalls += 1;
      return {
        content: null,
        toolCalls: [
          {
            id: `call_${chatCalls}`,
            type: "function",
            function: { name: "search__lookup", arguments: "{}" },
          },
        ],
      };
    };

    let callToolCalls = 0;
    const tools: McpToolSet = {
      openAiTools: [{ type: "function", function: { name: "search__lookup" } }],
      callTool: async () => {
        callToolCalls += 1;
        return { content: "more data" };
      },
    };

    const result = await runAgentLoop({ task: "loop forever" }, { chat, tools });

    expect(chatCalls).toBe(10);
    expect(callToolCalls).toBe(10);
    expect(typeof result.result).toBe("string");
    expect(result.result.length).toBeGreaterThan(0);
  });

  test("emits progress events via onProgress in order as the loop runs", async () => {
    let chatCalls = 0;
    const chat: AgentChatFn = async () => {
      chatCalls += 1;
      if (chatCalls === 1) {
        return {
          content: null,
          toolCalls: [
            { id: "call_1", type: "function", function: { name: "t__x", arguments: "{}" } },
          ],
        };
      }
      return { content: "done answer" };
    };
    const tools: McpToolSet = {
      openAiTools: [],
      callTool: async () => ({ content: "result" }),
    };

    const observed: string[] = [];
    const result = await runAgentLoop(
      { task: "do a thing" },
      { chat, tools, onProgress: (event) => observed.push(event.type) }
    );

    expect(observed).toEqual(result.steps.map((s) => s.type));
    expect(observed).toEqual(["thinking", "tool_call", "tool_result", "thinking", "done"]);
  });

  test("includes context and knownTerms in the initial user message when present", async () => {
    let capturedMessages: AgentChatMessage[] = [];
    const chat: AgentChatFn = async (messages) => {
      capturedMessages = messages;
      return { content: "ok" };
    };

    await runAgentLoop(
      { task: "summarize this", context: "some selected text", knownTerms: "Known terms: Foo" },
      { chat, tools: noTools() }
    );

    const userMessage = capturedMessages.find((m) => m.role === "user");
    expect(userMessage?.content).toContain("summarize this");
    expect(userMessage?.content).toContain("some selected text");
    expect(userMessage?.content).toContain("Known terms: Foo");

    const systemMessage = capturedMessages.find((m) => m.role === "system");
    expect(systemMessage?.content).toBeTruthy();
  });

  // Task 10 (design §3.5): `recentActivity` is rendered by
  // `memory/recentActivity.ts` and handed to the loop verbatim. It must land
  // in the same place `knownTerms`/`runtimeContext` do -- the final user
  // message -- and never in the system message. Content that changes on
  // every request (this block changes every time the episodic store gains a
  // new row) invalidates the whole KV-cache prefix if it lands in the system
  // prompt (`docs/model-context-inventory.md` §5), so this is a correctness
  // property, not a style preference.
  test("recentActivity is appended to the final user message, never to the system message", async () => {
    let capturedMessages: AgentChatMessage[] = [];
    const chat: AgentChatFn = async (messages) => {
      capturedMessages = messages;
      return { content: "ok" };
    };
    const recentActivity =
      'Recent activity, oldest first.\n{"eventId":43,"mode":"ask","input":"明天那边天气怎么样"}';

    await runAgentLoop(
      { task: "做事", recentActivity },
      { chat, tools: noTools() }
    );

    expect(capturedMessages[0]?.role).toBe("system");
    expect(capturedMessages[0]?.content).not.toContain("Recent activity");
    expect(capturedMessages[0]?.content).not.toContain("明天那边天气怎么样");

    const lastMessage = capturedMessages[capturedMessages.length - 1];
    expect(lastMessage?.role).toBe("user");
    expect(lastMessage?.content).toContain("Recent activity, oldest first.");
    expect(lastMessage?.content).toContain("明天那边天气怎么样");
  });

  test("omitting recentActivity produces no stray header or trace of it in the user message", async () => {
    let capturedMessages: AgentChatMessage[] = [];
    const chat: AgentChatFn = async (messages) => {
      capturedMessages = messages;
      return { content: "ok" };
    };

    await runAgentLoop({ task: "做事" }, { chat, tools: noTools() });

    const userMessage = capturedMessages.find((m) => m.role === "user");
    expect(userMessage?.content).not.toContain("Recent activity");
  });

  // First-party tools/skills/agents design §3.4
  // (docs/superpowers/specs/2026-08-28-first-party-tools-skills-and-agents-design.md):
  // `RunAgentLoopInput.skills` is the rendered skill index (skillStore.ts's
  // `renderSkillIndex`), injected exactly like `knownTerms` / `runtimeContext`
  // / `recentActivity` -- final user message only, appended AFTER
  // recentActivity -- because a user can add a skill file at any moment, and
  // anything that can change between requests must never land in the system
  // message (docs/model-context-inventory.md §5's prefix-stability rule).
  test("skills is appended to the final user message after recentActivity, never the system message", async () => {
    let capturedMessages: AgentChatMessage[] = [];
    const chat: AgentChatFn = async (messages) => {
      capturedMessages = messages;
      return { content: "ok" };
    };
    const recentActivity = 'Recent activity, oldest first.\n{"eventId":1,"mode":"ask","input":"x"}';
    const skills = "find-and-open: locate and open a file\norganize-files: tidy up a folder";

    await runAgentLoop(
      { task: "做事", recentActivity, skills },
      { chat, tools: noTools() }
    );

    expect(capturedMessages[0]?.role).toBe("system");
    expect(capturedMessages[0]?.content).not.toContain("find-and-open");
    expect(capturedMessages[0]?.content).not.toContain(skills);

    const lastMessage = capturedMessages[capturedMessages.length - 1];
    expect(lastMessage?.role).toBe("user");
    const content = lastMessage?.content ?? "";
    expect(content).toContain(skills);

    const recentActivityIndex = content.indexOf(recentActivity);
    const skillsIndex = content.indexOf(skills);
    expect(recentActivityIndex).toBeGreaterThanOrEqual(0);
    expect(skillsIndex).toBeGreaterThan(recentActivityIndex);
  });

  test("the system message is byte-identical with or without skills (KV-cache prefix stability)", async () => {
    let withSkillsMessages: AgentChatMessage[] = [];
    let withoutSkillsMessages: AgentChatMessage[] = [];
    const chatWith: AgentChatFn = async (messages) => {
      withSkillsMessages = messages;
      return { content: "ok" };
    };
    const chatWithout: AgentChatFn = async (messages) => {
      withoutSkillsMessages = messages;
      return { content: "ok" };
    };

    await runAgentLoop(
      { task: "做事", skills: "find-and-open: locate and open a file" },
      { chat: chatWith, tools: noTools() }
    );
    // No `skills` key at all here -- this is the "today's" call the field
    // must not change anything for.
    await runAgentLoop({ task: "做事" }, { chat: chatWithout, tools: noTools() });

    const systemWith = withSkillsMessages.find((m) => m.role === "system")?.content;
    const systemWithout = withoutSkillsMessages.find((m) => m.role === "system")?.content;
    expect(systemWith).toBeTruthy();
    expect(systemWith).toBe(systemWithout as string);

    // The invariant above ("system message unaffected") is trivially true if
    // `skills` were simply never wired up at all, so pin it against a second
    // invariant that only holds once the field IS wired: the USER message
    // must actually differ between the two calls, since one of them carries
    // a skill index the other doesn't.
    const userWith = withSkillsMessages.find((m) => m.role === "user")?.content;
    const userWithout = withoutSkillsMessages.find((m) => m.role === "user")?.content;
    expect(userWith).not.toBe(userWithout);
  });

  test("omitting skills produces a user message byte-identical to today's", async () => {
    let baselineMessages: AgentChatMessage[] = [];
    let omittedMessages: AgentChatMessage[] = [];
    const chatBaseline: AgentChatFn = async (messages) => {
      baselineMessages = messages;
      return { content: "ok" };
    };
    const chatOmitted: AgentChatFn = async (messages) => {
      omittedMessages = messages;
      return { content: "ok" };
    };

    // Same input shape as pre-this-batch code would have passed (no `skills`
    // key), run twice, to prove the new optional field is invisible when unused.
    await runAgentLoop({ task: "总结一下这段文字", context: "some text" }, { chat: chatBaseline, tools: noTools() });
    await runAgentLoop({ task: "总结一下这段文字", context: "some text" }, { chat: chatOmitted, tools: noTools() });

    const baselineUser = baselineMessages.find((m) => m.role === "user")?.content;
    const omittedUser = omittedMessages.find((m) => m.role === "user")?.content;
    expect(baselineUser).toBe(omittedUser as string);
    expect(baselineUser).not.toContain("Skills");
  });
});

/**
 * B2 open-file + ask-web design §2
 * (docs/superpowers/specs/2026-08-13-b2-open-file-and-ask-web-design.md):
 * `runAgentLoop` is generalized so `/oneshot/ask` can reuse it with a
 * web-only toolset. Contract these tests pin (for stage 3): three new
 * OPTIONAL fields on `RunAgentLoopInput`, each defaulting to today's exact
 * behavior --
 * - `systemPrompt?: string` (default `AGENT_SYSTEM_PROMPT`),
 * - `priorMessages?: AgentChatMessage[]` (inserted between the system
 *   message and the final user message, in order, unmodified -- real
 *   message-array replay, not a squashed summary),
 * - `maxIterations?: number` (default the existing 10; the default-cap
 *   behavior is already covered by the "hits the iteration cap" test above,
 *   so it is not re-asserted here).
 */
describe("runAgentLoop generalization (open-file + ask-web design §2)", () => {
  test("a provided systemPrompt becomes the system message instead of AGENT_SYSTEM_PROMPT", async () => {
    let capturedMessages: AgentChatMessage[] = [];
    const chat: AgentChatFn = async (messages) => {
      capturedMessages = messages;
      return { content: "ok" };
    };

    await runAgentLoop(
      { task: "answer the question", systemPrompt: "CUSTOM ASK PROMPT with web guidance" },
      { chat, tools: noTools() }
    );

    expect(capturedMessages[0]?.role).toBe("system");
    expect(capturedMessages[0]?.content).toBe("CUSTOM ASK PROMPT with web guidance");
    expect(capturedMessages[0]?.content).not.toBe(AGENT_SYSTEM_PROMPT);
  });

  test("without a systemPrompt the system message is AGENT_SYSTEM_PROMPT, unchanged", async () => {
    let capturedMessages: AgentChatMessage[] = [];
    const chat: AgentChatFn = async (messages) => {
      capturedMessages = messages;
      return { content: "ok" };
    };

    await runAgentLoop({ task: "plain task" }, { chat, tools: noTools() });

    expect(capturedMessages[0]).toEqual({ role: "system", content: AGENT_SYSTEM_PROMPT });
  });

  test("priorMessages appear between the system message and the final user message, in order, unmodified", async () => {
    let capturedMessages: AgentChatMessage[] = [];
    const chat: AgentChatFn = async (messages) => {
      capturedMessages = messages;
      return { content: "since 2019" };
    };
    const priorMessages: AgentChatMessage[] = [
      { role: "user", content: "who is the CEO of Acme?" },
      { role: "assistant", content: "Jane Doe is the CEO of Acme." },
    ];

    await runAgentLoop({ task: "since when?", priorMessages }, { chat, tools: noTools() });

    expect(capturedMessages).toHaveLength(4);
    expect(capturedMessages[0]?.role).toBe("system");
    // Replayed exactly -- same role/content, same order, nothing rewritten.
    expect(capturedMessages.slice(1, 3)).toEqual(priorMessages);
    expect(capturedMessages[3]?.role).toBe("user");
    expect(capturedMessages[3]?.content).toContain("since when?");
  });

  test("maxIterations: 3 stops an always-tool-calling chat after exactly 3 iterations", async () => {
    let chatCalls = 0;
    const chat: AgentChatFn = async () => {
      chatCalls += 1;
      return {
        content: null,
        toolCalls: [
          {
            id: `call_${chatCalls}`,
            type: "function",
            function: { name: "search__lookup", arguments: "{}" },
          },
        ],
      };
    };
    let callToolCalls = 0;
    const tools: McpToolSet = {
      openAiTools: [{ type: "function", function: { name: "search__lookup" } }],
      callTool: async () => {
        callToolCalls += 1;
        return { content: "more data" };
      },
    };

    const result = await runAgentLoop(
      { task: "loop forever", maxIterations: 3 },
      { chat, tools }
    );

    expect(chatCalls).toBe(3);
    expect(callToolCalls).toBe(3);
    expect(typeof result.result).toBe("string");
    expect(result.result.length).toBeGreaterThan(0);
  });
});

/**
 * The mid-run `projectContext` dep on `RunAgentLoopDeps` (design §10.1/§10.2,
 * docs/superpowers/specs/2026-08-28-first-party-tools-skills-and-agents-design.md).
 * Wired the same way `repeatGuard` already is (see `repeatGuard.test.ts`'s
 * "a reminder never replaces the tool result it follows" test, which this
 * mirrors): observed once per tool call, its non-undefined return pushed as
 * its OWN `user` message, strictly after the tool's own `tool` message and
 * never in place of it.
 *
 * `RunAgentLoopDeps.projectContext` is shaped like `repeatGuard`'s own dep
 * field -- an object with a single `observe(toolName, args)` method -- so a
 * plain object literal satisfying that shape is a valid fake here without
 * importing anything from `projectContext.ts` itself; these tests only pin
 * the LOOP's wiring, not the observer's own resolution logic (that's
 * `projectContext.test.ts`'s job).
 */
describe("runAgentLoop projectContext dep (design §10.1/§10.2 mid-run discovery)", () => {
  interface FakeProjectContextObserver {
    observe(toolName: string, args: unknown): string | undefined;
  }

  test("a projectContext observer's non-undefined return is pushed as a user message, after and separate from the tool result", async () => {
    let chatCalls = 0;
    const capturedMessages: AgentChatMessage[][] = [];
    const chat: AgentChatFn = async (messages) => {
      capturedMessages.push(messages);
      chatCalls += 1;
      if (chatCalls === 1) {
        return {
          content: null,
          toolCalls: [
            {
              id: "call_1",
              type: "function",
              function: { name: "opentype__bash", arguments: '{"cwd":"/repo"}' },
            },
          ],
        };
      }
      return { content: "done" };
    };
    const tools: McpToolSet = {
      openAiTools: [],
      callTool: async () => ({ content: "TOOL OUTPUT VERBATIM" }),
    };
    const observedCalls: Array<{ toolName: string; args: unknown }> = [];
    const projectContext: FakeProjectContextObserver = {
      observe: (toolName, args) => {
        observedCalls.push({ toolName, args });
        return "PROJECT CONTEXT BLOCK FOR /repo";
      },
    };

    const result = await runAgentLoop({ task: "do something" }, { chat, tools, projectContext });

    expect(result.result).toBe("done");
    // The loop must pass the tool call's own (parsed) name and arguments
    // through unchanged -- this is what lets the observer extract cwd/path.
    expect(observedCalls).toEqual([{ toolName: "opentype__bash", args: { cwd: "/repo" } }]);

    const finalMessages = capturedMessages.at(-1)!;
    const toolMessages = finalMessages.filter((m) => (m as { role: string }).role === "tool");
    expect(toolMessages).toHaveLength(1);
    // The tool result itself must stay the tool's own verbatim output -- the
    // injected block is a SEPARATE message, never a replacement or mutation
    // of it, so the step log and any audit of it remain faithful (the exact
    // rule repeatGuard's own test of this pins for its reminder).
    expect((toolMessages[0] as { content: string }).content).toBe("TOOL OUTPUT VERBATIM");

    const projectMessages = finalMessages.filter(
      (m) =>
        (m as { role: string }).role === "user" &&
        String((m as { content: unknown }).content).includes("PROJECT CONTEXT BLOCK FOR /repo")
    );
    expect(projectMessages).toHaveLength(1);

    // §10.4's "goes in the user message, never the system message" rule
    // applies to the mid-run discovery path too, not just the run-start
    // path (routes.test.ts covers run-start). The system message is built
    // once at the very start of the loop and never touched again, so this
    // also guards against a future refactor that started mutating it.
    const systemMessages = finalMessages.filter((m) => (m as { role: string }).role === "system");
    expect(systemMessages).toHaveLength(1);
    expect((systemMessages[0] as { content: string }).content).not.toContain(
      "PROJECT CONTEXT BLOCK FOR /repo"
    );
  });

  test("projectContext returning undefined pushes no extra message", async () => {
    let chatCalls = 0;
    const capturedMessages: AgentChatMessage[][] = [];
    const chat: AgentChatFn = async (messages) => {
      capturedMessages.push(messages);
      chatCalls += 1;
      if (chatCalls === 1) {
        return {
          content: null,
          toolCalls: [
            { id: "call_1", type: "function", function: { name: "opentype__grep", arguments: "{}" } },
          ],
        };
      }
      return { content: "done" };
    };
    const tools: McpToolSet = {
      openAiTools: [],
      callTool: async () => ({ content: "GREP RESULT" }),
    };
    const projectContext: FakeProjectContextObserver = { observe: () => undefined };

    await runAgentLoop({ task: "search something" }, { chat, tools, projectContext });

    const finalMessages = capturedMessages.at(-1)!;
    const userMessages = finalMessages.filter((m) => (m as { role: string }).role === "user");
    // Only the ORIGINAL task's user message -- no extra one from a
    // non-firing observer.
    expect(userMessages).toHaveLength(1);
  });

  // Stage-4 review, priority item #1: `parsedArgs` in `loop.ts` is declared
  // with `let` just above the per-tool-call `try` block, INSIDE the `for
  // (const toolCall of toolCalls)` loop -- so each tool call gets its own
  // fresh binding. If it were instead hoisted OUTSIDE that loop (one
  // binding shared across every tool call in the batch), a tool call whose
  // `JSON.parse` failed would leave `parsedArgs` holding the PREVIOUS call's
  // arguments, and `projectContext.observe` would silently resolve against
  // the wrong tool call's path -- a stale-args bug no other test here would
  // catch, since none of them issue two tool calls in one iteration where
  // the second has unparseable arguments. This test does exactly that.
  test("two tool calls in one iteration, the second with unparseable arguments: the observer never sees the FIRST call's args for the SECOND call", async () => {
    let chatCalls = 0;
    const chat: AgentChatFn = async () => {
      chatCalls += 1;
      if (chatCalls === 1) {
        return {
          content: null,
          toolCalls: [
            {
              id: "call_1",
              type: "function",
              function: { name: "opentype__bash", arguments: '{"cwd":"/repo-one"}' },
            },
            {
              id: "call_2",
              type: "function",
              // Deliberately malformed JSON -- `JSON.parse` throws, so
              // `parsedArgs` for THIS call must be `undefined`, never a
              // leftover from call_1.
              function: { name: "opentype__bash", arguments: "{not valid json" },
            },
          ],
        };
      }
      return { content: "done" };
    };
    const tools: McpToolSet = {
      openAiTools: [],
      callTool: async () => ({ content: "TOOL OUTPUT" }),
    };
    const observedCalls: Array<{ toolName: string; args: unknown }> = [];
    const projectContext: FakeProjectContextObserver = {
      observe: (toolName, args) => {
        observedCalls.push({ toolName, args });
        return undefined;
      },
    };

    const result = await runAgentLoop({ task: "do two things" }, { chat, tools, projectContext });

    expect(result.result).toBe("done");
    expect(observedCalls).toHaveLength(2);
    // call_1's own arguments, parsed.
    expect(observedCalls[0]).toEqual({ toolName: "opentype__bash", args: { cwd: "/repo-one" } });
    // call_2's arguments failed to parse -- must be `undefined`, NEVER
    // call_1's `{ cwd: "/repo-one" }` leaking across the loop iteration.
    expect(observedCalls[1]).toEqual({ toolName: "opentype__bash", args: undefined });
  });

  test("omitting the projectContext dep leaves the loop byte-identical to today (no extra messages, no crash)", async () => {
    let chatCalls = 0;
    const capturedMessages: AgentChatMessage[][] = [];
    const chat: AgentChatFn = async (messages) => {
      capturedMessages.push(messages);
      chatCalls += 1;
      if (chatCalls === 1) {
        return {
          content: null,
          toolCalls: [
            { id: "call_1", type: "function", function: { name: "opentype__bash", arguments: '{"cwd":"/repo"}' } },
          ],
        };
      }
      return { content: "done" };
    };
    const tools: McpToolSet = {
      openAiTools: [],
      callTool: async () => ({ content: "TOOL OUTPUT" }),
    };

    // No `projectContext` key at all in deps -- exactly every pre-existing
    // caller of runAgentLoop today.
    const result = await runAgentLoop({ task: "do something" }, { chat, tools });

    expect(result.result).toBe("done");
    const finalMessages = capturedMessages.at(-1)!;
    // system + original user + assistant (tool_calls) + tool result --
    // exactly 4 messages, no fifth "project context" user message sneaking
    // in when the dep was never supplied.
    expect(finalMessages).toHaveLength(4);
    expect(finalMessages.map((m) => (m as { role: string }).role)).toEqual([
      "system",
      "user",
      "assistant",
      "tool",
    ]);
  });
});
