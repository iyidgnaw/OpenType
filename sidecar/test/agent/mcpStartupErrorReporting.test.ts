/**
 * STAGE-1 (red) tests for the **unfinished half** of §G of
 * `docs/superpowers/specs/2026-08-15-product-batch-plan.md`:
 *
 *   「跳过的 server 要能被用户看见：`GET /config/mcp` 的返回里带
 *    `lastStartupError`，MCP 面板那一行显示「启动超时，已跳过」。
 *    **静默跳过等于换一个静默失败**。」
 *
 * ---------------------------------------------------------------------------
 * Why this file is narrower than §G reads
 * ---------------------------------------------------------------------------
 *
 * §G was written against `current-state` §11's boot-path-hazard bullet, and
 * both are stale: the connect half of §G already shipped in commit `1245eb7`
 * ("Stop one hung MCP server from bricking the app"), which is an ancestor of
 * 1.0.0. `startMcpConnections` already bounds every server individually
 * (`MCP_CONNECT_TIMEOUT_MS`, overridable per call via `connectTimeoutMs`, with
 * an injectable `delay` so no test sleeps), already connects concurrently, and
 * already records each outcome as `connecting | connected | failed | timedOut`
 * with an `error` string. `server.ts` no longer awaits any of it before
 * `Bun.serve`. All of that is pinned by `test/agent/mcpBootResilience.test.ts`
 * and is green -- re-asserting it here would add a second fake-transport
 * approach to the same behavior, not coverage:
 *
 *   §G / brief item                      already covered by, in mcpBootResilience.test.ts
 *   -----------------------------------  -----------------------------------------------
 *   hung server abandoned after budget   "a hung server is abandoned and reported as timedOut"
 *   ...and the caller is never blocked   "a server whose connect() never resolves does not block the returned set"
 *   ...including the awaiting entry point "connectConfiguredMcpServers is bounded by the same per-server budget"
 *   a later healthy server still connects "one hung server costs only its own tools -- the others still connect"
 *   a fast server is unaffected          "a slow server that answers within its budget still contributes its tools"
 *   timed-out vs failed are distinct     "a server that fails outright is reported as failed, with its real error"
 *
 * What is genuinely missing is the **exit**: that report reaches nobody. The
 * `LazyMcpToolSet` returned in `main()` is merged into the tool set and its
 * `status()` is never read, and `buildMcpConfigRoutes` is constructed with
 * `{ envJson }` alone. So today a server that times out at boot is skipped
 * *silently* -- the MCP panel shows the row exactly as it shows a working one,
 * and the user's model of the product ("I saved it, so the agent has it") is
 * wrong with nothing on screen to correct it. That is the failure §G's last
 * bullet names, and this file is red on precisely it.
 *
 * ---------------------------------------------------------------------------
 * The contract stage 3 must implement
 * ---------------------------------------------------------------------------
 *
 * In `src/agent/mcpConfigRoutes.ts`:
 *
 *   export interface McpConfigRouteDeps {
 *     probeMcpServer: ...;                       // unchanged
 *     envJson: string | undefined;               // unchanged
 *     // NEW. A getter, deliberately -- see "read per request" below. Optional,
 *     // so the ~50 existing route tests (and any assembly that has no MCP tool
 *     // set to hand over) keep working with no `lastStartupError` anywhere.
 *     connectionReport?: () => McpConnectionReport;
 *   }
 *
 * and each server row in `GET /config/mcp` gains:
 *
 *   lastStartupError?: string;   // absent unless that server failed or timed out
 *
 * In `src/server.ts`, `buildApp` gains a 13th optional parameter threaded into
 * those deps, and `main()` passes `mcpTools.status`:
 *
 *   mcpConnectionReport?: () => McpConnectionReport
 *
 * Three properties are load-bearing and each has a test below:
 *
 * - **Read per request, not captured at build time.** Routes are built during
 *   boot, when every server is still `connecting`; the connections settle
 *   seconds later and the user opens the panel later still. A snapshot taken at
 *   build time would permanently report "no errors" -- i.e. exactly the silent
 *   skip this item exists to end. Hence a getter, not a value.
 * - **Matched by name, never by position.** The route lists `allServers`
 *   (disabled ones included, so they stay recoverable) while only the *enabled*
 *   subset is ever connected, so the two lists differ in length and order the
 *   moment one server is switched off. Zipping by index would pin a failure on
 *   an innocent row.
 * - **A timeout and an outright failure stay distinguishable in the text.** The
 *   user's fix differs -- "this server is too slow / unreachable, it was
 *   skipped" versus "npx isn't on PATH" -- and the panel has one string to
 *   render.
 *
 * Not demanded here: any change to the response's top-level shape. It stays
 * `{ configured, source, servers }` -- `mcpConfigRoutes.test.ts`'s first test
 * asserts that with a strict `toEqual`, and this is per-server information.
 *
 * NOTE for stage 3 on the budget value: §G says 8s, `MCP_CONNECT_TIMEOUT_MS` is
 * 12s. That is not drift to "fix" -- 8s was argued when connecting still
 * blocked `Bun.serve` and had to fit inside Swift's 5s readiness budget, and
 * the shipped design removed that constraint. No test here pins either number.
 *
 * No test in this file sleeps: `delay` is injected, in a manually-expired shape
 * so a connection can be observed mid-flight and then timed out on demand.
 */
