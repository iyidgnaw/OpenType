import { createAnthropicClient } from "./anthropic";
import { createOpenAICompatibleClient } from "./openaiCompatible";
import type { LLMProviderClient, LLMProviderConfig } from "./types";

/**
 * Dispatches a stored/candidate `LLMProviderConfig` to the matching concrete
 * client. The one place that needs to know both provider implementations
 * exist -- `provider/routes.ts` and `server.ts`'s config-aware chat resolver
 * both go through this instead of importing `anthropic.ts`/
 * `openaiCompatible.ts` directly.
 */
export function createLLMClientFromConfig(
  config: LLMProviderConfig,
  fetchImpl: typeof fetch = fetch
): LLMProviderClient {
  return config.type === "anthropic"
    ? createAnthropicClient(config, fetchImpl)
    : createOpenAICompatibleClient(config, fetchImpl);
}
