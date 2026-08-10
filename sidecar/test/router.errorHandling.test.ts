import { describe, expect, test } from "bun:test";
import { createRouter } from "../src/router";
// Namespace import so a not-yet-existing `ApiError` export resolves to
// `undefined` instead of failing the whole module at link time. Stage 3 is
// expected to add `export class ApiError` to `../src/router` with the same
// `(message, status)` constructor convention the provider error classes use
// (DeepSeekApiError/AnthropicApiError/OpenAICompatibleApiError).
import * as routerModule from "../src/router";

describe("createRouter error handling", () => {
  test("a handler that throws a plain Error yields a 500 JSON response, not text/html", async () => {
    const router = createRouter([
      {
        method: "GET",
        path: "/boom",
        handler: () => {
          throw new Error("kaboom");
        },
      },
    ]);

    const response = await router(new Request("http://sidecar/boom"));

    expect(response.status).toBe(500);

    const contentType = response.headers.get("content-type") ?? "";
    expect(contentType).toContain("application/json");
    expect(contentType).not.toContain("text/html");

    const body = (await response.json()) as { error?: unknown };
    expect(body.error).toBeDefined();
  });

  test("a handler that throws a typed ApiError yields that status and message in JSON", async () => {
    const { ApiError } = routerModule as {
      ApiError?: new (message: string, status: number) => Error;
    };

    // Contract Stage 3 must satisfy: `ApiError` is exported from ../src/router.
    expect(ApiError).toBeDefined();

    const router = createRouter([
      {
        method: "GET",
        path: "/protected",
        handler: () => {
          throw new ApiError!("unauthorized", 401);
        },
      },
    ]);

    const response = await router(new Request("http://sidecar/protected"));

    expect(response.status).toBe(401);

    const contentType = response.headers.get("content-type") ?? "";
    expect(contentType).toContain("application/json");
    expect(contentType).not.toContain("text/html");

    const body = (await response.json()) as { error?: unknown };
    expect(body.error).toBe("unauthorized");
  });

  test("a malformed JSON body to a route that reads req.json() yields a 400 JSON error, not a 500", async () => {
    const router = createRouter([
      {
        method: "POST",
        path: "/echo",
        handler: async (req) => {
          const body = await req.json();
          return Response.json({ echoed: body });
        },
      },
    ]);

    const response = await router(
      new Request("http://sidecar/echo", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: "{ this is not valid json",
      })
    );

    expect(response.status).toBe(400);

    const contentType = response.headers.get("content-type") ?? "";
    expect(contentType).toContain("application/json");
    expect(contentType).not.toContain("text/html");

    const body = (await response.json()) as { error?: unknown };
    expect(body.error).toBeDefined();
  });
});
