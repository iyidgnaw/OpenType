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
import {
  buildRecentActivityContext,
  RECENT_ACTIVITY_EXCLUDED_MODES,
  RECENT_ACTIVITY_LIMIT,
} from "../memory/recentActivity";
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
import { createPromptingApprovalPolicy, withApproval, yoloApprovalPolicy } from "./approval";
import {
  AgentCancelledError,
  createCancellationRegistry,
  runBudgetSignal,
  type CancellationRegistry,
} from "./cancellation";
import { logContextUsage, type ContextUsageLogWriter } from "../oneshot/contextDebugLog";
import { resolveConversation } from "../oneshot/routes";
import type { OneShotChatMessage } from "../oneshot/client";
import { renderSkillIndex, type Skill } from "../skills/skillStore";
import { AGENT_SYSTEM_PROMPT } from "../oneshot/prompts";
import {
  applyAgentToolAllowlist,
  buildAgentSystemPrompt,
  resolveAgentFromTask,
  type AgentDefinition,
} from "./agentDefinitions";

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
  /**
   * Explicit agent selection (design §4.4's second, future-UI path) --
   * precedence over the voice-prefix match `resolveAgentFromTask` performs
   * on `task` itself. An unrecognised name is a caller error (400): unlike a
   * voice prefix that simply fails to match anything (which just means "no
   * agent selected", not a mistake), a client that names a specific agent
   * and gets a different, or no, persona back would silently misfire.
   */
  agentName?: string;
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
 * Injectable source for the skill index (design §3.3/§3.4,
 * docs/superpowers/specs/2026-08-28-first-party-tools-skills-and-agents-design.md).
 * Shaped as a store (`{ list(): Skill[] }`, the same shape `createSkillStore`
 * returns) rather than a pre-rendered string, so `handleAgentRun` renders it
 * fresh -- and picks up the skill store's own short TTL cache (design §5) --
 * on every `/agent/run` call instead of freezing it at server-boot time.
 */
export interface SkillIndexSource {
  list(): Skill[];
}

/**
 * Injectable source for agent definitions + AGENTS.md global instructions
 * (design §4, §4.5). `list()` is the discovered `AgentDefinition[]`
 * (`agentDefinitions.ts`'s `createAgentDefinitionStore`, TTL-cached the same
 * way the skill store is); `globalInstructions()` is the already-assembled
 * `AGENTS.md` text (`loadGlobalInstructions`, called with whichever root
 * list `server.ts` resolved -- the `~/.claude` exclusion, design §9.2/§9.4,
 * lives entirely in which roots that call is given, not in anything here).
 * Both are re-read fresh per call, same reasoning as `SkillIndexSource`
 * above.
 */
export interface AgentDefinitionsSource {
  list(): AgentDefinition[];
  globalInstructions(): string | undefined;
}

/**
 * §9.1's reconciled trailing options object: this batch's three concurrent
 * lines (approval mode, skill index, agent definitions) each wanted to add a
 * parameter to `buildAgentRoutes`; rather than stack three more positional
 * arguments after `spillRoot`/`runLogRoot` (which stay positional --
 * pre-existing, and every pre-existing call site already relies on their
 * position), all three land here as one options object instead. Every field
 * optional and every pre-existing call site (none of which pass an 8th
 * argument at all) keeps compiling and gets exactly today's behavior:
 * `approvalMode` defaults to `"yolo"`, no skill index is injected, no agent
 * selection or AGENTS.md happens.
 */
