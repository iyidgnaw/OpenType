/**
 * STAGE-1 (red) tests for "a hung MCP server must not stop the voice service
 * from starting".
 *
 * ---------------------------------------------------------------------------
 * The bug
 * ---------------------------------------------------------------------------
 *
 *   server.ts:171   const mcpTools = await connectConfiguredMcpServers(...)
 *   server.ts:320   const server = Bun.serve({ unix: env.socketPath, fetch })
 *
 * Nothing is served until every configured MCP server has connected, the
 * connect loop is serial, and `mcpClient.ts` has no timeout of its own (it is
 * bounded only by the MCP SDK's own long `initialize` timeout). Meanwhile
 * `SidecarClient.swift:523` gives the sidecar `waitUntilReady(timeout: 5)`,
 * then declares it unhealthy and lets the supervisor restart it -- which hangs
 * again.
 *
 * The result is a boot loop with no exit: the Settings panel that would let the
 * user delete the bad server is served by the sidecar that cannot start. Until
 * commit 1833908 this was theoretical (MCP servers came only from
 * `OPENTYPE_MCP_SERVERS`, which a packaged-app user cannot set); now a user can
 * reach this state in two clicks. The redesign handoff
 * (`design_handoff_opentype_redesign_v1/README.md`, "MCP 的关键行为" item 1)
 * flags the same hazard independently.
 *
 * ---------------------------------------------------------------------------
 * The contract stage 3 must implement
 * ---------------------------------------------------------------------------
 *
 * In `src/agent/mcpClient.ts`:
 *
 *   export const MCP_CONNECT_TIMEOUT_MS: number;
 *
 *   export type McpServerConnectionState =
 *     | "connecting" | "connected" | "failed" | "timedOut";
 *
 *   export interface McpServerConnectionStatus {
 *     name: string;
 *     state: McpServerConnectionState;
 *     toolCount: number;      // 0 unless connected
 *     error?: string;         // present for "failed" / "timedOut"
 *   }
 *
 *   export interface McpConnectionReport {
 *     servers: McpServerConnectionStatus[];   // configured order
 *   }
 *
 *   export interface McpConnectOptions {
 *     factories?: McpConnectionFactories;
 *     connectTimeoutMs?: number;              // default MCP_CONNECT_TIMEOUT_MS
 *     // Injected timer, resolving when this server's budget is spent. Default
 *     // is setTimeout-backed. Injected for the same reason
 *     // `startupConsolidation` injects `schedule`: so no test here sleeps.
 *     delay?: (ms: number) => Promise<void>;
 *   }
 *
 *   export interface LazyMcpToolSet extends McpToolSet {
 *     readonly ready: Promise<McpConnectionReport>;  // never rejects
 *     status(): McpConnectionReport;
 *   }
 *
 *   export function startMcpConnections(
 *     servers: McpServerConfig[],
 *     options?: McpConnectOptions
 *   ): LazyMcpToolSet;                        // SYNCHRONOUS -- not a promise
 *
 * plus two smaller changes:
 *
 *   - `McpConnectionFactories.createClient` takes the `McpServerConfig` it is
 *     building a client for: `(config: McpServerConfig) => McpClientLike`.
 *     Once connections run concurrently, a fake cannot infer which server a
 *     bare `createClient()` belongs to from call order. Widening a parameter is
 *     backward compatible -- the existing zero-arg fakes in `mcpClient.test.ts`
 *     and `mcpConfigStore.test.ts` still satisfy it.
 *   - `connectConfiguredMcpServers` keeps its signature and gains a third
 *     optional `Omit<McpConnectOptions, "factories">` argument, so the
 *     await-everything entry point is bounded by the same per-server budget
 *     rather than remaining an unbounded back door.
 *
 * and in `src/server.ts`'s `main()`: start connecting, then serve. Nothing on
 * the readiness path may await an MCP connection.
 *
 * ---------------------------------------------------------------------------
 * Why this shape
 * ---------------------------------------------------------------------------
 *
 * `main()` is not exported and never will be testable -- the same reason
 * `src/lifecycle.ts` exists. So the property "serving does not wait on MCP" is
 * expressed as a seam that *cannot* be waited on by accident: a factory that
 * returns a usable tool set synchronously, with tools arriving later. One
 * source-level guard at the bottom of this file covers the remaining half (that
 * `main()` does not then await `.ready` anyway), because that ordering lives
 * nowhere else.
 *
 * The tool set is live rather than a snapshot, and that is load-bearing: today
 * `mergeToolSets` eagerly `flatMap`s its sources and `withApproval` copies the
 * array reference, so a set that gains tools after boot would contribute
 * nothing to the model forever. "MCP tools that arrive late still reach
 * /agent/run" is pinned end to end below rather than as a `mergeToolSets` unit
 * test, so the implementer can fix it wherever it actually belongs.
 *
 * No test in this file sleeps. `delay` is injected in one of two shapes:
 * `nextTurnDelay` expires the budget on the next turn of the event loop, and
 * `neverExpiringDelay` never expires it. The fake clients settle on microtasks,
 * which always drain before that next turn, so "a server that answers wins the
 * race, a hung one loses it" is ordering, not timing.
 */
