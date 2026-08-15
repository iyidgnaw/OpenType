import { describe, expect, test } from "bun:test";
import { buildAsrRoutes } from "../../src/asr/routes";
import type { EntityTerm } from "../../src/memory/MemoryStore";
import { createRouter } from "../../src/router";

function post(body: unknown): Request {
  return new Request("http://sidecar/asr/transcribe", {
    method: "POST",
    body: JSON.stringify(body),
  });
}

let nextTermId = 1;

function makeTerm(canonicalTerm: string, aliases: string[] = []): EntityTerm {
  return {
    id: nextTermId++,
    canonicalTerm,
    aliases,
    category: "term",
    confidence: 0.9,
    origin: "owner",
    sourceEventIds: [],
    createdAt: 0,
    updatedAt: 0,
    supersedes: null,
  };
}

interface TranscribeOptions {
  initialPrompt?: string;
}

describe("POST /asr/transcribe", () => {
  test("decodes the base64 audio and returns the transcribed text", async () => {
    let capturedAudio: Uint8Array | undefined;
    const transcribe = async (audio: Uint8Array) => {
      capturedAudio = audio;
      return "hello world";
    };
    const router = createRouter(buildAsrRoutes(transcribe));

    // "hi" base64-encoded, standing in for WAV bytes.
    const response = await router(post({ audioBase64: "aGk=" }));

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ text: "hello world" });
    expect(capturedAudio).toEqual(new Uint8Array([104, 105]));
  });

  test("400s when audioBase64 is missing", async () => {
    const router = createRouter(buildAsrRoutes(async () => "unused"));

    const response = await router(post({}));

    expect(response.status).toBe(400);
  });

  test("400s when audioBase64 is not valid base64", async () => {
    const router = createRouter(buildAsrRoutes(async () => "unused"));

    const response = await router(post({ audioBase64: "not valid base64!!" }));

    expect(response.status).toBe(400);
  });

  test("502s and surfaces the error message when transcription fails", async () => {
    const transcribe = async () => {
      throw new Error("whisper server unavailable");
    };
    const router = createRouter(buildAsrRoutes(transcribe));

    const response = await router(post({ audioBase64: "aGk=" }));

    expect(response.status).toBe(502);
    const body = (await response.json()) as { error: string };
    expect(body.error).toContain("whisper server unavailable");
  });
});

describe("POST /asr/transcribe dictionary bias", () => {
  test("passes no initialPrompt when the route is built without deps", async () => {
    let capturedOptions: TranscribeOptions | undefined;
    let optionsSeen = false;
    const transcribe = async (_audio: Uint8Array, options?: TranscribeOptions) => {
      capturedOptions = options;
      optionsSeen = true;
      return "hello world";
    };
    const router = createRouter(buildAsrRoutes(transcribe));

    const response = await router(post({ audioBase64: "aGk=" }));

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ text: "hello world" });
    expect(optionsSeen).toBe(true);
    expect(capturedOptions?.initialPrompt).toBeUndefined();
  });

  test("passes the built initial prompt to transcribe when the dictionary has terms", async () => {
    let capturedOptions: TranscribeOptions | undefined;
    const transcribe = async (_audio: Uint8Array, options?: TranscribeOptions) => {
      capturedOptions = options;
      return "hello world";
    };
    const router = createRouter(
      buildAsrRoutes(transcribe, {
        listTerms: () => [makeTerm("PayPal"), makeTerm("Anthropic")],
      })
    );

    const response = await router(post({ audioBase64: "aGk=" }));

    expect(response.status).toBe(200);
    expect(capturedOptions?.initialPrompt).toBeDefined();
    expect(capturedOptions?.initialPrompt).toContain("PayPal");
    expect(capturedOptions?.initialPrompt).toContain("Anthropic");
  });

  test("applies alias corrections to the transcribed text", async () => {
    const transcribe = async () => "我用呸泡付款";
    const router = createRouter(
      buildAsrRoutes(transcribe, {
        listTerms: () => [makeTerm("PayPal", ["呸泡"])],
      })
    );

    const response = await router(post({ audioBase64: "aGk=" }));

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ text: "我用PayPal付款" });
  });

  test("omits initialPrompt entirely when the dictionary is empty", async () => {
    let capturedOptions: TranscribeOptions | undefined;
    const transcribe = async (_audio: Uint8Array, options?: TranscribeOptions) => {
      capturedOptions = options;
      return "hello world";
    };
    const router = createRouter(buildAsrRoutes(transcribe, { listTerms: () => [] }));

    const response = await router(post({ audioBase64: "aGk=" }));

    expect(response.status).toBe(200);
    // An empty string is not the same as "no prompt": it would still be
    // handed to whisperClient and encoded into the request URL.
    expect(capturedOptions?.initialPrompt).toBeUndefined();
  });

  test("still transcribes, uncorrected, when listTerms throws", async () => {
    // A broken or locked memory DB must never take dictation down -- losing
    // term biasing is a degradation, losing transcription is an outage.
    const transcribe = async () => "我用呸泡付款";
    const router = createRouter(
      buildAsrRoutes(transcribe, {
        listTerms: () => {
          throw new Error("database is locked");
        },
      })
    );

    const response = await router(post({ audioBase64: "aGk=" }));

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ text: "我用呸泡付款" });
  });
});
