import type { MemoryStore } from "../memory/MemoryStore";
import type { Route } from "../router";
import type { OneShotChatFn } from "./client";
import { buildKnownTermsContext, findKnownTerms } from "./memoryContext";
import { ASK_SYSTEM_PROMPT } from "./prompts";
import { logContextUsage, type ContextUsageLogWriter } from "./contextDebugLog";

/**
 * Shared "build messages, call the client, extract text" helper. Only one
 * one-shot endpoint (`/oneshot/ask`) remains after the 3-mode cut removed
 * polish/translate/xreply, but this is kept as its own function rather than
 * inlined so the system-prompt/user-content/response-parsing shape stays
 * clearly separated from the endpoint's request/response plumbing.
 */
async function generateText(
  chat: OneShotChatFn,
  systemPrompt: string,
  userContent: string
): Promise<string> {
  const result = await chat([
    { role: "system", content: systemPrompt },
    { role: "user", content: userContent },
  ]);
  return (result.content ?? "").trim();
}

async function readJsonBody<T>(req: Request): Promise<T> {
  return (await req.json()) as T;
}

interface AskRequestBody {
  question?: string;
}

async function handleAsk(
  req: Request,
  store: MemoryStore,
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

  // No fidelity validation here by design — Ask is the one mode allowed to
  // answer rather than preserve/transform.
  const result = await generateText(chat, ASK_SYSTEM_PROMPT, userContent);
  return Response.json({ result });
}

export function buildOneShotRoutes(
  store: MemoryStore,
  chat: OneShotChatFn,
  contextLogWriter: ContextUsageLogWriter
): Route[] {
  return [
    {
      method: "POST",
      path: "/oneshot/ask",
      handler: (req) => handleAsk(req, store, chat, contextLogWriter),
    },
  ];
}

export type { OneShotChatFn } from "./client";
