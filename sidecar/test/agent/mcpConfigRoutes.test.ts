/**
 * STAGE-1 (red) tests for P2-13's HTTP surface over the MCP server config
 * store -- the endpoints the Settings "MCP 服务器" panel calls, mirroring
 * `src/provider/routes.ts` (which does the same job for LLM/Whisper config).
 *
 * Expected RED: neither `src/agent/mcpConfigStore.ts` nor
 * `src/agent/mcpConfigRoutes.ts` exists yet.
 *
 * ---------------------------------------------------------------------------
 * Decisions pinned here
 * ---------------------------------------------------------------------------
 *
 * SURFACE
 *   GET    /config/mcp        -> { configured, source, servers: [masked...] }
 *   POST   /config/mcp        -> create one server        -> { server: masked }
 *   PUT    /config/mcp/:name  -> replace one server       -> { server: masked }
 *   DELETE /config/mcp/:name  -> remove one server        -> { deleted: true }
 *   POST   /config/mcp/test   -> probe a candidate server -> { success, tools|error }
 *
 * STATUS MATRIX. 400 for anything the request body gets wrong (missing/illegal
 * name, unknown transport, missing command/url, a duplicate name); 404 only
 * for addressing a server that does not exist. A duplicate name is deliberately
 * a 400 rather than a 409: it is the request body failing the store's
 * uniqueness rule, and keeping the matrix to exactly {400, 404} matches every
 * other config route in this sidecar, so Swift has one error path to handle.
 *
 * SECRETS. An MCP server config carries tokens: `env` values for stdio
 * servers (GITHUB_TOKEN=...), `headers` values for http ones
 * (Authorization: Bearer ...). They are masked on the way out exactly the way
 * `provider/routes.ts` masks an API key -- same `maskApiKey` rule -- and, as
 * there, under a *different key* (`envMasked`/`headersMasked`) so a masked
 * value can never be mistaken for a real one by shape alone. Map keys are not
 * masked: the user needs to see that `GITHUB_TOKEN` is set, only not what it
 * is set to.
 *
 * MASK ROUND-TRIP. The edit form is populated from `envMasked`, so a "rename
 * this server" save would otherwise POST the mask back and overwrite the real
 * token with `ghp*****lue`. Rule: on a write, a secret value that equals the
 * mask of the currently-stored value for that same server+key keeps the
 * stored value; any other value is taken as a genuine new secret. A create
 * has no stored value to preserve, so a mask-shaped value there is stored
 * verbatim (there is nothing else it could mean).
 *
 * PUT IS A REPLACE, NOT A PATCH. A key absent from the submitted `env`/
 * `headers` map is removed, and so is the whole map when the body omits it --
 * "omitted" and "explicitly empty" mean the same thing here. That is only
 * safe *because* of the round-trip rule above -- the UI sends every key back,
 * untouched ones carrying their masks -- and it is what makes "delete this
 * env var" expressible at all. Collapsing the two states is deliberate: the
 * mask round-trip is then the single way a secret survives a write, instead
 * of there also being a quieter one (omit the field) that no UI exercises.
 * The masks are resolved against the server the URL addresses, never against
 * the config as a whole.
 */
import { describe, expect, test, beforeEach, afterEach } from "bun:test";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createRouter } from "../../src/router";
import { maskApiKey } from "../../src/provider/maskApiKey";
import { McpConfigStore, type StoredMcpServer } from "../../src/agent/mcpConfigStore";
import {
  buildMcpConfigRoutes,
  type McpConfigRouteDeps,
} from "../../src/agent/mcpConfigRoutes";

const STDIO_SECRET = "ghp_realsecretvalue";
const HTTP_SECRET = "Bearer realtokenvalue";

let dir: string;
let store: McpConfigStore;

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), "opentype-mcp-routes-"));
  store = new McpConfigStore(join(dir, "mcp-servers.json"));
});

afterEach(() => {
  rmSync(dir, { recursive: true, force: true });
});

/**
 * `buildMcpConfigRoutes(store, deps)` mirrors `buildProviderConfigRoutes`:
 * `probeMcpServer` is overridable so `/config/mcp/test` needs no real child
 * process or network, and `envJson` is injected (server.ts passes
 * `process.env.OPENTYPE_MCP_SERVERS`) so the precedence branch of
 * `GET /config/mcp` is testable without mutating the process environment.
 */
