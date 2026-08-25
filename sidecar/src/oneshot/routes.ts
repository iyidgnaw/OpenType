import type { AgentChatFn } from "../agent/loop";
import { runAgentLoop } from "../agent/loop";
import { filterToolSet, type ToolSet } from "../agent/toolSets";
import { buildTimeContext } from "../context/timeContext";
import type { MemoryStore } from "../memory/MemoryStore";
import type { ConversationStore } from "../memory/conversations";
import type { Route } from "../router";
import { ApiError } from "../router";
import type { OneShotChatFn, OneShotChatMessage } from "./client";
import { buildKnownTermsContext, findKnownTerms } from "./memoryContext";
import {
  buildRecentActivityContext,
  RECENT_ACTIVITY_EXCLUDED_MODES,
  RECENT_ACTIVITY_LIMIT,
} from "../memory/recentActivity";
import { ASK_SYSTEM_PROMPT } from "./prompts";
import { logContextUsage, type ContextUsageLogWriter } from "./contextDebugLog";

async function readJsonBody<T>(req: Request): Promise<T> {
  return (await req.json()) as T;
}

interface AskRequestBody {
  question?: string;
  conversationId?: number;
}

/**
 * Ask = LLM + web only (open-file + ask-web design,
 * docs/superpowers/specs/2026-08-13-b2-open-file-and-ask-web-design.md §2):
 * the handler itself narrows whatever ToolSet it is given down to exactly
 * these two names, so the web-only property belongs to the ask route, not to
 * the server wiring.
 */
export const ASK_TOOL_NAMES = ["opentype__web_search", "opentype__web_fetch"];

/** Spec §2: an answer should need at most a few searches, not the agent's 10. */
const ASK_MAX_ITERATIONS = 6;

/** For legacy 4-arg call sites with no ToolSet: no descriptors are offered, so a plain-answer chat behaves as before. */
const EMPTY_TOOL_SET: ToolSet = {
  openAiTools: [],
  callTool: async (name) => {
    throw new Error(`Unknown tool: ${name}`);
  },
};

/**
 * Resolves the conversation a turn belongs to: continues `conversationId` if
 * it names a real conversation, otherwise (missing or stale/unknown id)
 * starts a fresh one titled from `seedMessage`. Returns both the id and any
 * prior messages so the caller can replay them as real chat history.
 */
function resolveConversation(
  conversations: ConversationStore,
  kind: "ask" | "agent",
  conversationId: number | undefined,
  seedMessage: string
): { conversationId: number; priorMessages: OneShotChatMessage[] } {
  if (conversationId != null) {
    const existing = conversations.getConversation(conversationId);
    if (existing) {
      return {
        conversationId,
        priorMessages: existing.messages.map((m) => ({ role: m.role, content: m.content })),
      };
    }
  }
  return {
    conversationId: conversations.createConversation(kind, seedMessage),
    priorMessages: [],
  };
}

async function handleAsk(
  req: Request,
  store: MemoryStore,
  conversations: ConversationStore,
  chat: OneShotChatFn,
  contextLogWriter: ContextUsageLogWriter,
  tools?: ToolSet
): Promise<Response> {
  const body = await readJsonBody<AskRequestBody>(req);
  const question = body.question ?? "";
  if (String(question).trim() === "") {
    throw new ApiError("question is required", 400);
  }
  const matchedTerms = findKnownTerms(store, question);
  const ownerFactsCount = store.allOwnerFacts().length;
  logContextUsage(
    { endpoint: "ask", inputText: question, matchedTerms, ownerFactsCount },
    contextLogWriter
  );
  const knownTerms = buildKnownTermsContext(store, question);
  // Last RECENT_ACTIVITY_LIMIT episodic events across all three modes (Task
  // 10, spec §3.5) -- `RECENT_ACTIVITY_EXCLUDED_MODES` is empty on purpose,
  // so a plain dictation shows up here too. `includeIds: false` because ask
  // has no `opentype__read_history` tool (web-only toolset, see
  // `ASK_TOOL_NAMES` above); showing it an eventId it cannot act on would
  // only be noise. Agent gets `includeIds: true` for the same reason in
  // reverse -- see `agent/routes.ts`.
  const recentActivity = buildRecentActivityContext(
    store.recentEvents(RECENT_ACTIVITY_LIMIT, { excludeModes: RECENT_ACTIVITY_EXCLUDED_MODES }),
    { includeIds: false }
  );

  const { conversationId, priorMessages } = resolveConversation(
    conversations,
    "ask",
    body.conversationId,
    question
  );
  conversations.appendMessage(conversationId, "user", question);

  // No fidelity validation here by design — Ask is the one mode allowed to
  // answer rather than preserve/transform. Prior turns are replayed as real
  // chat history via the loop's `priorMessages` (not squashed into one
  // message) so a follow-up like "since when?" resolves against the actual
  // conversation, not a fresh one-shot call every time. Since the ask-web
  // design, the single chat call became a short `runAgentLoop` over the
  // web-only toolset above — same `{ result, conversationId }` wire shape,
  // but the model may search/fetch the web before its final text.
  const webTools = filterToolSet(tools ?? EMPTY_TOOL_SET, ASK_TOOL_NAMES);
  // `chat` keeps the narrower one-shot message shape in its declared type
  // for the pre-existing call sites; production wiring already passes
  // server.ts's `AgentChatFn` (see buildApp's doc comment there), and the
  // assertion follows that same structural-compatibility direction.
  const loopResult = await runAgentLoop(
    {
      task: question,
      knownTerms,
      runtimeContext: buildTimeContext(),
      recentActivity,
      systemPrompt: ASK_SYSTEM_PROMPT,
      priorMessages,
      maxIterations: ASK_MAX_ITERATIONS,
    },
    { chat: chat as AgentChatFn, tools: webTools }
  );
  const result = loopResult.result.trim();

  conversations.appendMessage(conversationId, "assistant", result);

  return Response.json({ result, conversationId });
}

/**
 * `tools` (optional, appended last so pre-existing 4-arg call sites keep
 * working) is the same server-level merged, approval-wrapped ToolSet
 * `buildAgentRoutes` receives; the ask handler narrows it to the web-only
 * subset itself. Omitted, ask runs its loop with an empty toolset and
 * behaves like the pre-web single-answer chat.
 */
export function buildOneShotRoutes(
  store: MemoryStore,
  conversations: ConversationStore,
  chat: OneShotChatFn,
  contextLogWriter: ContextUsageLogWriter,
  tools?: ToolSet
): Route[] {
  return [
    {
      method: "POST",
      path: "/oneshot/ask",
      handler: (req) => handleAsk(req, store, conversations, chat, contextLogWriter, tools),
    },
  ];
}

export type { OneShotChatFn } from "./client";
export { resolveConversation };
