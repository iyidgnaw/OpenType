/**
 * STAGE-1 (red) tests for P2-13's persisted MCP server config store.
 *
 * Today MCP servers can only be attached through the `OPENTYPE_MCP_SERVERS`
 * env var (`src/agent/mcpClient.ts`). A user of the packaged app cannot set
 * that, so Agent mode's toolset is frozen at whatever ships built in. P2-13
 * moves that config into a sidecar-owned store with an HTTP surface, exactly
 * the way `ProviderConfigStore` (`src/provider/configStore.ts`) already does
 * for LLM/Whisper provider config.
 *
 * These tests are written against the DESIRED API and are expected to be RED
 * (`src/agent/mcpConfigStore.ts` does not exist yet).
 *
 * ---------------------------------------------------------------------------
 * Decisions pinned here
 * ---------------------------------------------------------------------------
 *
 * STORAGE conventions are copied from `ProviderConfigStore` rather than
 * reinvented: plain JSON on local disk next to the SQLite data dir, written
 * to a fresh `{ mode: 0o600 }` temp file and atomically renamed onto the
 * destination (so there is never a broad-mode window over a file holding
 * tokens, and never an observably truncated destination), no temp artifact
 * left behind, and a corrupt file self-heals -- bytes preserved to a
 * `*.corrupt*` sibling, logged, boot continues empty -- because this store is
 * constructed during sidecar boot and throwing there would brick the whole
 * process (including transcribe-only users who never touched MCP).
 *
 * SHAPE. A server is `{ name, transport }` plus transport-specific fields:
 * stdio takes `command`/`args`/`env`, http takes `url`/`headers`. The env-var
 * format documented today (`{name, command, args}` with no `transport`) stays
 * valid by defaulting to stdio.
 *
 * NAME CHARSET. A server's tools are exposed to the model as
 * `${serverName}__${toolName}` (see `connectConfiguredMcpServers`), and
 * OpenAI-style function names are restricted to `[A-Za-z0-9_-]`. A server
 * named "my server" would therefore emit tool descriptors the provider
 * rejects -- which fails the *entire* request, not just that server's tools.
 * So the charset is validated at the store, at the point the user types it,
 * rather than discovered as a broken agent run later.
 *
 * PRECEDENCE (section C of the task). Saved config wins; the env var is the
 * zero-config dev fallback. This mirrors `resolveChat`/`resolveTranscribe`'s
 * rule that "configured" is explicit and never ambient: only a real mutation
 * through this store flips `mcpConfigured`, and once it is flipped the env var
 * is ignored *entirely* -- including when the saved list is empty, so that
 * "remove my last MCP server" actually removes it in a dev checkout that also
 * has the env var set, instead of silently resurrecting the env servers.
 *
 * URL NORMALIZATION is deliberately NOT copied from `ProviderConfigStore`.
 * That store strips trailing slashes because a provider baseUrl gets a path
 * appended to it; an MCP endpoint URL is used whole and its path is
 * server-defined, so it is validated (parseable, http/https only) and stored
 * byte-for-byte as given.
 *
 * ---------------------------------------------------------------------------
 * ADDED: `enabled` (MCP boot-resilience batch)
 * ---------------------------------------------------------------------------
 *
 * `StoredMcpServer` gains a required `enabled: boolean`, and
 * `ResolvedMcpServers` gains `allServers`:
 *
 *   export interface StoredMcpServer { ...; enabled: boolean; }
 *
 *   export interface ResolvedMcpServers {
 *     source: McpConfigSource;
 *     servers: StoredMcpServer[];      // ENABLED only -- what gets connected
 *     allServers: StoredMcpServer[];   // everything -- what the UI lists
 *   }
 *
 * WHY. A server that fails "Test Connection" must be storable in a disabled
 * state ("停用并保存" in the redesign handoff, §7C) rather than forcing the user
 * to throw away the token they just typed. Disabled servers are skipped at
 * connect time, so a known-bad server costs nothing at boot.
 *
 * DEFAULT `true`. Two reasons, and both point the same way. (1) Records already
 * on users' disks carry no `enabled` field; defaulting to `false` would
 * silently disable every server anyone has already configured, on upgrade, with
 * no user action. Same for the `OPENTYPE_MCP_SERVERS` entries, which have no
 * such field and never will. (2) Adding a server is itself the act of enabling
 * it -- disabling is the exception the user opts into on a failed test, not a
 * second confirmation step every successful add has to pass. The field is
 * MATERIALIZED at normalization (not left undefined and read as truthy), so the
 * stored JSON is explicit and the type stays a plain required boolean.
 *
 * WHY `allServers` EXISTS. Filtering inside `resolveMcpServers` is what keeps a
 * disabled server off the boot path -- but `GET /config/mcp` answers from the
 * same function, so filtering alone would also erase disabled servers from the
 * Settings list, leaving the user unable to see or re-enable the thing they
 * just saved. That is the same "no way to recover" shape as the bug this batch
 * exists to close, so the resolved value carries both views and the caller
 * picks: `main()` connects `servers`, the route lists `allServers`.
 *
 * The two helpers below therefore build servers with `enabled: true` -- that is
 * now part of what a stored server IS. The default is exercised separately, by
 * submitting objects with no `enabled` key at all.
 */