import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import {
  connectConfiguredMcpServers,
  startMcpConnections,
  MCP_CONNECT_TIMEOUT_MS,
  type McpClientLike,
  type McpConnectionFactories,
  type McpServerConfig,
} from "../../src/agent/mcpClient";
import { mergeToolSets, type ToolSet } from "../../src/agent/toolSets";
import { withApproval, yoloApprovalPolicy } from "../../src/agent/approval";
import { buildAgentRoutes } from "../../src/agent/routes";
import { createRouter } from "../../src/router";
import { openDatabase } from "../../src/memory/db";
import { MemoryStore } from "../../src/memory/MemoryStore";
import { ConversationStore } from "../../src/memory/conversations";
import type { AgentChatFn, AgentChatMessage } from "../../src/agent/loop";
import type { ContextUsageLogWriter } from "../../src/oneshot/contextDebugLog";

// ---------------------------------------------------------------------------
// Fakes
// ---------------------------------------------------------------------------

function deferred<T = void>(): {
  promise: Promise<T>;
  resolve: (value: T) => void;
  reject: (err: unknown) => void;
} {
  let resolve!: (value: T) => void;
  let reject!: (err: unknown) => void;
  const promise = new Promise<T>((res, rej) => {
    resolve = res;
    reject = rej;
  });
  return { promise, resolve, reject };
}

/** A promise that never settles -- the shape of the bug being fixed. */
function never<T = void>(): Promise<T> {
  return new Promise<T>(() => {});
}

interface FakeClientOptions {
  tools?: Array<{ name: string; description?: string; inputSchema?: unknown }>;
  /** Overrides connect(). Default: resolves immediately. */
  connect?: () => Promise<void>;
  /** Overrides listTools(). Default: resolves `tools`. */
  listTools?: () => Promise<{
    tools: Array<{ name: string; description?: string; inputSchema?: unknown }>;
  }>;
  onCallTool?: (params: { name: string; arguments?: unknown }) => unknown;
  /** Overrides close(). Default: records the call and resolves. */
  close?: () => Promise<void>;
}

interface FakeClient extends McpClientLike {
  connectCalls: number;
  listToolsCalls: number;
  closeCalls: number;
}

function makeFakeClient(options: FakeClientOptions = {}): FakeClient {
  const tools = options.tools ?? [];
  const client: FakeClient = {
    connectCalls: 0,
    listToolsCalls: 0,
    closeCalls: 0,
    async connect() {
      client.connectCalls += 1;
      if (options.connect) {
        return options.connect();
      }
    },
    async listTools() {
      client.listToolsCalls += 1;
      if (options.listTools) {
        return options.listTools();
      }
      return { tools };
    },
    async callTool(params) {
      const content = options.onCallTool
        ? options.onCallTool(params)
        : { called: params.name, arguments: params.arguments };
      return { content: [{ type: "text", text: JSON.stringify(content) }] };
    },
    async close() {
      client.closeCalls += 1;
      if (options.close) {
        return options.close();
      }
    },
  };
  return client;
}

/**
 * Resolves a fake client by the server's *name*, taken from the config handed
 * to `createClient`. The pre-existing helper in `mcpClient.test.ts` infers the
 * server from the order of the preceding `createTransport` call, which only
 * holds while connections are serial -- see the header note on widening
 * `createClient`.
 */
