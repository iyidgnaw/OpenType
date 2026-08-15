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
const ASK_TOOL_NAMES = ["opentype__web_search", "opentype__web_fetch"];

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
      systemPrompt: ASK_SYSTEM_PROMPT,
      priorMessages,
      maxIterations: ASK_MAX_ITERATIONS,
    },
    { chat: chat as AgentChatFn, tools: webTools }
  );
  const result = loopResult.result.trim();

  conversations.appendMessage(conversationId, "assistant", result);
  recordAnsweredQuestion(store, question, result);

  return Response.json({ result, conversationId });
}

/**
 * P1-7: Q&A feeds consolidation too, alongside `/agent/run` and (since the same
 * batch) `/asr/transcribe`. A question is where a project, person or term the
 * owner cares about tends to get named for the first time.
 *
 * Raw and corrected are the same string here because this route never sees a
 * pre-correction form — by the time Swift posts, the text is already
 * transcribed — which is exactly what `/agent/run` does with its `task`.
 * `origin: "agent"` also matches it: since the ask-web batch the `result` half
 * is machine-produced text that may quote fetched pages, and recording that as
 * the owner's own words is the provenance confusion `EventOrigin` exists to
 * prevent.
 *
 * Recorded only after the answer exists, and swallowed on failure: the answer
 * is the product, the episodic row is bookkeeping.
 */
function recordAnsweredQuestion(store: MemoryStore, question: string, result: string): void {
  try {
    store.recordEpisodicEvent({
      mode: "ask",
      rawTranscript: question,
      correctedTranscript: question,
      effectiveInput: question,
      // Ask deliberately needs no selection, and the body carries none.
      selectedContext: null,
      result,
      // Placeholder, same reason as `/agent/run`'s "OpenType Agent": nothing on
      // the wire tells the sidecar the frontmost app.
      applicationName: "OpenType Ask",
      origin: "agent",
    });
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    console.warn(`ask: could not record episodic event, continuing: ${message}`);
  }
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