import { describe, expect, test, beforeEach, afterEach } from "bun:test";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createRouter } from "../../src/router";
import { openDatabase } from "../../src/memory/db";
import { MemoryStore } from "../../src/memory/MemoryStore";
import { ConversationStore } from "../../src/memory/conversations";
import { ProviderConfigStore } from "../../src/provider/configStore";
import { buildApp } from "../../src/server";
import type { AgentChatFn } from "../../src/agent/loop";
import type { ToolSet } from "../../src/agent/toolSets";
import {
  startMcpConnections,
  type McpClientLike,
  type McpConnectionFactories,
  type McpConnectionReport,
  type McpServerConfig,
} from "../../src/agent/mcpClient";
import { McpConfigStore, resolveMcpServers } from "../../src/agent/mcpConfigStore";
import {
  buildMcpConfigRoutes,
  MCP_STARTUP_TIMEOUT_PREFIX,
  type McpConfigRouteDeps,
} from "../../src/agent/mcpConfigRoutes";

// ---------------------------------------------------------------------------
// Fakes -- the same shape `mcpBootResilience.test.ts` established: a client
// resolved by the *name* on the config handed to `createClient`, and an
// injected budget so nothing here waits out a real duration.
// ---------------------------------------------------------------------------

/** A promise that never settles -- a server that accepts and then says nothing. */
function never<T = void>(): Promise<T> {
  return new Promise<T>(() => {});
}

function makeFakeClient(
  options: {
    tools?: Array<{ name: string; description?: string }>;
    connect?: () => Promise<void>;
  } = {}
): McpClientLike {
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
      return { content: [{ type: "text", text: JSON.stringify({ ran: params.name })}] };
    },
    async close() {},
  };
}

function makeFactories(
  clientsByName: Record<string, McpClientLike>
): McpConnectionFactories {
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

/**
 * A budget that expires only when the test says so. This is what lets one test
 * observe a server while it is still `connecting`, then time it out and look
 * again -- the whole point of the getter seam.
 *
 * Expiry lands on a *macrotask*, matching `nextTurnDelay` in
 * `mcpBootResilience.test.ts` and for the same reason: the fake clients settle
 * on microtasks, which always drain first, so "a server that answers at all
 * beats its budget" is ordering rather than timing. Resolving the promise
 * directly would make a healthy fake lose the race too, and a test whose
 * healthy server silently timed out would assert nothing.
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

/** A budget that never expires -- for servers expected to answer on their own. */
const neverExpiringDelay = () => never<void>();

/** Text that should read as "this server never answered", however it is worded. */
const TIMEOUT_LANGUAGE = /timed out|timeout|no response|did not (answer|respond)/i;

const SPAWN_FAILURE = "spawn npx ENOENT";

// ---------------------------------------------------------------------------

let dir: string;
let store: McpConfigStore;

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), "opentype-mcp-startup-errors-"));
  store = new McpConfigStore(join(dir, "mcp-servers.json"));
});

afterEach(() => {
  rmSync(dir, { recursive: true, force: true });
});

