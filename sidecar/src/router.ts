export type RouteHandler = (req: Request) => Promise<Response> | Response;

export interface Route {
  method: string;
  path: string;
  handler: RouteHandler;
}

export function createRouter(routes: Route[]): RouteHandler {
  return async (req: Request) => {
    const url = new URL(req.url);
    const route = routes.find(
      (candidate) =>
        candidate.method === req.method && candidate.path === url.pathname
    );
    if (!route) {
      return Response.json({ error: "not_found" }, { status: 404 });
    }
    return route.handler(req);
  };
}
