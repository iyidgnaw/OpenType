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
import { createRepeatGuard } from "./repeatGuard";
import { createRunLog, type RunLog } from "./runLog";
import {
  createAskUserBroker,
  createAskUserTool,
  type AskUserAnswer,
  type AskUserBroker,
} from "./askUser";
import { mergeToolSets } from "./toolSets";
import { createPromptingApprovalPolicy, withApproval } from "./approval";
import {
  AgentCancelledError,
  createCancellationRegistry,
  runBudgetSignal,
  type CancellationRegistry,
} from "./cancellation";
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
 * How long a question waits for a human before the agent gives up. The
 * backstop against a question outliving the user's attention: the voice
 * surface is transient, so a user who starts speaking again never sees the
 * pending question at all (spec §13.4).
 */
const ASK_USER_TIMEOUT_MS = 120_000;

/**
 * How long a destructive-command approval card waits (P1-6). Same number and
 * same reasoning as the question timeout above -- a card the user never saw
 * (they started speaking again, they walked away) must expire rather than hold
 * the run open forever, and expiring reads as `unavailable`, never as consent.
 */
const APPROVAL_TIMEOUT_MS = 120_000;

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
  cancellations: CancellationRegistry,
  askUser: AskUserBroker,
  spillRoot?: string,
  runLog?: RunLog
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
  // Only a run the client identified can be cancelled: without a runId there
  // is nothing for `POST /agent/cancel/:runId` to address. The budget still
  // applies either way, so an unidentified run cannot block forever.
  const signal = runBudgetSignal(runId ? cancellations.register(runId) : undefined);
  let loopResult;
  try {
    loopResult = await runAgentLoop(
      { task, context: combinedContext, knownTerms, runtimeContext: buildTimeContext() },
      {
        chat,
        // ask_user is built per run because it must address THIS run's
        // surface; merged in here rather than living in the shared set for
        // that reason (T5).
        //
        // P1-6 wraps that same per-run set in the prompting approval policy,
        // and it has to happen here rather than where `server.ts` assembles
        // the tool set: asking needs this run's id, this run's cancellation
        // signal, and the broker, none of which exist at construction time.
        // MCP tools stay inside the wrapper, as they have been since the
        // seam landed -- `tools` is the whole merged set.
        tools: withApproval(
          mergeToolSets(
            tools,
            createAskUserTool(askUser, { runId, timeoutMs: ASK_USER_TIMEOUT_MS })
          ),
          createPromptingApprovalPolicy({
            broker: askUser,
            runId,
            timeoutMs: APPROVAL_TIMEOUT_MS,
            signal,
          })
        ),
        // One producer, two consumers (T7): the durable log keeps the full
        // record, the display registry keeps its bounded view of it. The log
        // append is fire-and-forget -- it never rejects, and awaiting it here
        // would put disk latency inside the agent's step loop.
        onProgress: runId
          ? (event) => {
              progressRegistry.append(runId, event);
              void runLog?.append(runId, event);
            }
          : undefined,
        // The loop knows nothing about run ids or spill roots; this closure
        // supplies both, keeping that seam to "here is text, give me a
        // locator" (T2). Omitted when no root is configured, which restores
        // the pre-spill truncate-and-discard behavior exactly.
        spill: spillRoot
          ? (text, toolName) => saveSpill(text, { toolName, runId }, spillRoot)
          : undefined,
        // One guard per run: chains must never leak between runs (T3).
        repeatGuard: createRepeatGuard(),
        signal,
      }
    );
  } catch (error) {
    if (error instanceof AgentCancelledError) {
      // A cancelled run is not a failed one. It gets its own terminal status,
      // its own status code, and -- deliberately -- NO episodic memory event:
      // an abandoned run is not a task the user completed, so recording it
      // would teach the memory layer from work that never happened. The user
      // message already appended to the conversation stays, because it did
      // happen.
      if (runId) {
        progressRegistry.finish(runId, "cancelled");
        cancellations.release(runId);
      }
      // 499 is the discriminator Swift keys on. No extra `code` field: the
      // router renders only `{ error: message }`, so one would be dead
      // weight that reads as machine-readable without being reachable.
      throw new ApiError(error.message, 499);
    }
    if (runId) {
      progressRegistry.finish(runId, "failed");
      cancellations.release(runId);
    }
    throw error;
  }
  if (runId) {
    progressRegistry.finish(runId, "done");
    cancellations.release(runId);
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

/** Serves the question one run is currently waiting on, for the UI to render. */
function handleAgentQuestion(req: Request, askUser: AskUserBroker): Response {
  const pathname = new URL(req.url).pathname;
  const runId = decodeURIComponent(pathname.slice(pathname.lastIndexOf("/") + 1));
  return Response.json(askUser.pending(runId) ?? { runId, questions: [] });
}

/** Delivers the user's answer back to the waiting run. */
async function handleAgentAnswer(req: Request, askUser: AskUserBroker): Promise<Response> {
  const pathname = new URL(req.url).pathname;
  const runId = decodeURIComponent(pathname.slice(pathname.lastIndexOf("/") + 1));
  const body = await readJsonBody<AskUserAnswer>(req);
  askUser.answer(runId, { answers: Array.isArray(body?.answers) ? body.answers : [] });
  return Response.json({ delivered: true });
}

/**
 * Cancels one in-flight run. An unknown id is not an error -- it is
 * "nothing to cancel" -- so it answers 200 with `{ cancelled: false }`,
 * matching the precedent `GET /agent/progress/:runId` set for unknown ids.
 */
function handleAgentCancel(req: Request, cancellations: CancellationRegistry): Response {
  const pathname = new URL(req.url).pathname;
  const runId = decodeURIComponent(pathname.slice(pathname.lastIndexOf("/") + 1));
  return Response.json({ cancelled: cancellations.cancel(runId) });
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
  spillRoot?: string,
  runLogRoot?: string
): Route[] {
  const progressRegistry = createAgentProgressRegistry();
  const cancellations = createCancellationRegistry();
  const runLog = runLogRoot ? createRunLog(runLogRoot) : undefined;
  const askUser = createAskUserBroker();
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
          cancellations,
          askUser,
          spillRoot,
          runLog
        ),
    },
    {
      method: "GET",
      path: "/agent/progress/:runId",
      handler: (req) => handleAgentProgress(req, progressRegistry),
    },
    {
      method: "POST",
      path: "/agent/cancel/:runId",
      handler: (req) => handleAgentCancel(req, cancellations),
    },
    {
      method: "GET",
      path: "/agent/question/:runId",
      handler: (req) => handleAgentQuestion(req, askUser),
    },
    {
      method: "POST",
      path: "/agent/answer/:runId",
      handler: (req) => handleAgentAnswer(req, askUser),
    },
  ];
}