function makeApp(overrides: Partial<McpConfigRouteDeps> = {}) {
  return createRouter(buildMcpConfigRoutes(store, overrides));
}

async function call(
  app: ReturnType<typeof createRouter>,
  method: string,
  path: string,
  body?: unknown
) {
  const req = new Request(`http://localhost${path}`, {
    method,
    headers: body ? { "Content-Type": "application/json" } : undefined,
    body: body ? JSON.stringify(body) : undefined,
  });
  const res = await app(req);
  const json = (await res.json()) as any;
  return { status: res.status, json, text: JSON.stringify(json) };
}

const stdioBody = (over: Record<string, unknown> = {}) => ({
  name: "filesystem",
  transport: "stdio",
  command: "npx",
  args: ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"],
  ...over,
});

const httpBody = (over: Record<string, unknown> = {}) => ({
  name: "linear",
  transport: "http",
  url: "https://mcp.linear.app/mcp",
  ...over,
});

// ---------------------------------------------------------------------------
// GET /config/mcp
// ---------------------------------------------------------------------------

describe("GET /config/mcp", () => {
  test("reports unconfigured with no servers initially", async () => {
    const app = makeApp();
    const { status, json } = await call(app, "GET", "/config/mcp");

    expect(status).toBe(200);
    expect(json).toEqual({ configured: false, source: "env", servers: [] });
  });

  test("surfaces env-var servers as source:\"env\" while still reporting configured:false", async () => {
    const app = makeApp({
      envJson: JSON.stringify([{ name: "envserver", command: "node", args: ["s.js"] }]),
    });

    const { json } = await call(app, "GET", "/config/mcp");

    // The UI can show the dev-only env servers, but must not present MCP as
    // something the user has configured -- "configured" is explicit, never
    // ambient (same rule as `/config/status`'s llmConfigured).
    expect(json.configured).toBe(false);
    expect(json.source).toBe("env");
    expect(json.servers.map((s: any) => s.name)).toEqual(["envserver"]);
  });

  test("saved servers win over the env var and flip configured to true", async () => {
    store.addServer({ name: "filesystem", transport: "stdio", command: "npx", args: [] });
    const app = makeApp({
      envJson: JSON.stringify([{ name: "envserver", command: "node", args: ["s.js"] }]),
    });

    const { json } = await call(app, "GET", "/config/mcp");

    expect(json.configured).toBe(true);
    expect(json.source).toBe("saved");
    expect(json.servers.map((s: any) => s.name)).toEqual(["filesystem"]);
  });

  test("masks env values, keeps env keys visible, and omits the raw env map", async () => {
    store.addServer({
      name: "gh",
      transport: "stdio",
      command: "npx",
      args: [],
      env: { GITHUB_TOKEN: STDIO_SECRET, PUBLIC_FLAG: "1" },
    });
    const app = makeApp();

    const { json, text } = await call(app, "GET", "/config/mcp");

    const server = json.servers[0];
    expect(server.envMasked).toEqual({
      GITHUB_TOKEN: maskApiKey(STDIO_SECRET),
      PUBLIC_FLAG: maskApiKey("1"),
    });
    expect(server.env).toBeUndefined();
    expect(text).not.toContain(STDIO_SECRET);
  });

  test("masks http header values under headersMasked and omits the raw headers", async () => {
    store.addServer({
      name: "linear",
      transport: "http",
      url: "https://mcp.linear.app/mcp",
      headers: { Authorization: HTTP_SECRET },
    });
    const app = makeApp();

    const { json, text } = await call(app, "GET", "/config/mcp");

    expect(json.servers[0].headersMasked).toEqual({ Authorization: maskApiKey(HTTP_SECRET) });
    expect(json.servers[0].headers).toBeUndefined();
    expect(text).not.toContain("realtokenvalue");
  });

  test("returns the non-secret fields a UI needs to render a row", async () => {
    store.addServer({
      name: "filesystem",
      transport: "stdio",
      command: "npx",
      args: ["-y", "server-filesystem"],
    });
    const app = makeApp();

    const { json } = await call(app, "GET", "/config/mcp");

    expect(json.servers[0]).toMatchObject({
      name: "filesystem",
      transport: "stdio",
      command: "npx",
      args: ["-y", "server-filesystem"],
    });
  });
});

// ---------------------------------------------------------------------------
// POST /config/mcp
// ---------------------------------------------------------------------------

