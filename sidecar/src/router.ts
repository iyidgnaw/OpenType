export type RouteHandler = (req: Request) => Promise<Response> | Response;

export interface Route {
  method: string;
  path: string;
  handler: RouteHandler;
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
    return route.handler(req);
  };
}