import { describe, expect, test, beforeEach, afterEach } from "bun:test";
import {
  existsSync,
  mkdtempSync,
  readFileSync,
  readdirSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { basename, join } from "node:path";
import {
  McpConfigStore,
  normalizeMcpServer,
  resolveMcpServers,
  type StoredMcpServer,
} from "../../src/agent/mcpConfigStore";
import {
  connectConfiguredMcpServers,
  type McpClientLike,
  type McpConnectionFactories,
} from "../../src/agent/mcpClient";
import { mergeToolSets } from "../../src/agent/toolSets";
import { withApproval, yoloApprovalPolicy } from "../../src/agent/approval";

let dir: string;

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), "opentype-mcp-config-"));
});

afterEach(() => {
  rmSync(dir, { recursive: true, force: true });
});

function storePath(): string {
  return join(dir, "mcp-servers.json");
}

const stdioServer = (over: Partial<StoredMcpServer> = {}): StoredMcpServer => ({
  name: "filesystem",
  transport: "stdio",
  command: "npx",
  args: ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"],
  enabled: true,
  ...over,
});

const httpServer = (over: Partial<StoredMcpServer> = {}): StoredMcpServer => ({
  name: "linear",
  transport: "http",
  url: "https://mcp.linear.app/mcp",
  enabled: true,
  ...over,
});

// ---------------------------------------------------------------------------
// CRUD
// ---------------------------------------------------------------------------

describe("McpConfigStore CRUD", () => {
  test("starts empty and unconfigured when no file exists on disk", () => {
    const store = new McpConfigStore(storePath());

    expect(store.listServers()).toEqual([]);
    expect(store.getStatus()).toEqual({ mcpConfigured: false });
    expect(store.getServer("filesystem")).toBeUndefined();
  });

  test("addServer stores the server and marks mcpConfigured true", () => {
    const store = new McpConfigStore(storePath());

    store.addServer(stdioServer());

    expect(store.getStatus()).toEqual({ mcpConfigured: true });
    expect(store.listServers()).toEqual([stdioServer()]);
    expect(store.getServer("filesystem")).toEqual(stdioServer());
  });

  test("addServer keeps multiple servers in insertion order", () => {
    const store = new McpConfigStore(storePath());

    store.addServer(stdioServer());
    store.addServer(httpServer());

    expect(store.listServers().map((s) => s.name)).toEqual(["filesystem", "linear"]);
  });

  test("updateServer replaces the named server's fields wholesale", () => {
    const store = new McpConfigStore(storePath());
    store.addServer(stdioServer());

    store.updateServer("filesystem", stdioServer({ args: ["-y", "other-server"] }));

    expect(store.getServer("filesystem")?.args).toEqual(["-y", "other-server"]);
    expect(store.listServers()).toHaveLength(1);
  });

  test("updateServer can rename a server, and the old name stops resolving", () => {
    const store = new McpConfigStore(storePath());
    store.addServer(stdioServer());

    store.updateServer("filesystem", stdioServer({ name: "files" }));

    expect(store.getServer("filesystem")).toBeUndefined();
    expect(store.getServer("files")?.command).toBe("npx");
    expect(store.listServers()).toHaveLength(1);
  });

  test("updateServer rejects a rename onto a name another server already holds", () => {
    const store = new McpConfigStore(storePath());
    store.addServer(stdioServer());
    store.addServer(httpServer());

    expect(() => store.updateServer("linear", httpServer({ name: "filesystem" }))).toThrow();
    // The failed rename must not have disturbed either row.
    expect(store.listServers().map((s) => s.name)).toEqual(["filesystem", "linear"]);
  });

  test("updateServer on an unknown name throws rather than silently creating one", () => {
    const store = new McpConfigStore(storePath());

    expect(() => store.updateServer("nope", stdioServer({ name: "nope" }))).toThrow();
    expect(store.listServers()).toEqual([]);
  });

  test("removeServer removes the named server and reports whether it existed", () => {
    const store = new McpConfigStore(storePath());
    store.addServer(stdioServer());
    store.addServer(httpServer());

    expect(store.removeServer("filesystem")).toBe(true);
    expect(store.listServers().map((s) => s.name)).toEqual(["linear"]);
    expect(store.removeServer("filesystem")).toBe(false);
  });

  /**
   * The whole point of the precedence rule below: after the user has taken
   * ownership of MCP config, emptying the list means "no MCP servers", not
   * "go back to whatever the env var said".
   */
  test("removing the last server leaves the store configured-but-empty", () => {
    const store = new McpConfigStore(storePath());
    store.addServer(stdioServer());

    store.removeServer("filesystem");

    expect(store.listServers()).toEqual([]);
    expect(store.getStatus()).toEqual({ mcpConfigured: true });
  });
});