describe("POST /config/mcp", () => {
  test("creates a stdio server and answers with the masked record", async () => {
    const app = makeApp();

    const { status, json, text } = await call(
      app,
      "POST",
      "/config/mcp",
      stdioBody({ env: { GITHUB_TOKEN: STDIO_SECRET } })
    );

    expect(status).toBe(200);
    expect(json.server.name).toBe("filesystem");
    expect(json.server.envMasked).toEqual({ GITHUB_TOKEN: maskApiKey(STDIO_SECRET) });
    expect(text).not.toContain(STDIO_SECRET);
    // ...but the real value is what actually got stored.
    expect(store.getServer("filesystem")?.env).toEqual({ GITHUB_TOKEN: STDIO_SECRET });
    expect(store.getStatus()).toEqual({ mcpConfigured: true });
  });

  test("creates an http server", async () => {
    const app = makeApp();

    const { status, json } = await call(
      app,
      "POST",
      "/config/mcp",
      httpBody({ headers: { Authorization: HTTP_SECRET } })
    );

    expect(status).toBe(200);
    expect(json.server.transport).toBe("http");
    expect(json.server.url).toBe("https://mcp.linear.app/mcp");
    expect(store.getServer("linear")?.headers).toEqual({ Authorization: HTTP_SECRET });
  });

  test("400s a missing name and stores nothing", async () => {
    const app = makeApp();

    const { status, json } = await call(app, "POST", "/config/mcp", stdioBody({ name: "" }));

    expect(status).toBe(400);
    expect(json.error).toBeTruthy();
    expect(store.listServers()).toEqual([]);
    expect(store.getStatus()).toEqual({ mcpConfigured: false });
  });

  test("400s a name that is illegal in a namespaced tool name", async () => {
    const app = makeApp();

    const { status } = await call(app, "POST", "/config/mcp", stdioBody({ name: "my server" }));

    expect(status).toBe(400);
  });

  test("400s an unknown transport", async () => {
    const app = makeApp();

    const { status } = await call(
      app,
      "POST",
      "/config/mcp",
      stdioBody({ transport: "carrier-pigeon" })
    );

    expect(status).toBe(400);
  });

  test("400s a stdio server with no command", async () => {
    const app = makeApp();

    const { status } = await call(app, "POST", "/config/mcp", stdioBody({ command: undefined }));

    expect(status).toBe(400);
  });

  test("400s an http server with a missing or non-http(s) url", async () => {
    const app = makeApp();

    expect((await call(app, "POST", "/config/mcp", httpBody({ url: undefined }))).status).toBe(400);
    expect((await call(app, "POST", "/config/mcp", httpBody({ url: "not a url" }))).status).toBe(400);
    expect(
      (await call(app, "POST", "/config/mcp", httpBody({ url: "file:///etc/passwd" }))).status
    ).toBe(400);
    expect(store.listServers()).toEqual([]);
  });

  /**
   * The last cell of the {400, 404} matrix. `createRouter` already maps a
   * `req.json()` SyntaxError to 400, so this pins that the handler lets it
   * through rather than catching it into a 500 -- and that a body that parses
   * but is not an object degrades to the same validation 400 instead of
   * throwing on a property read.
   */
  test("400s a malformed or non-object JSON body without mutating anything", async () => {
    const app = makeApp();
    const raw = async (body: string) =>
      (
        await app(
          new Request("http://localhost/config/mcp", {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body,
          })
        )
      ).status;

    expect(await raw("{ not json")).toBe(400);
    expect(await raw('"hello"')).toBe(400);
    expect(store.listServers()).toEqual([]);
  });

  test("400s a duplicate name and leaves the existing server untouched", async () => {
    const app = makeApp();
    await call(app, "POST", "/config/mcp", stdioBody());

    const { status, json } = await call(app, "POST", "/config/mcp", stdioBody({ command: "bun" }));

    expect(status).toBe(400);
    expect(json.error).toBeTruthy();
    expect(store.listServers()).toHaveLength(1);
    expect(store.getServer("filesystem")?.command).toBe("npx");
  });

  /**
   * The first save takes ownership; it does not silently absorb the dev env
   * var's servers into persisted config. Copying them in would turn a
   * throwaway shell export into permanent state the user never asked for.
   */
  test("the first create does not absorb env-var servers into saved config", async () => {
    const app = makeApp({
      envJson: JSON.stringify([{ name: "envserver", command: "node", args: ["s.js"] }]),
    });

    await call(app, "POST", "/config/mcp", stdioBody());
    const { json } = await call(app, "GET", "/config/mcp");

    expect(json.source).toBe("saved");
    expect(json.servers.map((s: any) => s.name)).toEqual(["filesystem"]);
  });

  /**
   * On a create there is no stored secret to preserve, so a value that merely
   * looks like a mask is a real (if odd) secret. Pinned so the round-trip rule
   * below cannot be implemented as "any mask-shaped string is ignored".
   */
  test("a mask-shaped value on create is stored verbatim", async () => {
    const app = makeApp();
    const maskShaped = maskApiKey(STDIO_SECRET);

    await call(app, "POST", "/config/mcp", stdioBody({ env: { GITHUB_TOKEN: maskShaped } }));

    expect(store.getServer("filesystem")?.env).toEqual({ GITHUB_TOKEN: maskShaped });
  });
});

