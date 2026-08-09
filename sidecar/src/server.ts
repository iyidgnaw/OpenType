import { unlinkSync, existsSync } from "node:fs";
import { buildAgentRoutes } from "./agent/routes";
import type { AgentChatFn } from "./agent/loop";
import { connectConfiguredMcpServers, type McpToolSet } from "./agent/mcpClient";
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
  contextLogWriter: ContextUsageLogWriter
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
  ]);
}

async function main() {
  const env = loadEnv();
  const store = new MemoryStore(openDatabase(env.dbPath));
  const deepSeekClient = createDeepSeekClient(env);
  const tools = await connectConfiguredMcpServers(process.env.OPENTYPE_MCP_SERVERS);
  const contextLogWriter = createFileContextUsageLogWriter(env.contextLogPath);
  const fetch = buildApp(store, deepSeekClient.chat, tools, contextLogWriter);

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
