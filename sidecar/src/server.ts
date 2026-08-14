import { unlinkSync, existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { buildAgentRoutes } from "./agent/routes";
import { withApproval, yoloApprovalPolicy } from "./agent/approval";
import type { AgentChatFn } from "./agent/loop";
import { startMcpConnections } from "./agent/mcpClient";
import { McpConfigStore, resolveMcpServers } from "./agent/mcpConfigStore";
import { buildMcpConfigRoutes } from "./agent/mcpConfigRoutes";
import { createBuiltInTools } from "./agent/builtInTools";
import { createCoreTools } from "./agent/coreTools";
import { mergeToolSets, type ToolSet } from "./agent/toolSets";
import { buildAsrRoutes, type TranscribeFn } from "./asr/routes";
import { createRemoteWhisperClient } from "./asr/remoteWhisperClient";
import { defaultWhisperClientFactories, WhisperClient } from "./asr/whisperClient";
import { loadEnv } from "./env";
import { decideSocketStartup, shouldStartLocalWhisper } from "./lifecycle";
import { openDatabase } from "./memory/db";
import { MemoryStore } from "./memory/MemoryStore";
import { buildMemoryRoutes } from "./memory/routes";
import { ConversationStore } from "./memory/conversations";
import { buildConversationRoutes } from "./memory/conversationRoutes";
import type { CallLLM } from "./memory/consolidator";
import { scheduleStartupConsolidation } from "./memory/startupConsolidation";
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
 * `tools` is expected to already be the merge of the built-in memory tools
 * (`agent/builtInTools.ts`, always available), the core shell/Python/file/web
 * tools (`agent/coreTools.ts`, always available), and whatever MCP servers
 * are configured (`agent/mcpClient.ts`) -- wrapped in the approval seam
 * (`agent/approval.ts`) so every tool call flows through one gate. See
 * `main()` below for the assembly. `buildApp` itself doesn't care which is
 * which, it just needs one combined `ToolSet`. The agent routes get the full
 * set; the one-shot routes get the same set and `/oneshot/ask` narrows it
 * down to the two web tools itself (Ask = LLM + web only, see
 * `oneshot/routes.ts`).
 */
export function buildApp(
  store: MemoryStore,
  conversations: ConversationStore,
  chat: AgentChatFn,
  tools: ToolSet,
  contextLogWriter: ContextUsageLogWriter,
  callLLM: CallLLM,
  transcribe: TranscribeFn,
  providerConfigStore: ProviderConfigStore,
  /**
   * Root for spilled oversized tool results (T2). Omitted -- as every
   * pre-existing test call site does -- restores the truncate-and-discard
   * behavior, so spilling is opt-in per assembly rather than ambient.
   */
  spillRoot?: string,
  /** Root for durable per-run step logs (T7); omitted disables recording. */
  runLogRoot?: string,
  /**
   * Backs the Settings "MCP 服务器" panel (P2-13). Optional so pre-existing
   * assembly call sites keep compiling; omitted, the app simply serves no
   * `/config/mcp` routes. `mcpEnvJson` is the `OPENTYPE_MCP_SERVERS` fallback
   * those routes report as `source: "env"` -- passed in rather than read from
   * `process.env` here so it is one explicit wiring decision, made in
   * `main()`.
   */
  mcpConfigStore?: McpConfigStore,
  mcpEnvJson?: string
) {
  return createRouter([
    {
      method: "GET",
      path: "/health",
      handler: () => Response.json({ status: "ok" }),
    },
    ...buildOneShotRoutes(store, conversations, chat, contextLogWriter, tools),
    ...buildMemoryRoutes(store, callLLM),
    ...buildAgentRoutes(
      store,
      conversations,
      chat,
      tools,
      contextLogWriter,
      spillRoot,
      runLogRoot
    ),
    ...buildConversationRoutes(conversations),
    // P0-1: the entity dictionary feeds back into recognition -- read per
    // request (not captured once) so a term taught mid-session applies to the
    // very next utterance. See `asr/dictionaryBias.ts`. P1-7 adds the other
    // direction: each successful dictation appends an episodic event, so
    // consolidation's raw material is no longer agent tasks alone.
    ...buildAsrRoutes(transcribe, {
      listTerms: () => store.allTerms(),
      recordEpisodicEvent: (input) => store.recordEpisodicEvent(input),
    }),
    ...buildTranscribeRoutes(chat, { store }),
    ...buildProviderConfigRoutes(providerConfigStore),
    ...(mcpConfigStore
      ? buildMcpConfigRoutes(mcpConfigStore, { envJson: mcpEnvJson })
      : []),
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
  // MCP servers: the user's saved config (Settings' "MCP 服务器" panel, P2-13)
  // if they have any, otherwise the `OPENTYPE_MCP_SERVERS` env var kept as the
  // zero-config dev fallback -- `resolveMcpServers` owns that precedence, and
  // the same "configured is explicit, never ambient" rule as the provider
  // config: an env var alone never reports as configured. Persisted next to
  // the SQLite DB, same data-directory convention as `provider-config.json`.
  //
  // Connections are established once, here, for this process's lifetime: a
  // server added or edited through the API applies from the next sidecar
  // start, not mid-run.
  const mcpConfigStore = new McpConfigStore(
    join(dirname(env.dbPath), "mcp-servers.json")
  );
  const resolvedMcpServers = resolveMcpServers(
    mcpConfigStore,
    process.env.OPENTYPE_MCP_SERVERS
  );
  // NOT awaited, and that is the whole point. Connecting used to block this
  // line until every configured server had answered, so one server that hung
  // on `initialize` meant the voice service never started -- and since
  // `SidecarClient.waitUntilReady` gives up after 5s, the supervisor restarted
  // into the same hang forever. The Settings panel that would delete the bad
  // server is served by this process, so there was no way out from inside the
  // product. MCP can now cost its own tools and nothing else: the set is
  // usable immediately and fills in as servers answer, each bounded by its own
  // budget. `mcpBootResilience.test.ts` reads this file and fails if an await
  // ever reappears above `Bun.serve`.
  const mcpTools = startMcpConnections(resolvedMcpServers.servers);
  const builtInTools = createBuiltInTools({ store, callLLM });
  const coreTools = createCoreTools({});
  // The approval seam wraps the *merged* set so built-in memory tools, core
  // tools, and MCP tools all flow through the same gate. The policy here is
  // the always-allow baseline, and stays that way on purpose: this is the set
  // `/oneshot/ask` also narrows down to its two web tools, and ask has no run
  // to prompt through. `/agent/run` applies the real, user-prompting policy
  // (P1-6, `agent/approval.ts`) on top of this, per run, because asking needs
  // that run's id, signal and question broker -- none of which exist here. See
  // `agent/routes.ts`. No guards are registered: the YOLO stance is unchanged
  // (T6 added the guard SEAM and its monotonicity, not a policy). The audit
  // sink is left unset here because the approval pair belongs to a run, and
  // only the agent route knows which run a call belongs to.
  const tools = withApproval(mergeToolSets(builtInTools, coreTools, mcpTools), yoloApprovalPolicy);
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
  // P2: only spawn the local MLX-Whisper python process when local whisper is
  // actually in play -- i.e. unless the user explicitly saved a remote-Whisper
  // config (`whisperConfigured` + `mode: "remote"`, same explicit-save
  // semantics `resolveTranscribe` below keys off). A remote-Whisper user
  // otherwise pays for a python subprocess + model download they never use.
  const whisperStatusAtBoot = providerConfigStore.getStatus();
  const whisperConfigAtBoot = providerConfigStore.getWhisperConfig();
  const startLocalWhisper = shouldStartLocalWhisper({
    whisperConfigured: whisperStatusAtBoot.whisperConfigured,
    mode: whisperConfigAtBoot?.mode,
  });
  let whisperReady: Promise<void>;
  if (startLocalWhisper) {
    whisperReady = whisperClient
      .start()
      .then(() => {
        console.log(`local MLX-Whisper server ready on unix:${env.whisperSocketPath}`);
      })
      .catch((err) => {
        console.error("Failed to start local MLX-Whisper server; /asr/transcribe will fail.", err);
        throw err;
      });
  } else {
    console.log(
      "Remote Whisper is configured; skipping local MLX-Whisper startup."
    );
    // Should never be awaited (a remote-Whisper `resolveTranscribe` takes the
    // remote branch), but give the local branch a clear error if it ever is.
    whisperReady = Promise.reject(
      new Error("Local MLX-Whisper is not running (remote Whisper is configured).")
    );
  }
  // Second independent subscriber so a startup failure (or the skipped-local
  // rejection above) before any `/asr/transcribe` request arrives doesn't
  // surface as a Bun "unhandled promise rejection" -- the real error still
  // reaches request handlers, each of which `await whisperReady` on its own.
  whisperReady.catch(() => {});

  // Config-aware transcribe resolver: local MLX-Whisper unless the user has
  // explicitly configured (and saved) remote Whisper via `/config/whisper`
  // -- same "configured" precision as `resolveChat` above. The
  // request/response contract `asr/routes.ts` exposes stays identical
  // either way; only which backend actually serves the request changes.
  const resolveTranscribe = async (
    audio: Uint8Array,
    options: { initialPrompt?: string } = {}
  ): Promise<string> => {
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
      // The remote (OpenAI-shaped) transcription API has no equivalent of
      // `initial_prompt`, so a remote user gets only the deterministic half of
      // the dictionary feedback -- the alias rewrite `asr/routes.ts` applies to
      // whatever comes back.
      return remoteClient.transcribe(audio);
    }
    await whisperReady;
    return whisperClient.transcribe(audio, options.initialPrompt);
  };

  const fetch = buildApp(
    store,
    conversations,
    resolveChat,
    tools,
    contextLogWriter,
    callLLM,
    resolveTranscribe,
    providerConfigStore,
    env.spillRoot,
    env.runLogRoot,
    mcpConfigStore,
    process.env.OPENTYPE_MCP_SERVERS
  );

  // P1-9 single-instance guard: an existing socket file is only safe to
  // unlink + rebind if no live instance is currently serving it. Stomping a
  // socket a healthy sibling instance owns would silently steal its clients;
  // a leftover file from a crashed instance is fine to clear. `globalThis.fetch`
  // (not the local `fetch` router bound above) probes liveness over the socket.
  const startupDecision = await decideSocketStartup(env.socketPath, {
    exists: (path) => existsSync(path),
    isServed: async (path) => {
      try {
        const response = await globalThis.fetch("http://localhost/health", {
          unix: path,
          signal: AbortSignal.timeout(500),
        } as RequestInit);
        return response.ok;
      } catch {
        return false;
      }
    },
  });
  if (startupDecision === "refuse") {
    console.error(
      `Another opentype-sidecar instance is already serving unix:${env.socketPath}; refusing to start.`
    );
    process.exit(1);
  }

  if (existsSync(env.socketPath)) {
    unlinkSync(env.socketPath);
  }

  const server = Bun.serve({
    unix: env.socketPath,
    fetch,
  });

  console.log(`opentype-sidecar listening on unix:${env.socketPath}`);

  // P1-7: the consolidation gate finally gets a caller. One check, on a delay,
  // after we're serving -- not a polling timer, and never on the startup path.
  // See `memory/startupConsolidation.ts` for why the policy lives in a seam.
  scheduleStartupConsolidation(store, callLLM);

  // P1-7: on a termination signal, tear down the local whisper python child
  // (otherwise it's orphaned and keeps holding its socket/model) and remove our
  // own socket file before exiting, so a restart isn't blocked by a stale one.
  const shutdown = (signal: NodeJS.Signals) => {
    console.log(`Received ${signal}; shutting down opentype-sidecar.`);
    try {
      whisperClient.stop();
    } catch {
      // best-effort: never let cleanup failure block exit
    }
    try {
      server.stop();
    } catch {
      // best-effort
    }
    try {
      if (existsSync(env.socketPath)) {
        unlinkSync(env.socketPath);
      }
    } catch {
      // best-effort
    }
    process.exit(0);
  };
  process.on("SIGTERM", () => shutdown("SIGTERM"));
  process.on("SIGINT", () => shutdown("SIGINT"));
}

if (import.meta.main) {
  main();
}
