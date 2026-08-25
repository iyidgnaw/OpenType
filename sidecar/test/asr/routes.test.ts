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
    // `rawText` is now part of the pinned shape everywhere `text` is (Task 4):
    // it's the pre-dictionary-rewrite transcript, which `buildConsolidationPrompt`
    // needs to mine ASR mishearings. With no dictionary in play the two are
    // identical, but the key must still be present -- see the dedicated
    // "rawText" describe block below for the case where they diverge.
    expect(await response.json()).toEqual({ text: "hello world", rawText: "hello world" });
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
    const body = (await response.json()) as Record<string, unknown>;
    expect(body.error).toContain("whisper server unavailable");
    // The catch block never had a `text` to read rawText from -- transcribe
    // threw before either variable existed -- so rawText must not appear here,
    // the one other place the handler returns a response.
    expect("rawText" in body).toBe(false);
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
    // See Task 4 note above: rawText is now part of this shape too.
    expect(await response.json()).toEqual({ text: "hello world", rawText: "hello world" });
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
    const term = makeTerm("PayPal", ["呸泡"]);
    const router = createRouter(
      buildAsrRoutes(transcribe, {
        listTerms: () => [term],
      })
    );

    const response = await router(post({ audioBase64: "aGk=" }));

    expect(response.status).toBe(200);
    // A rewrite is now reported alongside the text it changed (D-1) — the
    // silent version of this response is what
    // `test/asr/replacements.test.ts` exists to end. The no-rewrite shape is
    // unchanged and still pinned strictly by the tests above and below.
    // rawText (Task 4) carries what Whisper actually produced, before the
    // dictionary rewrote 呸泡 -> PayPal -- see the "rawText" describe block
    // below for the dedicated coverage of that divergence.
    expect(await response.json()).toEqual({
      text: "我用PayPal付款",
      rawText: "我用呸泡付款",
      replacements: [{ from: "呸泡", to: "PayPal", termId: term.id }],
    });
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
    // rawText must survive the degrade-to-uncorrected path too: it's just
    // whatever `transcribe` returned, independent of whether the dictionary
    // read succeeded.
    expect(await response.json()).toEqual({
      text: "我用呸泡付款",
      rawText: "我用呸泡付款",
    });
  });
});

describe("POST /asr/transcribe rawText", () => {
  // Task 4: `/asr/transcribe` today returns only the dictionary-rewritten
  // `text`, discarding the raw Whisper output inside the handler.
  // `buildConsolidationPrompt` mines the raw-vs-corrected pair to discover ASR
  // mishearings (docs/superpowers/specs/2026-08-25-unified-memory-and-recent-context-design.md
  // §3.2) -- without a `rawText` field on the wire, Swift has only the
  // corrected half to send and that signal is gone for good.

  test("carries both text (rewritten) and rawText (what Whisper actually produced), and they differ", async () => {
    const transcribe = async () => "我用呸泡付款";
    const term = makeTerm("PayPal", ["呸泡"]);
    const router = createRouter(
      buildAsrRoutes(transcribe, {
        listTerms: () => [term],
      })
    );

    const response = await router(post({ audioBase64: "aGk=" }));
    const body = (await response.json()) as { text: string; rawText: string };

    expect(response.status).toBe(200);
    // Each field must be the *right* one -- an implementation that returned
    // the corrected text twice would pass a looser "both keys present"
    // assertion while silently discarding the exact signal this field exists
    // to keep.
    expect(body.text).toBe("我用PayPal付款");
    expect(body.rawText).toBe("我用呸泡付款");
    expect(body.rawText).not.toBe(body.text);
  });

  test("rawText equals text when the dictionary has terms but none match", async () => {
    const transcribe = async () => "今天天气不错";
    const router = createRouter(
      buildAsrRoutes(transcribe, {
        listTerms: () => [makeTerm("PayPal", ["呸泡"])],
      })
    );

    const response = await router(post({ audioBase64: "aGk=" }));
    const body = (await response.json()) as { text: string; rawText: string };

    expect(response.status).toBe(200);
    expect(body.rawText).toBe(body.text);
    expect(body.text).toBe("今天天气不错");
    expect("replacements" in body).toBe(false);
  });

  test("rawText equals text when the dictionary is empty", async () => {
    const transcribe = async () => "今天天气不错";
    const router = createRouter(buildAsrRoutes(transcribe, { listTerms: () => [] }));

    const response = await router(post({ audioBase64: "aGk=" }));
    const body = (await response.json()) as { text: string; rawText: string };

    expect(response.status).toBe(200);
    expect(body.rawText).toBe(body.text);
    expect(body.text).toBe("今天天气不错");
  });

  test("rawText is present on both return paths -- with replacements and without", async () => {
    const withReplacements = createRouter(
      buildAsrRoutes(async () => "我用呸泡付款", {
        listTerms: () => [makeTerm("PayPal", ["呸泡"])],
      })
    );
    const withoutReplacements = createRouter(
      buildAsrRoutes(async () => "今天天气不错", { listTerms: () => [] })
    );

    const withRes = await withReplacements(post({ audioBase64: "aGk=" }));
    const withoutRes = await withoutReplacements(post({ audioBase64: "aGk=" }));
    const withBody = (await withRes.json()) as Record<string, unknown>;
    const withoutBody = (await withoutRes.json()) as Record<string, unknown>;

    // The handler has two `Response.json(...)` return statements (with and
    // without `replacements`); rawText must be added to both, not just the
    // more commonly-tested one.
    expect("replacements" in withBody).toBe(true);
    expect("rawText" in withBody).toBe(true);
    expect("replacements" in withoutBody).toBe(false);
    expect("rawText" in withoutBody).toBe(true);
  });
});
