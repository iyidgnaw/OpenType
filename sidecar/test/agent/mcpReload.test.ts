/**
 * STAGE-1 (red) tests for hot-reloading MCP server connections.
 *
 * ---------------------------------------------------------------------------
 * The gap
 * ---------------------------------------------------------------------------
 *
 * MCP servers are connected exactly once, at sidecar boot
 * (`server.ts`: `const mcpTools = startMcpConnections(resolvedMcpServers.servers)`).
 * A server added, edited, enabled, disabled or deleted through the Settings
 * panel (`PUT /config/mcp/:name` etc., `agent/mcpConfigRoutes.ts`) is
 * persisted to `McpConfigStore` but has no effect on the running agent until
 * the sidecar restarts -- `docs/superpowers/specs/2026-08-09-current-system-state.md`
 * §11 names this as a known gap, and the Settings panel currently just says
 * so rather than fixing it.
 *
 * `agent/toolSets.ts`'s `mergeToolSets` already reads through to its member
 * sets' `openAiTools` on every access (see its doc comment) rather than
 * snapshotting them once, so a merged set built at boot time will observe a
 * swap of the underlying MCP tool set happening later -- no change needed
 * there. What's missing is a *reloadable* MCP tool set to swap underneath it,
 * and a place that calls it.
 *
 * ---------------------------------------------------------------------------
 * The contract stage 3 must implement, in `src/agent/mcpClient.ts`
 * ---------------------------------------------------------------------------
 *
 *   export interface ReloadableMcpToolSet extends LazyMcpToolSet {
 *     reload(servers: McpServerConfig[]): void;
 *   }
 *   export function createReloadableMcpToolSet(
 *     servers: McpServerConfig[],
 *     options?: McpConnectOptions
 *   ): ReloadableMcpToolSet;
 *
 * Six properties, one test group each below:
 *
 *   1. Before any reload, behaves exactly like `startMcpConnections`: returns
 *      synchronously, `openAiTools` fills in as servers connect, `status()`
 *      reports connecting/connected/failed/timedOut, `ready` settles and
 *      never rejects.
 *   2. `reload(newServers)` also returns synchronously -- reload must never
 *      reintroduce the boot-blocking hazard `startMcpConnections`'s own doc
 *      comment describes, just at a later point in the process's life. The
 *      new servers' tools appear in `openAiTools` once they connect.
 *   3. A server removed by the reload loses its tools: they disappear from
 *      `openAiTools`, and calling one afterwards fails the way an unknown
 *      tool already fails (`mcpClient.ts`'s own `Unknown MCP tool: ...`),
 *      not by routing into a now-dead client.
 *   4. `status()` after a reload describes the new server list, not the old
 *      one -- matched by name. A server that is gone must not linger in the
 *      report; a reordered/kept one and a brand new one must both appear
 *      correctly.
 *   5. The old clients are closed when reload swaps them out -- otherwise a
 *      stdio MCP server's `npx` child process leaks for the sidecar's
 *      lifetime on every save.
 *   5b. (owner decision, added after stage-2 review) Reload does NOT close
 *      and reconnect servers whose config is unchanged -- only the ones that
 *      actually differ (by value, not by name/reference) get torn down and
 *      replaced. A wholesale teardown-and-reconnect on every save would blank
 *      the agent's whole toolset for the length of the slowest server's
 *      reconnect (a cold `npx -y ...` already exceeds the sidecar's own 5s
 *      boot budget) just to apply an edit to one of several servers.
 *   6. A tool call already in flight when a reload happens is not broken by
 *      it: it holds its own client reference and is allowed to finish (or
 *      fail on its own terms) rather than being cancelled or misrouted.
 *
 * Reuses the fake-client/factory/manual-delay machinery already established
 * in `mcpClient.test.ts` and `mcpBootResilience.test.ts` rather than building
 * a second one.
 */
import { describe, expect, test } from "bun:test";
import {
  createReloadableMcpToolSet,
  type McpClientLike,
  type McpConnectionFactories,
  type McpServerConfig,
} from "../../src/agent/mcpClient";

/** A promise that never settles -- a server that accepts and then says nothing. */
function never<T = void>(): Promise<T> {
  return new Promise<T>(() => {});
}

/**
 * A budget that expires only when the test says so -- lets a test observe a
 * server mid-handshake, then time it out on demand. Same shape as
 * `mcpStartupErrorReporting.test.ts`'s `manualDelay`, landed on a macrotask so
 * a fake client's own microtask resolution always wins the race first.
 */