function makeFactories(clientsByName: Record<string, McpClientLike>): {
  factories: McpConnectionFactories;
  transportOrder: string[];
  clientOrder: string[];
  seenConfigs: McpServerConfig[];
} {
  const transportOrder: string[] = [];
  const clientOrder: string[] = [];
  const seenConfigs: McpServerConfig[] = [];
  const factories: McpConnectionFactories = {
    createTransport: (config: McpServerConfig) => {
      transportOrder.push(config.name);
      seenConfigs.push(config);
      return { __fakeTransportFor: config.name };
    },
    createClient: (config: McpServerConfig) => {
      clientOrder.push(config.name);
      const client = clientsByName[config.name];
      if (!client) {
        throw new Error(`no fake client configured for server ${config.name}`);
      }
      return client;
    },
  };
  return { factories, transportOrder, clientOrder, seenConfigs };
}

/**
 * A budget that expires on the next turn of the event loop, recording the ms it
 * was asked for. Deterministic rather than timing-dependent: the fake clients
 * above settle on microtasks, which always drain before this macrotask, so a
 * server that answers at all wins the race and a genuinely hung one loses it.
 * Not a sleep -- no test here waits out a real duration.
 */
function nextTurnDelay(): { delay: (ms: number) => Promise<void>; requested: number[] } {
  const requested: number[] = [];
  return {
    requested,
    delay: (ms: number) => {
      requested.push(ms);
      return new Promise<void>((resolve) => setTimeout(resolve, 0));
    },
  };
}

/** "The budget never expires." Records what was asked for. */
function neverExpiringDelay(): {
  delay: (ms: number) => Promise<void>;
  requested: number[];
} {
  const requested: number[] = [];
  return {
    requested,
    delay: (ms: number) => {
      requested.push(ms);
      return never<void>();
    },
  };
}

const stdio = (name: string): McpServerConfig => ({
  name,
  transport: "stdio",
  command: "npx",
  args: ["-y", `@example/${name}`],
});

function toolNames(set: { openAiTools: unknown[] }): string[] {
  return set.openAiTools.map(
    (tool) => (tool as { function: { name: string } }).function.name
  );
}

// ---------------------------------------------------------------------------
// 1. Serving must not wait on MCP
// ---------------------------------------------------------------------------