// ---------------------------------------------------------------------------
// Validation
// ---------------------------------------------------------------------------

describe("McpConfigStore validation", () => {
  test("rejects an empty name", () => {
    const store = new McpConfigStore(storePath());
    expect(() => store.addServer(stdioServer({ name: "" }))).toThrow();
  });

  test("rejects a whitespace-only name", () => {
    const store = new McpConfigStore(storePath());
    expect(() => store.addServer(stdioServer({ name: "   " }))).toThrow();
  });

  test("trims surrounding whitespace off an otherwise-valid name", () => {
    const store = new McpConfigStore(storePath());
    store.addServer(stdioServer({ name: "  filesystem  " }));
    expect(store.getServer("filesystem")?.name).toBe("filesystem");
  });

  /**
   * See the header note: the name becomes half of an OpenAI function name
   * (`${name}__${tool}`), so a name outside `[A-Za-z0-9_-]` produces tool
   * descriptors the provider rejects for the whole request.
   */
  test("rejects a name containing characters that are illegal in a tool name", () => {
    const store = new McpConfigStore(storePath());
    expect(() => store.addServer(stdioServer({ name: "my server" }))).toThrow();
    expect(() => store.addServer(stdioServer({ name: "server.one" }))).toThrow();
    expect(() => store.addServer(stdioServer({ name: "服务器" }))).toThrow();
  });

  test("accepts a name made of letters, digits, underscores and hyphens", () => {
    const store = new McpConfigStore(storePath());
    expect(() => store.addServer(stdioServer({ name: "fs-server_2" }))).not.toThrow();
  });

  test("rejects a duplicate name on add", () => {
    const store = new McpConfigStore(storePath());
    store.addServer(stdioServer());

    expect(() => store.addServer(stdioServer({ command: "bun" }))).toThrow();
    expect(store.listServers()).toHaveLength(1);
    expect(store.getServer("filesystem")?.command).toBe("npx");
  });

  test("rejects an unknown transport", () => {
    const store = new McpConfigStore(storePath());
    expect(() =>
      store.addServer({ name: "x", transport: "carrier-pigeon" } as unknown as StoredMcpServer)
    ).toThrow();
  });

  test("rejects a stdio server with no command", () => {
    const store = new McpConfigStore(storePath());
    expect(() => store.addServer(stdioServer({ command: undefined }))).toThrow();
    expect(() => store.addServer(stdioServer({ command: "" }))).toThrow();
  });

  test("a stdio server may omit args (defaults to an empty list)", () => {
    const store = new McpConfigStore(storePath());
    store.addServer(stdioServer({ args: undefined }));
    expect(store.getServer("filesystem")?.args).toEqual([]);
  });

  test("rejects an http server with no url", () => {
    const store = new McpConfigStore(storePath());
    expect(() => store.addServer(httpServer({ url: undefined }))).toThrow();
    expect(() => store.addServer(httpServer({ url: "" }))).toThrow();
  });

  test("rejects a malformed url", () => {
    const store = new McpConfigStore(storePath());
    expect(() => store.addServer(httpServer({ url: "not a url" }))).toThrow();
  });

  test("rejects a non-http(s) url scheme", () => {
    const store = new McpConfigStore(storePath());
    expect(() => store.addServer(httpServer({ url: "file:///etc/passwd" }))).toThrow();
    expect(() => store.addServer(httpServer({ url: "ftp://example.com/mcp" }))).toThrow();
  });

  /**
   * Unlike a provider baseUrl (which gets a path appended), an MCP endpoint
   * URL is used whole -- so it is stored exactly as given, trailing slash and
   * all, rather than normalized.
   */
  test("stores a valid url byte-for-byte, without trailing-slash normalization", () => {
    const store = new McpConfigStore(storePath());
    store.addServer(httpServer({ url: "https://mcp.linear.app/mcp/" }));
    expect(store.getServer("linear")?.url).toBe("https://mcp.linear.app/mcp/");
  });

  test("a rejected add persists nothing to disk", () => {
    const path = storePath();
    const store = new McpConfigStore(path);

    expect(() => store.addServer(stdioServer({ name: "" }))).toThrow();

    expect(existsSync(path)).toBe(false);
    expect(store.getStatus()).toEqual({ mcpConfigured: false });
  });
});

