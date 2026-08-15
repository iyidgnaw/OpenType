/**
 * Stage-1 (TDD red) coverage for §C of
 * `docs/superpowers/specs/2026-08-15-product-batch-plan.md` — carrying the
 * user's chosen transcription language all the way to whichever backend
 * actually recognises the audio.
 *
 * Today nothing in `src/asr/` has the word `language` in it: the 27-language
 * picker in Settings only ever reached Apple's live-caption preview, so the
 * final transcript ignored it (`docs/reviews/2026-08-15-product-review.md` §2).
 *
 * The chain this file pins, end to end:
 *
 *     POST /asr/transcribe { audioBase64, language? }
 *       -> TranscribeFn(audio, { initialPrompt?, language? })
 *          -> local:  WhisperClient.transcribe(audio, { initialPrompt?, language? })
 *                       -> POST unix:/transcribe?initial_prompt=…&language=…
 *             remote: createRemoteWhisperClient().transcribe(audio, { language? })
 *                       -> multipart field `language`
 *
 * **Both backends, deliberately.** If only the local one honours it, the
 * setting becomes false again the moment a user configures remote Whisper —
 * the same bug in a new place.
 *
 * Two invariants run through every test here:
 *  - *Absent means absent.* No `language` key, no query parameter, no form
 *    field — never an empty string. `automatic` (the default) is the absence
 *    of a language, and `language=""` would reach the decoder as a language
 *    named "" rather than as "detect it yourself".
 *  - *Language composes with the dictionary bias.* `initialPrompt` and
 *    `language` are independent decode options; setting one must not drop the
 *    other, or §C silently undoes the 2026-08-14 dictionary work.
 */
import { describe, expect, test } from "bun:test";
import { buildAsrRoutes } from "../../src/asr/routes";
import { createRemoteWhisperClient } from "../../src/asr/remoteWhisperClient";
import {
  WhisperClient,
  defaultWhisperClientFactories,
  type SpawnedProcess,
  type WhisperClientFactories,
} from "../../src/asr/whisperClient";
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

/** The options bag `asr/routes.ts` hands to its injected transcribe function. */
interface TranscribeOptions {
  initialPrompt?: string;
  language?: string;
}

describe("POST /asr/transcribe language passthrough", () => {
  test("passes the requested language through to the transcribe function", async () => {
    let capturedOptions: TranscribeOptions | undefined;
    const transcribe = async (_audio: Uint8Array, options?: TranscribeOptions) => {
      capturedOptions = options;
      return "hello world";
    };
    const router = createRouter(buildAsrRoutes(transcribe));

    const response = await router(post({ audioBase64: "aGk=", language: "en" }));

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ text: "hello world" });
    expect(capturedOptions?.language).toBe("en");
  });

  test("leaves the call shape untouched when the body carries no language", async () => {
    // This is the regression guard for everything that already works: with no
    // dictionary and no language, the options bag must still be exactly `{}`.
    // `Object.keys` rather than `toEqual({})` on purpose — `toEqual` treats
    // `{ language: undefined }` as equal to `{}`, and an explicitly-undefined
    // key is how a passthrough starts leaking a `?language=undefined`.
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
    expect(optionsSeen).toBe(true);
    expect(Object.keys(capturedOptions ?? {})).toEqual([]);
  });

  test("omits the language key entirely when the body sends an empty string", async () => {
    // `automatic` must serialise as "no language", and a client that sends ""
    // instead of omitting the field must not turn that into a language.
    let capturedOptions: TranscribeOptions | undefined;
    const transcribe = async (_audio: Uint8Array, options?: TranscribeOptions) => {
      capturedOptions = options;
      return "hello world";
    };
    const router = createRouter(buildAsrRoutes(transcribe));

    const response = await router(post({ audioBase64: "aGk=", language: "" }));

    expect(response.status).toBe(200);
    expect(Object.keys(capturedOptions ?? {})).toEqual([]);
  });

  test("passes language and the dictionary initial prompt together", async () => {
    // The two decode options are independent. A language must not replace the
    // entity-dictionary bias built by `buildInitialPrompt`, nor vice versa.
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

    const response = await router(post({ audioBase64: "aGk=", language: "zh" }));

    expect(response.status).toBe(200);
    expect(capturedOptions?.language).toBe("zh");
    expect(capturedOptions?.initialPrompt).toContain("PayPal");
    expect(capturedOptions?.initialPrompt).toContain("Anthropic");
  });

  test("passes language even when the dictionary is empty", async () => {
    let capturedOptions: TranscribeOptions | undefined;
    const transcribe = async (_audio: Uint8Array, options?: TranscribeOptions) => {
      capturedOptions = options;
      return "hello world";
    };
    const router = createRouter(buildAsrRoutes(transcribe, { listTerms: () => [] }));

    await router(post({ audioBase64: "aGk=", language: "ja" }));

    // Exactly one key: no empty `initialPrompt` sneaks in alongside it.
    expect(Object.keys(capturedOptions ?? {})).toEqual(["language"]);
    expect(capturedOptions?.language).toBe("ja");
  });

  test("still applies alias corrections to a language-scoped transcription", async () => {
    // The post-hoc half of the dictionary feedback is backend-agnostic and
    // must survive the new parameter.
    const transcribe = async () => "我用呸泡付款";
    const router = createRouter(
      buildAsrRoutes(transcribe, {
        listTerms: () => [makeTerm("PayPal", ["呸泡"])],
      })
    );

    const response = await router(post({ audioBase64: "aGk=", language: "zh" }));

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ text: "我用PayPal付款" });
  });
});

