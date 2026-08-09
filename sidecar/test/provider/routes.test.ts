import { describe, expect, test, beforeEach, afterEach } from "bun:test";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createRouter } from "../../src/router";
import { ProviderConfigStore } from "../../src/provider/configStore";
import { buildProviderConfigRoutes } from "../../src/provider/routes";
import type { LLMProviderClient } from "../../src/provider/types";

let dir: string;
let store: ProviderConfigStore;

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), "opentype-provider-routes-"));
  store = new ProviderConfigStore(join(dir, "provider-config.json"));
});

afterEach(() => {
  rmSync(dir, { recursive: true, force: true });
});

function makeApp(overrides: {
  createLLMClient?: (config: { type: string; baseUrl: string; apiKey: string; model: string }) => LLMProviderClient;
  createRemoteWhisperClient?: (config: { baseUrl: string; apiKey: string; model?: string }) => {
    testConnection: () => Promise<{ success: boolean; error?: string }>;
  };
} = {}) {
  const routes = buildProviderConfigRoutes(store, overrides as any);
  return createRouter(routes);
}

async function call(app: ReturnType<typeof createRouter>, method: string, path: string, body?: unknown) {
  const req = new Request(`http://localhost${path}`, {
    method,
    headers: body ? { "Content-Type": "application/json" } : undefined,
    body: body ? JSON.stringify(body) : undefined,
  });
  const res = await app(req);
  const json = await res.json();
  return { status: res.status, json };
}

describe("GET /config/status", () => {
  test("reports both unconfigured initially", async () => {
    const app = makeApp();
    const { status, json } = await call(app, "GET", "/config/status");
    expect(status).toBe(200);
    expect(json).toEqual({ llmConfigured: false, whisperConfigured: false, ready: false });
  });

  test("reports ready:true once both are configured", async () => {
    store.setLLMConfig({ type: "openai-compatible", baseUrl: "https://api.deepseek.com", apiKey: "sk-x", model: "deepseek-chat" });
    store.setWhisperConfig({ mode: "local" });
    const app = makeApp();
    const { json } = await call(app, "GET", "/config/status");
    expect(json).toEqual({ llmConfigured: true, whisperConfigured: true, ready: true });
  });
});

describe("PUT /config/llm", () => {
  test("saves a valid config, masks the api key in the response, and marks configured", async () => {
    const app = makeApp();
    const { status, json } = await call(app, "PUT", "/config/llm", {
      type: "openai-compatible",
      baseUrl: "https://api.deepseek.com",
      apiKey: "sk-super-secret-key",
      model: "deepseek-chat",
    });

    expect(status).toBe(200);
    expect(json.configured).toBe(true);
    expect(json.apiKeyMasked).not.toContain("super-secret");
    expect(json.apiKeyMasked).toContain("-key");
    expect(store.getStatus().llmConfigured).toBe(true);
    expect(store.getLLMConfig()?.apiKey).toBe("sk-super-secret-key");
  });

  test("rejects a request missing required fields with 400", async () => {
    const app = makeApp();
    const { status, json } = await call(app, "PUT", "/config/llm", { type: "openai-compatible" });
    expect(status).toBe(400);
    expect(json.error).toBeTruthy();
    expect(store.getStatus().llmConfigured).toBe(false);
  });
});

describe("GET /config/llm", () => {
  test("returns configured:false when nothing is saved yet", async () => {
    const app = makeApp();
    const { json } = await call(app, "GET", "/config/llm");
    expect(json).toEqual({ configured: false });
  });

  test("returns the masked config once saved", async () => {
    store.setLLMConfig({ type: "anthropic", baseUrl: "https://api.anthropic.com", apiKey: "sk-ant-abcd1234", model: "claude-sonnet-4-5-20250929" });
    const app = makeApp();
    const { json } = await call(app, "GET", "/config/llm");
    expect(json.configured).toBe(true);
    expect(json.type).toBe("anthropic");
    expect(json.model).toBe("claude-sonnet-4-5-20250929");
    expect(json.apiKeyMasked).not.toBe("sk-ant-abcd1234");
  });
});

