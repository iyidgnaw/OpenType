import { describe, expect, test } from "bun:test";
import { loadEnv } from "../src/env";

describe("loadEnv", () => {
  test("falls back to dev defaults when nothing is set", () => {
    const env = loadEnv({});
    expect(env.socketPath).toBe("/tmp/opentype-sidecar-dev.sock");
    expect(env.deepSeekModel).toBe("deepseek-v4-flash");
    expect(env.deepSeekBaseUrl).toBe("https://api.deepseek.com");
    expect(env.deepSeekApiKey).toBe("");
    expect(env.dbPath).toBe("sidecar/.data/opentype.sqlite3");
    expect(env.contextLogPath).toBe("sidecar/.data/context-debug.log");
  });

  test("reads values from the provided source", () => {
    const env = loadEnv({
      OPENTYPE_SIDECAR_SOCKET: "/tmp/custom.sock",
      DEEPSEEK_API_KEY: "sk-test",
      DEEPSEEK_MODEL: "deepseek-chat",
      DEEPSEEK_BASE_URL: "https://example.invalid",
      OPENTYPE_SIDECAR_DB_PATH: "/tmp/custom.sqlite3",
      OPENTYPE_CONTEXT_LOG_PATH: "/tmp/custom-context-debug.log",
    });
    expect(env.socketPath).toBe("/tmp/custom.sock");
    expect(env.deepSeekApiKey).toBe("sk-test");
    expect(env.deepSeekModel).toBe("deepseek-chat");
    expect(env.deepSeekBaseUrl).toBe("https://example.invalid");
    expect(env.dbPath).toBe("/tmp/custom.sqlite3");
    expect(env.contextLogPath).toBe("/tmp/custom-context-debug.log");
  });
});
