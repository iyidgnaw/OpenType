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
});
