/**
 * Remote ASR backend for the new Whisper local/remote setting: implements
 * OpenAI's audio transcription endpoint shape (`POST
 * /audio/transcriptions`, `whisper-1`/`gpt-4o-transcribe`-family models) --
 * the most standard "remote Whisper" surface. `baseUrl` is user-supplied
 * (not hardcoded to `api.openai.com`) so a self-hosted OpenAI-API-compatible
 * transcription server also works, not just OpenAI itself. Mirrors
 * `provider/openaiCompatible.ts`'s error-handling shape (typed error with
 * HTTP status + extracted API error message) for consistency, and exposes
 * the same `transcribe`/`testConnection` split `asr/routes.ts` and
 * `provider/routes.ts` expect from the local `WhisperClient` and the LLM
 * provider clients respectively.
 */
import { DEFAULT_REQUEST_TIMEOUT_MS, requestTimeoutSignal } from "../http/requestTimeout";

export interface RemoteWhisperConfig {
  baseUrl: string;
  apiKey: string;
  model?: string;
}

export interface RemoteWhisperClientOptions {
  /** Per-request timeout floor; defaults to {@link DEFAULT_REQUEST_TIMEOUT_MS}. */
  timeoutMs?: number;
}

export interface RemoteWhisperTestResult {
  success: boolean;
  error?: string;
}

/**
 * Per-request decode options. Deliberately narrower than the local backend's:
 * OpenAI's transcription endpoint has no `initial_prompt` equivalent, so the
 * dictionary bias cannot cross this seam (a remote user still gets the
 * deterministic alias rewrite `asr/routes.ts` applies afterwards). `language`
 * it does take, and honouring it here is what keeps the setting from becoming
 * a false promise again the moment someone configures remote Whisper.
 */
export interface RemoteWhisperTranscribeOptions {
  /** ISO-639-1 code — the same vocabulary the local backend uses. */
  language?: string;
}

export class RemoteWhisperError extends Error {
  readonly status: number;

  constructor(message: string, status: number) {
    super(message);
    this.name = "RemoteWhisperError";
    this.status = status;
  }
}

const DEFAULT_MODEL = "whisper-1";

function extractErrorMessage(body: unknown): string | undefined {
  if (body && typeof body === "object") {
    const maybeError = (body as { error?: unknown }).error;
    if (maybeError && typeof maybeError === "object") {
      const message = (maybeError as { message?: unknown }).message;
      if (typeof message === "string") {
        return message;
      }
    }
    if (typeof (body as { message?: unknown }).message === "string") {
      return (body as { message: string }).message;
    }
  }
  return undefined;
}

async function parseJsonBody(response: Response): Promise<unknown> {
  const rawText = await response.text();
  try {
    return rawText.length > 0 ? JSON.parse(rawText) : undefined;
  } catch {
    return undefined;
  }
}

export function createRemoteWhisperClient(
  config: RemoteWhisperConfig,
  fetchImpl: typeof fetch = fetch,
  // Named for the client rather than `options` so `transcribe`'s own
  // per-request bag below doesn't shadow it -- the two are unrelated, and a
  // reader of `options.language` should not have to check which one is in
  // scope.
  clientOptions: RemoteWhisperClientOptions = {}
) {
  const timeoutMs = clientOptions.timeoutMs ?? DEFAULT_REQUEST_TIMEOUT_MS;

  async function transcribe(
    audio: Uint8Array,
    options: RemoteWhisperTranscribeOptions = {}
  ): Promise<string> {
    const form = new FormData();
    form.set("model", config.model ?? DEFAULT_MODEL);
    form.set("file", new Blob([audio], { type: "audio/wav" }), "audio.wav");
    // The field is left out of the form entirely rather than sent empty: the
    // API reads a present-but-empty `language` as a language, which would
    // suppress its own detection instead of requesting it.
    if (options.language) {
      form.set("language", options.language);
    }

    const response = await fetchImpl(`${config.baseUrl}/audio/transcriptions`, {
      method: "POST",
      headers: { Authorization: `Bearer ${config.apiKey}` },
      body: form,
      signal: requestTimeoutSignal(timeoutMs),
    });

    const parsedBody = await parseJsonBody(response);
    if (!response.ok) {
      const detail = extractErrorMessage(parsedBody);
      const message = detail
        ? `Remote Whisper API request failed with status ${response.status}: ${detail}`
        : `Remote Whisper API request failed with status ${response.status}`;
      throw new RemoteWhisperError(message, response.status);
    }

    const body = parsedBody as { text?: string } | undefined;
    return body?.text ?? "";
  }

  /** Cheap connectivity check: lists models rather than sending real audio. */
  async function testConnection(): Promise<RemoteWhisperTestResult> {
    try {
      const response = await fetchImpl(`${config.baseUrl}/models`, {
        method: "GET",
        headers: { Authorization: `Bearer ${config.apiKey}` },
        signal: requestTimeoutSignal(timeoutMs),
      });
      const parsedBody = await parseJsonBody(response);
      if (!response.ok) {
        const detail = extractErrorMessage(parsedBody);
        return {
          success: false,
          error: detail
            ? `Remote Whisper API request failed with status ${response.status}: ${detail}`
            : `Remote Whisper API request failed with status ${response.status}`,
        };
      }
      return { success: true };
    } catch (err) {
      return { success: false, error: err instanceof Error ? err.message : String(err) };
    }
  }

  return { transcribe, testConnection };
}
