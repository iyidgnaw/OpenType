import { DEFAULT_REQUEST_TIMEOUT_MS, requestTimeoutSignal } from "../http/requestTimeout";
import type {
  LLMProviderClient,
  LLMProviderConfig,
  ProviderChatMessage,
  ProviderChatOptions,
  ProviderChatResult,
  ProviderModel,
  ProviderTestResult,
} from "./types";

export interface ProviderClientOptions {
  /** Per-request timeout floor; defaults to {@link DEFAULT_REQUEST_TIMEOUT_MS}. */
  timeoutMs?: number;
}

/**
 * Generic OpenAI-compatible Chat Completions client (`/chat/completions`,
 * `/models`) -- the shape DeepSeek, OpenAI itself, and many self-hosted
 * servers all share. Structurally the same request/response handling as
 * `provider/deepseek.ts`'s `createDeepSeekClient`, generalized to take a
 * full `LLMProviderConfig` (base URL / API key / model, all user-supplied)
 * instead of reading fixed env vars, and extended with `testConnection`/
 * `listModels` for the new Settings "Test Connection" + model-picker flow.
 * `deepseek.ts` itself is left untouched -- it remains the zero-config env
 * fallback (see `server.ts`), this is the client used for anything
 * explicitly configured through the new provider-config system.
 */
export class OpenAICompatibleApiError extends Error {
  readonly status: number;
  readonly body?: unknown;

  constructor(message: string, status: number, body?: unknown) {
    super(message);
    this.name = "OpenAICompatibleApiError";
    this.status = status;
    this.body = body;
  }
}

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

export function createOpenAICompatibleClient(
  config: LLMProviderConfig,
  fetchImpl: typeof fetch = fetch,
  options: ProviderClientOptions = {}
): LLMProviderClient {
  const timeoutMs = options.timeoutMs ?? DEFAULT_REQUEST_TIMEOUT_MS;

  async function chat(
    messages: ProviderChatMessage[],
    options?: ProviderChatOptions
  ): Promise<ProviderChatResult> {
    const url = `${config.baseUrl}/chat/completions`;
    const requestBody: Record<string, unknown> = {
      model: config.model,
      messages,
    };
    if (options?.tools) {
      requestBody.tools = options.tools;
    }

    const response = await fetchImpl(url, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${config.apiKey}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify(requestBody),
      signal: requestTimeoutSignal(timeoutMs, options?.signal),
    });

    const parsedBody = await parseJsonBody(response);
    if (!response.ok) {
      const detail = extractErrorMessage(parsedBody);
      const message = detail
        ? `OpenAI-compatible API request failed with status ${response.status}: ${detail}`
        : `OpenAI-compatible API request failed with status ${response.status}`;
      throw new OpenAICompatibleApiError(message, response.status, parsedBody);
    }

    const body = parsedBody as { choices?: Array<{ message?: { content?: string | null; tool_calls?: unknown[] } }> } | undefined;
    const firstChoice = body?.choices?.[0];
    if (!firstChoice || !firstChoice.message) {
      throw new OpenAICompatibleApiError(
        "OpenAI-compatible API response did not contain the expected choices[0].message shape",
        response.status,
        parsedBody
      );
    }

    return {
      content: firstChoice.message.content ?? null,
      toolCalls: firstChoice.message.tool_calls,
    };
  }

  async function listModels(): Promise<ProviderModel[]> {
    const url = `${config.baseUrl}/models`;
    const response = await fetchImpl(url, {
      method: "GET",
      headers: { Authorization: `Bearer ${config.apiKey}` },
      signal: requestTimeoutSignal(timeoutMs),
    });

    const parsedBody = await parseJsonBody(response);
    if (!response.ok) {
      const detail = extractErrorMessage(parsedBody);
      const message = detail
        ? `OpenAI-compatible API request failed with status ${response.status}: ${detail}`
        : `OpenAI-compatible API request failed with status ${response.status}`;
      throw new OpenAICompatibleApiError(message, response.status, parsedBody);
    }

    const body = parsedBody as { data?: Array<{ id?: string }> } | undefined;
    if (!body?.data || !Array.isArray(body.data)) {
      throw new OpenAICompatibleApiError(
        "OpenAI-compatible API models response did not contain the expected data[] shape",
        response.status,
        parsedBody
      );
    }
    return body.data
      .filter((entry): entry is { id: string } => typeof entry.id === "string")
      .map((entry) => ({ id: entry.id }));
  }

  /**
   * Prefers `GET /models` (cheap, no generation cost) since most
   * OpenAI-compatible servers support it; if that endpoint itself is
   * missing/unsupported (some minimal self-hosted servers only implement
   * `/chat/completions`), falls back to a 1-message chat call so a
   * genuinely working but listing-less server still reports success rather
   * than a false failure.
   */
  async function testConnection(): Promise<ProviderTestResult> {
    try {
      await listModels();
      return { success: true };
    } catch (listErr) {
      if (listErr instanceof OpenAICompatibleApiError && listErr.status === 404) {
        try {
          await chat([{ role: "user", content: "ping" }]);
          return { success: true };
        } catch (chatErr) {
          return {
            success: false,
            error: chatErr instanceof Error ? chatErr.message : String(chatErr),
          };
        }
      }
      return {
        success: false,
        error: listErr instanceof Error ? listErr.message : String(listErr),
      };
    }
  }

  return { chat, testConnection, listModels };
}