// ---------------------------------------------------------------------------
// Persistence -- ProviderConfigStore's conventions, verbatim
// ---------------------------------------------------------------------------

describe("McpConfigStore persistence", () => {
  test("a fresh store reloads previously persisted servers from disk", () => {
    const path = storePath();
    const first = new McpConfigStore(path);
    first.addServer(stdioServer({ env: { GITHUB_TOKEN: "ghp_realsecretvalue" } }));
    first.addServer(httpServer({ headers: { Authorization: "Bearer realtokenvalue" } }));

    const second = new McpConfigStore(path);

    expect(second.getStatus()).toEqual({ mcpConfigured: true });
    expect(second.listServers().map((s) => s.name)).toEqual(["filesystem", "linear"]);
    expect(second.getServer("filesystem")?.env).toEqual({ GITHUB_TOKEN: "ghp_realsecretvalue" });
    expect(second.getServer("linear")?.headers).toEqual({ Authorization: "Bearer realtokenvalue" });
  });

  test("persists the config file with owner-only (0600) permissions", () => {
    const path = storePath();
    const store = new McpConfigStore(path);
    store.addServer(stdioServer({ env: { GITHUB_TOKEN: "ghp_realsecretvalue" } }));

    expect(statSync(path).mode & 0o777).toBe(0o600);
  });

  /**
   * Same discriminator `configStore.hardening.test.ts` uses: an in-place
   * `writeFileSync` reuses the destination inode (open + O_TRUNC); a
   * temp-file+rename swaps in a fresh one. This proves the token-bearing file
   * is never written through a broad-mode / truncated window.
   */
  test("re-saving swaps in a NEW inode (atomic temp-file + rename), still 0600", () => {
    const path = storePath();
    const store = new McpConfigStore(path);

    store.addServer(stdioServer());
    const firstInode = statSync(path).ino;
    expect(statSync(path).mode & 0o777).toBe(0o600);

    store.addServer(httpServer());
    const secondInode = statSync(path).ino;

    expect(secondInode).not.toBe(firstInode);
    expect(statSync(path).mode & 0o777).toBe(0o600);
  });

  test("leaves no temp artifact in the directory after a successful save", () => {
    const path = storePath();
    const store = new McpConfigStore(path);
    store.addServer(stdioServer());

    expect(readdirSync(dir)).toEqual([basename(path)]);
  });

  test("the persisted file is complete, valid JSON holding the config as written", () => {
    const path = storePath();
    const store = new McpConfigStore(path);
    store.addServer(stdioServer({ env: { GITHUB_TOKEN: "ghp_realsecretvalue" } }));

    const raw = readFileSync(path, "utf8");
    expect(raw.length).toBeGreaterThan(0);
    // Same documented plaintext tradeoff as ProviderConfigStore: the secret is
    // on local disk in the clear, protected by 0600 rather than by Keychain.
    expect(raw).toContain("ghp_realsecretvalue");
    expect(() => JSON.parse(raw)).not.toThrow();
  });

  test("a corrupt file self-heals: bytes preserved aside, store boots empty, no throw", () => {
    const path = storePath();
    const garbage = "{ this is not valid json ";
    writeFileSync(path, garbage, "utf8");

    let store: McpConfigStore | undefined;
    // Throwing here would brick sidecar boot -- this store is constructed in
    // server.ts main() with no surrounding try/catch.
    expect(() => {
      store = new McpConfigStore(path);
    }).not.toThrow();

    const preserved = readdirSync(dir).filter(
      (f) => f !== basename(path) && f.includes("corrupt")
    );
    expect(preserved.length).toBeGreaterThanOrEqual(1);
    expect(readFileSync(join(dir, preserved[0]!), "utf8")).toBe(garbage);

    expect(store!.listServers()).toEqual([]);
    expect(store!.getStatus()).toEqual({ mcpConfigured: false });
  });

  test("a zero-length (crash-truncated) file boots empty without preserving anything", () => {
    const path = storePath();
    writeFileSync(path, "", "utf8");

    let store: McpConfigStore | undefined;
    expect(() => {
      store = new McpConfigStore(path);
    }).not.toThrow();

    expect(store!.listServers()).toEqual([]);
    expect(store!.getStatus()).toEqual({ mcpConfigured: false });
  });

  test("a self-healed store is writable again afterwards", () => {
    const path = storePath();
    writeFileSync(path, "{ garbage", "utf8");
    const store = new McpConfigStore(path);

    store.addServer(stdioServer());

    expect(new McpConfigStore(path).listServers().map((s) => s.name)).toEqual(["filesystem"]);
  });
});

