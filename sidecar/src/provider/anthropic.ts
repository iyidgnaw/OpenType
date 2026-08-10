import { DEFAULT_REQUEST_TIMEOUT_MS, requestTimeoutSignal } from "../http/requestTimeout";
import type { ProviderClientOptions } from "./openaiCompatible";
import type {
  LLMProviderClient,
  LLMProviderConfig,
  ProviderChatMessage,
  ProviderChatOptions,
  ProviderChatResult,
  ProviderModel,
  ProviderTestResult,
} from "./types";

/**
 * Anthropic Messages API client (`/v1/messages`, `/v1/models`) -- the other
 * of the two provider shapes the new Settings provider picker supports
 * (`openaiCompatible.ts` is the other). Anthropic's request/response shape
 * differs enough from OpenAI-style Chat Completions that this module's real
 * job is translation, both directions:
 *
 *  - request: a leading `role:"system"` message is pulled out into a
 *    top-level `system` string (Anthropic has no `system` role in
 *    `messages`); a `role:"tool"` message (this loop's tool-result report,
 *    see `agent/loop.ts`) becomes a `role:"user"` message whose content is a
 *    `tool_result` block referencing `tool_use_id`; an assistant message
 *    carrying OpenAI-style `tool_calls` becomes a `tool_use` content block
 *    per call. OpenAI-shaped tool *definitions* (`{type:"function",
 *    function:{name,description,parameters}}`) become Anthropic's flatter
 *    `{name,description,input_schema}`.
 *  - response: Anthropic returns a `content` array of blocks (`text` and/or
 *    `tool_use`); this concatenates `text` blocks into `ProviderChatResult
 *    .content` and maps `tool_use` blocks back into the OpenAI-shaped
 *    `toolCalls` array (`{id,type:"function",function:{name,arguments}}`)
 *    that `agent/loop.ts` already knows how to execute, so the loop itself
 *    doesn't need to know which provider is active.
 */
export class AnthropicApiError extends Error {
  readonly status: number;
  readonly body?: unknown;

  constructor(message: string, status: number, body?: unknown) {
    super(message);
    this.name = "AnthropicApiError";
    this.status = status;
    this.body = body;
  }
}

interface AnthropicRequestContentBlock {
  type: string;
  text?: string;
  id?: string;
  name?: string;
  input?: unknown;
  tool_use_id?: string;
  content?: string;
}

