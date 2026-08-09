import { describe, expect, test } from "bun:test";
import { createAnthropicClient, AnthropicApiError } from "../../src/provider/anthropic";
import type { LLMProviderConfig } from "../../src/provider/types";

const testConfig: LLMProviderConfig = {
  type: "anthropic",
  baseUrl: "https://api.anthropic.com",
  apiKey: "sk-ant-test-key",
  model: "claude-sonnet-4-5-20250929",
};

function jsonResponse(body: unknown, init: ResponseInit = {}): Response {
  return new Response(JSON.stringify(body), {
    status: 200,
    headers: { "Content-Type": "application/json" },
    ...init,
  });
}

describe("createAnthropicClient.chat", () => {
  test("POSTs to <baseUrl>/v1/messages with x-api-key + anthropic-version headers", async () => {
    let capturedUrl: string | undefined;
    let capturedInit: RequestInit | undefined;
    const fakeFetch = async (url: string | URL | Request, init?: RequestInit) => {
      capturedUrl = url.toString();
      capturedInit = init;
      return jsonResponse({
        content: [{ type: "text", text: "hello" }],
        stop_reason: "end_turn",
      });
    };

    const client = createAnthropicClient(testConfig, fakeFetch as unknown as typeof fetch);
    await client.chat([{ role: "user", content: "hi" }]);

    expect(capturedUrl).toBe("https://api.anthropic.com/v1/messages");
    const headers = new Headers(capturedInit?.headers);
    expect(headers.get("x-api-key")).toBe("sk-ant-test-key");
    expect(headers.get("anthropic-version")).toBe("2023-06-01");
    const body = JSON.parse(capturedInit?.body as string);
    expect(body.model).toBe("claude-sonnet-4-5-20250929");
    expect(body.messages).toEqual([{ role: "user", content: "hi" }]);
  });

  test("moves a leading system message out of `messages` and into a top-level `system` field", async () => {
    let capturedBody: Record<string, unknown> | undefined;
    const fakeFetch = async (_url: string | URL | Request, init?: RequestInit) => {
      capturedBody = JSON.parse(init?.body as string);
      return jsonResponse({ content: [{ type: "text", text: "ok" }] });
    };

    const client = createAnthropicClient(testConfig, fakeFetch as unknown as typeof fetch);
    await client.chat([
      { role: "system", content: "You are helpful." },
      { role: "user", content: "hi" },
    ]);

    expect(capturedBody?.system).toBe("You are helpful.");
    expect(capturedBody?.messages).toEqual([{ role: "user", content: "hi" }]);
  });

  test("returns the concatenated text from response content blocks", async () => {
    const fakeFetch = async () =>
      jsonResponse({ content: [{ type: "text", text: "the answer is 42" }] });

    const client = createAnthropicClient(testConfig, fakeFetch as unknown as typeof fetch);
    const result = await client.chat([{ role: "user", content: "what is the answer?" }]);

    expect(result.content).toBe("the answer is 42");
    expect(result.toolCalls).toBeUndefined();
  });

  test("translates OpenAI-shaped tool defs into Anthropic tool defs in the request", async () => {
    let capturedBody: Record<string, unknown> | undefined;
    const fakeFetch = async (_url: string | URL | Request, init?: RequestInit) => {
      capturedBody = JSON.parse(init?.body as string);
      return jsonResponse({ content: [{ type: "text", text: "ok" }] });
    };

    const tools = [
      {
        type: "function",
        function: {
          name: "get_weather",
          description: "Get the weather",
          parameters: { type: "object", properties: { location: { type: "string" } } },
        },
      },
    ];

    const client = createAnthropicClient(testConfig, fakeFetch as unknown as typeof fetch);
    await client.chat([{ role: "user", content: "weather?" }], { tools });

    expect(capturedBody?.tools).toEqual([
      {
        name: "get_weather",
        description: "Get the weather",
        input_schema: { type: "object", properties: { location: { type: "string" } } },
      },
    ]);
  });

  test("translates a tool_use response content block into an OpenAI-shaped toolCall", async () => {
    const fakeFetch = async () =>
      jsonResponse({
        content: [
          { type: "tool_use", id: "toolu_1", name: "get_weather", input: { location: "SF" } },
        ],
      });

    const client = createAnthropicClient(testConfig, fakeFetch as unknown as typeof fetch);
    const result = await client.chat([{ role: "user", content: "weather in SF?" }]);

    expect(result.toolCalls).toEqual([
      {
        id: "toolu_1",
        type: "function",
        function: { name: "get_weather", arguments: JSON.stringify({ location: "SF" }) },
      },
    ]);
  });

  test("translates a role:tool message into an Anthropic tool_result user message", async () => {
    let capturedBody: Record<string, unknown> | undefined;
    const fakeFetch = async (_url: string | URL | Request, init?: RequestInit) => {
      capturedBody = JSON.parse(init?.body as string);
      return jsonResponse({ content: [{ type: "text", text: "ok" }] });
    };

    const client = createAnthropicClient(testConfig, fakeFetch as unknown as typeof fetch);
    await client.chat([
      { role: "user", content: "weather?" },
      {
        role: "assistant",
        content: null,
        tool_calls: [
          { id: "toolu_1", type: "function", function: { name: "get_weather", arguments: "{}" } },
        ],
      },
      { role: "tool", tool_call_id: "toolu_1", name: "get_weather", content: "Sunny, 72F" },
    ]);

    const messages = capturedBody?.messages as unknown[];
    expect(messages[2]).toEqual({
      role: "user",
      content: [{ type: "tool_result", tool_use_id: "toolu_1", content: "Sunny, 72F" }],
    });
  });

  test("throws AnthropicApiError with status + message on a non-2xx response", async () => {
    const fakeFetch = async () =>
      jsonResponse({ error: { message: "invalid x-api-key" } }, { status: 401 });

    const client = createAnthropicClient(testConfig, fakeFetch as unknown as typeof fetch);

    try {
      await client.chat([{ role: "user", content: "hi" }]);
      throw new Error("expected chat() to throw");
    } catch (err) {
      expect(err).toBeInstanceOf(AnthropicApiError);
      const apiErr = err as InstanceType<typeof AnthropicApiError>;
      expect(apiErr.status).toBe(401);
      expect(apiErr.message).toContain("invalid x-api-key");
    }
  });
});

