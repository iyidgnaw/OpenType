import type { MemoryStore } from "../memory/MemoryStore";
import type { ConversationStore } from "../memory/conversations";
import type { Route } from "../router";
import type { AgentChatFn } from "./loop";
import { runAgentLoop } from "./loop";
import type { McpToolSet } from "./mcpClient";
import { buildKnownTermsContext, findKnownTerms } from "../oneshot/memoryContext";
import { logContextUsage, type ContextUsageLogWriter } from "../oneshot/contextDebugLog";
import { resolveConversation } from "../oneshot/routes";
import type { OneShotChatMessage } from "../oneshot/client";

interface AgentRunRequestBody {
  task?: string;
  context?: string;
  conversationId?: number;
}

async function readJsonBody<T>(req: Request): Promise<T> {
  return (await req.json()) as T;
}

/**
 * Renders prior conversation turns as a short "previous task / previous
 * result" summary block for the loop's prompt -- enough for the model to
 * know what was already asked and delivered on this same task, without
 * replaying the full internal tool-call step trace (`AgentProgressEvent[]`)
 * from earlier runs.
 */
function formatPriorTurns(messages: OneShotChatMessage[]): string | undefined {
  if (messages.length === 0) {
    return undefined;
  }
  const lines = messages.map((message) =>
    message.role === "user"
      ? `Previous task: ${message.content}`
      : `Previous result: ${message.content}`
  );
  return ["PREVIOUS CONVERSATION (for context; this is a follow-up on the same task):", ...lines].join(
    "\n"
  );
}

async function handleAgentRun(
  req: Request,
  store: MemoryStore,
  conversations: ConversationStore,
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
  const ownerFactsCount = store.allOwnerFacts().length;
  logContextUsage(
    { endpoint: "agent", inputText: task, matchedTerms, ownerFactsCount },
    contextLogWriter
  );
  const knownTerms = buildKnownTermsContext(store, relevantText);

  const { conversationId, priorMessages } = resolveConversation(
    conversations,
    "agent",
    body.conversationId,
    task
  );
  conversations.appendMessage(conversationId, "user", task);

  const priorTurnsSummary = formatPriorTurns(priorMessages);
  const combinedContext = [priorTurnsSummary, context].filter(Boolean).join("\n\n") || undefined;

  const loopResult = await runAgentLoop(
    { task, context: combinedContext, knownTerms },
    { chat, tools }
  );

  conversations.appendMessage(conversationId, "assistant", loopResult.result);

  // Per design spec §4: the first real write with origin "agent" (distinct
  // from the owner's own dictation), so agent-produced content can be told
  // apart from the owner's words once it flows through consolidation. Keeps
  // recording the caller's original `context` (not `combinedContext`), so
  // this stays a faithful record of what was actually selected on screen.
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

  return Response.json({ result: loopResult.result, steps: loopResult.steps, conversationId });
}

/**
 * A single blocking call for tonight: `/agent/run` runs the whole loop and
 * returns the full progress log at once. There's no real-time progress
 * streaming to a UI yet (a Task List panel is a separate future task).
 */
export function buildAgentRoutes(
  store: MemoryStore,
  conversations: ConversationStore,
  chat: AgentChatFn,
  tools: McpToolSet,
  contextLogWriter: ContextUsageLogWriter
): Route[] {
  return [
    {
      method: "POST",
      path: "/agent/run",
      handler: (req) => handleAgentRun(req, store, conversations, chat, tools, contextLogWriter),
    },
  ];
}
