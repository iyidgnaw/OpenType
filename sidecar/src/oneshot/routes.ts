import type { MemoryStore } from "../memory/MemoryStore";
import type { ConversationStore } from "../memory/conversations";
import type { Route } from "../router";
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
  contextLogWriter: ContextUsageLogWriter
): Promise<Response> {
  const body = await readJsonBody<AskRequestBody>(req);
  const question = body.question ?? "";
  const matchedTerms = findKnownTerms(store, question);
  const ownerFactsCount = store.allOwnerFacts().length;
  logContextUsage(
    { endpoint: "ask", inputText: question, matchedTerms, ownerFactsCount },
    contextLogWriter
  );
  const knownTerms = buildKnownTermsContext(store, question);
  const userContent = knownTerms ? `${question}\n\n${knownTerms}` : question;

  const { conversationId, priorMessages } = resolveConversation(
    conversations,
    "ask",
    body.conversationId,
    question
  );
  conversations.appendMessage(conversationId, "user", question);

  // No fidelity validation here by design — Ask is the one mode allowed to
  // answer rather than preserve/transform. Prior turns are replayed as real
  // chat history (not just squashed into one message) so a follow-up like
  // "since when?" resolves against the actual conversation, not a fresh
  // one-shot call every time.
  const messages: OneShotChatMessage[] = [
    { role: "system", content: ASK_SYSTEM_PROMPT },
    ...priorMessages,
    { role: "user", content: userContent },
  ];
  const chatResult = await chat(messages);
  const result = (chatResult.content ?? "").trim();

  conversations.appendMessage(conversationId, "assistant", result);

  return Response.json({ result, conversationId });
}

export function buildOneShotRoutes(
  store: MemoryStore,
  conversations: ConversationStore,
  chat: OneShotChatFn,
  contextLogWriter: ContextUsageLogWriter
): Route[] {
  return [
    {
      method: "POST",
      path: "/oneshot/ask",
      handler: (req) => handleAsk(req, store, conversations, chat, contextLogWriter),
    },
  ];
}

export type { OneShotChatFn } from "./client";
export { resolveConversation };
