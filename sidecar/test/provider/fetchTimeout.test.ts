import { describe, expect, test } from "bun:test";
import { createAnthropicClient } from "../../src/provider/anthropic";
import { createOpenAICompatibleClient } from "../../src/provider/openaiCompatible";
import { createDeepSeekClient } from "../../src/provider/deepseek";
import { createRemoteWhisperClient } from "../../src/asr/remoteWhisperClient";
import type { LLMProviderConfig } from "../../src/provider/types";

/**
 * Bug P2: every outbound provider fetch is issued with no `AbortSignal`, so a
 * hung upstream (an LLM / remote-Whisper server that accepts the socket but
 * never responds) makes the request hang forever, wedging the request path.
 *
 * Desired fix: every outbound fetch a provider client issues must carry an
 * `AbortSignal` -- specifically an `AbortSignal.timeout(...)` -- so a hung
 * upstream aborts within a bounded time instead of hanging indefinitely.
 *
 * These tests assert the observable seam deterministically: inject a fetch
 * that resolves normally but captures `init.signal`, and assert the signal is
 * an `AbortSignal` on EVERY outbound call (chat / listModels / transcribe).
 * They intentionally do NOT drive a real never-resolving upstream to prove the
 * abort fires -- that can only produce RED by hanging until a test timeout,
 * which leaves a dangling pending promise and makes the suite flaky. Signal
 * presence is the deterministic proof that the timeout is wired in.
 *
 * Desired seam (see report): each factory takes an optional final
 * `options?: { timeoutMs?: number }` arg (default ~60_000) and passes
 * `signal: AbortSignal.timeout(options?.timeoutMs ?? DEFAULT)` on every
 * outbound fetch.
 */

const llmConfig: LLMProviderConfig = {
  type: "openai-compatible",
  baseUrl: "https://api.example.com",
  apiKey: "sk-test-key",
  model: "test-model",
};

const anthropicConfig: LLMProviderConfig = {
  type: "anthropic",
  baseUrl: "https://api.anthropic.com",
  apiKey: "sk-ant-test-key",
  model: "claude-test",
};

function jsonResponse(body: unknown): Response {
  return new Response(JSON.stringify(body), {
    status: 200,
    headers: { "Content-Type": "application/json" },
  });
}

function capturingFetch(body: unknown, sink: { init?: RequestInit }): typeof fetch {
  const impl = async (_url: string | URL | Request, init?: RequestInit) => {
    sink.init = init;
    return jsonResponse(body);
  };
  return impl as unknown as typeof fetch;
}

describe("openai-compatible client passes an AbortSignal on outbound fetches", () => {
  test("chat() attaches an AbortSignal to the request", async () => {
    const sink: { init?: RequestInit } = {};
    const client = createOpenAICompatibleClient(
      llmConfig,
      capturingFetch({ choices: [{ message: { role: "assistant", content: "hi" } }] }, sink)
    );
    await client.chat([{ role: "user", content: "hi" }]);
    expect(sink.init?.signal).toBeInstanceOf(AbortSignal);
  });

  test("listModels() attaches an AbortSignal to the request", async () => {
    const sink: { init?: RequestInit } = {};
    const client = createOpenAICompatibleClient(
      llmConfig,
      capturingFetch({ data: [{ id: "test-model" }] }, sink)
    );
    await client.listModels();
    expect(sink.init?.signal).toBeInstanceOf(AbortSignal);
  });
});

describe("anthropic client passes an AbortSignal on outbound fetches", () => {
  test("chat() attaches an AbortSignal to the request", async () => {
    const sink: { init?: RequestInit } = {};
    const client = createAnthropicClient(
      anthropicConfig,
      capturingFetch({ content: [{ type: "text", text: "hi" }] }, sink)
    );
    await client.chat([{ role: "user", content: "hi" }]);
    expect(sink.init?.signal).toBeInstanceOf(AbortSignal);
  });

  test("listModels() attaches an AbortSignal to the request", async () => {
    const sink: { init?: RequestInit } = {};
    const client = createAnthropicClient(
      anthropicConfig,
      capturingFetch({ data: [{ id: "claude-test" }] }, sink)
    );
    await client.listModels();
    expect(sink.init?.signal).toBeInstanceOf(AbortSignal);
  });
});

describe("deepseek client passes an AbortSignal on outbound fetches", () => {
  const env = {
    deepSeekApiKey: "sk-deepseek",
    deepSeekModel: "deepseek-chat",
    deepSeekBaseUrl: "https://api.deepseek.com",
  };

  test("chat() attaches an AbortSignal to the request", async () => {
    const sink: { init?: RequestInit } = {};
    const client = createDeepSeekClient(
      env,
      capturingFetch({ choices: [{ message: { role: "assistant", content: "hi" } }] }, sink)
    );
    await client.chat([{ role: "user", content: "hi" }]);
    expect(sink.init?.signal).toBeInstanceOf(AbortSignal);
  });
});

describe("remote whisper client passes an AbortSignal on outbound fetches", () => {
  const config = {
    baseUrl: "https://whisper.example.com",
    apiKey: "sk-whisper",
    model: "whisper-1",
  };

  test("transcribe() attaches an AbortSignal to the request", async () => {
    const sink: { init?: RequestInit } = {};
    const client = createRemoteWhisperClient(config, capturingFetch({ text: "hello" }, sink));
    await client.transcribe(new Uint8Array([1, 2, 3]));
    expect(sink.init?.signal).toBeInstanceOf(AbortSignal);
  });
});