describe("POST /config/llm/test", () => {
  test("returns success:true when the underlying client reports success", async () => {
    const app = makeApp({
      createLLMClient: () =>
        ({
          chat: async () => ({ content: "" }),
          testConnection: async () => ({ success: true }),
          listModels: async () => [],
        }) as LLMProviderClient,
    });

    const { status, json } = await call(app, "POST", "/config/llm/test", {
      type: "openai-compatible",
      baseUrl: "https://api.deepseek.com",
      apiKey: "sk-x",
    });

    expect(status).toBe(200);
    expect(json).toEqual({ success: true });
  });

  test("passes through a real error message on failure", async () => {
    const app = makeApp({
      createLLMClient: () =>
        ({
          chat: async () => ({ content: "" }),
          testConnection: async () => ({ success: false, error: "Invalid API key" }),
          listModels: async () => [],
        }) as LLMProviderClient,
    });

    const { json } = await call(app, "POST", "/config/llm/test", {
      type: "openai-compatible",
      baseUrl: "https://api.deepseek.com",
      apiKey: "sk-bad",
    });

    expect(json).toEqual({ success: false, error: "Invalid API key" });
  });
});

describe("POST /config/llm/models", () => {
  test("returns models with fallback:false when listing succeeds", async () => {
    const app = makeApp({
      createLLMClient: () =>
        ({
          chat: async () => ({ content: "" }),
          testConnection: async () => ({ success: true }),
          listModels: async () => [{ id: "deepseek-chat" }, { id: "deepseek-reasoner" }],
        }) as LLMProviderClient,
    });

    const { json } = await call(app, "POST", "/config/llm/models", {
      type: "openai-compatible",
      baseUrl: "https://api.deepseek.com",
      apiKey: "sk-x",
    });

    expect(json).toEqual({ models: ["deepseek-chat", "deepseek-reasoner"], fallback: false });
  });

  test("falls back to the hardcoded known-model list when listing fails", async () => {
    const app = makeApp({
      createLLMClient: () =>
        ({
          chat: async () => ({ content: "" }),
          testConnection: async () => ({ success: false }),
          listModels: async () => {
            throw new Error("listing not supported");
          },
        }) as LLMProviderClient,
    });

    const { json } = await call(app, "POST", "/config/llm/models", {
      type: "anthropic",
      baseUrl: "https://api.anthropic.com",
      apiKey: "sk-ant-x",
    });

    expect(json.fallback).toBe(true);
    expect(Array.isArray(json.models)).toBe(true);
    expect(json.models.length).toBeGreaterThan(0);
  });
});

describe("PUT /config/whisper", () => {
  test("saves local mode with no url/key required", async () => {
    const app = makeApp();
    const { status, json } = await call(app, "PUT", "/config/whisper", { mode: "local" });
    expect(status).toBe(200);
    expect(json.configured).toBe(true);
    expect(json.mode).toBe("local");
    expect(store.getStatus().whisperConfigured).toBe(true);
  });

  test("rejects remote mode missing baseUrl/apiKey with 400", async () => {
    const app = makeApp();
    const { status, json } = await call(app, "PUT", "/config/whisper", { mode: "remote" });
    expect(status).toBe(400);
    expect(json.error).toBeTruthy();
  });

  test("saves remote mode and masks the api key in the response", async () => {
    const app = makeApp();
    const { status, json } = await call(app, "PUT", "/config/whisper", {
      mode: "remote",
      baseUrl: "https://api.openai.com/v1",
      apiKey: "sk-remote-secret",
    });
    expect(status).toBe(200);
    expect(json.mode).toBe("remote");
    expect(json.apiKeyMasked).not.toContain("remote-secret");
  });
});

describe("POST /config/whisper/test", () => {
  test("delegates to the remote whisper client and reports success/failure", async () => {
    const app = makeApp({
      createRemoteWhisperClient: () => ({
        testConnection: async () => ({ success: false, error: "bad key" }),
      }),
    });

    const { json } = await call(app, "POST", "/config/whisper/test", {
      baseUrl: "https://api.openai.com/v1",
      apiKey: "sk-bad",
    });

    expect(json).toEqual({ success: false, error: "bad key" });
  });
});