describe("createAnthropicClient.listModels", () => {
  test("GETs <baseUrl>/v1/models with anthropic auth headers and returns parsed ids", async () => {
    let capturedUrl: string | undefined;
    let capturedInit: RequestInit | undefined;
    const fakeFetch = async (url: string | URL | Request, init?: RequestInit) => {
      capturedUrl = url.toString();
      capturedInit = init;
      return jsonResponse({ data: [{ id: "claude-sonnet-4-5-20250929" }] });
    };

    const client = createAnthropicClient(testConfig, fakeFetch as unknown as typeof fetch);
    const models = await client.listModels();

    expect(capturedUrl).toBe("https://api.anthropic.com/v1/models");
    const headers = new Headers(capturedInit?.headers);
    expect(headers.get("x-api-key")).toBe("sk-ant-test-key");
    expect(models).toEqual([{ id: "claude-sonnet-4-5-20250929" }]);
  });

  test("throws when the models endpoint returns a non-2xx response", async () => {
    const fakeFetch = async () => jsonResponse({ error: { message: "unauthorized" } }, { status: 401 });
    const client = createAnthropicClient(testConfig, fakeFetch as unknown as typeof fetch);

    await expect(client.listModels()).rejects.toThrow(AnthropicApiError);
  });
});

describe("createAnthropicClient.testConnection", () => {
  test("returns success:true when listing models succeeds", async () => {
    const fakeFetch = async () => jsonResponse({ data: [{ id: "claude-sonnet-4-5-20250929" }] });
    const client = createAnthropicClient(testConfig, fakeFetch as unknown as typeof fetch);

    const result = await client.testConnection();
    expect(result).toEqual({ success: true });
  });

  test("returns success:false with the real error message on failure", async () => {
    const fakeFetch = async () =>
      jsonResponse({ error: { message: "invalid x-api-key" } }, { status: 401 });
    const client = createAnthropicClient(testConfig, fakeFetch as unknown as typeof fetch);

    const result = await client.testConnection();
    expect(result.success).toBe(false);
    expect(result.error).toContain("invalid x-api-key");
  });
});