// ---------------------------------------------------------------------------
// Precedence: saved config vs OPENTYPE_MCP_SERVERS  (section C)
// ---------------------------------------------------------------------------

describe("resolveMcpServers precedence", () => {
  const envJson = JSON.stringify([
    { name: "envserver", command: "node", args: ["env-server.js"] },
  ]);

  test("with nothing saved, the env var supplies the servers as a dev fallback", () => {
    const store = new McpConfigStore(storePath());

    const resolved = resolveMcpServers(store, envJson);

    expect(resolved.source).toBe("env");
    expect(resolved.servers.map((s) => s.name)).toEqual(["envserver"]);
  });

  /**
   * The env format documented in `mcpClient.ts` has no `transport` field, so
   * an entry without one is stdio -- otherwise this feature would silently
   * break every existing dev setup.
   */
  test("env entries default to the stdio transport", () => {
    const store = new McpConfigStore(storePath());

    const resolved = resolveMcpServers(store, envJson);

    expect(resolved.servers[0]).toMatchObject({
      name: "envserver",
      transport: "stdio",
      command: "node",
      args: ["env-server.js"],
    });
  });

  test("with nothing saved and no env var, nothing resolves", () => {
    const store = new McpConfigStore(storePath());

    expect(resolveMcpServers(store, undefined)).toEqual({
      source: "env",
      servers: [],
      allServers: [],
    });
  });

  test("unparseable env JSON resolves to nothing rather than throwing", () => {
    const store = new McpConfigStore(storePath());

    expect(() => resolveMcpServers(store, "not json")).not.toThrow();
    expect(resolveMcpServers(store, "not json").servers).toEqual([]);
    expect(resolveMcpServers(store, '{"not":"an array"}').servers).toEqual([]);
  });

  test("saved config wins over the env var entirely -- env servers are not merged in", () => {
    const store = new McpConfigStore(storePath());
    store.addServer(stdioServer());

    const resolved = resolveMcpServers(store, envJson);

    expect(resolved.source).toBe("saved");
    expect(resolved.servers.map((s) => s.name)).toEqual(["filesystem"]);
  });

  /**
   * The sharp edge of "saved wins entirely". A dev with the env var set who
   * adds then removes a server through the UI must end up with zero MCP
   * servers -- not with the env servers quietly reinstated behind their back.
   */
  test("an emptied-but-configured store resolves to no servers, not back to the env var", () => {
    const store = new McpConfigStore(storePath());
    store.addServer(stdioServer());
    store.removeServer("filesystem");

    const resolved = resolveMcpServers(store, envJson);

    expect(resolved.source).toBe("saved");
    expect(resolved.servers).toEqual([]);
  });

  /**
   * Mirrors `ProviderConfigStore`'s "configured is explicit, never ambient"
   * rule: an ambient env var is a fallback, not a user decision, so the UI
   * must not report MCP as configured just because one is set.
   */
  test("an ambient env var alone never makes the store report configured", () => {
    const store = new McpConfigStore(storePath());

    resolveMcpServers(store, envJson);

    expect(store.getStatus()).toEqual({ mcpConfigured: false });
    expect(store.listServers()).toEqual([]);
  });
});