function save(name: string, over: Partial<Record<string, unknown>> = {}): void {
  store.addServer({
    name,
    transport: "stdio",
    command: "npx",
    args: ["-y", `@example/${name}`],
    ...over,
  });
}

/** Exactly what `main()` hands `startMcpConnections`: the enabled subset. */
function bootServers(): McpServerConfig[] {
  return resolveMcpServers(store, undefined).servers;
}

function makeApp(overrides: Partial<McpConfigRouteDeps> = {}) {
  return createRouter(buildMcpConfigRoutes(store, overrides));
}

async function getConfig(app: ReturnType<typeof createRouter>) {
  const res = await app(new Request("http://localhost/config/mcp", { method: "GET" }));
  const json = (await res.json()) as {
    servers: Array<{ name: string; lastStartupError?: string }>;
  };
  return {
    status: res.status,
    json,
    /** The rows keyed by name -- position is never what this feature is about. */
    byName: Object.fromEntries(json.servers.map((server) => [server.name, server])),
  };
}

// ---------------------------------------------------------------------------
// 1. A skipped server is visible in the config the panel reads
// ---------------------------------------------------------------------------

describe("GET /config/mcp surfaces why a server was skipped at startup", () => {
  test("a server that timed out carries a lastStartupError that reads as a timeout", async () => {
    save("hungServer");
    const factories = makeFactories({
      hungServer: makeFakeClient({ connect: () => never() }),
    });
    const budget = manualDelay();
    const connections = startMcpConnections(bootServers(), {
      factories,
      delay: budget.delay,
      connectTimeoutMs: 1_000,
    });
    budget.expire();
    const report = await connections.ready;
    const recorded = report.servers[0]?.error;
    expect(recorded).toEqual(expect.any(String));

    const app = makeApp({ connectionReport: () => connections.status() });
    const { status, byName } = await getConfig(app);

    expect(status).toBe(200);
    // The panel renders 「启动超时，已跳过」off this string; a row that looks
    // identical to a working one is the silent failure §G exists to close.
    expect(byName.hungServer?.lastStartupError).toEqual(expect.any(String));
    expect(byName.hungServer?.lastStartupError).toMatch(TIMEOUT_LANGUAGE);
    // ...and it is *this run's* recorded error reaching the row, not a constant
    // the route invented for every non-connected server. `TIMEOUT_LANGUAGE`
    // alone would be satisfied by a hardcoded "timed out", and that string
    // would then survive any later improvement to what `startMcpConnections`
    // records -- the report would be decoration again, one layer further on.
    // Containment, not equality: wrapping the recorded text is fine, replacing
    // it is what this rules out.
    expect(byName.hungServer?.lastStartupError).toContain(recorded!);
  });

  test("a server that failed outright carries its real error, not a timeout message", async () => {
    // The two are not interchangeable to the person reading the row: a timeout
    // means "unreachable or too slow, we skipped it", `spawn npx ENOENT` means
    // "your command is wrong". Same field, and it has to say which.
    save("badServer");
    const factories = makeFactories({
      badServer: makeFakeClient({
        connect: async () => {
          throw new Error(SPAWN_FAILURE);
        },
      }),
    });
    const connections = startMcpConnections(bootServers(), {
      factories,
      delay: neverExpiringDelay,
    });
    await connections.ready;

    const app = makeApp({ connectionReport: () => connections.status() });
    const { byName } = await getConfig(app);

    // Asserted first so the red here reads as "the field is missing" rather
    // than as `toContain`'s type complaint about `undefined`.
    expect(byName.badServer?.lastStartupError).toEqual(expect.any(String));
    expect(byName.badServer?.lastStartupError).toContain(SPAWN_FAILURE);
    expect(byName.badServer?.lastStartupError).not.toMatch(TIMEOUT_LANGUAGE);
  });

  test("a healthy server carries no lastStartupError while a hung one does", async () => {
    save("hungServer");
    save("healthyServer");
    const factories = makeFactories({
      hungServer: makeFakeClient({ connect: () => never() }),
      healthyServer: makeFakeClient({ tools: [{ name: "search" }] }),
    });
    const budget = manualDelay();
    const connections = startMcpConnections(bootServers(), {
      factories,
      delay: budget.delay,
      connectTimeoutMs: 1_000,
    });
    budget.expire();
    await connections.ready;
    // Precondition, stated so this test cannot go vacuous: the healthy server
    // really did connect rather than quietly timing out alongside the hung one.
    expect(connections.status().servers.map((server) => server.state)).toEqual([
      "timedOut",
      "connected",
    ]);

    const app = makeApp({ connectionReport: () => connections.status() });
    const { byName } = await getConfig(app);

    expect(byName.hungServer?.lastStartupError).toMatch(TIMEOUT_LANGUAGE);
    // Absent, not an empty string: "no error" must not render as a blank
    // warning line under a server that is working.
    expect(byName.healthyServer?.lastStartupError).toBeUndefined();
  });

  test("a server still connecting carries no lastStartupError -- in flight is not a failure", async () => {
    save("slowServer");
    const factories = makeFactories({
      slowServer: makeFakeClient({ connect: () => never() }),
    });
    const connections = startMcpConnections(bootServers(), {
      factories,
      // Budget not expired and never awaited: this server is mid-handshake,
      // which is what every server looks like for the first seconds of a launch.
      delay: manualDelay().delay,
      connectTimeoutMs: 1_000,
    });
    expect(connections.status().servers[0]?.state).toBe("connecting");

    const app = makeApp({ connectionReport: () => connections.status() });
    const { byName } = await getConfig(app);

    expect(byName.slowServer?.lastStartupError).toBeUndefined();
  });

  test("the report is read per request, not captured when the routes were built", async () => {
    // Routes are built during boot, while every server is still `connecting`.
    // A snapshot taken then would report "no errors" for the rest of the
    // process's life -- the silent skip, reintroduced one layer up.
    save("hungServer");
    const factories = makeFactories({
      hungServer: makeFakeClient({ connect: () => never() }),
    });
    const budget = manualDelay();
    const connections = startMcpConnections(bootServers(), {
      factories,
      delay: budget.delay,
      connectTimeoutMs: 1_000,
    });

    const app = makeApp({ connectionReport: () => connections.status() });

    const duringBoot = await getConfig(app);
    expect(duringBoot.byName.hungServer?.lastStartupError).toBeUndefined();

    budget.expire();
    await connections.ready;

    const afterSettling = await getConfig(app);
    expect(afterSettling.byName.hungServer?.lastStartupError).toMatch(TIMEOUT_LANGUAGE);
  });

  test("errors are matched to servers by name, not by position in the list", async () => {
    // The two lists genuinely differ: the response lists `allServers` so a
    // disabled server stays visible and re-enableable, while only the enabled
    // subset is ever connected. With `beta` off, `gamma` is index 2 in the
    // response and index 1 in the report -- zipping by index would blame
    // `beta`, a server that was never even started.
    save("alpha");
    save("beta", { enabled: false });
    save("gamma");
    const factories = makeFactories({
      alpha: makeFakeClient({ tools: [{ name: "ok" }] }),
      gamma: makeFakeClient({ connect: () => never() }),
    });
    const budget = manualDelay();
    const connections = startMcpConnections(bootServers(), {
      factories,
      delay: budget.delay,
      connectTimeoutMs: 1_000,
    });
    budget.expire();
    await connections.ready;

    const app = makeApp({ connectionReport: () => connections.status() });
    const { json, byName } = await getConfig(app);

    expect(json.servers.map((server) => server.name)).toEqual(["alpha", "beta", "gamma"]);
    expect(connections.status().servers).toMatchObject([
      { name: "alpha", state: "connected" },
      { name: "gamma", state: "timedOut" },
    ]);
    expect(byName.gamma?.lastStartupError).toMatch(TIMEOUT_LANGUAGE);
    expect(byName.alpha?.lastStartupError).toBeUndefined();
    // A server the boot path never learned about cannot have failed to start.
    expect(byName.beta?.lastStartupError).toBeUndefined();
  });

  test("with no connection report wired, no server carries a lastStartupError", async () => {
    // Keeps the dep optional: the ~50 tests in `mcpConfigRoutes.test.ts` build
    // these routes without one, and an assembly with no MCP tool set to report
    // on must answer the same shape it always did rather than inventing an
    // error.
    save("filesystem");
    const app = makeApp();

    const { json, byName } = await getConfig(app);

    expect(json.servers).toHaveLength(1);
    expect(byName.filesystem?.lastStartupError).toBeUndefined();
  });
});

