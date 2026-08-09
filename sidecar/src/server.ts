import { unlinkSync, existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { buildAgentRoutes } from "./agent/routes";
import type { AgentChatFn } from "./agent/loop";
import { connectConfiguredMcpServers } from "./agent/mcpClient";
import { createBuiltInTools } from "./agent/builtInTools";
import { mergeToolSets, type ToolSet } from "./agent/toolSets";
import { buildAsrRoutes } from "./asr/routes";
import { createRemoteWhisperClient } from "./asr/remoteWhisperClient";
import { defaultWhisperClientFactories, WhisperClient } from "./asr/whisperClient";
import { loadEnv } from "./env";
import { openDatabase } from "./memory/db";
import { MemoryStore } from "./memory/MemoryStore";
import { buildMemoryRoutes } from "./memory/routes";
import { ConversationStore } from "./memory/conversations";
import { buildConversationRoutes } from "./memory/conversationRoutes";
import type { CallLLM } from "./memory/consolidator";
import { buildOneShotRoutes } from "./oneshot/routes";
import { createFileContextUsageLogWriter, type ContextUsageLogWriter } from "./oneshot/contextDebugLog";
import { createDeepSeekClient } from "./provider/deepseek";
import { ProviderConfigStore } from "./provider/configStore";
import { createLLMClientFromConfig } from "./provider/registry";
import { buildProviderConfigRoutes } from "./provider/routes";
import { createRouter } from "./router";
import { buildTranscribeRoutes } from "./transcribe/routes";

/**
 * `chat` is typed `AgentChatFn` (rather than the narrower `OneShotChatFn`)
 * because it's shared with `/agent/run`, which needs the tool-calling
 * message shape; `AgentChatFn` is structurally compatible with
 * `OneShotChatFn`, so it still satisfies `buildOneShotRoutes` unchanged.
 *
 * `tools` is expected to already be the merge of built-in tools
 * (`agent/builtInTools.ts`, always available) and whatever MCP servers are
 * configured (`agent/mcpClient.ts`) -- see `mergeToolSets` in
 * `agent/toolSets.ts` and its use in `main()` below. `buildApp` itself
 * doesn't care which is which, it just needs one combined `ToolSet`.
 */
export function buildApp(
  store: MemoryStore,
  conversations: ConversationStore,
  chat: AgentChatFn,
  tools: ToolSet,
  contextLogWriter: ContextUsageLogWriter,
  callLLM: CallLLM,
  transcribe: (audio: Uint8Array) => Promise<string>,
  providerConfigStore: ProviderConfigStore
) {
  return createRouter([
    {
      method: "GET",
      path: "/health",
      handler: () => Response.json({ status: "ok" }),
    },
    ...buildOneShotRoutes(store, conversations, chat, contextLogWriter),
    ...buildMemoryRoutes(store, callLLM),
    ...buildAgentRoutes(store, conversations, chat, tools, contextLogWriter),
    ...buildConversationRoutes(conversations),
    ...buildAsrRoutes(transcribe),
    ...buildTranscribeRoutes(chat),
    ...buildProviderConfigRoutes(providerConfigStore),
  ]);
}

async function main() {
  const env = loadEnv();
  const store = new MemoryStore(openDatabase(env.dbPath));
  // Shares the same underlying Database as `store` (one sqlite file per
  // sidecar instance) rather than opening a second connection.
  const conversations = new ConversationStore(store.db);
  const deepSeekClient = createDeepSeekClient(env);

  // Provider config: persisted next to the SQLite DB (same data directory
  // convention -- dev mode uses "sidecar/.data/", the packaged app pins both
  // to an absolute Application-Support-adjacent path via
  // OPENTYPE_SIDECAR_DB_PATH, see SidecarClient.swift). See
  // `provider/configStore.ts`'s doc comment for the plaintext-JSON /
  // Keychain tradeoff this makes deliberately.
  const providerConfigStore = new ProviderConfigStore(
    join(dirname(env.dbPath), "provider-config.json")
  );

  // Config-aware chat resolver: routes through whichever LLM provider the
  // user explicitly configured via `/config/llm` (Settings/onboarding
  // wizard), falling back to the always-available env-based DeepSeek client
  // when nothing has been explicitly configured yet -- "configured" here
  // means `providerConfigStore`'s `llmConfigured` flag, which only a
  // completed Test-Connection-then-save flow sets (see that store's doc
  // comment), never just an ambient `DEEPSEEK_API_KEY`. `/oneshot/ask` and
  // `/agent/run` both go through this same function, same as before this
  // feature existed they both went through `deepSeekClient.chat` directly.
  const resolveChat: AgentChatFn = async (messages, options) => {
    const status = providerConfigStore.getStatus();
    const stored = providerConfigStore.getLLMConfig();
    if (status.llmConfigured && stored) {
      const client = createLLMClientFromConfig(stored);
      return client.chat(messages, options);
    }
    return deepSeekClient.chat(messages, options);
  };

  const callLLM: CallLLM = async (prompt) => {
    const result = await resolveChat([{ role: "user", content: prompt }]);
    return result.content ?? "";
  };
  const mcpTools = await connectConfiguredMcpServers(process.env.OPENTYPE_MCP_SERVERS);
  const builtInTools = createBuiltInTools({ store, callLLM });
  const tools = mergeToolSets(builtInTools, mcpTools);
  const contextLogWriter = createFileContextUsageLogWriter(env.contextLogPath);

  // Local MLX-Whisper ASR: spawns the python server once here (alongside the
  // other collaborators above) and reuses it for every `/asr/transcribe`
  // request for the lifetime of this process. `start()` is *not* awaited
  // here -- loading the MLX model takes real, multi-second wall time, and
  // blocking on it here would delay this sidecar's own `/health` (Swift's
  // `SidecarClient.start()` polls that with a short timeout, and doesn't
  // care about whisper readiness at all). Instead `whisperReady` is awaited
  // per-request, inside the `/asr/transcribe` handler below, so it only
  // blocks the first transcription request (typically well after the model
  // has finished loading in the background) rather than sidecar startup.
  const whisperClient = new WhisperClient(
    { socketPath: env.whisperSocketPath },
    defaultWhisperClientFactories({
      pythonBin: env.whisperPythonBin,
      scriptPath: env.whisperScriptPath,
    })
  );
  const whisperReady = whisperClient
    .start()
    .then(() => {
      console.log(`local MLX-Whisper server ready on unix:${env.whisperSocketPath}`);
    })
    .catch((err) => {
      console.error("Failed to start local MLX-Whisper server; /asr/transcribe will fail.", err);
      throw err;
    });
  // Second independent subscriber so a startup failure before any
  // `/asr/transcribe` request arrives doesn't surface as a Bun "unhandled
  // promise rejection" -- the real error still reaches request handlers,
  // each of which `await whisperReady` on its own.
  whisperReady.catch(() => {});

  // Config-aware transcribe resolver: local MLX-Whisper unless the user has
  // explicitly configured (and saved) remote Whisper via `/config/whisper`
  // -- same "configured" precision as `resolveChat` above. The
  // request/response contract `asr/routes.ts` exposes stays identical
  // either way; only which backend actually serves the request changes.
  const resolveTranscribe = async (audio: Uint8Array): Promise<string> => {
    const status = providerConfigStore.getStatus();
    const whisperConfig = providerConfigStore.getWhisperConfig();
    if (
      status.whisperConfigured &&
      whisperConfig?.mode === "remote" &&
      whisperConfig.baseUrl &&
      whisperConfig.apiKey
    ) {
      const remoteClient = createRemoteWhisperClient({
        baseUrl: whisperConfig.baseUrl,
        apiKey: whisperConfig.apiKey,
        model: whisperConfig.model,
      });
      return remoteClient.transcribe(audio);
    }
    await whisperReady;
    return whisperClient.transcribe(audio);
  };

  const fetch = buildApp(
    store,
    conversations,
    resolveChat,
    tools,
    contextLogWriter,
    callLLM,
    resolveTranscribe,
    providerConfigStore
  );

  if (existsSync(env.socketPath)) {
    unlinkSync(env.socketPath);
  }

  Bun.serve({
    unix: env.socketPath,
    fetch,
  });

  console.log(`opentype-sidecar listening on unix:${env.socketPath}`);
}

if (import.meta.main) {
  main();
}
