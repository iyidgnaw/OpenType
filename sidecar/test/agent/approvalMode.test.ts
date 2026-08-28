/**
 * Tests for §2.1 of
 * docs/superpowers/specs/2026-08-28-first-party-tools-skills-and-agents-design.md
 * ("权限放松"): `/agent/run` stops prompting for destructive commands by
 * default (the product's "闸门默认打开" stance, §0), while
 * `OPENTYPE_AGENT_APPROVAL=prompt` restores today's always-prompt behavior.
 *
 * Reuses the HTTP-level harness `test/agent/routes.test.ts` already
 * established (fake `AgentChatFn` requesting a tool call, fake `McpToolSet`
 * recording what actually ran, `createRouter(buildAgentRoutes(...))`) rather
 * than inventing a new one.
 *
 * AMBIGUITY (flagged per pipeline instructions, not resolved silently): the
 * design spec pseudocode --
 *   const approvalMode = env.agentApprovalMode ?? "yolo";
 *   policy = approvalMode === "prompt" ? createPromptingApprovalPolicy(...) : yoloApprovalPolicy
 * -- does not say how `approvalMode` reaches `buildAgentRoutes`/
 * `handleAgentRun`. These tests assume it is threaded through as a new,
 * trailing optional parameter on `buildAgentRoutes` (after the existing
 * `spillRoot`/`runLogRoot`, following that same "positional, optional,
 * defaults preserve old behavior" pattern already used for those two), typed
 * `"yolo" | "prompt" | undefined`, defaulting to `"yolo"` when omitted. If
 * stage 3 instead wires this from `env` directly inside `server.ts` (never
 * as a `buildAgentRoutes` parameter), these tests will need their call sites
 * adjusted accordingly -- the BEHAVIORAL claims below (yolo doesn't prompt,
 * prompt does) are what matters, not this exact plumbing shape.
 */
import { describe, expect, test } from "bun:test";
import { openDatabase } from "../../src/memory/db";
import { MemoryStore } from "../../src/memory/MemoryStore";
import { ConversationStore } from "../../src/memory/conversations";
import type { AgentChatFn } from "../../src/agent/loop";
import type { McpToolSet } from "../../src/agent/mcpClient";
import { buildAgentRoutes } from "../../src/agent/routes";
import { createRouter } from "../../src/router";
import type { ContextUsageLogWriter } from "../../src/oneshot/contextDebugLog";
import { APPROVAL_APPROVE_LABEL, APPROVAL_QUESTION_ID } from "../../src/agent/approval";
import type { RouteHandler } from "../../src/router";

function makeStore(): MemoryStore {
  return new MemoryStore(openDatabase(":memory:"));
}

function makeConversations(): ConversationStore {
  return new ConversationStore(openDatabase(":memory:"));
}

function captureContextLog(): { writer: ContextUsageLogWriter; lines: string[] } {
  const lines: string[] = [];
  return { writer: (line) => lines.push(line), lines };
}

function post(body: unknown): Request {
  return new Request("http://sidecar/agent/run", {
    method: "POST",
    body: JSON.stringify(body),
  });
}

function getQuestion(runId: string): Request {
  return new Request(`http://sidecar/agent/question/${runId}`, { method: "GET" });
}

function answer(runId: string, selected: string[]): Request {
  return new Request(`http://sidecar/agent/answer/${runId}`, {
    method: "POST",
    body: JSON.stringify({ answers: [{ id: APPROVAL_QUESTION_ID, selected }] }),
  });
}

/** First call requests one `opentype__bash` call for a destructive command; second call answers. */
function bashThenAnswerChat(finalAnswer: string, command: string): AgentChatFn {
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
            function: { name: "opentype__bash", arguments: JSON.stringify({ command }) },
          },
        ],
      };
    }
    return { content: finalAnswer };
  };
}

/** First call requests one call to `toolName` with `args`; second call answers. */
function toolThenAnswerChat(finalAnswer: string, toolName: string, args: unknown): AgentChatFn {
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
            function: { name: toolName, arguments: JSON.stringify(args) },
          },
        ],
      };
    }
    return { content: finalAnswer };
  };
}

interface RecordedCall {
  name: string;
  args: unknown;
}

/** A fake bash tool that records every call it actually receives -- proof the underlying tool ran. */
function makeBashToolSet(result: string): { tools: McpToolSet; calls: RecordedCall[] } {
  const calls: RecordedCall[] = [];
  return {
    tools: {
      openAiTools: [{ type: "function", function: { name: "opentype__bash" } }],
      callTool: async (name, args) => {
        calls.push({ name, args });
        return { content: result };
      },
    },
    calls,
  };
}

/** A fake tool set exposing a single named tool that records every call it actually receives. */
function makeSingleToolSet(
  toolName: string,
  result: string
): { tools: McpToolSet; calls: RecordedCall[] } {
  const calls: RecordedCall[] = [];
  return {
    tools: {
      openAiTools: [{ type: "function", function: { name: toolName } }],
      callTool: async (name, args) => {
        calls.push({ name, args });
        return { content: result };
      },
    },
    calls,
  };
}

/** Polls GET /agent/question/:runId until a question appears or the window elapses. */
async function pollForPendingQuestion(
  router: RouteHandler,
  runId: string,
  maxWaitMs = 500,
  stepMs = 20
): Promise<{ runId: string; questions: unknown[] }> {
  const deadline = Date.now() + maxWaitMs;
  for (;;) {
    const response = await router(getQuestion(runId));
    const body = (await response.json()) as { runId: string; questions: unknown[] };
    if (body.questions.length > 0 || Date.now() >= deadline) {
      return body;
    }
    await new Promise((resolve) => setTimeout(resolve, stepMs));
  }
}