function manualDelay(): { delay: (ms: number) => Promise<void>; expire: () => void } {
  let expire!: () => void;
  const spent = new Promise<void>((resolve) => {
    expire = () => {
      setTimeout(resolve, 0);
    };
  });
  return { delay: () => spent, expire };
}

const neverExpiringDelay = () => never<void>();

interface FakeClientOptions {
  tools?: Array<{ name: string; description?: string }>;
  connect?: () => Promise<void>;
  onCallTool?: (params: { name: string; arguments?: unknown }) => Promise<unknown> | unknown;
  onClose?: () => void;
}

function makeFakeClient(options: FakeClientOptions = {}): McpClientLike {
  return {
    async connect() {
      if (options.connect) {
        return options.connect();
      }
    },
    async listTools() {
      return { tools: options.tools ?? [] };
    },
    async callTool(params) {
      const content = options.onCallTool
        ? await options.onCallTool(params)
        : { called: params.name, arguments: params.arguments };
      return { content: [{ type: "text", text: JSON.stringify(content) }] };
    },
    async close() {
      options.onClose?.();
    },
  };
}

/**
 * Resolves the client to hand back purely from the *name* on the config
 * `createClient` receives -- same pattern as the sibling MCP test files, and
 * the only pattern that survives concurrent connects (call order can't be
 * used to infer which server a bare `createClient()` belongs to).
 */
function makeFactories(clientsByName: Record<string, McpClientLike>): McpConnectionFactories {
  return {
    createTransport: (config: McpServerConfig) => ({ __fakeTransportFor: config.name }),
    createClient: (config: McpServerConfig) => {
      const client = clientsByName[config.name];
      if (!client) {
        throw new Error(`no fake client configured for server ${config.name}`);
      }
      return client;
    },
  };
}

function toolName(config: { name: string }, tool: { name: string }): string {
  return `${config.name}__${tool.name}`;
}

/**
 * Same as `makeFactories`, plus a per-name count of how many times
 * `createClient` was actually invoked -- the signal a "no second handshake"
 * assertion needs. `makeFactories` alone can't tell "the same client object
 * happened to still be around" apart from "a fresh connection was started",
 * because its fake map returns the same object for a given name either way.
 */
function makeCountingFactories(clientsByName: Record<string, McpClientLike>): {
  factories: McpConnectionFactories;
  createClientCalls: Record<string, number>;
} {
  const createClientCalls: Record<string, number> = {};
  const factories: McpConnectionFactories = {
    createTransport: (config: McpServerConfig) => ({ __fakeTransportFor: config.name }),
    createClient: (config: McpServerConfig) => {
      createClientCalls[config.name] = (createClientCalls[config.name] ?? 0) + 1;
      const client = clientsByName[config.name];
      if (!client) {
        throw new Error(`no fake client configured for server ${config.name}`);
      }
      return client;
    },
  };
  return { factories, createClientCalls };
}

// ---------------------------------------------------------------------------
// 1. Before any reload: identical to startMcpConnections
// ---------------------------------------------------------------------------

describe("createReloadableMcpToolSet before any reload", () => {
  test("returns synchronously, and openAiTools fills in as servers connect", () => {
    const alpha: McpServerConfig = { name: "alpha", command: "node", args: ["a.js"] };
    const factories = makeFactories({
      alpha: makeFakeClient({ tools: [{ name: "lookup" }] }),
    });

    const set = createReloadableMcpToolSet([alpha], { factories });

    // Nothing has been awaited yet -- if this constructor blocked on the
    // connection, this assertion would still run before the fake client's
    // `connect` promise could resolve, so an empty set here isn't proof of
    // synchronicity by itself, but a *thrown* or hung call here would be.
    expect(Array.isArray(set.openAiTools)).toBe(true);
    expect(typeof set.reload).toBe("function");
  });

  test("status() reports connecting -> connected/failed/timedOut, ready settles and never rejects", async () => {
    const good: McpServerConfig = { name: "good", command: "node", args: ["good.js"] };
    const bad: McpServerConfig = { name: "bad", command: "node", args: ["bad.js"] };
    const hung: McpServerConfig = { name: "hung", command: "node", args: ["hung.js"] };
    const factories = makeFactories({
      good: makeFakeClient({ tools: [{ name: "ok" }] }),
      bad: makeFakeClient({
        connect: async () => {
          throw new Error("boom");
        },
      }),
      hung: makeFakeClient({ connect: () => never() }),
    });
    const budget = manualDelay();

    const set = createReloadableMcpToolSet([good, bad, hung], {
      factories,
      delay: budget.delay,
      connectTimeoutMs: 1_000,
    });

    expect(set.status().servers.map((s) => s.state)).toEqual([
      "connecting",
      "connecting",
      "connecting",
    ]);

    budget.expire();
    const report = await set.ready;

    expect(report.servers).toEqual([
      { name: "good", state: "connected", toolCount: 1 },
      expect.objectContaining({ name: "bad", state: "failed" }),
      expect.objectContaining({ name: "hung", state: "timedOut" }),
    ]);
    expect(set.openAiTools).toEqual([
      {
        type: "function",
        function: { name: "good__ok", description: "", parameters: { type: "object", properties: {} } },
      },
    ]);
  });
});