// ---------------------------------------------------------------------------
// PUT /config/mcp/:name
// ---------------------------------------------------------------------------

describe("PUT /config/mcp/:name", () => {
  beforeEach(() => {
    store.addServer({
      name: "filesystem",
      transport: "stdio",
      command: "npx",
      args: [],
      env: { GITHUB_TOKEN: STDIO_SECRET },
    });
  });

  test("replaces the named server and answers with the masked record", async () => {
    const app = makeApp();

    const { status, json, text } = await call(
      app,
      "PUT",
      "/config/mcp/filesystem",
      stdioBody({ command: "bun", env: { GITHUB_TOKEN: STDIO_SECRET } })
    );

    expect(status).toBe(200);
    expect(json.server.command).toBe("bun");
    // Same masked shape as GET. This response is the likeliest place for a
    // real token to escape: the handler has just resolved the submitted value
    // into the full stored record, so answering with that record unmasked is
    // one missing call away.
    expect(json.server.envMasked).toEqual({ GITHUB_TOKEN: maskApiKey(STDIO_SECRET) });
    expect(json.server.env).toBeUndefined();
    expect(text).not.toContain(STDIO_SECRET);
    expect(store.getServer("filesystem")?.command).toBe("bun");
  });

  test("404s an unknown server name", async () => {
    const app = makeApp();

    const { status, json } = await call(
      app,
      "PUT",
      "/config/mcp/nope",
      stdioBody({ name: "nope" })
    );

    expect(status).toBe(404);
    expect(json.error).toBeTruthy();
    expect(store.listServers()).toHaveLength(1);
  });

  test("400s an invalid body for an existing server", async () => {
    const app = makeApp();

    const { status } = await call(
      app,
      "PUT",
      "/config/mcp/filesystem",
      stdioBody({ command: "" })
    );

    expect(status).toBe(400);
    expect(store.getServer("filesystem")?.command).toBe("npx");
  });

  test("renames a server when the body carries a different, free name", async () => {
    const app = makeApp();

    const { status } = await call(
      app,
      "PUT",
      "/config/mcp/filesystem",
      stdioBody({ name: "files" })
    );

    expect(status).toBe(200);
    expect(store.getServer("filesystem")).toBeUndefined();
    expect(store.getServer("files")).toBeDefined();
  });

  test("400s a rename onto a name another server already holds", async () => {
    store.addServer({ name: "linear", transport: "http", url: "https://mcp.linear.app/mcp" });
    const app = makeApp();

    const { status } = await call(
      app,
      "PUT",
      "/config/mcp/linear",
      httpBody({ name: "filesystem" })
    );

    expect(status).toBe(400);
    expect(store.listServers().map((s) => s.name)).toEqual(["filesystem", "linear"]);
  });

  // -- mask round-trip ------------------------------------------------------

  test("writing back the masked env value keeps the stored secret", async () => {
    const app = makeApp();

    await call(
      app,
      "PUT",
      "/config/mcp/filesystem",
      stdioBody({ command: "bun", env: { GITHUB_TOKEN: maskApiKey(STDIO_SECRET) } })
    );

    expect(store.getServer("filesystem")?.env).toEqual({ GITHUB_TOKEN: STDIO_SECRET });
    expect(store.getServer("filesystem")?.command).toBe("bun");
  });

  /**
   * The realistic rename. The form was populated from `envMasked`, so saving a
   * new name submits that new name *together with* the mask. The stored value
   * the mask has to be resolved against belongs to the server the URL
   * addresses -- looking it up by `body.name` instead finds nothing (the new
   * name is still free), the mask is taken for a genuine new secret, and the
   * token is destroyed by a rename the user thought was cosmetic. Nothing
   * surfaces until the server next fails to authenticate.
   */
  test("renaming while writing back the masked env value keeps the stored secret", async () => {
    const app = makeApp();

    const { status } = await call(
      app,
      "PUT",
      "/config/mcp/filesystem",
      stdioBody({ name: "files", env: { GITHUB_TOKEN: maskApiKey(STDIO_SECRET) } })
    );

    expect(status).toBe(200);
    expect(store.getServer("filesystem")).toBeUndefined();
    expect(store.getServer("files")?.env).toEqual({ GITHUB_TOKEN: STDIO_SECRET });
  });

  /**
   * Resolution is scoped to the addressed server, never a search across the
   * whole config for a stored value whose mask matches. A global lookup would
   * turn the mask into a read primitive: paste the mask shown for one
   * server's token into a second server's config, and the sidecar hands that
   * second server's endpoint the first one's real credential.
   */
  test("a mask matching a DIFFERENT server's secret is not resolved against it", async () => {
    const otherSecret = "ghp_othersecretvalue";
    store.addServer({
      name: "other",
      transport: "stdio",
      command: "npx",
      args: [],
      env: { GITHUB_TOKEN: otherSecret },
    });
    const app = makeApp();

    await call(
      app,
      "PUT",
      "/config/mcp/filesystem",
      stdioBody({ env: { GITHUB_TOKEN: maskApiKey(otherSecret) } })
    );

    expect(store.getServer("filesystem")?.env).toEqual({
      GITHUB_TOKEN: maskApiKey(otherSecret),
    });
    expect(store.getServer("other")?.env).toEqual({ GITHUB_TOKEN: otherSecret });
  });

  test("a genuinely new env value replaces the stored secret", async () => {
    const app = makeApp();

    await call(
      app,
      "PUT",
      "/config/mcp/filesystem",
      stdioBody({ env: { GITHUB_TOKEN: "ghp_brandnewsecret" } })
    );

    expect(store.getServer("filesystem")?.env).toEqual({ GITHUB_TOKEN: "ghp_brandnewsecret" });
  });

  test("preserves a masked key and adds a new one in the same write", async () => {
    const app = makeApp();

    await call(
      app,
      "PUT",
      "/config/mcp/filesystem",
      stdioBody({
        env: { GITHUB_TOKEN: maskApiKey(STDIO_SECRET), EXTRA: "plainvalue" },
      })
    );

    expect(store.getServer("filesystem")?.env).toEqual({
      GITHUB_TOKEN: STDIO_SECRET,
      EXTRA: "plainvalue",
    });
  });

  test("PUT is a replace: an env key omitted from the body is removed", async () => {
    const app = makeApp();

    await call(app, "PUT", "/config/mcp/filesystem", stdioBody({ env: {} }));

    // Whether "no env" is stored as `{}` or dropped entirely is the
    // implementation's call; what must be true is that the previously-stored
    // token is gone.
    expect(store.getServer("filesystem")?.env?.GITHUB_TOKEN).toBeUndefined();
    expect(Object.keys(store.getServer("filesystem")?.env ?? {})).toEqual([]);
  });

  /**
   * ...and an omitted map means the same as an empty one. The two are
   * deliberately collapsed rather than split into "clear" vs "leave alone":
   * this endpoint replaces the whole record (`transport`, `command`, `args`,
   * `url` all behave that way), the mask round-trip above is the *one*
   * mechanism for carrying a secret across a write, and a second, silent one
   * would be a path no UI exercises and no test watches. Pinned because
   * leaving it unstated lets an implementation pick either and stay green.
   */
  test("PUT is a replace: an omitted env map clears env exactly like an empty one", async () => {
    const app = makeApp();

    await call(app, "PUT", "/config/mcp/filesystem", stdioBody({ command: "bun" }));

    expect(Object.keys(store.getServer("filesystem")?.env ?? {})).toEqual([]);
    expect(store.getServer("filesystem")?.command).toBe("bun");
  });

  /**
   * The concrete case that rule exists for: an http server has no `env`, so
   * switching transport submits no `env` at all. The stdio credentials must
   * not survive as a stale field on a record that no longer has any use for
   * them.
   */
  test("switching a server from stdio to http drops the stdio-only fields", async () => {
    const app = makeApp();

    await call(app, "PUT", "/config/mcp/filesystem", httpBody({ name: "filesystem" }));

    const saved = store.getServer("filesystem");
    expect(saved?.transport).toBe("http");
    expect(saved?.url).toBe("https://mcp.linear.app/mcp");
    expect(saved?.command).toBeUndefined();
    expect(Object.keys(saved?.env ?? {})).toEqual([]);
  });

  test("the masked value never lands in storage as if it were the real secret", async () => {
    const app = makeApp();
    const masked = maskApiKey(STDIO_SECRET);

    await call(
      app,
      "PUT",
      "/config/mcp/filesystem",
      stdioBody({ env: { GITHUB_TOKEN: masked } })
    );

    expect(store.getServer("filesystem")?.env?.GITHUB_TOKEN).not.toBe(masked);
  });

  test("the same round-trip rule applies to http headers", async () => {
    store.addServer({
      name: "linear",
      transport: "http",
      url: "https://mcp.linear.app/mcp",
      headers: { Authorization: HTTP_SECRET },
    });
    const app = makeApp();

    await call(
      app,
      "PUT",
      "/config/mcp/linear",
      httpBody({
        url: "https://mcp.linear.app/v2/mcp",
        headers: { Authorization: maskApiKey(HTTP_SECRET) },
      })
    );

    expect(store.getServer("linear")).toMatchObject({
      url: "https://mcp.linear.app/v2/mcp",
      headers: { Authorization: HTTP_SECRET },
    });
  });

  /**
   * The mask is only meaningful for the key it came from. A mask copied onto a
   * *different* key has no stored counterpart, so it is a literal value --
   * never a wildcard that reads some other key's secret.
   */
  test("a mask under a different key is not resolved against another key's secret", async () => {
    const app = makeApp();
    const masked = maskApiKey(STDIO_SECRET);

    await call(app, "PUT", "/config/mcp/filesystem", stdioBody({ env: { OTHER: masked } }));

    expect(store.getServer("filesystem")?.env).toEqual({ OTHER: masked });
  });
});