function makeFactories(
  overrides: Partial<WhisperClientFactories> = {}
): WhisperClientFactories {
  const fakeProcess: SpawnedProcess = { pid: 1234, kill: () => {} };
  return {
    spawnProcess: () => fakeProcess,
    checkHealth: async () => true,
    postAudio: async () => ({ text: "" }),
    sleep: async () => {},
    ...overrides,
  };
}

describe("WhisperClient.transcribe language", () => {
  test("passes the language through to postAudio", async () => {
    let capturedLanguage: string | undefined;
    let languageArgSeen = false;
    const factories = makeFactories({
      postAudio: async (_socketPath, _audio, _initialPrompt, language) => {
        capturedLanguage = language;
        languageArgSeen = true;
        return { text: "hello world" };
      },
    });
    const client = new WhisperClient({ socketPath: "/tmp/whisper-test.sock" }, factories);

    const text = await client.transcribe(new Uint8Array([1, 2, 3]), { language: "en" });

    expect(text).toBe("hello world");
    expect(languageArgSeen).toBe(true);
    expect(capturedLanguage).toBe("en");
  });

  test("passes the initial prompt and the language together", async () => {
    let capturedPrompt: string | undefined;
    let capturedLanguage: string | undefined;
    const factories = makeFactories({
      postAudio: async (_socketPath, _audio, initialPrompt, language) => {
        capturedPrompt = initialPrompt;
        capturedLanguage = language;
        return { text: "hello world" };
      },
    });
    const client = new WhisperClient({ socketPath: "/tmp/whisper-test.sock" }, factories);

    await client.transcribe(new Uint8Array([1, 2, 3]), {
      initialPrompt: "可能出现的专有名词：PayPal。",
      language: "zh",
    });

    expect(capturedPrompt).toBe("可能出现的专有名词：PayPal。");
    expect(capturedLanguage).toBe("zh");
  });

  test("passes no language when called without options", async () => {
    let capturedLanguage: string | undefined = "sentinel";
    const factories = makeFactories({
      postAudio: async (_socketPath, _audio, _initialPrompt, language) => {
        capturedLanguage = language;
        return { text: "hello world" };
      },
    });
    const client = new WhisperClient({ socketPath: "/tmp/whisper-test.sock" }, factories);

    await client.transcribe(new Uint8Array([1, 2, 3]));

    expect(capturedLanguage).toBeUndefined();
  });

  test("passes no language when the options bag carries only a prompt", async () => {
    let capturedLanguage: string | undefined = "sentinel";
    const factories = makeFactories({
      postAudio: async (_socketPath, _audio, _initialPrompt, language) => {
        capturedLanguage = language;
        return { text: "hello world" };
      },
    });
    const client = new WhisperClient({ socketPath: "/tmp/whisper-test.sock" }, factories);

    await client.transcribe(new Uint8Array([1, 2, 3]), { initialPrompt: "PayPal" });

    expect(capturedLanguage).toBeUndefined();
  });
});

/**
 * `sidecar/whisper/serve.py` parses `language` off the query string the same
 * way it already parses `initial_prompt` (headers must be latin-1 safe, which
 * the dictionary is not), and feeds it to `mlx_whisper.transcribe` through
 * `**decode_options` — measured 2026-08-14 and recorded in
 * `docs/superpowers/specs/2026-08-14-product-batch-plan.md`: `language` is
 * **not** a top-level named parameter of that function.
 *
 * There is no python test harness in this repo (`scripts/tests/` holds shell
 * scripts only), so — following the precedent set by the `initial_prompt` URL
 * tests in `whisperClient.test.ts` — the contract is pinned from this side:
 * these tests fix the exact URL the real factory builds, and serve.py's own
 * parsing is covered by review plus the packaged-app verification step.
 */
