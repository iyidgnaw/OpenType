import { createRemoteWhisperClient, type RemoteWhisperConfig } from "../asr/remoteWhisperClient";
import type { Route } from "../router";
import type { ProviderConfigStore, StoredWhisperConfig, WhisperMode } from "./configStore";
import { maskApiKey } from "./maskApiKey";
import { createLLMClientFromConfig } from "./registry";
import { KNOWN_MODELS_FALLBACK, type LLMProviderConfig, type LLMProviderType } from "./types";

/**
 * Re-exported so the masking rule is unit-testable
 * (`test/provider/maskApiKey.test.ts`) without reaching into route wiring; the
 * implementation lives in `./maskApiKey`.
 */
export { maskApiKey };

async function readJsonBody<T>(req: Request): Promise<T> {
  return (await req.json()) as T;
}

interface ProviderConfigRouteDeps {
  createLLMClient: typeof createLLMClientFromConfig;
  createRemoteWhisperClient: typeof createRemoteWhisperClient;
}

const defaultDeps: ProviderConfigRouteDeps = {
  createLLMClient: createLLMClientFromConfig,
  createRemoteWhisperClient,
};

interface LLMConfigRequestBody {
  type?: string;
  baseUrl?: string;
  apiKey?: string;
  model?: string;
}

function isValidLLMType(type: unknown): type is LLMProviderType {
  return type === "anthropic" || type === "openai-compatible";
}

function llmConfigResponse(config: { type: LLMProviderType; baseUrl: string; apiKey: string; model: string }) {
  return {
    configured: true,
    type: config.type,
    baseUrl: config.baseUrl,
    model: config.model,
    apiKeyMasked: maskApiKey(config.apiKey),
  };
}

interface WhisperConfigRequestBody {
  mode?: string;
  baseUrl?: string;
  apiKey?: string;
  model?: string;
}

function whisperConfigResponse(config: StoredWhisperConfig) {
  return {
    configured: true,
    mode: config.mode,
    baseUrl: config.baseUrl,
    model: config.model,
    apiKeyMasked: config.apiKey ? maskApiKey(config.apiKey) : undefined,
  };
}

/**
 * HTTP surface backing the Settings provider-config UI and the first-run
 * onboarding wizard (same underlying store either way -- see
 * `docs/superpowers/specs/2026-08-09-current-system-state.md`'s provider
 * config section for why the wizard reuses these exact endpoints rather
 * than a parallel implementation). `deps` is overridable for tests so
 * `/config/llm/test` and `/config/llm/models` don't need a real network
 * call, and `/config/whisper/test` doesn't need a real remote server.
 */
export function buildProviderConfigRoutes(
  store: ProviderConfigStore,
  deps: Partial<ProviderConfigRouteDeps> = {}
): Route[] {
  const { createLLMClient, createRemoteWhisperClient: createRemoteWhisper } = {
    ...defaultDeps,
    ...deps,
  };

  return [
    {
      method: "GET",
      path: "/config/status",
      handler: () => {
        const status = store.getStatus();
        return Response.json({
          llmConfigured: status.llmConfigured,
          whisperConfigured: status.whisperConfigured,
          ready: status.llmConfigured && status.whisperConfigured,
        });
      },
    },
    {
      method: "GET",
      path: "/config/llm",
      handler: () => {
        const config = store.getLLMConfig();
        if (!config || !store.getStatus().llmConfigured) {
          return Response.json({ configured: false });
        }
        return Response.json(llmConfigResponse(config));
      },
    },
    {
      method: "PUT",
      path: "/config/llm",
      handler: async (req) => {
        const body = await readJsonBody<LLMConfigRequestBody>(req);
        if (!isValidLLMType(body.type)) {
          return Response.json({ error: "type must be 'anthropic' or 'openai-compatible'" }, { status: 400 });
        }
        if (!body.baseUrl || !body.apiKey || !body.model) {
          return Response.json({ error: "baseUrl, apiKey, and model are all required" }, { status: 400 });
        }
        const config: LLMProviderConfig = {
          type: body.type,
          baseUrl: body.baseUrl,
          apiKey: body.apiKey,
          model: body.model,
        };
        store.setLLMConfig(config);
        return Response.json(llmConfigResponse(config));
      },
    },
    {
      method: "POST",
      path: "/config/llm/test",
      handler: async (req) => {
        const body = await readJsonBody<LLMConfigRequestBody>(req);
        if (!isValidLLMType(body.type) || !body.baseUrl || !body.apiKey) {
          return Response.json({ error: "type, baseUrl, and apiKey are all required" }, { status: 400 });
        }
        const client = createLLMClient({
          type: body.type,
          baseUrl: body.baseUrl,
          apiKey: body.apiKey,
          model: body.model ?? "",
        });
        const result = await client.testConnection();
        return Response.json(result);
      },
    },
    {
      method: "POST",
      path: "/config/llm/models",
      handler: async (req) => {
        const body = await readJsonBody<LLMConfigRequestBody>(req);
        if (!isValidLLMType(body.type) || !body.baseUrl || !body.apiKey) {
          return Response.json({ error: "type, baseUrl, and apiKey are all required" }, { status: 400 });
        }
        const client = createLLMClient({
          type: body.type,
          baseUrl: body.baseUrl,
          apiKey: body.apiKey,
          model: body.model ?? "",
        });
        try {
          const models = await client.listModels();
          return Response.json({ models: models.map((m) => m.id), fallback: false });
        } catch {
          return Response.json({ models: KNOWN_MODELS_FALLBACK[body.type], fallback: true });
        }
      },
    },
    {
      method: "GET",
      path: "/config/whisper",
      handler: () => {
        const config = store.getWhisperConfig();
        if (!config || !store.getStatus().whisperConfigured) {
          return Response.json({ configured: false });
        }
        return Response.json(whisperConfigResponse(config));
      },
    },
    {
      method: "PUT",
      path: "/config/whisper",
      handler: async (req) => {
        const body = await readJsonBody<WhisperConfigRequestBody>(req);
        if (body.mode !== "local" && body.mode !== "remote") {
          return Response.json({ error: "mode must be 'local' or 'remote'" }, { status: 400 });
        }
        if (body.mode === "remote" && (!body.baseUrl || !body.apiKey)) {
          return Response.json(
            { error: "baseUrl and apiKey are required when mode is 'remote'" },
            { status: 400 }
          );
        }
        const mode: WhisperMode = body.mode;
        const config: StoredWhisperConfig =
          mode === "local"
            ? { mode }
            : { mode, baseUrl: body.baseUrl, apiKey: body.apiKey, model: body.model };
        store.setWhisperConfig(config);
        return Response.json(whisperConfigResponse(config));
      },
    },
    {
      method: "POST",
      path: "/config/whisper/test",
      handler: async (req) => {
        const body = await readJsonBody<WhisperConfigRequestBody>(req);
        if (!body.baseUrl || !body.apiKey) {
          return Response.json({ error: "baseUrl and apiKey are required" }, { status: 400 });
        }
        const config: RemoteWhisperConfig = {
          baseUrl: body.baseUrl,
          apiKey: body.apiKey,
          model: body.model,
        };
        const client = createRemoteWhisper(config);
        const result = await client.testConnection();
        return Response.json(result);
      },
    },
  ];
}
