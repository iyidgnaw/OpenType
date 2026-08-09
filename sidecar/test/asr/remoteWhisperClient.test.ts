import { describe, expect, test } from "bun:test";
import {
  createRemoteWhisperClient,
  RemoteWhisperError,
} from "../../src/asr/remoteWhisperClient";

const testConfig = {
  baseUrl: "https://api.openai.com/v1",
  apiKey: "sk-test-key",
  model: "whisper-1",
};

function jsonResponse(body: unknown, init: ResponseInit = {}): Response {
  return new Response(JSON.stringify(body), {
    status: 200,
    headers: { "Content-Type": "application/json" },
    ...init,
  });
}

describe("createRemoteWhisperClient.transcribe", () => {
  test("POSTs multipart form data to <baseUrl>/audio/transcriptions with bearer auth", async () => {
    let capturedUrl: string | undefined;
    let capturedInit: RequestInit | undefined;
    const fakeFetch = async (url: string | URL | Request, init?: RequestInit) => {
      capturedUrl = url.toString();
      capturedInit = init;
      return jsonResponse({ text: "hello world" });
    };

    const client = createRemoteWhisperClient(testConfig, fakeFetch as unknown as typeof fetch);
    const text = await client.transcribe(new Uint8Array([1, 2, 3]));

    expect(text).toBe("hello world");
    expect(capturedUrl).toBe("https://api.openai.com/v1/audio/transcriptions");
    const headers = new Headers(capturedInit?.headers);
    expect(headers.get("Authorization")).toBe("Bearer sk-test-key");
    expect(capturedInit?.body).toBeInstanceOf(FormData);
    const form = capturedInit?.body as FormData;
    expect(form.get("model")).toBe("whisper-1");
    expect(form.get("file")).toBeTruthy();
  });

  test("defaults to model whisper-1 when no model is configured", async () => {
    let capturedForm: FormData | undefined;
    const fakeFetch = async (_url: string | URL | Request, init?: RequestInit) => {
      capturedForm = init?.body as FormData;
      return jsonResponse({ text: "ok" });
    };

    const client = createRemoteWhisperClient(
      { baseUrl: "https://api.openai.com/v1", apiKey: "sk-test-key" },
      fakeFetch as unknown as typeof fetch
    );
    await client.transcribe(new Uint8Array([1, 2, 3]));

    expect(capturedForm?.get("model")).toBe("whisper-1");
  });

  test("throws RemoteWhisperError with response detail on a non-2xx response", async () => {
    const fakeFetch = async () =>
      jsonResponse({ error: { message: "Invalid API key" } }, { status: 401 });

    const client = createRemoteWhisperClient(testConfig, fakeFetch as unknown as typeof fetch);

    try {
      await client.transcribe(new Uint8Array([1, 2, 3]));
      throw new Error("expected transcribe() to throw");
    } catch (err) {
      expect(err).toBeInstanceOf(RemoteWhisperError);
      expect((err as Error).message).toContain("Invalid API key");
    }
  });
});

describe("createRemoteWhisperClient.testConnection", () => {
  test("returns success:true when GET <baseUrl>/models succeeds", async () => {
    let capturedUrl: string | undefined;
    const fakeFetch = async (url: string | URL | Request) => {
      capturedUrl = url.toString();
      return jsonResponse({ data: [{ id: "whisper-1" }] });
    };

    const client = createRemoteWhisperClient(testConfig, fakeFetch as unknown as typeof fetch);
    const result = await client.testConnection();

    expect(result).toEqual({ success: true });
    expect(capturedUrl).toBe("https://api.openai.com/v1/models");
  });

  test("returns success:false with a real error message on failure", async () => {
    const fakeFetch = async () =>
      jsonResponse({ error: { message: "Invalid API key" } }, { status: 401 });
    const client = createRemoteWhisperClient(testConfig, fakeFetch as unknown as typeof fetch);

    const result = await client.testConnection();
    expect(result.success).toBe(false);
    expect(result.error).toContain("Invalid API key");
  });
});
