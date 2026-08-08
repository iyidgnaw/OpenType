import { unlinkSync, existsSync } from "node:fs";
import { loadEnv } from "./env";
import { openDatabase } from "./memory/db";
import { MemoryStore } from "./memory/MemoryStore";
import { buildMemoryRoutes } from "./memory/routes";
import type { OneShotChatFn } from "./oneshot/client";
import { buildOneShotRoutes } from "./oneshot/routes";
import { createDeepSeekClient } from "./provider/deepseek";
import { createRouter } from "./router";

export function buildApp(store: MemoryStore, chat: OneShotChatFn) {
  return createRouter([
    {
      method: "GET",
      path: "/health",
      handler: () => Response.json({ status: "ok" }),
    },
    ...buildOneShotRoutes(store, chat),
    ...buildMemoryRoutes(store),
  ]);
}

function main() {
  const env = loadEnv();
  const store = new MemoryStore(openDatabase(env.dbPath));
  const deepSeekClient = createDeepSeekClient(env);
  const fetch = buildApp(store, deepSeekClient.chat);

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