describe("startMcpConnections: usable immediately, tools arrive later", () => {
  test("returns a tool set synchronously, not a promise", () => {
    const hung = makeFakeClient({ connect: () => never() });
    const { factories } = makeFactories({ hungServer: hung });

    const set = startMcpConnections([stdio("hungServer")], {
      factories,
      delay: neverExpiringDelay().delay,
    });

    // If this were a promise, `main()` would have something to await and the
    // boot loop could come straight back.
    expect(typeof (set as unknown as { then?: unknown }).then).not.toBe("function");
    expect(Array.isArray(set.openAiTools)).toBe(true);
    expect(typeof set.callTool).toBe("function");
  });

  test("a server whose connect() never resolves does not block the returned set", () => {
    const hung = makeFakeClient({ connect: () => never() });
    const { factories } = makeFactories({ hungServer: hung });

    const set = startMcpConnections([stdio("hungServer")], {
      factories,
      delay: neverExpiringDelay().delay,
    });

    // Nothing has connected, so there are no MCP tools yet -- but the set
    // exists and is fully usable, which is the whole point.
    expect(set.openAiTools).toEqual([]);
    expect(set.status().servers).toEqual([
      { name: "hungServer", state: "connecting", toolCount: 0 },
    ]);
  });

  test("all servers start connecting before any of them settles (not a serial loop)", () => {
    // A serial `for ... await` loop means one hung server also costs every
    // later server's connect latency -- "one hung server costs that server's
    // tools and nothing else" requires the connections to be concurrent.
    const hung = makeFakeClient({ connect: () => never() });
    const healthy = makeFakeClient({ tools: [{ name: "lookup" }] });
    const { factories, transportOrder } = makeFactories({
      hungServer: hung,
      healthyServer: healthy,
    });

    startMcpConnections([stdio("hungServer"), stdio("healthyServer")], {
      factories,
      delay: neverExpiringDelay().delay,
    });

    // Asserted synchronously, before the hung server has any chance to settle.
    expect(transportOrder).toEqual(["hungServer", "healthyServer"]);
    expect(hung.connectCalls).toBe(1);
    expect(healthy.connectCalls).toBe(1);
  });

  test("a healthy server's tools appear on the same set once it connects", async () => {
    const healthy = makeFakeClient({
      tools: [
        {
          name: "lookup",
          description: "look things up",
          inputSchema: { type: "object", properties: { q: { type: "string" } } },
        },
      ],
    });
    const { factories } = makeFactories({ healthyServer: healthy });

    const set = startMcpConnections([stdio("healthyServer")], {
      factories,
      delay: neverExpiringDelay().delay,
    });
    expect(set.openAiTools).toEqual([]);

    await set.ready;

    expect(set.openAiTools).toEqual([
      {
        type: "function",
        function: {
          name: "healthyServer__lookup",
          description: "look things up",
          parameters: { type: "object", properties: { q: { type: "string" } } },
        },
      },
    ]);
  });

  test("callTool routes to the right server once connected", async () => {
    const a = makeFakeClient({
      tools: [{ name: "lookup" }],
      onCallTool: (params) => ({ from: "A", name: params.name, args: params.arguments }),
    });
    const b = makeFakeClient({
      tools: [{ name: "lookup" }],
      onCallTool: (params) => ({ from: "B", name: params.name, args: params.arguments }),
    });
    const { factories } = makeFactories({ serverA: a, serverB: b });

    const set = startMcpConnections([stdio("serverA"), stdio("serverB")], {
      factories,
      delay: neverExpiringDelay().delay,
    });
    await set.ready;

    expect(JSON.parse((await set.callTool("serverA__lookup", { q: "x" })).content)).toEqual({
      from: "A",
      name: "lookup",
      args: { q: "x" },
    });
    expect(JSON.parse((await set.callTool("serverB__lookup", { q: "y" })).content)).toEqual({
      from: "B",
      name: "lookup",
      args: { q: "y" },
    });
  });

  test("calling a tool that has not connected yet rejects rather than hanging", async () => {
    const hung = makeFakeClient({ connect: () => never(), tools: [{ name: "lookup" }] });
    const { factories } = makeFactories({ hungServer: hung });

    const set = startMcpConnections([stdio("hungServer")], {
      factories,
      delay: neverExpiringDelay().delay,
    });

    // The model never saw this tool (it was not in `openAiTools`), so a call
    // for it is genuinely unknown. Waiting for a connection that may never
    // arrive would hand the hang to the agent run instead.
    await expect(set.callTool("hungServer__lookup", {})).rejects.toThrow(
      /Unknown MCP tool/
    );
  });

  test("no servers: an empty set, a resolved ready, and no connection attempts", async () => {
    let createTransportCalls = 0;
    const factories: McpConnectionFactories = {
      createTransport: () => {
        createTransportCalls += 1;
        return {};
      },
      createClient: () => makeFakeClient(),
    };

    const set = startMcpConnections([], { factories });

    expect(set.openAiTools).toEqual([]);
    expect(set.status()).toEqual({ servers: [] });
    expect(await set.ready).toEqual({ servers: [] });
    expect(createTransportCalls).toBe(0);
  });

  test("a transport factory that throws synchronously never escapes the call", async () => {
    // `defaultCreateTransport` calls `new URL(config.url ?? "")`, which throws
    // synchronously on a bad url. Because this factory returns synchronously,
    // an escaping throw would crash `main()` *before* `Bun.serve` -- exactly
    // the failure mode being closed.
    const healthy = makeFakeClient({ tools: [{ name: "ok" }] });
    const factories: McpConnectionFactories = {
      createTransport: (config: McpServerConfig) => {
        if (config.name === "badServer") {
          throw new TypeError("Invalid URL");
        }
        return {};
      },
      createClient: () => healthy,
    };

    let set!: ReturnType<typeof startMcpConnections>;
    expect(() => {
      set = startMcpConnections([stdio("badServer"), stdio("healthyServer")], {
        factories,
        delay: neverExpiringDelay().delay,
      });
    }).not.toThrow();

    const report = await set.ready;
    expect(report.servers.find((s) => s.name === "badServer")?.state).toBe("failed");
    expect(toolNames(set)).toEqual(["healthyServer__ok"]);
  });

  test("ready resolves rather than rejecting even when every server fails", async () => {
    const a = makeFakeClient({ connect: async () => { throw new Error("spawn npx ENOENT"); } });
    const b = makeFakeClient({ connect: async () => { throw new Error("401 unauthorized"); } });
    const { factories } = makeFactories({ serverA: a, serverB: b });

    const set = startMcpConnections([stdio("serverA"), stdio("serverB")], {
      factories,
      delay: neverExpiringDelay().delay,
    });

    // An unhandled rejection out of a boot-path promise is a crashed sidecar
    // under Bun -- the same reason `whisperReady.catch(() => {})` exists.
    const report = await set.ready;
    expect(report.servers.map((s) => s.state)).toEqual(["failed", "failed"]);
  });
});

