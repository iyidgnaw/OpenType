import { unlinkSync, existsSync } from "node:fs";
import { buildAgentRoutes } from "./agent/routes";
import type { AgentChatFn } from "./agent/loop";
import { connectConfiguredMcpServers, type McpToolSet } from "./agent/mcpClient";
import { buildAsrRoutes } from "./asr/routes";
import { defaultWhisperClientFactories, WhisperClient } from "./asr/whisperClient";
import { loadEnv } from "./env";
import { openDatabase } from "./memory/db";
import { MemoryStore } from "./memory/MemoryStore";
import { buildMemoryRoutes } from "./memory/routes";
import { buildOneShotRoutes } from "./oneshot/routes";
import { createFileContextUsageLogWriter, type ContextUsageLogWriter } from "./oneshot/contextDebugLog";
import { createDeepSeekClient } from "./provider/deepseek";
import { createRouter } from "./router";

/**
 * `chat` is typed `AgentChatFn` (rather than the narrower `OneShotChatFn`)
 * because it's shared with `/agent/run`, which needs the tool-calling
 * message shape; `AgentChatFn` is structurally compatible with
 * `OneShotChatFn`, so it still satisfies `buildOneShotRoutes` unchanged.
 */
export function buildApp(
  store: MemoryStore,
  chat: AgentChatFn,
  tools: McpToolSet,
  contextLogWriter: ContextUsageLogWriter,
  transcribe: (audio: Uint8Array) => Promise<string>
) {
  return createRouter([
    {
      method: "GET",
      path: "/health",
      handler: () => Response.json({ status: "ok" }),
    },
    ...buildOneShotRoutes(store, chat, contextLogWriter),
    ...buildMemoryRoutes(store),
    ...buildAgentRoutes(store, chat, tools, contextLogWriter),
    ...buildAsrRoutes(transcribe),
  ]);
}

async function main() {
  const env = loadEnv();
  const store = new MemoryStore(openDatabase(env.dbPath));
  const deepSeekClient = createDeepSeekClient(env);
  const tools = await connectConfiguredMcpServers(process.env.OPENTYPE_MCP_SERVERS);
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

  const fetch = buildApp(store, deepSeekClient.chat, tools, contextLogWriter, async (audio) => {
    await whisperReady;
    return whisperClient.transcribe(audio);
  });

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