// ---------------------------------------------------------------------------
// 2. reload() also returns synchronously, and its servers' tools arrive later
// ---------------------------------------------------------------------------

describe("reload()", () => {
  test("returns synchronously -- a hung new server does not block the call", () => {
    const factories = makeFactories({
      hungOnReload: makeFakeClient({ connect: () => never() }),
    });
    const set = createReloadableMcpToolSet([], { factories, delay: neverExpiringDelay });

    expect(() => {
      set.reload([{ name: "hungOnReload", command: "node", args: [] }]);
    }).not.toThrow();

    // Called synchronously and inspected on the same tick, with nothing
    // awaited in between -- a set that blocked reload() on the new server's
    // handshake would never let this line run at all.
    expect(set.status().servers.map((s) => s.name)).toEqual(["hungOnReload"]);
    expect(set.status().servers[0]?.state).toBe("connecting");
    expect(set.openAiTools).toEqual([]);
  });

  test("the reloaded servers' tools appear in openAiTools once they connect", async () => {
    const factories = makeFactories({
      searchServer: makeFakeClient({
        tools: [{ name: "search", description: "Search the web" }],
      }),
    });
    const set = createReloadableMcpToolSet([], { factories });

    set.reload([{ name: "searchServer", command: "node", args: ["s.js"] }]);
    const report = await set.ready;

    expect(report.servers).toEqual([
      { name: "searchServer", state: "connected", toolCount: 1 },
    ]);
    expect(set.openAiTools).toEqual([
      {
        type: "function",
        function: {
          name: "searchServer__search",
          description: "Search the web",
          parameters: { type: "object", properties: {} },
        },
      },
    ]);
  });
});

// ---------------------------------------------------------------------------
// 3. A server removed by reload loses its tools and its calls fail cleanly
// ---------------------------------------------------------------------------

describe("removing a server via reload", () => {
  test("its tools disappear from openAiTools and calling one fails like an unknown tool", async () => {
    const alpha: McpServerConfig = { name: "alpha", command: "node", args: ["a.js"] };
    const beta: McpServerConfig = { name: "beta", command: "node", args: ["b.js"] };
    const factories = makeFactories({
      alpha: makeFakeClient({ tools: [{ name: "keep" }] }),
      beta: makeFakeClient({ tools: [{ name: "lookup" }] }),
    });
    const set = createReloadableMcpToolSet([alpha, beta], { factories });
    await set.ready;
    expect(set.openAiTools.map((t: any) => t.function.name).sort()).toEqual([
      "alpha__keep",
      "beta__lookup",
    ]);

    set.reload([alpha]);
    await set.ready;

    const names = set.openAiTools.map((t: any) => t.function.name);
    expect(names).toContain("alpha__keep");
    expect(names).not.toContain("beta__lookup");

    await expect(set.callTool("beta__lookup", {})).rejects.toThrow(/unknown/i);
  });
});

// ---------------------------------------------------------------------------
// 4. status() after reload describes the new list, matched by name
// ---------------------------------------------------------------------------