// ---------------------------------------------------------------------------
// 2. Every connection is individually bounded
// ---------------------------------------------------------------------------

describe("per-server connect timeout", () => {
  test("MCP_CONNECT_TIMEOUT_MS is a named constant with a defensible value", () => {
    expect(typeof MCP_CONNECT_TIMEOUT_MS).toBe("number");
    // Long enough that `npx -y <pkg>` can fetch and boot a server on a cold
    // cache; short enough that a hung server's tools are declared missing
    // within the session rather than at the SDK's own much longer bound.
    expect(MCP_CONNECT_TIMEOUT_MS).toBeGreaterThanOrEqual(5_000);
    expect(MCP_CONNECT_TIMEOUT_MS).toBeLessThanOrEqual(60_000);
  });

  test("the default budget is MCP_CONNECT_TIMEOUT_MS when none is given", async () => {
    const hung = makeFakeClient({ connect: () => never() });
    const { factories } = makeFactories({ hungServer: hung });
    const { delay, requested } = nextTurnDelay();

    await startMcpConnections([stdio("hungServer")], { factories, delay }).ready;

    expect(requested).toEqual([MCP_CONNECT_TIMEOUT_MS]);
  });

  test("an explicit connectTimeoutMs overrides the default", async () => {
    const hung = makeFakeClient({ connect: () => never() });
    const { factories } = makeFactories({ hungServer: hung });
    const { delay, requested } = nextTurnDelay();

    await startMcpConnections([stdio("hungServer")], {
      factories,
      delay,
      connectTimeoutMs: 1_234,
    }).ready;

    expect(requested).toEqual([1_234]);
  });

  test("a hung server is abandoned and reported as timedOut", async () => {
    const hung = makeFakeClient({ connect: () => never() });
    const { factories } = makeFactories({ hungServer: hung });
    const { delay } = nextTurnDelay();

    const set = startMcpConnections([stdio("hungServer")], {
      factories,
      delay,
      connectTimeoutMs: 1_000,
    });
    const report = await set.ready;

    expect(report.servers).toHaveLength(1);
    expect(report.servers[0]?.name).toBe("hungServer");
    expect(report.servers[0]?.state).toBe("timedOut");
    expect(report.servers[0]?.toolCount).toBe(0);
    expect(typeof report.servers[0]?.error).toBe("string");
    expect(set.openAiTools).toEqual([]);
  });

  test("the budget covers listTools too, not just connect", async () => {
    // A server that completes the handshake and then never answers
    // `tools/list` wedges boot exactly as thoroughly as one that never
    // connects, so the budget has to span both calls.
    const halfHung = makeFakeClient({ listTools: () => never() });
    const { factories } = makeFactories({ halfHungServer: halfHung });
    const { delay } = nextTurnDelay();

    const report = await startMcpConnections([stdio("halfHungServer")], {
      factories,
      delay,
      connectTimeoutMs: 1_000,
    }).ready;

    expect(report.servers[0]?.state).toBe("timedOut");
  });

  test("one hung server costs only its own tools -- the others still connect", async () => {
    const hung = makeFakeClient({ connect: () => never(), tools: [{ name: "never" }] });
    const healthy = makeFakeClient({ tools: [{ name: "ok_tool", description: "fine" }] });
    const alsoHealthy = makeFakeClient({ tools: [{ name: "other_tool" }] });
    const { factories } = makeFactories({
      hungServer: hung,
      healthyServer: healthy,
      otherServer: alsoHealthy,
    });
    const { delay } = nextTurnDelay();

    const set = startMcpConnections(
      [stdio("hungServer"), stdio("healthyServer"), stdio("otherServer")],
      { factories, delay, connectTimeoutMs: 1_000 }
    );
    const report = await set.ready;

    expect(toolNames(set)).toEqual(["healthyServer__ok_tool", "otherServer__other_tool"]);
    expect(report.servers).toEqual([
      {
        name: "hungServer",
        state: "timedOut",
        toolCount: 0,
        error: expect.any(String),
      },
      { name: "healthyServer", state: "connected", toolCount: 1 },
      { name: "otherServer", state: "connected", toolCount: 1 },
    ]);
  });

  test("each server gets its own full budget, not a shared one", async () => {
    const hungA = makeFakeClient({ connect: () => never() });
    const hungB = makeFakeClient({ connect: () => never() });
    const { factories } = makeFactories({ hungA, hungB });
    const { delay, requested } = nextTurnDelay();

    await startMcpConnections([stdio("hungA"), stdio("hungB")], {
      factories,
      delay,
      connectTimeoutMs: 3_000,
    }).ready;

    expect(requested).toEqual([3_000, 3_000]);
  });

  test("a slow server that answers within its budget still contributes its tools", async () => {
    const gate = deferred<void>();
    const slow = makeFakeClient({
      tools: [{ name: "eventually" }],
      connect: () => gate.promise,
    });
    const { factories } = makeFactories({ slowServer: slow });

    const set = startMcpConnections([stdio("slowServer")], {
      factories,
      delay: neverExpiringDelay().delay,
      connectTimeoutMs: 1_000,
    });
    expect(set.openAiTools).toEqual([]);

    gate.resolve();
    const report = await set.ready;

    expect(report.servers[0]?.state).toBe("connected");
    expect(toolNames(set)).toEqual(["slowServer__eventually"]);
  });

  test("a timed-out server is abandoned, never retried", async () => {
    const hung = makeFakeClient({ connect: () => never() });
    const { factories, transportOrder, clientOrder } = makeFactories({ hungServer: hung });
    const { delay, requested } = nextTurnDelay();

    const set = startMcpConnections([stdio("hungServer")], {
      factories,
      delay,
      connectTimeoutMs: 1_000,
    });
    await set.ready;
    // Give any stray re-arm a turn of the loop to show itself.
    await Promise.resolve();

    expect(transportOrder).toEqual(["hungServer"]);
    expect(clientOrder).toEqual(["hungServer"]);
    expect(hung.connectCalls).toBe(1);
    expect(requested).toEqual([1_000]);
  });

  test("a timed-out server's client is closed so its child process is not leaked", async () => {
    // A stdio server is a spawned child process. Walking away from the promise
    // without closing the client leaves that child running for the lifetime of
    // the sidecar -- the same leak `probeMcpServer`'s `finally` block avoids.
    const hung = makeFakeClient({ connect: () => never() });
    const { factories } = makeFactories({ hungServer: hung });
    const { delay } = nextTurnDelay();

    await startMcpConnections([stdio("hungServer")], {
      factories,
      delay,
      connectTimeoutMs: 1_000,
    }).ready;

    expect(hung.closeCalls).toBe(1);
  });

  test("a close() that throws during teardown does not wedge the report", async () => {
    const hung = makeFakeClient({
      connect: () => never(),
      close: async () => {
        throw new Error("transport already dead");
      },
    });
    const healthy = makeFakeClient({ tools: [{ name: "ok_tool" }] });
    const { factories } = makeFactories({ hungServer: hung, healthyServer: healthy });
    const { delay } = nextTurnDelay();

    const set = startMcpConnections([stdio("hungServer"), stdio("healthyServer")], {
      factories,
      delay,
      connectTimeoutMs: 1_000,
    });
    const report = await set.ready;

    expect(report.servers[0]?.state).toBe("timedOut");
    expect(toolNames(set)).toEqual(["healthyServer__ok_tool"]);
  });

  test("a server that fails outright is reported as failed, with its real error", async () => {
    // The message is the whole diagnostic value: "spawn npx ENOENT" tells the
    // user what to fix, "MCP server unavailable" does not.
    const bad = makeFakeClient({
      connect: async () => {
        throw new Error("spawn npx ENOENT");
      },
    });
    const { factories } = makeFactories({ badServer: bad });

    const report = await startMcpConnections([stdio("badServer")], {
      factories,
      delay: neverExpiringDelay().delay,
    }).ready;

    expect(report.servers[0]?.state).toBe("failed");
    expect(report.servers[0]?.error).toContain("spawn npx ENOENT");
  });

  test("status() tracks each server independently while connections are in flight", async () => {
    const gate = deferred<void>();
    const slow = makeFakeClient({ tools: [{ name: "eventually" }], connect: () => gate.promise });
    const hung = makeFakeClient({ connect: () => never() });
    const { factories } = makeFactories({ slowServer: slow, hungServer: hung });
    const { delay } = nextTurnDelay();

    const set = startMcpConnections([stdio("slowServer"), stdio("hungServer")], {
      factories,
      delay,
      connectTimeoutMs: 1_000,
    });

    expect(set.status().servers.map((s) => s.state)).toEqual(["connecting", "connecting"]);

    gate.resolve();
    await set.ready;

    expect(set.status().servers.map((s) => s.state)).toEqual(["connected", "timedOut"]);
    // ready and status() agree once everything has settled.
    expect(set.status()).toEqual(await set.ready);
  });

  test("connectConfiguredMcpServers is bounded by the same per-server budget", async () => {
    // The await-everything entry point stays in the codebase; it must not
    // remain an unbounded back door into the same hang.
    const hung = makeFakeClient({ connect: () => never() });
    const healthy = makeFakeClient({ tools: [{ name: "ok_tool" }] });
    const { factories } = makeFactories({ hungServer: hung, healthyServer: healthy });
    const { delay, requested } = nextTurnDelay();

    const set = await connectConfiguredMcpServers(
      [stdio("hungServer"), stdio("healthyServer")],
      factories,
      { delay, connectTimeoutMs: 1_000 }
    );

    expect(requested).toEqual([1_000, 1_000]);
    expect(toolNames(set)).toEqual(["healthyServer__ok_tool"]);
  });
});

