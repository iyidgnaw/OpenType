import { AGENT_SYSTEM_PROMPT } from "../oneshot/prompts";
import type { McpToolSet } from "./mcpClient";
import { spillOrClamp } from "./spill";
import type { RepeatGuard } from "./repeatGuard";
import { AgentCancelledError } from "./cancellation";

/**
 * Agent-loop message shape. Deliberately not reusing `OneShotChatFn` from
 * `sidecar/src/oneshot/client.ts` (spec 3 §2 allows an equivalent instead) --
 * that type's messages have no room for `tool_calls`/`tool_call_id`, which
 * this loop needs for OpenAI-style tool-calling. Structurally identical to
 * `DeepSeekMessage` in `sidecar/src/provider/deepseek.ts`, so
 * `createDeepSeekClient(env).chat` satisfies `AgentChatFn` as-is.
 */
export interface AgentChatMessage {
  role: string;
  content: string | null;
  tool_calls?: unknown[];
  tool_call_id?: string;
  name?: string;
}

export interface AgentChatResult {
  content: string | null;
  toolCalls?: unknown[];
}

export type AgentChatFn = (
  messages: AgentChatMessage[],
  options?: { tools?: unknown[]; signal?: AbortSignal }
) => Promise<AgentChatResult>;

export type AgentProgressEvent =
  | { type: "thinking"; detail: string }
  | { type: "tool_call"; detail: string }
  | { type: "tool_result"; detail: string }
  | { type: "done"; detail: string }
  | { type: "error"; detail: string };

/**
 * The three optional fields below (`systemPrompt`, `priorMessages`,
 * `maxIterations`) generalize this loop for `/oneshot/ask`'s web-only reuse
 * (open-file + ask-web design,
 * docs/superpowers/specs/2026-08-13-b2-open-file-and-ask-web-design.md §2).
 * Each defaults to the loop's original behavior exactly: the agent system
 * prompt, no replayed history, the 10-iteration cap.
 */
export interface RunAgentLoopInput {
  task: string;
  context?: string;
  knownTerms?: string;
  /**
   * Trusted, harness-supplied runtime facts -- currently the wall-clock
   * anchor from `context/timeContext.ts` (T4).
   *
   * Deliberately NOT folded into `context`: the agent system prompt tells the
   * model to treat CONTEXT as UNTRUSTED data and never act on instructions
   * inside it, which is exactly wrong for a fact the harness itself asserts
   * and wants the model to rely on. Kept separate from `knownTerms` for the
   * same explicit-over-implicit reason -- one field, one source, one entry in
   * `docs/model-context-inventory.md`.
   */
  runtimeContext?: string;
  /**
   * Last few episodic events spanning all three modes, rendered by
   * `memory/recentActivity.ts`'s `buildRecentActivityContext` (T9/T10, spec
   * §3.5).
   *
   * Appended to the FINAL USER MESSAGE, in the same place and for the same
   * reason as `knownTerms`/`runtimeContext` above: it changes on every
   * request (a new episodic row invalidates it), and content that changes
   * per-request must never land in the system message -- doing so would
   * invalidate the whole KV-cache prefix on every call
   * (`docs/model-context-inventory.md` §5). This field is exactly that kind
   * of content, so it follows the same rule, not a style choice.
   */
  recentActivity?: string;
  /**
   * Rendered skill index (`skills/skillStore.ts`'s `renderSkillIndex`) --
   * first-party tools/skills/agents design §3.4
   * (docs/superpowers/specs/2026-08-28-first-party-tools-skills-and-agents-design.md).
   *
   * Appended to the FINAL USER MESSAGE, after `recentActivity`, for the same
   * reason `knownTerms`/`runtimeContext`/`recentActivity` all live there and
   * not in the system message: a skill file can be added at any moment (no
   * hot-reload, but a 5s TTL cache means the very next request can see a new
   * one), so this content changes between requests in a way the system
   * message must never do -- landing it there would invalidate the whole
   * KV-cache prefix on every single call (`docs/model-context-inventory.md`
   * §5). Ask mode never sets this: its toolset is a web-only allowlist that
   * does not include `opentype__load_skill`, so an index it can't act on
   * would just be wasted context.
   */
  skills?: string;
  /** System message content; defaults to `AGENT_SYSTEM_PROMPT`. */
  systemPrompt?: string;
  /**
   * Prior conversation turns, replayed verbatim (same objects, same order)
   * between the system message and the final user message -- real
   * message-array replay, not a squashed summary.
   */
  priorMessages?: AgentChatMessage[];
  /** Loop iteration cap; defaults to `MAX_ITERATIONS` (10). */
  maxIterations?: number;
}