export interface AgentRouteOptions {
  /** §2.1: `"yolo"` (default -- no prompting) or `"prompt"` (today's always-prompt-on-destructive behavior). */
  approvalMode?: "yolo" | "prompt";
  /** §3.3/§3.4: source for the always-resident skill index. */
  skills?: SkillIndexSource;
  /** §4/§4.5: source for agent-name/voice-prefix selection and AGENTS.md global instructions. */
  agentDefinitions?: AgentDefinitionsSource;
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
  cancellations: CancellationRegistry,
  askUser: AskUserBroker,
  spillRoot?: string,
  runLog?: RunLog,
  approvalMode: "yolo" | "prompt" = "yolo",
  skillStore?: SkillIndexSource,
  agentDefinitions?: AgentDefinitionsSource
): Promise<Response> {
  const body = await readJsonBody<AgentRunRequestBody>(req);
  const rawTask = body.task ?? "";
  if (String(rawTask).trim() === "") {
    throw new ApiError("task is required", 400);
  }
  const context = body.context;
  const runId =
    typeof body.runId === "string" && body.runId.length > 0 ? body.runId : undefined;

  // Agent selection (design §4.4/§9.3): an explicit `agentName` wins outright
  // over the task's own voice prefix. An unrecognised explicit name is a
  // caller error (400) -- distinct from a voice prefix that simply fails to
  // match anything, which is not an error at all, just "no agent selected".
  //
  // Stripping is task hygiene, not a side effect of selection: whichever
  // agent ends up running, the task text it sees should never carry a
  // leading address to somebody else (or to itself). `resolveAgentFromTask`
  // scoped to a SINGLETON candidate list (`[explicit]`) reuses its exact
  // matching/stripping logic to answer "does the task's own prefix address
  // THIS agent" without re-deriving that logic here -- if the task's prefix
  // names a *different* agent than the one `agentName` explicitly selected,
  // nothing is stripped, since there is nothing addressing the agent that is
  // actually about to run.
  const definitionsList = agentDefinitions?.list() ?? [];
  let selectedDefinition: AgentDefinition | undefined;
  let task: string;
  if (typeof body.agentName === "string" && body.agentName.length > 0) {
    const explicit = definitionsList.find((definition) => definition.name === body.agentName);
    if (!explicit) {
      throw new ApiError(`Unknown agent: "${body.agentName}"`, 400);
    }
    selectedDefinition = explicit;
    task = resolveAgentFromTask(rawTask, [explicit]).task;
  } else {
    const resolved = resolveAgentFromTask(rawTask, definitionsList);
    selectedDefinition = resolved.definition;
    task = resolved.task;
  }

  // Composition is base -> agent body -> AGENTS.md global instructions
  // (design §4.2/§4.5), always APPENDING -- never replacing -- the base
  // prompt, which stays the harness's own defense regardless of what any
  // agent file or AGENTS.md says. With no agent selected and no global
  // instructions configured, this is byte-identical to `AGENT_SYSTEM_PROMPT`
  // (today's behavior, unchanged).
  const globalInstructions = agentDefinitions?.globalInstructions();
  const systemPrompt = buildAgentSystemPrompt(AGENT_SYSTEM_PROMPT, selectedDefinition, globalInstructions);
  // §4.3: a selected agent's `tools` frontmatter narrows the tool set THIS
  // run's model calls can see -- applied to the base merged set, before the
  // per-run `ask_user` tool below is added in, so an agent's tools allowlist
  // can never accidentally remove the harness's own ask-the-user escape
  // hatch (that isn't a "hand or foot" tool a persona author is choosing
  // between, it's plumbing).
  const runTools = selectedDefinition ? applyAgentToolAllowlist(tools, selectedDefinition) : tools;

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
  // Last RECENT_ACTIVITY_LIMIT episodic events across all three modes (Task
  // 10, spec §3.5) -- `RECENT_ACTIVITY_EXCLUDED_MODES` is empty on purpose,
  // so a plain dictation shows up here too. `includeIds: true` because agent
  // does carry `opentype__read_history` (registered in `coreTools.ts`), so
  // it can expand any `eventId`/`conversationId` it sees here -- the mirror
  // image of ask's `includeIds: false` in `oneshot/routes.ts`.
  const recentActivity = buildRecentActivityContext(
    store.recentEvents(RECENT_ACTIVITY_LIMIT, { excludeModes: RECENT_ACTIVITY_EXCLUDED_MODES }),
    { includeIds: true }
  );

  const { conversationId, priorMessages } = resolveConversation(
    conversations,
    "agent",
    body.conversationId,
    task
  );
  conversations.appendMessage(conversationId, "user", task);

  const priorTurnsSummary = formatPriorTurns(priorMessages);
  const combinedContext = [priorTurnsSummary, context].filter(Boolean).join("\n\n") || undefined;

  // Rendered fresh per request (design §3.3/§3.4): a skill file added since
  // the last call must be visible without a restart, bounded only by the
  // skill store's own short TTL cache. `undefined` when no store is wired
  // up (every pre-existing call site) so `RunAgentLoopInput.skills` is
  // simply omitted, matching today's behavior exactly.
  const skills = skillStore ? renderSkillIndex(skillStore.list()) : undefined;

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
      {
        task,
        context: combinedContext,
        knownTerms,
        runtimeContext: buildTimeContext(),
        recentActivity,
        skills,
        // undefined when no agent was selected and no AGENTS.md exists --
        // `buildAgentSystemPrompt` returns `AGENT_SYSTEM_PROMPT` unchanged in
        // that case, and `runAgentLoop` defaults to the same constant when
        // `systemPrompt` is omitted, so passing it explicitly here changes
        // nothing about today's behavior.
        systemPrompt,
      },
      {
        chat,
        // ask_user is built per run because it must address THIS run's
        // surface; merged in here rather than living in the shared set for
        // that reason (T5).
        //
        // P1-6 wraps that same per-run set in an approval policy, and it has
        // to happen here rather than where `server.ts` assembles the tool
        // set: asking needs this run's id, this run's cancellation signal,
        // and the broker, none of which exist at construction time. MCP
        // tools stay inside the wrapper, as they have been since the seam
        // landed -- `runTools` is the merged set, already narrowed by the
        // selected agent's `tools` allowlist if it has one (§4.3).
        //
        // Which policy depends on `approvalMode` (§2.1 of
        // docs/superpowers/specs/2026-08-28-first-party-tools-skills-and-agents-design.md,
        // threaded down from `env.agentApprovalMode` via `buildAgentRoutes`).
        // `yolo` is the default per the owner's §0 stance ("闸门默认打开") --
        // no prompting for destructive commands. This demotes
        // `createPromptingApprovalPolicy`/`commandRisk.ts`'s 942-line risk
        // tokeniser to opt-in; nothing about either was deleted, so flipping
        // `OPENTYPE_AGENT_APPROVAL=prompt` restores today's behavior exactly.
        tools: withApproval(
          mergeToolSets(
            runTools,
            createAskUserTool(askUser, { runId, timeoutMs: ASK_USER_TIMEOUT_MS })
          ),
          approvalMode === "prompt"
            ? createPromptingApprovalPolicy({
                broker: askUser,
                runId,
                timeoutMs: APPROVAL_TIMEOUT_MS,
                signal,
              })
            : yoloApprovalPolicy
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
      // A cancelled run is not a failed one. It gets its own terminal status
      // and its own status code. This route no longer writes an episodic
      // memory event on ANY path -- success, failure, or cancellation --
      // since that write moved to Swift's single write point
      // (`POST /memory/events`, design §3.2), which only fires once a
      // delivery actually completes. So there is nothing special about the
      // cancel path here to record or skip. The user message already
      // appended to the conversation stays, because it did happen.
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
 * Lists every discovered agent definition (design §4.4's "供将来的 UI 与调试
 * 使用"), narrowed to just name/description/source-root/tools -- not the
 * full internal `AgentDefinition` shape (which also carries the raw
 * markdown `body`/`path`/`model`), since nothing here needs a debug/UI
 * surface to echo an agent's entire system-prompt text back over HTTP. No
 * `agentDefinitions` source configured (every pre-existing call site) means
 * an empty list, not an error -- this route existing at all is opt-in.
 */
function handleAgentDefinitions(agentDefinitions?: AgentDefinitionsSource): Response {
  const definitions = (agentDefinitions?.list() ?? []).map((definition) => ({
    name: definition.name,
    description: definition.description,
    root: definition.root,
    tools: definition.tools,
  }));
  return Response.json(definitions);
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
  runLogRoot?: string,
  // §9.1: one trailing options object -- see `AgentRouteOptions`'s doc
  // comment for why this replaced three separate trailing parameters.
  // Omitted (every pre-existing call site), every field below falls back to
  // its own "exactly today's behavior" default.
  options?: AgentRouteOptions
): Route[] {
  const approvalMode = options?.approvalMode ?? "yolo";
  const skillStore = options?.skills;
  const agentDefinitions = options?.agentDefinitions;
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
          runLog,
          approvalMode,
          skillStore,
          agentDefinitions
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
    {
      method: "GET",
      path: "/agent/definitions",
      handler: () => handleAgentDefinitions(agentDefinitions),
    },
  ];
}