describe("defaultWhisperClientFactories().postAudio language query parameter", () => {
  async function captureRequestUrl(
    initialPrompt?: string,
    language?: string
  ): Promise<string> {
    const originalFetch = globalThis.fetch;
    let capturedUrl = "";
    globalThis.fetch = (async (input: unknown) => {
      capturedUrl =
        typeof input === "string"
          ? input
          : input instanceof URL
            ? input.toString()
            : (input as Request).url;
      return Response.json({ text: "ok" });
    }) as unknown as typeof fetch;
    try {
      const { postAudio } = defaultWhisperClientFactories();
      await postAudio(
        "/tmp/whisper-test.sock",
        new Uint8Array([1, 2, 3]),
        initialPrompt,
        language
      );
    } finally {
      globalThis.fetch = originalFetch;
    }
    return capturedUrl;
  }

  test("sends language as its own query parameter", async () => {
    const url = new URL(await captureRequestUrl(undefined, "en"));

    expect(url.pathname).toBe("/transcribe");
    expect([...url.searchParams.keys()]).toEqual(["language"]);
    expect(url.searchParams.get("language")).toBe("en");
  });

  test("sends both parameters when there is a prompt and a language", async () => {
    const prompt = "可能出现的专有名词：PayPal、呸泡。";

    const rawUrl = await captureRequestUrl(prompt, "zh");

    // Raw non-ASCII bytes in a request target are not valid HTTP; python's
    // parse_qs would not recover the term list from them.
    expect(rawUrl).not.toMatch(/[^\x00-\x7F]/);
    const url = new URL(rawUrl);
    expect(url.pathname).toBe("/transcribe");
    expect([...url.searchParams.keys()].sort()).toEqual(["initial_prompt", "language"]);
    expect(url.searchParams.get("initial_prompt")).toBe(prompt);
    expect(url.searchParams.get("language")).toBe("zh");
  });

  test("sends no language parameter when no language is given", async () => {
    // Not `?language=`: an absent language must reach mlx_whisper as the
    // default (None) so it detects the language itself.
    const url = new URL(await captureRequestUrl("PayPal"));

    expect([...url.searchParams.keys()]).toEqual(["initial_prompt"]);
    expect(url.searchParams.has("language")).toBe(false);
  });

  test("sends no query string at all when neither is given", async () => {
    const url = new URL(await captureRequestUrl());

    expect(url.pathname).toBe("/transcribe");
    expect(url.search).toBe("");
  });

  test("treats an empty language as no language", async () => {
    const url = new URL(await captureRequestUrl(undefined, ""));

    expect(url.search).toBe("");
  });
});

const remoteConfig = {
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

/**
 * The remote half. OpenAI's `POST /audio/transcriptions` takes `language` as a
 * multipart field (ISO-639-1), which is the same vocabulary `whisperCode`
 * produces on the Swift side — so the setting means the same thing on both
 * backends and there is nothing to translate between them.
 */
describe("createRemoteWhisperClient.transcribe language", () => {
  test("includes language in the multipart form when one is given", async () => {
    let capturedForm: FormData | undefined;
    const fakeFetch = async (_url: string | URL | Request, init?: RequestInit) => {
      capturedForm = init?.body as FormData;
      return jsonResponse({ text: "hello world" });
    };

    const client = createRemoteWhisperClient(
      remoteConfig,
      fakeFetch as unknown as typeof fetch
    );
    const text = await client.transcribe(new Uint8Array([1, 2, 3]), { language: "en" });

    expect(text).toBe("hello world");
    expect(capturedForm?.get("language")).toBe("en");
    // The rest of the form is unchanged.
    expect(capturedForm?.get("model")).toBe("whisper-1");
    expect(capturedForm?.get("file")).toBeTruthy();
  });

  test("omits the language field entirely when no language is given", async () => {
    // `has`, not `get`: the API treats a present-but-empty `language` as a
    // language, so the field must not exist at all rather than be "".
    let capturedForm: FormData | undefined;
    const fakeFetch = async (_url: string | URL | Request, init?: RequestInit) => {
      capturedForm = init?.body as FormData;
      return jsonResponse({ text: "hello world" });
    };

    const client = createRemoteWhisperClient(
      remoteConfig,
      fakeFetch as unknown as typeof fetch
    );
    await client.transcribe(new Uint8Array([1, 2, 3]));

    expect(capturedForm?.has("language")).toBe(false);
  });

  test("omits the language field when it is given as an empty string", async () => {
    let capturedForm: FormData | undefined;
    const fakeFetch = async (_url: string | URL | Request, init?: RequestInit) => {
      capturedForm = init?.body as FormData;
      return jsonResponse({ text: "hello world" });
    };

    const client = createRemoteWhisperClient(
      remoteConfig,
      fakeFetch as unknown as typeof fetch
    );
    await client.transcribe(new Uint8Array([1, 2, 3]), { language: "" });

    expect(capturedForm?.has("language")).toBe(false);
  });
});
