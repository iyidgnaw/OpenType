/**
 * Shared request-timeout plumbing for every outbound provider fetch (LLM
 * chat/listModels, remote Whisper transcribe/testConnection). Without a signal
 * a hung upstream -- a server that accepts the socket but never responds --
 * makes the request hang forever, wedging the request path (Bug P2). Every
 * `fetchImpl(...)` call a provider client issues carries a
 * `signal: AbortSignal.timeout(...)` built here so a hung upstream aborts
 * within a bounded time instead of hanging indefinitely.
 */

/** Default per-request budget; a caller may override via `{ timeoutMs }`. */
export const DEFAULT_REQUEST_TIMEOUT_MS = 60_000;

/**
 * Builds the `AbortSignal` for an outbound fetch. When a caller already has
 * its own signal, the two are composed so whichever fires first wins -- the
 * timeout is a floor, never a replacement for a caller's own cancellation.
 */
export function requestTimeoutSignal(timeoutMs: number, callerSignal?: AbortSignal): AbortSignal {
  const timeout = AbortSignal.timeout(timeoutMs);
  return callerSignal ? AbortSignal.any([callerSignal, timeout]) : timeout;
}