// ---------------------------------------------------------------------------
// 3. Degradation: fewer tools is correct, not coming up is not
// ---------------------------------------------------------------------------

function makeStore(): MemoryStore {
  return new MemoryStore(openDatabase(":memory:"));
}

function makeConversations(): ConversationStore {
  return new ConversationStore(openDatabase(":memory:"));
}

const noopContextLog: ContextUsageLogWriter = () => {};

/** Stands in for the always-available built-in/core tools. */
function fakeBuiltInTools(): ToolSet {
  return {
    openAiTools: [
      {
        type: "function",
        function: {
          name: "opentype__read_file",
          description: "read a file",
          parameters: { type: "object", properties: {} },
        },
      },
    ],
    callTool: async () => ({ content: "built-in ran" }),
  };
}

function post(body: unknown): Request {
  return new Request("http://sidecar/agent/run", {
    method: "POST",
    body: JSON.stringify(body),
  });
}

describe("an unreachable MCP server degrades /agent/run, it does not break it", () => {
  test("the agent runs while connections are still in flight, with the built-ins only", async () => {
    const hung = makeFakeClient({ connect: () => never(), tools: [{ name: "lookup" }] });
    const { factories } = makeFactories({ hungServer: hung });
    const mcp = startMcpConnections([stdio("hungServer")], {
      factories,
      delay: neverExpiringDelay().delay,
    });

    let capturedTools: unknown;
    const chat: AgentChatFn = async (_messages: AgentChatMessage[], options) => {
      capturedTools = options?.tools;
      return { content: "done" };
    };
    const tools = withApproval(mergeToolSets(fakeBuiltInTools(), mcp), yoloApprovalPolicy);
    const router = createRouter(
      buildAgentRoutes(makeStore(), makeConversations(), chat, tools, noopContextLog)
    );

    const response = await router(post({ task: "do the thing" }));

    expect(response.status).toBe(200);
    expect((await response.json()).result).toBe("done");
    const names = (capturedTools as Array<{ function: { name: string } }>).map(
      (t) => t.function.name
    );
    expect(names).toContain("opentype__read_file");
    expect(names).toContain("opentype__ask_user");
    expect(names).not.toContain("hungServer__lookup");
  });

  test("after a timeout, the healthy server's tools still reach the model", async () => {
    // The load-bearing one. `mergeToolSets` eagerly flatMaps its sources and
    // `withApproval` copies the array reference, both at wrap time -- so a set
    // that gains tools after boot contributes nothing unless that chain reads
    // its sources at call time. Wrapping happens BEFORE the connections settle
    // here, exactly as `main()` does it.
    const hung = makeFakeClient({ connect: () => never(), tools: [{ name: "lookup" }] });
    const healthy = makeFakeClient({ tools: [{ name: "search", description: "search" }] });
    const { factories } = makeFactories({ hungServer: hung, healthyServer: healthy });
    const { delay } = nextTurnDelay();

    const mcp = startMcpConnections([stdio("hungServer"), stdio("healthyServer")], {
      factories,
      delay,
      connectTimeoutMs: 1_000,
    });
    let capturedTools: unknown;
    const chat: AgentChatFn = async (_messages: AgentChatMessage[], options) => {
      capturedTools = options?.tools;
      return { content: "done" };
    };
    const tools = withApproval(mergeToolSets(fakeBuiltInTools(), mcp), yoloApprovalPolicy);
    const router = createRouter(
      buildAgentRoutes(makeStore(), makeConversations(), chat, tools, noopContextLog)
    );

    await mcp.ready;
    const response = await router(post({ task: "do the thing" }));

    expect(response.status).toBe(200);
    const names = (capturedTools as Array<{ function: { name: string } }>).map(
      (t) => t.function.name
    );
    expect(names).toContain("healthyServer__search");
    expect(names).toContain("opentype__read_file");
    expect(names).not.toContain("hungServer__lookup");
  });

  test("a late-arriving MCP tool is callable through the merged, approval-wrapped set", async () => {
    const healthy = makeFakeClient({
      tools: [{ name: "search" }],
      onCallTool: (params) => ({ ran: params.name }),
    });
    const { factories } = makeFactories({ healthyServer: healthy });

    const mcp = startMcpConnections([stdio("healthyServer")], {
      factories,
      delay: neverExpiringDelay().delay,
    });
    const tools = withApproval(mergeToolSets(fakeBuiltInTools(), mcp), yoloApprovalPolicy);

    await mcp.ready;

    expect(toolNames(tools)).toEqual(["opentype__read_file", "healthyServer__search"]);
    expect(JSON.parse((await tools.callTool("healthyServer__search", { q: "x" })).content)).toEqual(
      { ran: "search" }
    );
    // The built-ins are undisturbed by the late merge.
    expect((await tools.callTool("opentype__read_file", {})).content).toBe("built-in ran");
  });
});