// ---------------------------------------------------------------------------
// `enabled`: saving a known-bad server without handing it the boot path
// ---------------------------------------------------------------------------

/**
 * The recovery half of the MCP boot-resilience batch. A server that fails
 * "Test Connection" is saved disabled ("停用并保存", handoff §7C) instead of
 * being thrown away, and a disabled server is never connected -- so it costs
 * nothing at boot, and the user keeps the token they typed.
 */
describe("normalizeMcpServer: the enabled field", () => {
  test("defaults to true when the submitted server omits it", () => {
    // Records already on disk, and every OPENTYPE_MCP_SERVERS entry, have no
    // such field. Defaulting to false would disable them all on upgrade.
    expect(
      normalizeMcpServer({ name: "filesystem", transport: "stdio", command: "npx" }).enabled
    ).toBe(true);
    expect(
      normalizeMcpServer({ name: "linear", transport: "http", url: "https://x.test/mcp" })
        .enabled
    ).toBe(true);
  });

  test("defaults to true for the transport-less env-var format too", () => {
    expect(normalizeMcpServer({ name: "envserver", command: "node" }).enabled).toBe(true);
  });

  test("passes an explicit false through", () => {
    expect(
      normalizeMcpServer({
        name: "filesystem",
        transport: "stdio",
        command: "npx",
        enabled: false,
      }).enabled
    ).toBe(false);
  });

  test("passes an explicit true through", () => {
    expect(
      normalizeMcpServer({
        name: "filesystem",
        transport: "stdio",
        command: "npx",
        enabled: true,
      }).enabled
    ).toBe(true);
  });

  test("rejects a non-boolean enabled rather than coercing it", () => {
    // "false" and 0 are exactly the values a hand-edited file or a sloppy
    // client would produce, and coercion would silently pick the wrong one.
    for (const bad of ["false", "true", 0, 1]) {
      expect(() =>
        normalizeMcpServer({
          name: "filesystem",
          transport: "stdio",
          command: "npx",
          enabled: bad,
        })
      ).toThrow();
    }
  });

  test("null reads as absent, not as an error", () => {
    // Matches `normalizeStringMap`'s existing treatment of null in this module,
    // and it is the right direction on the load path: a rejected field drops
    // the whole row (see the loader's per-entry catch), losing a server and its
    // credentials over a field that was never the point.
    expect(
      normalizeMcpServer({
        name: "filesystem",
        transport: "stdio",
        command: "npx",
        enabled: null,
      }).enabled
    ).toBe(true);
  });
});

