import type { SidecarEnv } from "../env";
import { DEFAULT_REQUEST_TIMEOUT_MS, requestTimeoutSignal } from "../http/requestTimeout";

/**
 * `tool_calls`/`tool_call_id`/`name` support the agent loop's OpenAI-style
 * tool-calling messages (an assistant message requesting tool calls has
 * `content: null` and a `tool_calls` array; a `role: "tool"` message reports
 * one tool's result back via `tool_call_id`) -- an extension of the existing
 * shape, not a redesign; every field beyond role/content stays optional so
 * existing plain chat messages are unaffected.
 */
export interface DeepSeekMessage {
  role: string;
  content: string | null;
  tool_calls?: unknown[];
  tool_call_id?: string;
  name?: string;
}

export interface DeepSeekChatOptions {
  tools?: unknown[];
}

export interface DeepSeekChatResult {
  content: string | null;
  toolCalls?: unknown[];
}

interface DeepSeekChoice {
  message?: {
    role?: string;
    content?: string | null;
    tool_calls?: unknown[];
  };
}

interface DeepSeekChatResponseBody {
  choices?: DeepSeekChoice[];
}

/**
 * Typed error thrown by the DeepSeek client for any failure talking to the
 * API: non-2xx HTTP responses and responses whose body doesn't match the
 * expected chat-completions shape. Always carries the HTTP status (0 when
 * the failure isn't tied to a real HTTP response, e.g. an unexpected body
 * shape on an otherwise-ok response) plus whatever error detail the API
 * body offered.
 */
export class DeepSeekApiError extends Error {
  readonly status: number;
  readonly body?: unknown;

  constructor(message: string, status: number, body?: unknown) {
    super(message);
    this.name = "DeepSeekApiError";
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

export function createDeepSeekClient(
  env: Pick<SidecarEnv, "deepSeekApiKey" | "deepSeekModel" | "deepSeekBaseUrl">,
  fetchImpl: typeof fetch = fetch,
  options: { timeoutMs?: number } = {}
) {
  const timeoutMs = options.timeoutMs ?? DEFAULT_REQUEST_TIMEOUT_MS;

  async function chat(
    messages: DeepSeekMessage[],
    options?: DeepSeekChatOptions
  ): Promise<DeepSeekChatResult> {
    const url = `${env.deepSeekBaseUrl}/chat/completions`;
    const requestBody: Record<string, unknown> = {
      model: env.deepSeekModel,
      messages,
    };
    if (options?.tools) {
      requestBody.tools = options.tools;
    }

    const response = await fetchImpl(url, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${env.deepSeekApiKey}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify(requestBody),
      signal: requestTimeoutSignal(timeoutMs),
    });

    const rawText = await response.text();
    let parsedBody: unknown;
    try {
      parsedBody = rawText.length > 0 ? JSON.parse(rawText) : undefined;
    } catch {
      parsedBody = undefined;
    }

    if (!response.ok) {
      const detail = extractErrorMessage(parsedBody);
      const message = detail
        ? `DeepSeek API request failed with status ${response.status}: ${detail}`
        : `DeepSeek API request failed with status ${response.status}: ${rawText || response.statusText}`;
      throw new DeepSeekApiError(message, response.status, parsedBody);
    }

    const body = parsedBody as DeepSeekChatResponseBody | undefined;
    const firstChoice = body?.choices?.[0];
    if (!firstChoice || !firstChoice.message) {
      throw new DeepSeekApiError(
        "DeepSeek API response did not contain the expected choices[0].message shape",
        response.status,
        parsedBody
      );
    }

    const message = firstChoice.message;
    return {
      content: message.content ?? null,
      toolCalls: message.tool_calls,
    };
  }

  return { chat };
}