// ---------------------------------------------------------------------------
// 4. Boot ordering in main(), which lives nowhere else
// ---------------------------------------------------------------------------

describe("server.ts boots before it connects", () => {
  test("nothing on the path to Bun.serve awaits an MCP connection", () => {
    // `main()` is not exported and never will be testable -- the same reason
    // `src/lifecycle.ts` exists. Everything above proves the seam CAN be used
    // without blocking; this proves `main()` actually does. Deliberately
    // narrow: it only forbids awaiting an MCP connect helper or a connection
    // report before the server is listening.
    const source = readFileSync(
      join(import.meta.dir, "..", "..", "src", "server.ts"),
      "utf8"
    );
    const serveIndex = source.indexOf("Bun.serve(");
    expect(serveIndex).toBeGreaterThan(-1);
    const beforeServe = source.slice(0, serveIndex);

    expect(beforeServe).not.toMatch(/await\s+connectConfiguredMcpServers/);
    expect(beforeServe).not.toMatch(/await\s+startMcpConnections/);
    // `main()`'s boot construction is `createReloadableMcpToolSet(...)`, not
    // `startMcpConnections(...)` directly -- the line above stopped being
    // able to fail the moment that rename landed, and nothing guarded the
    // new name. Same hazard, same fix: forbid awaiting the actual symbol
    // `main()` calls today.
    expect(beforeServe).not.toMatch(/await\s+createReloadableMcpToolSet/);
    expect(beforeServe).not.toMatch(/await\s+\w*[Mm]cp\w*\s*\.\s*ready/);
  });
});
