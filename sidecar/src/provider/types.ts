/**
 * Shared shapes for the user-configurable LLM provider abstraction. Two
 * concrete implementations exist (`openaiCompatible.ts`, `anthropic.ts`),
 * both satisfying `LLMProviderClient` so `/oneshot/ask` and `/agent/run`
 * (via `server.ts`'s config-aware resolver) can call through either one
 * without caring which is active. Deliberately structurally compatible with
 * `AgentChatMessage`/`AgentChatFn` (`agent/loop.ts`) and `DeepSeekMessage`
 * (`provider/deepseek.ts`) -- same role/content/tool_calls/tool_call_id/name
 * fields -- so no adapter/cast is needed to plug a client's `chat` in
 * wherever those types are expected.
 */
export interface ProviderChatMessage {
  role: string;
  content: string | null;
  tool_calls?: unknown[];
  tool_call_id?: string;
  name?: string;
}

export interface ProviderChatOptions {
  tools?: unknown[];
  /**
   * Caller cancellation for this request, fused with the provider's own
   * timeout (T1). Lets an agent run abandon an in-flight model call instead
   * of paying for a completion nobody will read.
   */
  signal?: AbortSignal;
}

export interface ProviderChatResult {
  content: string | null;
  toolCalls?: unknown[];
}

export type ProviderChatFn = (
  messages: ProviderChatMessage[],
  options?: ProviderChatOptions
) => Promise<ProviderChatResult>;

export interface ProviderTestResult {
  success: boolean;
  error?: string;
}

export interface ProviderModel {
  id: string;
}

/** `models` is only populated on success; absent (not empty) on failure. */
export interface ProviderModelListResult {
  models: ProviderModel[];
  /** True when the provider's real listing endpoint failed/is unsupported
   *  and this is the hardcoded fallback list instead. */
  fallback: boolean;
}

export interface LLMProviderClient {
  chat: ProviderChatFn;
  testConnection(): Promise<ProviderTestResult>;
  /** Throws on failure -- callers that want the hardcoded-fallback behavior
   *  should catch and substitute `KNOWN_MODELS_FALLBACK[type]` themselves
   *  (see `provider/routes.ts`), so this stays a plain "did it work" client
   *  method that unit tests can assert against directly. */
  listModels(): Promise<ProviderModel[]>;
}

export type LLMProviderType = "anthropic" | "openai-compatible";

export interface LLMProviderConfig {
  type: LLMProviderType;
  baseUrl: string;
  apiKey: string;
  model: string;
}

/**
 * Reasonable hardcoded fallbacks for "list genuinely isn't available" (task
 * spec's requirement) -- current as of this writing, not fetched live.
 * `openai-compatible` also covers DeepSeek/self-hosted servers whose model
 * catalog can't be predicted, so this list is deliberately just the
 * well-known OpenAI + DeepSeek names, not exhaustive.
 */
export const KNOWN_MODELS_FALLBACK: Record<LLMProviderType, string[]> = {
  "openai-compatible": [
    "gpt-4o",
    "gpt-4o-mini",
    "gpt-4.1",
    "gpt-4-turbo",
    "deepseek-chat",
    "deepseek-reasoner",
  ],
  anthropic: [
    "claude-opus-4-1-20250805",
    "claude-sonnet-4-5-20250929",
    "claude-3-7-sonnet-20250219",
    "claude-3-5-haiku-20241022",
  ],
};