describe("agent approval mode (§2.1)", () => {
  test(
    "default (no approvalMode passed) is yolo: a destructive bash call executes without ever posting a question",
    async () => {
      const command = "rm -rf /tmp/opentype-agent-approval-default-test";
      const chat = bashThenAnswerChat("done: cleaned up", command);
      const { tools, calls } = makeBashToolSet("bash-ran-under-default-mode");
      const router = createRouter(
        buildAgentRoutes(makeStore(), makeConversations(), chat, tools, captureContextLog().writer)
        // approvalMode intentionally omitted -- this is the "no flag passed" case.
      );
      const runId = "run-default-approval";

      const runPromise = router(post({ task: "clean up the temp folder", runId }));

      // Poll briefly for a pending question. Under the correct (yolo)
      // default this window finds nothing -- the run either already
      // finished or is executing the tool directly, never parked on
      // `broker.wait`. If the pre-implementation code is still
      // unconditionally prompting, this DOES find a pending question; we
      // then answer it so the run can finish and this test doesn't hang on
      // the real ~120s approval timeout.
      const pending = await pollForPendingQuestion(router, runId, 300, 15);
      if (pending.questions.length > 0) {
        await router(answer(runId, [APPROVAL_APPROVE_LABEL]));
      }

      const response = await runPromise;
      expect(response.status).toBe(200);

      // The actual claim: no question was ever posted for this destructive
      // call while running under the default mode.
      expect(pending.questions).toEqual([]);
      // And the underlying tool really did run (not silently no-op'd).
      expect(calls).toHaveLength(1);
      expect(calls[0]).toMatchObject({ name: "opentype__bash", args: { command } });
    },
    5_000
  );

  test(
    "approvalMode 'prompt': a destructive bash call posts a question and waits for it before running",
    async () => {
      const command = "rm -rf /tmp/opentype-agent-approval-prompt-test";
      const chat = bashThenAnswerChat("done: cleaned up", command);
      const { tools, calls } = makeBashToolSet("bash-ran-under-prompt-mode");
      const router = createRouter(
        buildAgentRoutes(
          makeStore(),
          makeConversations(),
          chat,
          tools,
          captureContextLog().writer,
          undefined, // spillRoot
          undefined, // runLogRoot
          // approvalMode -- see the file-level AMBIGUITY note above. §9.1
          // reconciled this and the skill-index/agent-definitions params
          // into one trailing options object.
          { approvalMode: "prompt" }
        )
      );
      const runId = "run-prompt-approval";

      const runPromise = router(post({ task: "clean up the temp folder", runId }));

      const pending = await pollForPendingQuestion(router, runId, 1_000, 20);
      expect(pending.questions.length).toBeGreaterThan(0);
      // The card shown must be about THIS command, not some other question.
      expect(JSON.stringify(pending.questions)).toContain("rm -rf");
      // And the tool must not have run yet -- prompting means waiting BEFORE
      // execution, not asking after the fact.
      expect(calls).toHaveLength(0);

      await router(answer(runId, [APPROVAL_APPROVE_LABEL]));
      const response = await runPromise;

      expect(response.status).toBe(200);
      expect(calls).toHaveLength(1);
      expect(calls[0]).toMatchObject({ name: "opentype__bash", args: { command } });
    },
    5_000
  );

  // Design §2.1's last bullet: "新增的 5 个文件工具本来就不被 classifyCommandRisk
  // 分类，所以在任一模式下都直接放行；这是有意的，不是遗漏。" This is the one
  // assertion in this file that does NOT depend on the coreTools.ts file-tool
  // handlers existing -- classifyCommandRisk only special-cases
  // `opentype__bash`/`opentype__python` by exact tool name (src/agent/commandRisk.ts),
  // so any other tool name (real or, as here, faked) is already "safe" today.
  // It is included in this pipeline's scope because it is the other half of
  // the approval-mode behavior §2.1 describes, and because a future change to
  // commandRisk.ts that started classifying file-tool names would silently
  // break this promise without a test like this one to catch it.
  test(
    "a file tool call (e.g. opentype__trash) is never classified as destructive, so it runs without a question even under 'prompt' mode",
    async () => {
      const toolName = "opentype__trash";
      const args = { path: "/tmp/opentype-agent-approval-file-tool-test/should-be-trashed.txt" };
      const chat = toolThenAnswerChat("done: trashed it", toolName, args);
      const { tools, calls } = makeSingleToolSet(toolName, "trashed-under-prompt-mode");
      const router = createRouter(
        buildAgentRoutes(
          makeStore(),
          makeConversations(),
          chat,
          tools,
          captureContextLog().writer,
          undefined, // spillRoot
          undefined, // runLogRoot
          // approvalMode -- see the file-level AMBIGUITY note above. §9.1
          // reconciled this and the skill-index/agent-definitions params
          // into one trailing options object.
          { approvalMode: "prompt" }
        )
      );
      const runId = "run-prompt-file-tool-exempt";

      const runPromise = router(post({ task: "trash that file", runId }));

      const pending = await pollForPendingQuestion(router, runId, 300, 15);
      const response = await runPromise;

      expect(response.status).toBe(200);
      expect(pending.questions).toEqual([]);
      expect(calls).toHaveLength(1);
      expect(calls[0]).toMatchObject({ name: toolName, args });
    },
    5_000
  );
});
