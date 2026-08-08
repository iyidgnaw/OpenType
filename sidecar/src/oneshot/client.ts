/**
 * Injectable chat-client shape shared by the four one-shot endpoints — same
 * dependency-injection spirit as `createDeepSeekClient` and the
 * consolidator's `CallLLM`, so route handlers and their tests never import
 * the DeepSeek client directly. Structurally compatible with the object
 * `createDeepSeekClient(env).chat` returns.
 */
export interface OneShotChatMessage {
  role: string;
  content: string;
}

export interface OneShotChatResult {
  content: string | null;
  toolCalls?: unknown[];
}

export type OneShotChatFn = (
  messages: OneShotChatMessage[],
  options?: { tools?: unknown[] }
) => Promise<OneShotChatResult>;