// ---------------------------------------------------------------------------
// DELETE /config/mcp/:name
// ---------------------------------------------------------------------------

describe("DELETE /config/mcp/:name", () => {
  test("removes an existing server", async () => {
    store.addServer({ name: "filesystem", transport: "stdio", command: "npx", args: [] });
    const app = makeApp();

    const { status, json } = await call(app, "DELETE", "/config/mcp/filesystem");

    expect(status).toBe(200);
    expect(json).toEqual({ deleted: true });
    expect(store.listServers()).toEqual([]);
  });

  test("404s an unknown server name", async () => {
    const app = makeApp();

    const { status, json } = await call(app, "DELETE", "/config/mcp/nope");

    expect(status).toBe(404);
    expect(json.error).toBeTruthy();
  });

  test("deleting the last server leaves the config configured-but-empty (env stays overridden)", async () => {
    store.addServer({ name: "filesystem", transport: "stdio", command: "npx", args: [] });
    const app = makeApp({
      envJson: JSON.stringify([{ name: "envserver", command: "node", args: ["s.js"] }]),
    });

    await call(app, "DELETE", "/config/mcp/filesystem");
    const { json } = await call(app, "GET", "/config/mcp");

    expect(json).toEqual({ configured: true, source: "saved", servers: [] });
  });
});

