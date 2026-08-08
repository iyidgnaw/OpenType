import { describe, expect, test } from "bun:test";
import { createDeepSeekClient, DeepSeekApiError } from "../../src/provider/deepseek";
import type { SidecarEnv } from "../../src/env";

const testEnv: Pick<SidecarEnv, "deepSeekApiKey" | "deepSeekModel" | "deepSeekBaseUrl"> = {
  deepSeekApiKey: "sk-test-key",
  deepSeekModel: "deepseek-v4-flash",
  deepSeekBaseUrl: "https://api.deepseek.com",
};

function jsonResponse(body: unknown, init: ResponseInit = {}): Response {
  return new Response(JSON.stringify(body), {
    status: 200,
    headers: { "Content-Type": "application/json" },
    ...init,
  });
}

describe("createDeepSeekClient", () => {
  test("POSTs to the chat completions endpoint with correct headers and body", async () => {
    let capturedUrl: string | undefined;
    let capturedInit: RequestInit | undefined;

    const fakeFetch = async (url: string | URL | Request, init?: RequestInit) => {
      capturedUrl = url.toString();
      capturedInit = init;
      return jsonResponse({
        choices: [{ message: { role: "assistant", content: "hello there" } }],
      });
    };

    const client = createDeepSeekClient(testEnv, fakeFetch as unknown as typeof fetch);
    await client.chat([{ role: "user", content: "hi" }]);

    expect(capturedUrl).toBe("https://api.deepseek.com/chat/completions");
    expect(capturedInit?.method).toBe("POST");

    const headers = new Headers(capturedInit?.headers);
    expect(headers.get("Authorization")).toBe("Bearer sk-test-key");
    expect(headers.get("Content-Type")).toBe("application/json");

    const body = JSON.parse(capturedInit?.body as string);
    expect(body.model).toBe("deepseek-v4-flash");
    expect(body.messages).toEqual([{ role: "user", content: "hi" }]);
  });

  test("parses and returns the assistant's text content from a successful response", async () => {
    const fakeFetch = async () =>
      jsonResponse({
        choices: [{ message: { role: "assistant", content: "the answer is 42" } }],
      });

    const client = createDeepSeekClient(testEnv, fakeFetch as unknown as typeof fetch);
    const result = await client.chat([{ role: "user", content: "what is the answer?" }]);

    expect(result.content).toBe("the answer is 42");
    expect(result.toolCalls).toBeUndefined();
  });

  test("passes through a tools array in the request body when provided", async () => {
    let capturedInit: RequestInit | undefined;
    const fakeFetch = async (_url: string | URL | Request, init?: RequestInit) => {
      capturedInit = init;
      return jsonResponse({
        choices: [{ message: { role: "assistant", content: null } }],
      });
    };

    const tools = [
      {
        type: "function",
        function: {
          name: "get_weather",
          description: "Get the weather for a location",
          parameters: { type: "object", properties: {} },
        },
      },
    ];

    const client = createDeepSeekClient(testEnv, fakeFetch as unknown as typeof fetch);
    await client.chat([{ role: "user", content: "what's the weather?" }], { tools });

    const body = JSON.parse(capturedInit?.body as string);
    expect(body.tools).toEqual(tools);
  });

  test("returns tool_calls from the response when the model requests one", async () => {
    const toolCalls = [
      {
        id: "call_1",
        type: "function",
        function: { name: "get_weather", arguments: '{"location":"SF"}' },
      },
    ];

    const fakeFetch = async () =>
      jsonResponse({
        choices: [
          {
            message: { role: "assistant", content: null, tool_calls: toolCalls },
          },
        ],
      });

    const client = createDeepSeekClient(testEnv, fakeFetch as unknown as typeof fetch);
    const result = await client.chat([{ role: "user", content: "weather in SF?" }]);

    expect(result.content).toBeNull();
    expect(result.toolCalls).toEqual(toolCalls);
  });

  test("returns both content and tool_calls when the response includes both", async () => {
    const toolCalls = [
      { id: "call_1", type: "function", function: { name: "noop", arguments: "{}" } },
    ];

    const fakeFetch = async () =>
      jsonResponse({
        choices: [
          {
            message: {
              role: "assistant",
              content: "calling a tool now",
              tool_calls: toolCalls,
            },
          },
        ],
      });

    const client = createDeepSeekClient(testEnv, fakeFetch as unknown as typeof fetch);
    const result = await client.chat([{ role: "user", content: "go" }]);

    expect(result.content).toBe("calling a tool now");
    expect(result.toolCalls).toEqual(toolCalls);
  });

  test("throws a DeepSeekApiError with status and message on non-ok response (401)", async () => {
    const fakeFetch = async () =>
      jsonResponse(
        { error: { message: "Invalid API key", type: "authentication_error" } },
        { status: 401 }
      );

    const client = createDeepSeekClient(testEnv, fakeFetch as unknown as typeof fetch);

    await expect(client.chat([{ role: "user", content: "hi" }])).rejects.toThrow(
      DeepSeekApiError
    );

    try {
      await client.chat([{ role: "user", content: "hi" }]);
      throw new Error("expected chat() to throw");
    } catch (err) {
      expect(err).toBeInstanceOf(DeepSeekApiError);
      const apiErr = err as InstanceType<typeof DeepSeekApiError>;
      expect(apiErr.status).toBe(401);
      expect(apiErr.message).toContain("Invalid API key");
    }
  });

  test("throws a DeepSeekApiError with status and message on non-ok response (500)", async () => {
    const fakeFetch = async () =>
      new Response("Internal Server Error", {
        status: 500,
        headers: { "Content-Type": "text/plain" },
      });

    const client = createDeepSeekClient(testEnv, fakeFetch as unknown as typeof fetch);

    try {
      await client.chat([{ role: "user", content: "hi" }]);
      throw new Error("expected chat() to throw");
    } catch (err) {
      expect(err).toBeInstanceOf(DeepSeekApiError);
      const apiErr = err as InstanceType<typeof DeepSeekApiError>;
      expect(apiErr.status).toBe(500);
    }
  });

  test("throws a DeepSeekApiError when the response body doesn't parse as expected JSON shape", async () => {
    const fakeFetch = async () => jsonResponse({ unexpected: "shape" });

    const client = createDeepSeekClient(testEnv, fakeFetch as unknown as typeof fetch);

    try {
      await client.chat([{ role: "user", content: "hi" }]);
      throw new Error("expected chat() to throw");
    } catch (err) {
      expect(err).toBeInstanceOf(DeepSeekApiError);
    }
  });
});
