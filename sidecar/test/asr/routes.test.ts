import { describe, expect, test } from "bun:test";
import { buildAsrRoutes } from "../../src/asr/routes";
import { createRouter } from "../../src/router";

function post(body: unknown): Request {
  return new Request("http://sidecar/asr/transcribe", {
    method: "POST",
    body: JSON.stringify(body),
  });
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