// ---------------------------------------------------------------------------
// POST /config/mcp/test
// ---------------------------------------------------------------------------

describe("POST /config/mcp/test", () => {
  test("reports the tools a reachable server exposes", async () => {
    const app = makeApp({
      probeMcpServer: async () => ({
        tools: [
          { name: "read_file", description: "Read a file" },
          { name: "write_file", description: "Write a file" },
        ],
      }),
    });

    const { status, json } = await call(app, "POST", "/config/mcp/test", stdioBody());

    expect(status).toBe(200);
    expect(json).toEqual({
      success: true,
      tools: [
        { name: "read_file", description: "Read a file" },
        { name: "write_file", description: "Write a file" },
      ],
    });
  });

  test("reports a probe failure as success:false with the real error text", async () => {
    const app = makeApp({
      probeMcpServer: async () => {
        throw new Error("spawn npx ENOENT");
      },
    });

    const { status, json } = await call(app, "POST", "/config/mcp/test", stdioBody());

    expect(status).toBe(200);
    expect(json.success).toBe(false);
    expect(json.error).toContain("ENOENT");
    expect(json.tools).toBeUndefined();
  });

  test("a server exposing no tools is a success with an empty list, not a failure", async () => {
    const app = makeApp({ probeMcpServer: async () => ({ tools: [] }) });

    const { json } = await call(app, "POST", "/config/mcp/test", stdioBody());

    expect(json).toEqual({ success: true, tools: [] });
  });

  test("testing does not save anything", async () => {
    const app = makeApp({ probeMcpServer: async () => ({ tools: [] }) });

    await call(app, "POST", "/config/mcp/test", stdioBody());

    expect(store.listServers()).toEqual([]);
    expect(store.getStatus()).toEqual({ mcpConfigured: false });
  });

  test("400s an invalid candidate before attempting any connection", async () => {
    let probes = 0;
    const app = makeApp({
      probeMcpServer: async () => {
        probes += 1;
        return { tools: [] };
      },
    });

    const { status } = await call(app, "POST", "/config/mcp/test", stdioBody({ command: "" }));

    expect(status).toBe(400);
    expect(probes).toBe(0);
  });

  /**
   * The edit form is populated from `envMasked`, so "Test Connection" on an
   * already-saved server submits masks. The probe must receive the real stored
   * secrets -- otherwise every test of a saved server fails with an auth error
   * that has nothing to do with the user's config.
   */
  test("resolves masked secrets against the saved server of the same name before probing", async () => {
    store.addServer({
      name: "filesystem",
      transport: "stdio",
      command: "npx",
      args: [],
      env: { GITHUB_TOKEN: STDIO_SECRET },
    });
    let probed: StoredMcpServer | undefined;
    const app = makeApp({
      probeMcpServer: async (server) => {
        probed = server;
        return { tools: [] };
      },
    });

    await call(
      app,
      "POST",
      "/config/mcp/test",
      stdioBody({ env: { GITHUB_TOKEN: maskApiKey(STDIO_SECRET) } })
    );

    expect(probed?.env).toEqual({ GITHUB_TOKEN: STDIO_SECRET });
  });

  test("a candidate whose name is not saved is probed exactly as submitted", async () => {
    let probed: StoredMcpServer | undefined;
    const app = makeApp({
      probeMcpServer: async (server) => {
        probed = server;
        return { tools: [] };
      },
    });

    await call(
      app,
      "POST",
      "/config/mcp/test",
      stdioBody({ name: "unsaved", env: { GITHUB_TOKEN: "ghp_typedjustnow" } })
    );

    expect(probed?.env).toEqual({ GITHUB_TOKEN: "ghp_typedjustnow" });
  });

  /**
   * The probe is where a global mask lookup would hurt most: this endpoint
   * *sends* the resolved secrets to whatever endpoint the candidate names, and
   * the candidate is unsaved attacker-shaped input. Resolution stays keyed to
   * the saved server of the same name, so another server's mask is probed as
   * the literal string it is.
   */
  test("a mask belonging to a different saved server is not resolved before probing", async () => {
    store.addServer({
      name: "gh",
      transport: "stdio",
      command: "npx",
      args: [],
      env: { TOKEN: STDIO_SECRET },
    });
    let probed: StoredMcpServer | undefined;
    const app = makeApp({
      probeMcpServer: async (server) => {
        probed = server;
        return { tools: [] };
      },
    });

    await call(
      app,
      "POST",
      "/config/mcp/test",
      httpBody({
        name: "exfil",
        url: "https://attacker.example/mcp",
        headers: { TOKEN: maskApiKey(STDIO_SECRET) },
      })
    );

    expect(probed?.headers).toEqual({ TOKEN: maskApiKey(STDIO_SECRET) });
    expect(JSON.stringify(probed)).not.toContain(STDIO_SECRET);
  });

  test("the response never echoes the submitted secrets back", async () => {
    const app = makeApp({
      probeMcpServer: async () => ({ tools: [{ name: "read_file" }] }),
    });

    const { text } = await call(
      app,
      "POST",
      "/config/mcp/test",
      stdioBody({ env: { GITHUB_TOKEN: STDIO_SECRET } })
    );

    expect(text).not.toContain(STDIO_SECRET);
    expect(text).not.toContain("realsecretvalue");
  });
});
