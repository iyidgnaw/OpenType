export type RouteHandler = (req: Request) => Promise<Response> | Response;

export interface Route {
  method: string;
  path: string;
  handler: RouteHandler;
}

/**
 * Error a route handler can throw to control the HTTP status and message the
 * router surfaces. Mirrors the provider error classes
 * (DeepSeekApiError/AnthropicApiError/OpenAICompatibleApiError): same
 * `(message, status, body?)` constructor and public `readonly status`, so any
 * of those already-thrown errors also flow through the router's catch as a
 * `status`-bearing error and get the same JSON envelope treatment.
 */
export class ApiError extends Error {
  readonly status: number;
  readonly body?: unknown;

  constructor(message: string, status: number, body?: unknown) {
    super(message);
    this.name = "ApiError";
    this.status = status;
    this.body = body;
  }
}

function hasNumericStatus(error: unknown): error is { status: number; message?: unknown } {
  return (
    typeof error === "object" &&
    error !== null &&
    typeof (error as { status?: unknown }).status === "number"
  );
}

/**
 * Matches a route pattern (optionally containing `:param` segments, e.g.
 * `/conversations/:id`) against a concrete pathname. Segment counts must
 * match exactly -- a `:param` route never matches a path with extra or
 * missing segments -- and every non-`:param` segment must match literally.
 * Handlers still only receive the raw `Request`; a route that needs the
 * matched value reads it back out of `new URL(req.url).pathname` itself
 * (see `conversationRoutes.ts`), so this stays a pure matching change with
 * no change to the `Route`/`RouteHandler` shape.
 */
function matchesPath(pattern: string, pathname: string): boolean {
  const patternParts = pattern.split("/");
  const pathParts = pathname.split("/");
  if (patternParts.length !== pathParts.length) {
    return false;
  }
  return patternParts.every(
    (part, index) => part.startsWith(":") || part === pathParts[index]
  );
}

export function createRouter(routes: Route[]): RouteHandler {
  return async (req: Request) => {
    const url = new URL(req.url);
    const route = routes.find(
      (candidate) =>
        candidate.method === req.method && matchesPath(candidate.path, url.pathname)
    );
    if (!route) {
      return Response.json({ error: "not_found" }, { status: 404 });
    }
    try {
      return await route.handler(req);
    } catch (error) {
      // Malformed request body: `req.json()` rejects with a SyntaxError. Map it
      // to a 400 so a bad client payload never reads as a server failure.
      if (error instanceof SyntaxError) {
        return Response.json({ error: "invalid_json_body" }, { status: 400 });
      }
      // A typed ApiError -- or any error carrying an HTTP-style numeric status,
      // including the provider error classes -- controls the surfaced status
      // and message.
      if (error instanceof ApiError) {
        return Response.json({ error: error.message }, { status: error.status });
      }
      if (hasNumericStatus(error)) {
        const message =
          error instanceof Error ? error.message : "request_failed";
        return Response.json({ error: message }, { status: error.status });
      }
      // Anything else is an unexpected internal failure. Return a generic
      // message only -- do not leak internal error details or stack traces.
      return Response.json({ error: "internal_error" }, { status: 500 });
    }
  };
}