describe("status() after reload", () => {
  test("reflects exactly the new server list -- a dropped server does not linger, a new one appears", async () => {
    const alpha: McpServerConfig = { name: "alpha", command: "node", args: [] };
    const beta: McpServerConfig = { name: "beta", command: "node", args: [] };
    const gamma: McpServerConfig = { name: "gamma", command: "node", args: [] };
    const factories = makeFactories({
      alpha: makeFakeClient({ tools: [{ name: "a" }] }),
      beta: makeFakeClient({ tools: [{ name: "b" }] }),
      gamma: makeFakeClient({ tools: [{ name: "g" }] }),
    });
    const set = createReloadableMcpToolSet([alpha, beta], { factories });
    await set.ready;
    expect(set.status().servers.map((s) => s.name)).toEqual(["alpha", "beta"]);

    // Drop alpha, keep beta, add gamma -- reordered relative to the original
    // list, so a report that zipped old and new by position would misreport.
    set.reload([beta, gamma]);
    const report = await set.ready;

    const byName = Object.fromEntries(report.servers.map((s) => [s.name, s]));
    expect(Object.keys(byName).sort()).toEqual(["beta", "gamma"]);
    expect(byName.alpha).toBeUndefined();
    expect(byName.beta?.state).toBe("connected");
    expect(byName.gamma?.state).toBe("connected");
    expect(set.status().servers.map((s) => s.name)).toEqual(["beta", "gamma"]);
  });
});

// ---------------------------------------------------------------------------
// 5. Old clients are closed when reload swaps them out
// ---------------------------------------------------------------------------

describe("reload closes the clients it replaces", () => {
  test("every previously connected client is closed once its server is no longer current", async () => {
    const closed: string[] = [];
    const alpha: McpServerConfig = { name: "alpha", command: "node", args: [] };
    const beta: McpServerConfig = { name: "beta", command: "node", args: [] };
    const gamma: McpServerConfig = { name: "gamma", command: "node", args: [] };
    const factories = makeFactories({
      alpha: makeFakeClient({ tools: [{ name: "a" }], onClose: () => closed.push("alpha") }),
      beta: makeFakeClient({ tools: [{ name: "b" }], onClose: () => closed.push("beta") }),
      gamma: makeFakeClient({ tools: [{ name: "g" }], onClose: () => closed.push("gamma") }),
    });
    const set = createReloadableMcpToolSet([alpha, beta], { factories });
    await set.ready;
    expect(closed).toEqual([]);

    set.reload([gamma]);
    await set.ready;
    // Give any best-effort close() a microtask to run, matching how
    // `startMcpConnections`'s own abandoned-client close path is fire-and-forget.
    await Promise.resolve();
    await Promise.resolve();

    expect(closed.sort()).toEqual(["alpha", "beta"]);
    // The new server's client must not have been closed along with the old ones.
    expect(closed).not.toContain("gamma");
  });

  test("a stdio server dropped by reload does not keep costing a live client for the process's lifetime", async () => {
    // Named for the actual failure this pins: skipping close() here leaks one
    // npx child process per Settings save, silently, for as long as the
    // sidecar keeps running.
    let alphaClosed = false;
    const alpha: McpServerConfig = { name: "alpha", command: "npx", args: ["-y", "@example/alpha"] };
    const factories = makeFactories({
      alpha: makeFakeClient({ tools: [{ name: "a" }], onClose: () => (alphaClosed = true) }),
    });
    const set = createReloadableMcpToolSet([alpha], { factories });
    await set.ready;

    set.reload([]);
    await set.ready;
    await Promise.resolve();
    await Promise.resolve();

    expect(alphaClosed).toBe(true);
  });
});