export interface RunAgentLoopDeps {
  chat: AgentChatFn;
  tools: McpToolSet;
  onProgress?: (event: AgentProgressEvent) => void;
  /**
   * Persists one oversized tool result and returns its locator, or `null`
   * when it could not be stored (T2). Omitted, an oversized result is
   * truncated exactly as before -- so a caller that has nowhere to spill
   * (tests, the ask path before it opts in) keeps the original behavior.
   *
   * The loop deliberately does not know about run ids or spill roots: the
   * caller closes over both, keeping this seam to "here is text, give me a
   * locator".
   */
  spill?: (text: string, toolName: string) => Promise<string | null>;
  /**
   * Advisory repeat-call breaker (T3). One instance per run -- a chain must
   * never leak between runs. Omitted, the loop behaves exactly as before.
   */
  repeatGuard?: RepeatGuard;
  /**
   * Cancellation for the whole run (T1): checked before every model call and
   * after every tool call, and handed to each tool so an in-flight subprocess
   * or fetch is actually abandoned rather than merely ignored on return.
   *
   * Aborting rejects with the signal's reason, so a caller can tell a user
   * cancellation from a budget expiry. Omitted, the loop runs exactly as
   * before.
   */
  signal?: AbortSignal;
}

export interface RunAgentLoopResult {
  result: string;
  steps: AgentProgressEvent[];
}

/** Per spec 3 §3: "something in the 8-12 range"; 10 is this implementation's pick. */
const MAX_ITERATIONS = 10;

/**
 * Budget for a single tool result before it is fed back into the next chat
 * call. A tool that returns a huge string would otherwise blow up the context
 * (Bug P2); kept well under the router's 50k ceiling so an oversized result is
 * clamped long before it can wedge the request path.
 */
const MAX_TOOL_RESULT_CHARS = 20_000;

/**
 * Re-exported from `./spill`, which owns tool-result bounding since T2 added
 * the spill path beside this truncation. Kept exported here because it was
 * this module's public helper first and is imported as such.
 */
export { clampToolResult } from "./spill";

/**
 * Reject with the signal's own reason so the cause (`user` vs `budget`)
 * survives; a bare `AbortError` would lose the distinction the caller needs
 * to report the run honestly.
 */
function throwIfCancelled(signal: AbortSignal | undefined): void {
  if (signal?.aborted) {
    throw signal.reason instanceof Error
      ? signal.reason
      : new AgentCancelledError("user");
  }
}

interface OpenAiToolCall {
  id: string;
  type: "function";
  function: { name: string; arguments: string };
}

function isOpenAiToolCall(value: unknown): value is OpenAiToolCall {
  if (!value || typeof value !== "object") {
    return false;
  }
  const candidate = value as Partial<OpenAiToolCall>;
  return (
    typeof candidate.id === "string" &&
    typeof candidate.function === "object" &&
    candidate.function !== null &&
    typeof (candidate.function as { name?: unknown }).name === "string"
  );
}

/**
 * MODEL EXPERIENCE: this function IS the message-array assembly every model
 * request goes through (`docs/model-context-inventory.md` §1.1). Changing the
 * order or framing here changes what every mode's model sees — update that
 * document in the SAME change.
 */
function buildInitialMessages(input: RunAgentLoopInput): AgentChatMessage[] {
  const userContentParts = [`TASK:`, input.task];
  if (input.context) {
    userContentParts.push("", "CONTEXT:", input.context);
  }
  if (input.knownTerms) {
    userContentParts.push("", input.knownTerms);
  }
  if (input.runtimeContext) {
    userContentParts.push("", input.runtimeContext);
  }
  if (input.recentActivity) {
    userContentParts.push("", input.recentActivity);
  }
  if (input.skills) {
    userContentParts.push("", input.skills);
  }

  return [
    { role: "system", content: input.systemPrompt ?? AGENT_SYSTEM_PROMPT },
    ...(input.priorMessages ?? []),
    { role: "user", content: userContentParts.join("\n") },
  ];
}

