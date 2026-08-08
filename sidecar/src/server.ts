import { unlinkSync, existsSync } from "node:fs";
import { loadEnv } from "./env";
import { createRouter } from "./router";

export function buildApp() {
  return createRouter([
    {
      method: "GET",
      path: "/health",
      handler: () => Response.json({ status: "ok" }),
    },
  ]);
}

function main() {
  const env = loadEnv();
  const fetch = buildApp();

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