// ---------------------------------------------------------------------------
// 2. The one string the Swift client parses (added in stage-4 review)
// ---------------------------------------------------------------------------

describe("the timeout marker Swift matches on", () => {
  test("the prefix reads exactly as Swift expects, and a timed-out row carries it", async () => {
    // `Models.swift`'s `McpServerSummary.startupTimeoutMarker` prefix-matches
    // this literal to choose between 「启动超时，已跳过」 and showing the
    // server's own error, and *nothing else in this file pins it*: every
    // assertion above is already satisfied by the recorded text alone ("No
    // response within 12000ms." matches `TIMEOUT_LANGUAGE` by itself), so
    // rewording the prefix -- prose sitting in a template literal, exactly the
    // kind of string someone tidies -- leaves the suite green while Swift
    // quietly stops recognising timeouts and renders them as generic failures.
    //
    // A change detector on purpose, and the cheaper half of the coupling to
    // enforce: it fails at the moment of the edit, in the file the editor is
    // already in, with the Swift constant named right here. Verified by
    // mutation: with this test absent, renaming the prefix keeps all 407 tests
    // in `test/agent/` passing.
    expect(MCP_STARTUP_TIMEOUT_PREFIX).toBe("Startup timed out: ");

    // ...and the route still stamps it. The literal above is only a contract
    // if the response actually carries it -- dropping the prefix from
    // `startupErrorFor` while leaving the constant exported would break Swift
    // in precisely the same way.
    save("hungServer");
    const factories = makeFactories({
      hungServer: makeFakeClient({ connect: () => never() }),
    });
    const budget = manualDelay();
    const connections = startMcpConnections(bootServers(), {
      factories,
      delay: budget.delay,
      connectTimeoutMs: 1_000,
    });
    budget.expire();
    await connections.ready;

    const app = makeApp({ connectionReport: () => connections.status() });
    const { byName } = await getConfig(app);

    expect(byName.hungServer?.lastStartupError?.startsWith(MCP_STARTUP_TIMEOUT_PREFIX)).toBe(true);
  });
});