// ---------------------------------------------------------------------------
// 5b. Reload must not pay for connections it doesn't need to touch
// ---------------------------------------------------------------------------
//
// Decided by the owner (see team-lead's message): a reload closes and
// replaces only the servers whose configuration actually changed, drops the
// ones that are gone, connects the ones that are new, and leaves an
// *unchanged* server's live connection completely alone -- same client, no
// second handshake, no close.
//
// The reason this is load-bearing and not just tidiness: a stdio server is an
// `npx` child that can take real wall-clock seconds to come back (a cold
// `npx -y ...` fetch already exceeds the sidecar's own 5s boot-readiness
// budget -- see `startMcpConnections`'s doc comment). A wholesale
// teardown-and-reconnect on every save would mean editing one server out of
// five costs the user every *other* server's live process and blanks the
// agent's whole MCP toolset for the length of the slowest reconnect, on every
// Settings save. Property 5's tests above ("every previously connected client
// is closed...") remain valid under this: every case there is a server that
// is genuinely gone from the new list (no name overlap at all), so it's
// correctly closed either way -- these tests are what's new: a server that
// *is* still in the new list, unchanged.
//
// "Unchanged" is a deep equality over the server's whole `McpServerConfig`
// (name, transport, command, args, env, url, headers -- everything this
// function's input type actually carries; see the scope note at the bottom
// of this block for why `enabled` isn't part of that list here). The tests
// below pin that a same-*name* server with one different field value must
// NOT be treated as unchanged, so an implementation that only compares by
// name -- or only the fields exercised by a single example -- can't pass.
describe("reload preserves an unchanged server's live connection", () => {
  test("a server whose config is unchanged is neither closed nor reconnected -- compared by value, not by object reference", async () => {
    const closed: string[] = [];
    const alpha: McpServerConfig = { name: "alpha", command: "node", args: ["a.js"] };
    const betaV1: McpServerConfig = {
      name: "beta",
      command: "node",
      args: ["b.js"],
      env: { TOKEN: "x" },
    };
    const gamma: McpServerConfig = { name: "gamma", command: "node", args: ["g.js"] };
    const { factories, createClientCalls } = makeCountingFactories({
      alpha: makeFakeClient({ tools: [{ name: "a" }], onClose: () => closed.push("alpha") }),
      beta: makeFakeClient({ tools: [{ name: "b" }], onClose: () => closed.push("beta") }),
      gamma: makeFakeClient({ tools: [{ name: "g" }], onClose: () => closed.push("gamma") }),
    });
    const set = createReloadableMcpToolSet([alpha, betaV1], { factories });
    await set.ready;
    expect(createClientCalls.beta).toBe(1);

    // A structurally identical config for beta, but a genuinely different JS
    // object -- this is what forces the comparison to be by value: an
    // implementation that (mis)treats "unchanged" as "the exact same object
    // reference survived" would see this as a change and reconnect beta,
    // failing the assertions below.
    const betaV1Again: McpServerConfig = {
      name: "beta",
      command: "node",
      args: ["b.js"],
      env: { TOKEN: "x" },
    };
    set.reload([betaV1Again, gamma]);
    await set.ready;
    // Give any close()/reconnect side effects a couple of microtasks to land,
    // matching the pattern used throughout this file.
    await Promise.resolve();
    await Promise.resolve();

    expect(closed).toContain("alpha"); // genuinely dropped -- correctly closed
    expect(closed).not.toContain("beta"); // unchanged -- must be left alone
    expect(createClientCalls.beta).toBe(1); // still 1: no second handshake
    expect(set.status().servers.map((s) => s.name).sort()).toEqual(["beta", "gamma"]);
    expect(set.openAiTools.map((t: any) => t.function.name).sort()).toEqual([
      "beta__b",
      "gamma__g",
    ]);
  });

  test("a value-only change to a same-named server forces close + reconnect -- name alone is not 'unchanged'", async () => {
    const closed: string[] = [];
    const alpha: McpServerConfig = { name: "alpha", command: "node", args: ["a.js"] };
    const betaV1: McpServerConfig = { name: "beta", command: "node", args: ["b.js"] };
    const { factories, createClientCalls } = makeCountingFactories({
      alpha: makeFakeClient({ tools: [{ name: "a" }], onClose: () => closed.push("alpha") }),
      beta: makeFakeClient({ tools: [{ name: "b" }], onClose: () => closed.push("beta") }),
    });
    const set = createReloadableMcpToolSet([alpha, betaV1], { factories });
    await set.ready;
    expect(createClientCalls.beta).toBe(1);

    // Same name as betaV1, one field differs (`args`). A comparison keyed on
    // name alone would call this "unchanged" and leave the stale connection
    // (still running the old args) in place.
    const betaV2: McpServerConfig = {
      name: "beta",
      command: "node",
      args: ["b.js", "--verbose"],
    };
    set.reload([alpha, betaV2]);
    await set.ready;
    await Promise.resolve();
    await Promise.resolve();

    expect(closed).toContain("beta");
    expect(closed).not.toContain("alpha"); // alpha is the control: truly unchanged, must stay alone
    expect(createClientCalls.beta).toBe(2); // closed and reconnected
    expect(createClientCalls.alpha).toBe(1);
  });

  /**
   * The previous test only ever varies `args`. That leaves room for a
   * plausible partial port -- an implementation that compares only
   * `{command, args}` (the fields visible in that one test) -- to pass
   * everything above while still treating an `env`-only edit as "unchanged"
   * and keeping the stale connection. `env` is the field worth a dedicated
   * case rather than folding it into a doc comment: it is where a real user
   * edit carries a second-order cost beyond "my change didn't apply" -- a
   * user who rotates a leaked API token and finds the agent still calling
   * through the old credential has a small security problem stacked on top
   * of the UX one.
   */
  test("an env-only change to a same-named server forces close + reconnect -- rotating a credential must not leave the old one live", async () => {
    const closed: string[] = [];
    const alpha: McpServerConfig = { name: "alpha", command: "node", args: ["a.js"] };
    const betaV1: McpServerConfig = {
      name: "beta",
      command: "node",
      args: ["b.js"],
      env: { TOKEN: "leaked-old-token" },
    };
    const { factories, createClientCalls } = makeCountingFactories({
      alpha: makeFakeClient({ tools: [{ name: "a" }], onClose: () => closed.push("alpha") }),
      beta: makeFakeClient({ tools: [{ name: "b" }], onClose: () => closed.push("beta") }),
    });
    const set = createReloadableMcpToolSet([alpha, betaV1], { factories });
    await set.ready;
    expect(createClientCalls.beta).toBe(1);

    // Same name, same command, same args -- only `env` differs. A
    // `{command, args}`-only comparison would call this "unchanged" and keep
    // routing tool calls through the client still holding the old token.
    const betaV2: McpServerConfig = {
      name: "beta",
      command: "node",
      args: ["b.js"],
      env: { TOKEN: "rotated-new-token" },
    };
    set.reload([alpha, betaV2]);
    await set.ready;
    await Promise.resolve();
    await Promise.resolve();

    expect(closed).toContain("beta");
    expect(closed).not.toContain("alpha");
    expect(createClientCalls.beta).toBe(2);
    expect(createClientCalls.alpha).toBe(1);
  });

  // Scope decision on the remaining fields (`enabled`, `url`, `headers`),
  // left as reasoning rather than more tests:
  //
  // - `enabled` has no dedicated case here because it can't produce a
  //   same-name-different-field input at this layer in the first place.
  //   `McpServerConfig` (what `reload()` accepts) has no `enabled` field at
  //   all -- only `StoredMcpServer` does -- and by the time a server list
  //   reaches here, `resolveMcpServers`/the config routes have already
  //   filtered to enabled-only (property 7's "passes only the enabled
  //   ones"). Flipping a server off therefore doesn't arrive as "same name,
  //   `enabled` now false" -- it arrives as that server being absent from
  //   the next `reload()` call entirely, which is exactly what property 3
  //   ("removing a server via reload") already pins: its tools disappear and
  //   calling one fails immediately. A dedicated `enabled` case here would
  //   have to smuggle a field the type doesn't carry past this function's
  //   actual contract to test something property 3 already covers.
  // - `url`/`headers` are the http-transport counterparts of `command`/`args`
  //   and `env` and would exercise the identical comparison logic on a
  //   differently-shaped config -- not a new code path. Between `args` and
  //   `env` above, both "a plain field" and "the credential-carrying map"
  //   are already covered on the stdio side; a second, structurally
  //   identical pair of tests for http was judged not to earn its keep
  //   against the doc comment stating the full field list.
});