interface AnthropicRequestMessage {
  role: "user" | "assistant";
  content: string | AnthropicRequestContentBlock[];
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

function isOpenAiToolCall(
  value: unknown
): value is { id: string; function: { name: string; arguments: string } } {
  if (!value || typeof value !== "object") return false;
  const candidate = value as { id?: unknown; function?: { name?: unknown } };
  return typeof candidate.id === "string" && typeof candidate.function?.name === "string";
}

function translateRequestMessages(
  messages: ProviderChatMessage[]
): { system?: string; messages: AnthropicRequestMessage[] } {
  let system: string | undefined;
  const translated: AnthropicRequestMessage[] = [];

  for (const message of messages) {
    if (message.role === "system") {
      const text = message.content ?? "";
      system = system ? `${system}\n${text}` : text;
      continue;
    }

    if (message.role === "tool") {
      translated.push({
        role: "user",
        content: [
          {
            type: "tool_result",
            tool_use_id: message.tool_call_id ?? "",
            content: message.content ?? "",
          },
        ],
      });
      continue;
    }

    if (message.role === "assistant" && message.tool_calls && message.tool_calls.length > 0) {
      const blocks: AnthropicRequestContentBlock[] = [];
      if (message.content) {
        blocks.push({ type: "text", text: message.content });
      }
      for (const rawToolCall of message.tool_calls) {
        if (!isOpenAiToolCall(rawToolCall)) continue;
        let input: unknown = {};
        try {
          input = rawToolCall.function.arguments ? JSON.parse(rawToolCall.function.arguments) : {};
        } catch {
          input = {};
        }
        blocks.push({
          type: "tool_use",
          id: rawToolCall.id,
          name: rawToolCall.function.name,
          input,
        });
      }
      translated.push({ role: "assistant", content: blocks });
      continue;
    }

    translated.push({
      role: message.role === "assistant" ? "assistant" : "user",
      content: message.content ?? "",
    });
  }

  return { system, messages: translated };
}

function translateTools(tools: unknown[] | undefined): unknown[] | undefined {
  if (!tools) return undefined;
  return tools.map((rawTool) => {
    const tool = rawTool as {
      function: { name: string; description?: string; parameters?: unknown };
    };
    return {
      name: tool.function.name,
      description: tool.function.description,
      input_schema: tool.function.parameters,
    };
  });
}

interface AnthropicResponseContentBlock {
  type: string;
  text?: string;
  id?: string;
  name?: string;
  input?: unknown;
}

export function createAnthropicClient(
  config: LLMProviderConfig,
  fetchImpl: typeof fetch = fetch,
  options: ProviderClientOptions = {}
): LLMProviderClient {
  const timeoutMs = options.timeoutMs ?? DEFAULT_REQUEST_TIMEOUT_MS;
  const authHeaders = {
    "x-api-key": config.apiKey,
    "anthropic-version": "2023-06-01",
  };

  async function chat(
    messages: ProviderChatMessage[],
    options?: ProviderChatOptions
  ): Promise<ProviderChatResult> {
    const { system, messages: translatedMessages } = translateRequestMessages(messages);
    const requestBody: Record<string, unknown> = {
      model: config.model,
      max_tokens: 4096,
      messages: translatedMessages,
    };
    if (system) {
      requestBody.system = system;
    }
    const tools = translateTools(options?.tools);
    if (tools) {
      requestBody.tools = tools;
    }

    const response = await fetchImpl(`${config.baseUrl}/v1/messages`, {
      method: "POST",
      headers: {
        ...authHeaders,
        "Content-Type": "application/json",
      },
      body: JSON.stringify(requestBody),
      signal: requestTimeoutSignal(timeoutMs),
    });

    const parsedBody = await parseJsonBody(response);
    if (!response.ok) {
      const detail = extractErrorMessage(parsedBody);
      const message = detail
        ? `Anthropic API request failed with status ${response.status}: ${detail}`
        : `Anthropic API request failed with status ${response.status}`;
      throw new AnthropicApiError(message, response.status, parsedBody);
    }

    const body = parsedBody as { content?: AnthropicResponseContentBlock[] } | undefined;
    const blocks = body?.content ?? [];
    const textParts = blocks.filter((b) => b.type === "text").map((b) => b.text ?? "");
    const toolUseBlocks = blocks.filter((b) => b.type === "tool_use");

    const content = textParts.length > 0 ? textParts.join("") : null;
    const toolCalls =
      toolUseBlocks.length > 0
        ? toolUseBlocks.map((block) => ({
            id: block.id ?? "",
            type: "function",
            function: {
              name: block.name ?? "",
              arguments: JSON.stringify(block.input ?? {}),
            },
          }))
        : undefined;

    return { content, toolCalls };
  }

  async function listModels(): Promise<ProviderModel[]> {
    const response = await fetchImpl(`${config.baseUrl}/v1/models`, {
      method: "GET",
      headers: authHeaders,
      signal: requestTimeoutSignal(timeoutMs),
    });

    const parsedBody = await parseJsonBody(response);
    if (!response.ok) {
      const detail = extractErrorMessage(parsedBody);
      const message = detail
        ? `Anthropic API request failed with status ${response.status}: ${detail}`
        : `Anthropic API request failed with status ${response.status}`;
      throw new AnthropicApiError(message, response.status, parsedBody);
    }

    const body = parsedBody as { data?: Array<{ id?: string }> } | undefined;
    if (!body?.data || !Array.isArray(body.data)) {
      throw new AnthropicApiError(
        "Anthropic API models response did not contain the expected data[] shape",
        response.status,
        parsedBody
      );
    }
    return body.data
      .filter((entry): entry is { id: string } => typeof entry.id === "string")
      .map((entry) => ({ id: entry.id }));
  }

  async function testConnection(): Promise<ProviderTestResult> {
    try {
      await listModels();
      return { success: true };
    } catch (err) {
      return {
        success: false,
        error: err instanceof Error ? err.message : String(err),
      };
    }
  }

  return { chat, testConnection, listModels };
}
