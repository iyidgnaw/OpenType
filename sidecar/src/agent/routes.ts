import type { MemoryStore } from "../memory/MemoryStore";
import type { ConversationStore } from "../memory/conversations";
import type { Route } from "../router";
import { ApiError } from "../router";
import type { AgentChatFn } from "./loop";
import { runAgentLoop } from "./loop";
import type { McpToolSet } from "./mcpClient";
import type { AgentProgressRegistry } from "./progressRegistry";
import { createAgentProgressRegistry } from "./progressRegistry";
import { buildKnownTermsContext, findKnownTerms } from "../oneshot/memoryContext";
import { buildTimeContext } from "../context/timeContext";
import { saveSpill } from "./spill";
import { logContextUsage, type ContextUsageLogWriter } from "../oneshot/contextDebugLog";
import { resolveConversation } from "../oneshot/routes";
import type { OneShotChatMessage } from "../oneshot/client";

interface AgentRunRequestBody {
  task?: string;
  context?: string;
  conversationId?: number;
  /**
   * Optional client-generated id for live progress polling. When present the
   * run is registered in the progress registry and its loop events become
   * visible via `GET /agent/progress/:runId`; when absent, behavior and the
   * response shape are exactly as before and nothing is registered.
   */
  runId?: string;
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
 *
 * MODEL EXPERIENCE: this block reaches the model verbatim inside `CONTEXT:`,
 * and grows linearly with conversation length with no cap and no compaction.
 * See `docs/model-context-inventory.md` §3.3 — update it in the SAME change
 * that alters this rendering.
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
  contextLogWriter: ContextUsageLogWriter,
  progressRegistry: AgentProgressRegistry,
  spillRoot?: string
): Promise<Response> {
  const body = await readJsonBody<AgentRunRequestBody>(req);
  const task = body.task ?? "";
  if (String(task).trim() === "") {
    throw new ApiError("task is required", 400);
  }
  const context = body.context;
  const runId =
    typeof body.runId === "string" && body.runId.length > 0 ? body.runId : undefined;

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

  // With a `runId`, the loop's (previously unused) `onProgress` hook feeds
  // the in-memory progress registry so `GET /agent/progress/:runId` can show
  // a live feed while this blocking call is still running. The run is marked
  // `done`/`failed` the moment the loop resolves/throws; a throw is rethrown
  // unchanged so the router's existing error-envelope behavior (500 etc.) is
  // untouched.
  if (runId) {
    progressRegistry.register(runId);
  }
  let loopResult;
  try {
    loopResult = await runAgentLoop(
      { task, context: combinedContext, knownTerms, runtimeContext: buildTimeContext() },
      {
        chat,
        tools,
        onProgress: runId ? (event) => progressRegistry.append(runId, event) : undefined,
        // The loop knows nothing about run ids or spill roots; this closure
        // supplies both, keeping that seam to "here is text, give me a
        // locator" (T2). Omitted when no root is configured, which restores
        // the pre-spill truncate-and-discard behavior exactly.
        spill: spillRoot
          ? (text, toolName) => saveSpill(text, { toolName, runId }, spillRoot)
          : undefined,
      }
    );
  } catch (error) {
    if (runId) {
      progressRegistry.finish(runId, "failed");
    }
    throw error;
  }
  if (runId) {
    progressRegistry.finish(runId, "done");
  }

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
 * Reads the progress snapshot for one run. An unknown id is not an error —
 * it's "nothing to show" — so it returns 200 with
 * `{ status: "unknown", events: [] }` rather than a 404 (spec §2).
 */
function handleAgentProgress(req: Request, progressRegistry: AgentProgressRegistry): Response {
  const pathname = new URL(req.url).pathname;
  const runId = decodeURIComponent(pathname.slice(pathname.lastIndexOf("/") + 1));
  return Response.json(progressRegistry.get(runId));
}

/**
 * `/agent/run` is still a single blocking call: it runs the whole loop and
 * returns the full (untruncated) step log at once. Live feedback comes from
 * the sidecar-internal progress registry created here: a run dispatched with
 * a client-generated `runId` streams its loop events into it, and
 * `GET /agent/progress/:runId` serves the display-truncated snapshot for the
 * floating progress panel to poll while the run is in flight.
 */
export function buildAgentRoutes(
  store: MemoryStore,
  conversations: ConversationStore,
  chat: AgentChatFn,
  tools: McpToolSet,
  contextLogWriter: ContextUsageLogWriter,
  spillRoot?: string
): Route[] {
  const progressRegistry = createAgentProgressRegistry();
  return [
    {
      method: "POST",
      path: "/agent/run",
      handler: (req) =>
        handleAgentRun(
          req,
          store,
          conversations,
          chat,
          tools,
          contextLogWriter,
          progressRegistry,
          spillRoot
        ),
    },
    {
      method: "GET",
      path: "/agent/progress/:runId",
      handler: (req) => handleAgentProgress(req, progressRegistry),
    },
  ];
}
