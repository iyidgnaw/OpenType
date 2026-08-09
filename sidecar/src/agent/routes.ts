import type { MemoryStore } from "../memory/MemoryStore";
import type { Route } from "../router";
import type { AgentChatFn } from "./loop";
import { runAgentLoop } from "./loop";
import type { McpToolSet } from "./mcpClient";
import { buildKnownTermsContext, findKnownTerms } from "../oneshot/memoryContext";
import { logContextUsage, type ContextUsageLogWriter } from "../oneshot/contextDebugLog";

interface AgentRunRequestBody {
  task?: string;
  context?: string;
}

async function readJsonBody<T>(req: Request): Promise<T> {
  return (await req.json()) as T;
}

async function handleAgentRun(
  req: Request,
  store: MemoryStore,
  chat: AgentChatFn,
  tools: McpToolSet,
  contextLogWriter: ContextUsageLogWriter
): Promise<Response> {
  const body = await readJsonBody<AgentRunRequestBody>(req);
  const task = body.task ?? "";
  const context = body.context;

  // Agent mode's known-terms context lookup runs against the same input
  // (task + any selected context) `runAgentLoop`'s optional `knownTerms`
  // field expects. That field already existed on `RunAgentLoopInput` but
  // nothing was populating it, so the fetched context was architecturally
  // present without ever reaching the model — wire it through here and log
  // it, so it's provable that Agent mode both reads *and uses* stored
  // context, the same as `/oneshot/ask` does.
  const relevantText = `${task} ${context ?? ""}`;
  const matchedTerms = findKnownTerms(store, relevantText);
  logContextUsage({ endpoint: "agent", inputText: task, matchedTerms }, contextLogWriter);
  const knownTerms = buildKnownTermsContext(store, relevantText);

  const loopResult = await runAgentLoop({ task, context, knownTerms }, { chat, tools });

  // Per design spec §4: the first real write with origin "agent" (distinct
  // from the owner's own dictation), so agent-produced content can be told
  // apart from the owner's words once it flows through consolidation.
  store.recordEpisodicEvent({
    mode: "agent",
    rawTranscript: task,
    correctedTranscript: task,
    effectiveInput: task,
    selectedContext: context ?? null,
    result: loopResult.result,
    applicationName: "OpenType Agent",
    origin: "agent",
  });

  return Response.json({ result: loopResult.result, steps: loopResult.steps });
}

/**
 * A single blocking call for tonight: `/agent/run` runs the whole loop and
 * returns the full progress log at once. There's no real-time progress
 * streaming to a UI yet (a Task List panel is a separate future task).
 */
export function buildAgentRoutes(
  store: MemoryStore,
  chat: AgentChatFn,
  tools: McpToolSet,
  contextLogWriter: ContextUsageLogWriter
): Route[] {
  return [
    {
      method: "POST",
      path: "/agent/run",
      handler: (req) => handleAgentRun(req, store, chat, tools, contextLogWriter),
    },
  ];
}