// ---------------------------------------------------------------------------
// 3. Wiring: the seam must actually be connected in the assembled app
// ---------------------------------------------------------------------------

const emptyTools: ToolSet = {
  openAiTools: [],
  callTool: async (name) => {
    throw new Error(`Unknown tool: ${name}`);
  },
};

describe("buildApp hands the MCP connection report to the config route", () => {
  test("a timed-out server's error reaches GET /config/mcp through the assembled app", async () => {
    // Same reasoning as `test/memory/episodicWiring.test.ts`: an optional dep
    // is exactly the kind of seam that gets implemented and never plugged in,
    // and this repo has shipped one of those before (P1-7). Route-level tests
    // above would pass just as happily if `buildApp` forgot to pass it.
    save("hungServer");
    const factories = makeFactories({
      hungServer: makeFakeClient({ connect: () => never() }),
    });
    const budget = manualDelay();
    const connections = startMcpConnections(bootServers(), {
      factories,
      delay: budget.delay,
      connectTimeoutMs: 1_000,
    });
    budget.expire();
    const report: McpConnectionReport = await connections.ready;
    expect(report.servers[0]?.state).toBe("timedOut");

    const db = openDatabase(":memory:");
    const chat: AgentChatFn = async () => ({ content: "unused" });
    const app = buildApp(
      new MemoryStore(db),
      new ConversationStore(db),
      chat,
      emptyTools,
      () => {},
      async () => "unused",
      async () => "unused",
      new ProviderConfigStore(join(dir, "provider-config.json")),
      undefined, // spillRoot
      undefined, // runLogRoot
      store, // mcpConfigStore
      undefined, // mcpEnvJson
      () => connections.status() // NEW: the connection report getter
    );

    const { byName } = await getConfig(app);

    expect(byName.hungServer?.lastStartupError).toMatch(TIMEOUT_LANGUAGE);
  });
});
