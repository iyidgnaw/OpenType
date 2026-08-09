import { describe, expect, test } from "bun:test";
import {
  createOpenAICompatibleClient,
  OpenAICompatibleApiError,
} from "../../src/provider/openaiCompatible";
import type { LLMProviderConfig } from "../../src/provider/types";

const testConfig: LLMProviderConfig = {
  type: "openai-compatible",
  baseUrl: "https://api.deepseek.com",
  apiKey: "sk-test-key",
  model: "deepseek-chat",
};

function jsonResponse(body: unknown, init: ResponseInit = {}): Response {
  return new Response(JSON.stringify(body), {
    status: 200,
    headers: { "Content-Type": "application/json" },
    ...init,
  });
}

describe("createOpenAICompatibleClient.chat", () => {
  test("POSTs to <baseUrl>/chat/completions with bearer auth and the configured model", async () => {
    let capturedUrl: string | undefined;
    let capturedInit: RequestInit | undefined;

    const fakeFetch = async (url: string | URL | Request, init?: RequestInit) => {
      capturedUrl = url.toString();
      capturedInit = init;
      return jsonResponse({
        choices: [{ message: { role: "assistant", content: "hello" } }],
      });
    };

    const client = createOpenAICompatibleClient(testConfig, fakeFetch as unknown as typeof fetch);
    await client.chat([{ role: "user", content: "hi" }]);

    expect(capturedUrl).toBe("https://api.deepseek.com/chat/completions");
    const headers = new Headers(capturedInit?.headers);
    expect(headers.get("Authorization")).toBe("Bearer sk-test-key");
    const body = JSON.parse(capturedInit?.body as string);
    expect(body.model).toBe("deepseek-chat");
  });

  test("returns content and tool_calls from a successful response", async () => {
    const toolCalls = [
      { id: "call_1", type: "function", function: { name: "get_weather", arguments: "{}" } },
    ];
    const fakeFetch = async () =>
      jsonResponse({ choices: [{ message: { role: "assistant", content: null, tool_calls: toolCalls } }] });

    const client = createOpenAICompatibleClient(testConfig, fakeFetch as unknown as typeof fetch);
    const result = await client.chat([{ role: "user", content: "weather?" }]);

    expect(result.content).toBeNull();
    expect(result.toolCalls).toEqual(toolCalls);
  });

  test("throws OpenAICompatibleApiError with status + message on a non-2xx response", async () => {
    const fakeFetch = async () =>
      jsonResponse({ error: { message: "Invalid API key" } }, { status: 401 });

    const client = createOpenAICompatibleClient(testConfig, fakeFetch as unknown as typeof fetch);

    try {
      await client.chat([{ role: "user", content: "hi" }]);
      throw new Error("expected chat() to throw");
    } catch (err) {
      expect(err).toBeInstanceOf(OpenAICompatibleApiError);
      const apiErr = err as InstanceType<typeof OpenAICompatibleApiError>;
      expect(apiErr.status).toBe(401);
      expect(apiErr.message).toContain("Invalid API key");
    }
  });
});

describe("createOpenAICompatibleClient.listModels", () => {
  test("GETs <baseUrl>/models and returns the parsed ids", async () => {
    let capturedUrl: string | undefined;
    let capturedInit: RequestInit | undefined;
    const fakeFetch = async (url: string | URL | Request, init?: RequestInit) => {
      capturedUrl = url.toString();
      capturedInit = init;
      return jsonResponse({ data: [{ id: "deepseek-chat" }, { id: "deepseek-reasoner" }] });
    };

    const client = createOpenAICompatibleClient(testConfig, fakeFetch as unknown as typeof fetch);
    const models = await client.listModels();

    expect(capturedUrl).toBe("https://api.deepseek.com/models");
    const headers = new Headers(capturedInit?.headers);
    expect(headers.get("Authorization")).toBe("Bearer sk-test-key");
    expect(models).toEqual([{ id: "deepseek-chat" }, { id: "deepseek-reasoner" }]);
  });

  test("throws when the models endpoint returns a non-2xx response", async () => {
    const fakeFetch = async () => jsonResponse({ error: { message: "not found" } }, { status: 404 });
    const client = createOpenAICompatibleClient(testConfig, fakeFetch as unknown as typeof fetch);

    await expect(client.listModels()).rejects.toThrow(OpenAICompatibleApiError);
  });
});

describe("createOpenAICompatibleClient.testConnection", () => {
  test("returns success:true when listing models succeeds", async () => {
    const fakeFetch = async () => jsonResponse({ data: [{ id: "deepseek-chat" }] });
    const client = createOpenAICompatibleClient(testConfig, fakeFetch as unknown as typeof fetch);

    const result = await client.testConnection();
    expect(result).toEqual({ success: true });
  });

  test("returns success:false with a real error message on auth failure", async () => {
    const fakeFetch = async () =>
      jsonResponse({ error: { message: "Invalid API key" } }, { status: 401 });
    const client = createOpenAICompatibleClient(testConfig, fakeFetch as unknown as typeof fetch);

    const result = await client.testConnection();
    expect(result.success).toBe(false);
    expect(result.error).toContain("Invalid API key");
  });

  test("falls back to a minimal chat call when the models endpoint 404s", async () => {
    const calls: string[] = [];
    const fakeFetch = async (url: string | URL | Request) => {
      const urlString = url.toString();
      calls.push(urlString);
      if (urlString.endsWith("/models")) {
        return jsonResponse({ error: { message: "not found" } }, { status: 404 });
      }
      return jsonResponse({ choices: [{ message: { role: "assistant", content: "ok" } }] });
    };

    const client = createOpenAICompatibleClient(testConfig, fakeFetch as unknown as typeof fetch);
    const result = await client.testConnection();

    expect(result).toEqual({ success: true });
    expect(calls).toEqual([
      "https://api.deepseek.com/models",
      "https://api.deepseek.com/chat/completions",
    ]);
  });
});