/**
 * Runs the Agent-mode loop (spec 3 §3): build messages -> call the model with
 * the connected MCP tools attached -> execute any requested tool calls ->
 * loop back, until the model returns a plain final answer or the iteration
 * cap is hit. A single blocking call for tonight -- `steps` is the full
 * progress log, returned all at once at the end; `onProgress` is only a hook
 * for a caller that wants to observe as it happens, not a stream.
 */
export async function runAgentLoop(
  input: RunAgentLoopInput,
  deps: RunAgentLoopDeps
): Promise<RunAgentLoopResult> {
  const { chat, tools, onProgress, spill, repeatGuard, signal } = deps;
  const maxIterations = input.maxIterations ?? MAX_ITERATIONS;
  const messages = buildInitialMessages(input);
  const steps: AgentProgressEvent[] = [];

  function emit(event: AgentProgressEvent): void {
    steps.push(event);
    onProgress?.(event);
  }

  let lastContent: string | null = null;

  for (let iteration = 0; iteration < maxIterations; iteration++) {
    // Checked BEFORE the model call, so an abort that lands between steps
    // costs nothing: no request is issued and no tokens are spent.
    throwIfCancelled(signal);
    emit({ type: "thinking", detail: `Thinking (step ${iteration + 1}/${maxIterations})...` });

    const response = await chat(messages, { tools: tools.openAiTools, signal });
    lastContent = response.content ?? lastContent;

    const toolCalls = (response.toolCalls ?? []).filter(isOpenAiToolCall);
    if (toolCalls.length === 0) {
      const result = response.content ?? "";
      emit({ type: "done", detail: result });
      return { result, steps };
    }

    messages.push({
      role: "assistant",
      content: response.content ?? null,
      tool_calls: response.toolCalls,
    });

    for (const toolCall of toolCalls) {
      emit({
        type: "tool_call",
        detail: `Calling ${toolCall.function.name}(${toolCall.function.arguments})`,
      });

      let toolResultContent: string;
      try {
        const parsedArgs = toolCall.function.arguments
          ? JSON.parse(toolCall.function.arguments)
          : {};
        const toolResult = await tools.callTool(toolCall.function.name, parsedArgs, signal);
        toolResultContent = toolResult.content;
        emit({ type: "tool_result", detail: toolResultContent });
      } catch (err) {
        // A cancellation is not a tool failure to report back to the model:
        // it ends the run. Rethrowing here also stops the remaining calls in
        // this batch from being issued.
        if (err instanceof AgentCancelledError) {
          throw err;
        }
        toolResultContent = `Error calling tool ${toolCall.function.name}: ${
          err instanceof Error ? err.message : String(err)
        }`;
        emit({ type: "error", detail: toolResultContent });
      }

      messages.push({
        role: "tool",
        tool_call_id: toolCall.id,
        name: toolCall.function.name,
        content: await spillOrClamp(toolResultContent, {
          maxInline: MAX_TOOL_RESULT_CHARS,
          save: spill
            ? () => spill(toolResultContent, toolCall.function.name)
            : undefined,
        }),
      });

      // The reminder rides as its own user message AFTER the tool result,
      // never as a replacement for that result's content: the result stays
      // the tool's own output so the step log and any audit of it remain
      // faithful. Observation happens for every call including denied ones --
      // a model hammering a call the approval policy keeps refusing is
      // exactly the loop worth breaking, and a denial arrives here as an
      // ordinary result string.
      const reminder = repeatGuard?.observe(
        toolCall.function.name,
        toolCall.function.arguments ?? ""
      );
      if (reminder) {
        emit({ type: "thinking", detail: reminder });
        messages.push({ role: "user", content: reminder });
      }
    }
  }

  const cappedResult =
    lastContent && lastContent.length > 0
      ? lastContent
      : "The agent ran out of steps before reaching a final answer.";
  emit({ type: "error", detail: "Hit the iteration cap without a final answer." });
  return { result: cappedResult, steps };
}