describe("McpConfigStore: storing a disabled server", () => {
  test("addServer persists enabled: false and reloads it from disk", () => {
    const path = storePath();
    const first = new McpConfigStore(path);
    first.addServer(stdioServer({ enabled: false, env: { TOKEN: "ghp_realsecretvalue" } }));

    const second = new McpConfigStore(path);

    expect(second.getServer("filesystem")?.enabled).toBe(false);
    // The point of saving it at all: the credential survives, so re-enabling
    // is one click rather than re-typing the token.
    expect(second.getServer("filesystem")?.env).toEqual({ TOKEN: "ghp_realsecretvalue" });
  });

  test("a server added without enabled reloads as enabled", () => {
    const path = storePath();
    new McpConfigStore(path).addServer({
      name: "filesystem",
      transport: "stdio",
      command: "npx",
    });

    expect(new McpConfigStore(path).getServer("filesystem")?.enabled).toBe(true);
  });

  test("a stored record with no enabled field loads as enabled", () => {
    // The upgrade path: a file written before this field existed.
    const path = storePath();
    writeFileSync(
      path,
      JSON.stringify({
        mcpConfigured: true,
        servers: [{ name: "filesystem", transport: "stdio", command: "npx", args: [] }],
      }),
      "utf8"
    );

    expect(new McpConfigStore(path).getServer("filesystem")?.enabled).toBe(true);
  });

  test("updateServer can disable a server, and re-enable it again", () => {
    const store = new McpConfigStore(storePath());
    store.addServer(stdioServer());

    store.updateServer("filesystem", stdioServer({ enabled: false }));
    expect(store.getServer("filesystem")?.enabled).toBe(false);

    store.updateServer("filesystem", stdioServer({ enabled: true }));
    expect(store.getServer("filesystem")?.enabled).toBe(true);
  });

  test("listServers still returns disabled servers -- Settings has to show them", () => {
    const store = new McpConfigStore(storePath());
    store.addServer(stdioServer({ enabled: false }));
    store.addServer(httpServer());

    expect(store.listServers().map((s) => [s.name, s.enabled])).toEqual([
      ["filesystem", false],
      ["linear", true],
    ]);
  });

  test("saving a disabled server still counts as taking ownership of MCP config", () => {
    const store = new McpConfigStore(storePath());
    store.addServer(stdioServer({ enabled: false }));

    expect(store.getStatus()).toEqual({ mcpConfigured: true });
  });
});

describe("resolveMcpServers: disabled servers never reach the boot path", () => {
  const envJson = JSON.stringify([
    { name: "envserver", command: "node", args: ["env-server.js"] },
  ]);

  test("a disabled server is filtered out of what gets connected", () => {
    const store = new McpConfigStore(storePath());
    store.addServer(stdioServer({ enabled: false }));
    store.addServer(httpServer());

    expect(resolveMcpServers(store, undefined).servers.map((s) => s.name)).toEqual([
      "linear",
    ]);
  });

  test("but it is still present in allServers, so the UI can show and re-enable it", () => {
    // Without this the user saves a failing server, it vanishes from Settings,
    // and there is no way back -- the same dead end the boot loop created.
    const store = new McpConfigStore(storePath());
    store.addServer(stdioServer({ enabled: false }));
    store.addServer(httpServer());

    const resolved = resolveMcpServers(store, undefined);

    expect(resolved.allServers.map((s) => [s.name, s.enabled])).toEqual([
      ["filesystem", false],
      ["linear", true],
    ]);
  });

  test("with everything enabled, servers and allServers agree", () => {
    const store = new McpConfigStore(storePath());
    store.addServer(stdioServer());
    store.addServer(httpServer());

    const resolved = resolveMcpServers(store, undefined);

    expect(resolved.servers).toEqual(resolved.allServers);
  });

  test("a saved store whose only server is disabled connects nothing -- and still ignores the env var", () => {
    // "Saved wins entirely" is unchanged: disabling the last server must not
    // quietly reinstate the env servers, for the same reason removing it does
    // not.
    const store = new McpConfigStore(storePath());
    store.addServer(stdioServer({ enabled: false }));

    const resolved = resolveMcpServers(store, envJson);

    expect(resolved.source).toBe("saved");
    expect(resolved.servers).toEqual([]);
    expect(resolved.allServers.map((s) => s.name)).toEqual(["filesystem"]);
  });

  test("env servers resolve as enabled and are not filtered", () => {
    const store = new McpConfigStore(storePath());

    const resolved = resolveMcpServers(store, envJson);

    expect(resolved.servers.map((s) => s.name)).toEqual(["envserver"]);
    expect(resolved.servers[0]?.enabled).toBe(true);
    expect(resolved.allServers).toEqual(resolved.servers);
  });
});

// ---------------------------------------------------------------------------
// The saved config still reaches the agent through the approval seam
// ---------------------------------------------------------------------------

/**
 * Safety pin (task note): connecting an MCP server hands the agent new tools
 * that run unsandboxed, exactly like the built-in ones. `server.ts` wraps the
 * *merged* tool set in `withApproval` precisely so a future prompting policy
 * sees MCP calls too. Routing MCP config through a store must not quietly
 * bypass that seam, so these tests drive the real store -> resolve ->
 * connect -> merge -> withApproval path and assert the gate still bites.
 */
