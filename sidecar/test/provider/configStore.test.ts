import { describe, expect, test, beforeEach, afterEach } from "bun:test";
import { existsSync, mkdtempSync, readFileSync, rmSync, statSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { ProviderConfigStore } from "../../src/provider/configStore";

let dir: string;

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), "opentype-provider-config-"));
});

afterEach(() => {
  rmSync(dir, { recursive: true, force: true });
});

describe("ProviderConfigStore", () => {
  test("starts unconfigured for both llm and whisper when no file exists on disk", () => {
    const store = new ProviderConfigStore(join(dir, "provider-config.json"));
    expect(store.getStatus()).toEqual({ llmConfigured: false, whisperConfigured: false });
    expect(store.getLLMConfig()).toBeUndefined();
    expect(store.getWhisperConfig()).toBeUndefined();
  });

  test("setLLMConfig persists the config and marks llmConfigured true", () => {
    const path = join(dir, "provider-config.json");
    const store = new ProviderConfigStore(path);

    store.setLLMConfig({
      type: "openai-compatible",
      baseUrl: "https://api.deepseek.com",
      apiKey: "sk-secret",
      model: "deepseek-chat",
    });

    expect(store.getStatus().llmConfigured).toBe(true);
    expect(store.getLLMConfig()).toEqual({
      type: "openai-compatible",
      baseUrl: "https://api.deepseek.com",
      apiKey: "sk-secret",
      model: "deepseek-chat",
    });
    expect(existsSync(path)).toBe(true);
  });

  test("setWhisperConfig persists the config and marks whisperConfigured true", () => {
    const store = new ProviderConfigStore(join(dir, "provider-config.json"));

    store.setWhisperConfig({ mode: "local" });

    expect(store.getStatus().whisperConfigured).toBe(true);
    expect(store.getWhisperConfig()).toEqual({ mode: "local" });
  });

  test("a fresh store reloads previously persisted config from disk", () => {
    const path = join(dir, "provider-config.json");
    const first = new ProviderConfigStore(path);
    first.setLLMConfig({
      type: "anthropic",
      baseUrl: "https://api.anthropic.com",
      apiKey: "sk-ant-secret",
      model: "claude-sonnet-4-5-20250929",
    });
    first.setWhisperConfig({ mode: "remote", baseUrl: "https://api.openai.com/v1", apiKey: "sk-openai" });

    const second = new ProviderConfigStore(path);
    expect(second.getStatus()).toEqual({ llmConfigured: true, whisperConfigured: true });
    expect(second.getLLMConfig()?.model).toBe("claude-sonnet-4-5-20250929");
    expect(second.getWhisperConfig()?.mode).toBe("remote");
  });

  test("persists the config file with owner-only (0600) permissions", () => {
    const path = join(dir, "provider-config.json");
    const store = new ProviderConfigStore(path);
    store.setLLMConfig({
      type: "openai-compatible",
      baseUrl: "https://api.deepseek.com",
      apiKey: "sk-secret",
      model: "deepseek-chat",
    });

    const mode = statSync(path).mode & 0o777;
    expect(mode).toBe(0o600);
  });

  test("the persisted file is plain JSON containing the config as-written (documented plaintext tradeoff)", () => {
    const path = join(dir, "provider-config.json");
    const store = new ProviderConfigStore(path);
    store.setLLMConfig({
      type: "openai-compatible",
      baseUrl: "https://api.deepseek.com",
      apiKey: "sk-secret",
      model: "deepseek-chat",
    });

    const raw = readFileSync(path, "utf8");
    expect(raw).toContain("sk-secret");
  });
});