// ---------------------------------------------------------------------------
// 6. An in-flight call survives a reload that removes its server
// ---------------------------------------------------------------------------

describe("a tool call already in flight when a reload happens", () => {
  test("is allowed to finish on the client it started with, not cancelled or misrouted", async () => {
    let resolveCall!: (value: unknown) => void;
    const pendingResult = new Promise((resolve) => {
      resolveCall = resolve;
    });
    let closedWhileInFlight = false;
    const alpha: McpServerConfig = { name: "alpha", command: "node", args: [] };
    const factories = makeFactories({
      alpha: makeFakeClient({
        tools: [{ name: "slow" }],
        onCallTool: () => pendingResult,
        onClose: () => {
          closedWhileInFlight = true;
        },
      }),
    });
    const set = createReloadableMcpToolSet([alpha], { factories });
    await set.ready;

    // Start the call, but do not await it yet.
    const inFlight = set.callTool("alpha__slow", { q: "x" });

    // Reload removes alpha entirely -- its client is closed as part of the
    // swap (property 5), while the call above is still pending.
    set.reload([]);
    await set.ready;
    await Promise.resolve();
    expect(closedWhileInFlight).toBe(true);

    // The call must still complete successfully, on the client it actually
    // started with -- reload must not have cancelled it or thrown
    // "Unknown MCP tool" out from under an already-dispatched call.
    resolveCall({ ok: true });
    const result = await inFlight;
    expect(JSON.parse(result.content)).toEqual({ ok: true });
  });
});