describe("MCP tools from saved config still flow through the approval seam", () => {
  function fakeFactories(onCall: () => void): {
    factories: McpConnectionFactories;
    seenConfigs: StoredMcpServer[];
  } {
    const seenConfigs: StoredMcpServer[] = [];
    const client: McpClientLike = {
      async connect() {},
      async listTools() {
        return { tools: [{ name: "lookup", description: "look things up" }] };
      },
      async callTool(params) {
        onCall();
        return { content: [{ type: "text", text: `ran ${params.name}` }] };
      },
    };
    return {
      seenConfigs,
      factories: {
        createTransport: (config) => {
          seenConfigs.push(config as StoredMcpServer);
          return {};
        },
        createClient: () => client,
      },
    };
  }

  test("connectConfiguredMcpServers accepts the resolved config objects directly", async () => {
    const store = new McpConfigStore(storePath());
    store.addServer(stdioServer({ name: "srv", env: { TOKEN: "realsecretvalue" } }));
    const { factories, seenConfigs } = fakeFactories(() => {});

    const resolved = resolveMcpServers(store, undefined);
    const set = await connectConfiguredMcpServers(resolved.servers, factories);

    expect(set.openAiTools).toHaveLength(1);
    expect((set.openAiTools[0] as { function: { name: string } }).function.name).toBe(
      "srv__lookup"
    );
    // The transport factory receives the whole stored config -- transport kind,
    // env, url and headers included -- so it can build a stdio *or* an http
    // transport rather than assuming stdio.
    expect(seenConfigs[0]).toMatchObject({
      name: "srv",
      transport: "stdio",
      command: "npx",
      env: { TOKEN: "realsecretvalue" },
    });
  });

  test("an http server's url and headers reach the transport factory", async () => {
    const store = new McpConfigStore(storePath());
    store.addServer(
      httpServer({ name: "remote", headers: { Authorization: "Bearer realtokenvalue" } })
    );
    const { factories, seenConfigs } = fakeFactories(() => {});

    await connectConfiguredMcpServers(resolveMcpServers(store, undefined).servers, factories);

    expect(seenConfigs[0]).toMatchObject({
      name: "remote",
      transport: "http",
      url: "https://mcp.linear.app/mcp",
      headers: { Authorization: "Bearer realtokenvalue" },
    });
  });

  test("a denying policy blocks an MCP tool call and the server is never reached", async () => {
    const store = new McpConfigStore(storePath());
    store.addServer(stdioServer({ name: "srv" }));
    let underlyingCalls = 0;
    const { factories } = fakeFactories(() => {
      underlyingCalls += 1;
    });

    const mcpTools = await connectConfiguredMcpServers(
      resolveMcpServers(store, undefined).servers,
      factories
    );
    const guarded = withApproval(mergeToolSets(mcpTools), {
      approve: async () => "rejected",
    });

    const result = await guarded.callTool("srv__lookup", { q: "x" });

    expect(result.content).toContain("denied");
    expect(underlyingCalls).toBe(0);
  });

  test("the shipped YOLO policy still lets an MCP tool call through unchanged", async () => {
    const store = new McpConfigStore(storePath());
    store.addServer(stdioServer({ name: "srv" }));
    let underlyingCalls = 0;
    const { factories } = fakeFactories(() => {
      underlyingCalls += 1;
    });

    const mcpTools = await connectConfiguredMcpServers(
      resolveMcpServers(store, undefined).servers,
      factories
    );
    const guarded = withApproval(mergeToolSets(mcpTools), yoloApprovalPolicy);

    const result = await guarded.callTool("srv__lookup", { q: "x" });

    expect(result.content).toBe("ran lookup");
    expect(underlyingCalls).toBe(1);
  });

  test("the JSON-string form of connectConfiguredMcpServers still works (env fallback path)", async () => {
    const { factories } = fakeFactories(() => {});

    const set = await connectConfiguredMcpServers(
      JSON.stringify([{ name: "srv", command: "node", args: ["s.js"] }]),
      factories
    );

    expect((set.openAiTools[0] as { function: { name: string } }).function.name).toBe(
      "srv__lookup"
    );
  });
});
