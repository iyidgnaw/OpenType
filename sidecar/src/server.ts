import { unlinkSync, existsSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { homedir } from "node:os";
import { buildAgentRoutes, type SkillIndexSource } from "./agent/routes";
import { withApproval, yoloApprovalPolicy } from "./agent/approval";
import type { AgentChatFn } from "./agent/loop";
import {
  createReloadableMcpToolSet,
  type McpConnectionReport,
  type McpServerConfig,
} from "./agent/mcpClient";
import { McpConfigStore, resolveMcpServers } from "./agent/mcpConfigStore";
import { buildMcpConfigRoutes } from "./agent/mcpConfigRoutes";
import { createBuiltInTools } from "./agent/builtInTools";
import { createCoreTools } from "./agent/coreTools";
import { mergeToolSets, type ToolSet } from "./agent/toolSets";
import { createSkillStore } from "./skills/skillStore";
import { resolveSkillRoots } from "./skills/skillRoots";
import { createSkillTool } from "./skills/skillTool";
import { createAgentDefinitionStore, loadGlobalInstructions } from "./agent/agentDefinitions";
import { resolveAgentRoots, resolveGlobalInstructionRoots } from "./agent/agentRoots";
import type { AgentDefinitionsSource } from "./agent/routes";
import { buildAsrRoutes, type TranscribeFn, type TranscribeOptions } from "./asr/routes";
import { buildAsrStatusRoutes, type AsrStatusDeps, type LocalWhisperStatus } from "./asr/statusRoutes";
import { buildWhisperModelRoutes } from "./asr/whisperModelRoutes";
import { resolveWhisperModel } from "./asr/whisperModel";
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
  mcpEnvJson?: string,
  /**
   * How the boot-time MCP connections went (`main()` passes `mcpTools.status`).
   * A getter, read per request, because these routes are built while every
   * server is still `connecting` -- see `mcpConfigRoutes.ts`. Optional so an
   * assembly with no MCP tool set (every pre-existing test call site) answers
   * exactly the shape it always did.
   */
  mcpConnectionReport?: () => McpConnectionReport,
  /**
   * Fires a live MCP reload after a `/config/mcp` write commits -- `main()`
   * passes `mcpTools.reload` (the `ReloadableMcpToolSet` created above it).
   * Threaded through positionally, same as `mcpConnectionReport`, rather than
   * imported here, so this file stays free of a dependency on which MCP tool
   * set implementation the caller happens to be using. Optional so every
   * pre-existing test call site (none of which pass this far) keeps
   * compiling and simply gets a `/config/mcp` write with no live effect
   * beyond the next restart -- see `McpConfigRouteDeps.onServersChanged`'s
   * own doc comment for why it is never awaited.
   */
  mcpOnServersChanged?: (servers: McpServerConfig[]) => void,
  /**
   * `OPENTYPE_WHISPER_MODEL`, when set -- the fallback `/config/whisper-model`
   * reports as `source: "env"`. Passed in rather than read from `process.env`
   * here, following `mcpEnvJson`: one explicit wiring decision, made in
   * `main()`.
   */
  whisperModelEnvValue?: string,
  /**
   * How to answer `GET /asr/status`. Optional so an assembly with no whisper
   * child (every pre-existing test call site) simply serves no status route
   * rather than reporting on a process that does not exist.
   */
  asrStatusDeps?: AsrStatusDeps,
  /**
   * Backs `DELETE /memory/context-log` (see `memory/routes.ts`). Optional,
   * trailing, for the same reason as `spillRoot`/`runLogRoot` above -- every
   * pre-existing test call site (none of which pass this far) keeps
   * compiling and simply gets a route that reports "nothing to delete"
   * rather than one wired to a real path.
   */
  contextLogPath?: string,
  /**
   * §2.1 ("闸门默认打开"): whether `/agent/run` prompts before a destructive
   * shell/python call. `main()` passes the resolved `env.agentApprovalMode`
   * here -- this is the only place in the app that reads that env value, so
   * every other call site (all pre-existing test call sites included) keeps
   * compiling and gets the same "yolo" default `buildAgentRoutes` itself
   * falls back to when this is omitted.
   */
  agentApprovalMode?: "yolo" | "prompt",
  /**
   * Design §3.3/§3.4: source for the always-resident skill index, threaded
   * to `buildAgentRoutes` so `/agent/run` renders and injects it fresh on
   * every call. Optional, trailing, same reasoning as every other optional
   * param above -- every pre-existing call site keeps compiling and simply
   * gets no skill index (`RunAgentLoopInput.skills` stays unset, exactly
   * today's behavior).
   */
  skillStore?: SkillIndexSource,
  /**
   * Design §4/§4.5: source for agent-name/voice-prefix selection and
   * AGENTS.md global instructions, threaded to `buildAgentRoutes`. Optional,
   * trailing, same reasoning as `skillStore` above -- every pre-existing
   * call site keeps compiling and simply gets no agent selection or global
   * instructions (`/agent/run` behaves exactly as it did before this batch).
   */
  agentDefinitions?: AgentDefinitionsSource
) {
  return createRouter([
    {
      method: "GET",
      path: "/health",
      handler: () => Response.json({ status: "ok" }),
    },
    ...buildOneShotRoutes(store, conversations, chat, contextLogWriter, tools),
    ...buildMemoryRoutes(store, callLLM, contextLogPath),
    // §9.1: approval mode, the skill index source, and agent definitions all
    // land on `buildAgentRoutes` as one trailing options object rather than
    // three separate positional parameters -- see that function's own doc
    // comment (`AgentRouteOptions`, `src/agent/routes.ts`).
    ...buildAgentRoutes(store, conversations, chat, tools, contextLogWriter, spillRoot, runLogRoot, {
      approvalMode: agentApprovalMode,
      skills: skillStore,
      agentDefinitions,
    }),
    ...buildConversationRoutes(conversations),
    // P0-1: the entity dictionary feeds back into recognition -- read per
    // request (not captured once) so a term taught mid-session applies to the
    // very next utterance. See `asr/dictionaryBias.ts`. Episodic-event writing
    // no longer happens here (design §3.2): Swift now calls
    // `POST /memory/events` itself, once, at delivery time -- see
    // `memory/routes.ts`.
    ...buildAsrRoutes(transcribe, {
      listTerms: () => store.allTerms(),
    }),
    ...buildTranscribeRoutes(chat, { store }),
    ...buildProviderConfigRoutes(providerConfigStore),
    // §E-4: which local model to load, saved-beats-env exactly as MCP does it.
    ...buildWhisperModelRoutes(providerConfigStore, {
      envValue: whisperModelEnvValue,
    }),
    // §E-2: how far that model has got to loading, so the first launch is
    // something the user can read rather than a blank screen.
    ...(asrStatusDeps ? buildAsrStatusRoutes(asrStatusDeps) : []),
    ...(mcpConfigStore
      ? buildMcpConfigRoutes(mcpConfigStore, {
          envJson: mcpEnvJson,
          connectionReport: mcpConnectionReport,
          onServersChanged: mcpOnServersChanged,
        })
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
  // server added, edited, enabled, disabled or deleted through the API is
  // applied live -- see `onServersChanged` below -- rather than only from the
  // next sidecar start.
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
  //
  // `createReloadableMcpToolSet` rather than `startMcpConnections`: behaves
  // identically up to this point (same synchronous-construction contract
  // `mcpBootResilience.test.ts` pins), but also exposes `reload(...)`, which
  // is what lets a config-route write below apply without a restart.
  const mcpTools = createReloadableMcpToolSet(resolvedMcpServers.servers);
  const builtInTools = createBuiltInTools({ store, callLLM });
  const coreTools = createCoreTools({ memoryStore: store, conversations });
  // Skill discovery (design §3.2/§8): built-in `sidecar/skills/` (bundled
  // alongside this module, `OPENTYPE_SKILLS_DIR`-overridable) -> user
  // `~/.opentype/skills` -> read-only Claude-Code-compat `~/.claude/skills`,
  // first root wins a name collision. `resolveSkillRoots` is pure path
  // logic; `createSkillStore` does the actual (TTL-cached) disk reads, on
  // demand from `agent/routes.ts`'s per-request `renderSkillIndex` call --
  // not read once here and frozen for the process lifetime.
  const skillStore = createSkillStore({
    roots: resolveSkillRoots({
      homeDir: homedir(),
      builtInSkillsDir: resolve(import.meta.dir, "..", "skills"),
      env: process.env,
    }),
    // Design §5: "不做文件监听热重载" -- a short TTL substitutes for it. Without
    // this, `createResourceStore`'s `ttlMs` defaults to 0 (always re-read),
    // which would walk all three skill roots and re-parse every SKILL.md on
    // every single `/agent/run` call instead of once per 5s window.
    ttlMs: 5_000,
  });
  const skillTool = createSkillTool({ store: skillStore });
  // Agent-definition discovery (design §4/§8/§9.4): same three-root,
  // first-root-wins shape as skills above, built on the SAME
  // `resources/resourceStore.ts` layer (`layout: "file"` instead of
  // `"directory"`) rather than a parallel implementation. `resolveAgentRoots`
  // is pure path logic, mirroring `resolveSkillRoots`.
  //
  // AGENTS.md global instructions (§4.5) use a DIFFERENT, shorter root list
  // (`resolveGlobalInstructionRoots`): built-in + `~/.opentype` only, never
  // `~/.claude` -- see that function's doc comment (`agent/agentRoots.ts`)
  // for why an imported skill/agent and an imported AGENTS.md have different
  // consent models even though they can live in the same `~/.claude`
  // directory. `loadGlobalInstructions` itself doesn't know or care which
  // root is "compat"; the exclusion is entirely this call site handing it
  // the shorter list.
  const builtInAgentsDir = resolve(import.meta.dir, "..", "agents");
  const agentDefinitionStore = createAgentDefinitionStore({
    roots: resolveAgentRoots({
      homeDir: homedir(),
      builtInAgentsDir,
      env: process.env,
    }),
    ttlMs: 5_000,
  });
  const globalInstructionRoots = resolveGlobalInstructionRoots({
    homeDir: homedir(),
    builtInAgentsDir,
  });
  const agentDefinitions: AgentDefinitionsSource = {
    list: () => agentDefinitionStore.list(),
    globalInstructions: () => loadGlobalInstructions(globalInstructionRoots),
  };
  // The approval seam wraps the *merged* set so built-in memory tools, core
  // tools, and MCP tools all flow through the same gate. The policy here is
  // always the always-allow baseline, unconditionally -- this is the set
  // `/oneshot/ask` also narrows down to its two web tools, and ask has no run
  // to prompt through, ever, regardless of `agentApprovalMode`. `/agent/run`
  // is where `agentApprovalMode` (§2.1, read from `env.agentApprovalMode`,
  // resolved once in `main()` and threaded down through `buildApp` ->
  // `buildAgentRoutes`) actually chooses between this same always-allow
  // policy (the "yolo" default) and the user-prompting one (P1-6,
  // `agent/approval.ts`, opt-in via `OPENTYPE_AGENT_APPROVAL=prompt`) on top
  // of this, per run, because asking needs that run's id, signal and
  // question broker -- none of which exist here. See `agent/routes.ts`. No
  // guards are registered: the YOLO stance is unchanged (T6 added the guard
  // SEAM and its monotonicity, not a policy). The audit sink is left unset
  // here because the approval pair belongs to a run, and only the agent
  // route knows which run a call belongs to.
  // `skillTool` (`opentype__load_skill`) is merged into the same set as
  // every other built-in/core/MCP tool. It reaches Ask mode's tool set too
  // in principle (`tools` is the one merged set both `/oneshot/ask` and
  // `/agent/run` start from), but Ask narrows down to `ASK_TOOL_NAMES` (web
  // search/fetch only) before use, so `load_skill` is absent there for free
  // -- see `oneshot/routes.ts`, and design §3.4's "Ask 模式不注入" line.
  const tools = withApproval(
    mergeToolSets(builtInTools, coreTools, skillTool, mcpTools),
    yoloApprovalPolicy
  );
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
  // §E-4: which weights to load. Saved beats `OPENTYPE_WHISPER_MODEL` beats the
  // default, and the resolved value is handed down as that same variable --
  // `serve.py` reads it from there, so passing the resolved string is what
  // makes 「保存的配置优先」 true at the only layer that decides which weights
  // actually get downloaded.
  const resolvedWhisperModel = resolveWhisperModel(
    providerConfigStore.getWhisperModel(),
    process.env.OPENTYPE_WHISPER_MODEL
  );
  const whisperClient = new WhisperClient(
    {
      socketPath: env.whisperSocketPath,
      extraEnv: { OPENTYPE_WHISPER_MODEL: resolvedWhisperModel.model },
    },
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
    options: TranscribeOptions = {}
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
      // whatever comes back. `language` it does take, in the same ISO-639-1
      // vocabulary, so the transcription-language setting means the same thing
      // whichever backend is serving; the branch drops only what it cannot use.
      return remoteClient.transcribe(audio, { language: options.language });
    }
    await whisperReady;
    return whisperClient.transcribe(audio, options);
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
    process.env.OPENTYPE_MCP_SERVERS,
    // The exit for the connection report above. Without this, the outcome of
    // every boot connection is recorded and read by nobody, so a server skipped
    // at startup renders in the panel exactly like one that works -- a silent
    // skip is just a silent failure one layer along. `status` is a closure over
    // that report rather than a method, so passing it unbound is safe.
    mcpTools.status,
    // Same closure-not-method reasoning as `mcpTools.status` above: `reload`
    // closes over this `mcpTools` instance's own state rather than reading
    // `this`, so passing it unbound is safe. Fires-and-returns immediately --
    // `reload` itself is synchronous (see its doc comment) and nothing here
    // awaits it or its `.ready`, which is exactly what
    // `McpConfigRouteDeps.onServersChanged`'s contract requires.
    mcpTools.reload,
    process.env.OPENTYPE_WHISPER_MODEL,
    {
      // Read per request: the user can save a remote-Whisper config at any
      // point after boot, and a captured value would report the boot-time
      // backend for the life of the process.
      //
      // Keyed off `shouldStartLocalWhisper` -- the predicate that decided
      // whether a python child exists at all -- rather than
      // `resolveTranscribe`'s rule, which additionally demands a baseUrl and
      // key. A saved remote config missing its key would read as "local" under
      // that rule and poll for a download, while there is no child in existence
      // to ask.
      backend: () => {
        const current = providerConfigStore.getStatus();
        return shouldStartLocalWhisper({
          whisperConfigured: current.whisperConfigured,
          mode: providerConfigStore.getWhisperConfig()?.mode,
        })
          ? "local"
          : "remote";
      },
      localStatus: async () => {
        const response = await globalThis.fetch("http://localhost/status", {
          unix: env.whisperSocketPath,
          signal: AbortSignal.timeout(2_000),
        } as RequestInit);
        if (!response.ok) {
          // An older `serve.py` without /status 404s here. A child that is up
          // but not answering this contract is, to the user, the same
          // situation as one that is not up -- the route reports `starting`.
          throw new Error(`whisper /status answered ${response.status}`);
        }
        return (await response.json()) as LocalWhisperStatus;
      },
    },
    env.contextLogPath,
    env.agentApprovalMode,
    skillStore,
    agentDefinitions
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
