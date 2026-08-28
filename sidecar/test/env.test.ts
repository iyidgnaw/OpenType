import { describe, expect, test } from "bun:test";
import { resolve } from "node:path";
import { loadEnv } from "../src/env";

describe("loadEnv", () => {
  test("falls back to dev defaults when nothing is set", () => {
    const env = loadEnv({});
    expect(env.socketPath).toBe("/tmp/opentype-sidecar-dev.sock");
    expect(env.deepSeekModel).toBe("deepseek-v4-flash");
    expect(env.deepSeekBaseUrl).toBe("https://api.deepseek.com");
    expect(env.deepSeekApiKey).toBe("");
    expect(env.dbPath).toBe(
      resolve(import.meta.dir, "..", ".data", "opentype.sqlite3")
    );
    expect(env.contextLogPath).toBe("sidecar/.data/context-debug.log");
    expect(env.whisperSocketPath).toBe("sidecar/.data/whisper.sock");
  });

  test("reads values from the provided source", () => {
    const env = loadEnv({
      OPENTYPE_SIDECAR_SOCKET: "/tmp/custom.sock",
      DEEPSEEK_API_KEY: "sk-test",
      DEEPSEEK_MODEL: "deepseek-chat",
      DEEPSEEK_BASE_URL: "https://example.invalid",
      OPENTYPE_SIDECAR_DB_PATH: "/tmp/custom.sqlite3",
      OPENTYPE_CONTEXT_LOG_PATH: "/tmp/custom-context-debug.log",
      OPENTYPE_WHISPER_SOCKET: "/tmp/custom-whisper.sock",
    });
    expect(env.socketPath).toBe("/tmp/custom.sock");
    expect(env.deepSeekApiKey).toBe("sk-test");
    expect(env.deepSeekModel).toBe("deepseek-chat");
    expect(env.deepSeekBaseUrl).toBe("https://example.invalid");
    expect(env.dbPath).toBe("/tmp/custom.sqlite3");
    expect(env.contextLogPath).toBe("/tmp/custom-context-debug.log");
    expect(env.whisperSocketPath).toBe("/tmp/custom-whisper.sock");
  });
});

/**
 * §2.1 of docs/superpowers/specs/2026-08-28-first-party-tools-skills-and-agents-design.md:
 * "闸门默认打开" -- `/agent/run` stops prompting for destructive commands by
 * default. `OPENTYPE_AGENT_APPROVAL` is the escape hatch back to today's
 * always-prompt behavior. `env.agentApprovalMode` does not exist on
 * `SidecarEnv` yet, so every assertion below reads `undefined` until it's
 * added -- the expected RED failure mode for this whole block.
 */
describe("agentApprovalMode (OPENTYPE_AGENT_APPROVAL)", () => {
  test("defaults to 'yolo' when unset", () => {
    const env = loadEnv({});
    expect(env.agentApprovalMode).toBe("yolo");
  });

  test("reads 'prompt' from OPENTYPE_AGENT_APPROVAL", () => {
    const env = loadEnv({ OPENTYPE_AGENT_APPROVAL: "prompt" });
    expect(env.agentApprovalMode).toBe("prompt");
  });

  test("reads 'yolo' explicitly", () => {
    const env = loadEnv({ OPENTYPE_AGENT_APPROVAL: "yolo" });
    expect(env.agentApprovalMode).toBe("yolo");
  });

  // Fail-closed toward the SAFER (prompting-capable) baseline product
  // stance would suggest, but design §2.1 is explicit: unrecognised values
  // fall back to "yolo", not "prompt" -- an env var a user mistyped should
  // not silently make the product act as if they'd asked for confirmation
  // prompts they never opted into.
  test("falls back to 'yolo' for any unrecognised value", () => {
    const env = loadEnv({ OPENTYPE_AGENT_APPROVAL: "sudo-mode" });
    expect(env.agentApprovalMode).toBe("yolo");
  });
});
