import { describe, expect, test } from "bun:test";
import { createRouter } from "../src/router";

describe("createRouter", () => {
  test("dispatches to the matching method+path handler", async () => {
    const router = createRouter([
      {
        method: "GET",
        path: "/health",
        handler: () => Response.json({ status: "ok" }),
      },
    ]);

    const response = await router(new Request("http://sidecar/health"));
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ status: "ok" });
  });

  test("returns 404 for an unknown route", async () => {
    const router = createRouter([]);
    const response = await router(new Request("http://sidecar/nope"));
    expect(response.status).toBe(404);
  });

  test("does not match a known path with the wrong method", async () => {
    const router = createRouter([
      { method: "GET", path: "/health", handler: () => new Response("ok") },
    ]);
    const response = await router(
      new Request("http://sidecar/health", { method: "POST" })
    );
    expect(response.status).toBe(404);
  });

  test("matches a route with a :param segment against a concrete path", async () => {
    const router = createRouter([
      {
        method: "GET",
        path: "/conversations/:id",
        handler: (req) => Response.json({ pathname: new URL(req.url).pathname }),
      },
    ]);

    const response = await router(new Request("http://sidecar/conversations/42"));

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ pathname: "/conversations/42" });
  });

  test("does not let a :param route swallow a different, more specific path", async () => {
    const router = createRouter([
      {
        method: "GET",
        path: "/conversations/:id",
        handler: () => Response.json({ matched: "param" }),
      },
      {
        method: "GET",
        path: "/conversations",
        handler: () => Response.json({ matched: "list" }),
      },
    ]);

    const response = await router(new Request("http://sidecar/conversations"));

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ matched: "list" });
  });

  test("a :param route does not match a path with extra segments", async () => {
    const router = createRouter([
      {
        method: "GET",
        path: "/conversations/:id",
        handler: () => Response.json({ matched: "param" }),
      },
    ]);

    const response = await router(
      new Request("http://sidecar/conversations/42/extra")
    );

    expect(response.status).toBe(404);
  });
});
