import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import {
  StdioClientTransport,
  getDefaultEnvironment,
} from "@modelcontextprotocol/sdk/client/stdio.js";
import { StreamableHTTPClientTransport } from "@modelcontextprotocol/sdk/client/streamableHttp.js";

/**
 * Config shape for one MCP server. Two sources produce it: the saved config
 * `McpConfigStore` persists (`agent/mcpConfigStore.ts`, what the Settings
 * panel writes) and the `OPENTYPE_MCP_SERVERS` env var kept as a zero-config
 * dev fallback -- `resolveMcpServers` decides between them and hands the
 * winner here.
 *
 * Every field past `name` is optional so the env var's original
 * `{name, command, args}` documented format still satisfies this type; a
 * missing `transport` means stdio. `StoredMcpServer` (which requires
 * `transport`) is assignable to this.
 */
export interface McpServerConfig {
  name: string;
  transport?: "stdio" | "http";
  /** stdio only. */
  command?: string;
  args?: string[];
  env?: Record<string, string>;
  /** http only. */
  url?: string;
  headers?: Record<string, string>;
}

/** OpenAI-style tool descriptor produced from an MCP tool for `chat(..., {tools})`. */
interface OpenAiFunctionTool {
  type: "function";
  function: {
    name: string;
    description: string;
    parameters: unknown;
  };
}

export interface McpToolSet {
  openAiTools: unknown[];
  callTool: (
    name: string,
    args: unknown,
    signal?: AbortSignal
  ) => Promise<{ content: string }>;
}

interface McpToolDescriptor {
  name: string;
  description?: string;
  inputSchema?: unknown;
}

/**
 * Minimal surface of the MCP SDK's `Client` this module depends on. Real
 * `Client` instances satisfy this structurally; tests substitute a fake here
 * instead of spawning real child processes/stdio transports.
 */
export interface McpClientLike {
  connect(transport: unknown): Promise<void>;
  listTools(): Promise<{ tools: McpToolDescriptor[] }>;
  callTool(
    params: { name: string; arguments?: unknown },
    resultSchema?: unknown,
    options?: { signal?: AbortSignal }
  ): Promise<{ content: unknown }>;
  /**
   * Optional so existing fakes still satisfy this interface. `probeMcpServer`
   * uses it to shut a throwaway connection down again -- a "Test Connection"
   * button that leaked one npx child process per click would be a slow leak
   * on the user's machine.
   */
  close?(): Promise<void>;
}

/**
 * Construction of the transport/client is isolated behind this factory pair
 * so `connectConfiguredMcpServers` is unit-testable without a real MCP
 * server: tests inject fakes, production uses `defaultMcpConnectionFactories`.
 */
export interface McpConnectionFactories {
  createTransport: (config: McpServerConfig) => unknown;
  /**
   * Takes the config it is building a client for. Once connections run
   * concurrently (`startMcpConnections`) a fake can no longer infer which
   * server a bare `createClient()` belongs to from call order. Widening a
   * parameter is backward compatible, so existing zero-arg fakes still satisfy
   * this.
   */
  createClient: (config: McpServerConfig) => McpClientLike;
}

function defaultCreateTransport(config: McpServerConfig): unknown {
  if (config.transport === "http") {
    return new StreamableHTTPClientTransport(new URL(config.url ?? ""), {
      requestInit: config.headers ? { headers: config.headers } : undefined,
    });
  }
  return new StdioClientTransport({
    command: config.command ?? "",
    args: config.args ?? [],
    // The SDK *replaces* the child's environment when `env` is given rather
    // than extending it, so a server configured with a single API-key entry
    // would otherwise lose PATH and fail to even find `npx`. Merge onto the
    // SDK's own safe-to-inherit default set instead.
    ...(config.env
      ? { env: { ...getDefaultEnvironment(), ...config.env } }
      : {}),
  });
}

function defaultCreateClient(): McpClientLike {
  return new Client({ name: "opentype-sidecar", version: "0.1.0" }) as unknown as McpClientLike;
}

export const defaultMcpConnectionFactories: McpConnectionFactories = {
  createTransport: defaultCreateTransport,
  createClient: defaultCreateClient,
};

function parseServerConfigs(
  configJson: string | McpServerConfig[] | undefined
): McpServerConfig[] {
  if (Array.isArray(configJson)) {
    // Already-resolved config objects (`resolveMcpServers`) -- the production
    // path since P2-13; the JSON-string form below stays for the raw env var.
    return configJson;
  }
  if (!configJson) {
    return [];
  }
  let parsed: unknown;
  try {
    parsed = JSON.parse(configJson);
  } catch {
    console.warn(
      "OPENTYPE_MCP_SERVERS is not valid JSON; starting with no MCP servers configured."
    );
    return [];
  }
  if (!Array.isArray(parsed)) {
    console.warn(
      "OPENTYPE_MCP_SERVERS did not parse to a JSON array; starting with no MCP servers configured."
    );
    return [];
  }
  return parsed as McpServerConfig[];
}

/** Flattens an MCP tool-call result's content into a plain string for callers. */
function stringifyToolResultContent(content: unknown): string {
  if (typeof content === "string") {
    return content;
  }
  if (Array.isArray(content)) {
    const texts = content
      .map((block) => {
        if (block && typeof block === "object" && (block as { type?: unknown }).type === "text") {
          return (block as { text?: unknown }).text;
        }
        return undefined;
      })
      .filter((text): text is string => typeof text === "string");
    if (texts.length > 0) {
      return texts.join("\n");
    }
  }
  return JSON.stringify(content);
}

/**
 * Connects to every configured MCP server -- either already-resolved config
 * objects (what `resolveMcpServers` hands over: saved config if the user has
 * any, else the env var's) or the raw `OPENTYPE_MCP_SERVERS` JSON string --
 * lists each server's tools, and converts them into one combined OpenAI-style
 * tool list plus a dispatcher that routes a call back to the right
 * server/original tool name.
 *
 * The resulting set is merged with the built-in tools and wrapped in
 * `withApproval` by `server.ts`, so MCP tool calls pass the same approval gate
 * as everything else -- an MCP server's tools run unsandboxed exactly like the
 * built-in ones, and the v1 "no-side-effect tools only" expectation is retired
 * along with the rest of that policy.
 *
 * Unset/unparseable config defaults to no servers (logged, not thrown). A
 * server that fails to connect is logged and skipped -- it never prevents
 * the other configured servers from connecting.
 */
export async function connectConfiguredMcpServers(
  configJson: string | McpServerConfig[] | undefined,
  factories: McpConnectionFactories = defaultMcpConnectionFactories,
  options: Omit<McpConnectOptions, "factories"> = {}
): Promise<McpToolSet> {
  const set = startMcpConnections(parseServerConfigs(configJson), {
    ...options,
    factories,
  });
  await set.ready;
  return set;
}

/**
 * How long one server gets to finish its whole handshake -- transport, MCP
 * `initialize`, and `listTools` -- before it is abandoned.
 *
 * Twelve seconds is chosen against the two clocks that already exist rather
 * than picked for feel: the MCP SDK's own `initialize` timeout is 60s, which
 * is far past the point where a user decides the app is broken, and
 * `SidecarClient.waitUntilReady` gives the whole sidecar 5s. Since connections
 * no longer block serving, this budget no longer competes with that 5s -- it
 * only bounds how long a dead server keeps a slot open before its tools are
 * declared absent. Long enough for a cold `npx` fetch on a slow link, short
 * enough that a user who mistyped a command sees "failed" within one glance at
 * the panel.
 */
export const MCP_CONNECT_TIMEOUT_MS = 12_000;

export type McpServerConnectionState = "connecting" | "connected" | "failed" | "timedOut";

export interface McpServerConnectionStatus {
  name: string;
  state: McpServerConnectionState;
  /** 0 unless `connected`. */
  toolCount: number;
  /** Present for `failed` / `timedOut`. */
  error?: string;
}

export interface McpConnectionReport {
  /** Configured order, so a UI can line these up against the user's list. */
  servers: McpServerConnectionStatus[];
}

export interface McpConnectOptions {
  factories?: McpConnectionFactories;
  connectTimeoutMs?: number;
  /**
   * Injected timer resolving when a server's budget is spent. Default is
   * `setTimeout`-backed; injected for the same reason `startupConsolidation`
   * injects `schedule` -- so no test has to sleep.
   */
  delay?: (ms: number) => Promise<void>;
}

export interface LazyMcpToolSet extends McpToolSet {
  /** Settles when every server has connected, failed or timed out. Never rejects. */
  readonly ready: Promise<McpConnectionReport>;
  status(): McpConnectionReport;
}

const TIMED_OUT = Symbol("mcp-connect-timed-out");

function defaultDelay(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

/**
 * Turns one server's raw tool list into this module's two derived shapes:
 * the OpenAI-style function descriptors merged into `openAiTools`, and the
 * `serverName__toolName -> toolName` map used to route a call back to its
 * original name. Shared by `startMcpConnections` and
 * `createReloadableMcpToolSet` so the two connect paths can't drift on how a
 * tool gets namespaced.
 */
function namespaceMcpTools(
  serverName: string,
  tools: McpToolDescriptor[]
): { openAiTools: OpenAiFunctionTool[]; routes: Map<string, string> } {
  const openAiTools: OpenAiFunctionTool[] = [];
  const routes = new Map<string, string>();
  for (const tool of tools) {
    const namespacedName = `${serverName}__${tool.name}`;
    routes.set(namespacedName, tool.name);
    openAiTools.push({
      type: "function",
      function: {
        name: namespacedName,
        description: tool.description ?? "",
        parameters: tool.inputSchema ?? { type: "object", properties: {} },
      },
    });
  }
  return { openAiTools, routes };
}

/**
 * Starts connecting to every configured MCP server and returns a tool set
 * **synchronously**, before any of them has answered.
 *
 * This shape is the fix for a bug that could brick the app. `server.ts` used to
 * `await` the connect loop before `Bun.serve`, the loop was serial, and nothing
 * bounded it, so one hung server meant the voice service never started;
 * `SidecarClient.waitUntilReady` gave up after 5s and the supervisor restarted
 * into the same hang. The Settings panel that would remove the bad server is
 * served by the sidecar that will not start, so there was no way out from
 * inside the product. Returning immediately means MCP can only ever cost its
 * own tools, never the app.
 *
 * Three properties follow from that and are each pinned by tests:
 *
 * - **Serving never waits.** The set is usable at once; `openAiTools` fills in
 *   as servers answer. A model that asks for a tool that has not arrived gets
 *   a rejection it can read, not a hang.
 * - **Connections run concurrently**, so ten servers cost one budget, not ten.
 * - **Each server gets its own budget**, covering `connect` *and* `listTools`:
 *   a server that completes the handshake and then stalls listing its tools is
 *   the same failure from the user's side.
 *
 * An abandoned connection is orphaned rather than cancelled -- the SDK's
 * `connect` has no cancellation channel, so the promise is left to settle into
 * nothing. That is deliberate and worth knowing: a hung `npx` child is reaped
 * when the sidecar exits, not when its budget runs out.
 */
export function startMcpConnections(
  servers: McpServerConfig[],
  options: McpConnectOptions = {}
): LazyMcpToolSet {
  const factories = options.factories ?? defaultMcpConnectionFactories;
  const budgetMs = options.connectTimeoutMs ?? MCP_CONNECT_TIMEOUT_MS;
  const delay = options.delay ?? defaultDelay;

  const openAiTools: OpenAiFunctionTool[] = [];
  const routes = new Map<string, { client: McpClientLike; originalName: string }>();
  const statuses: McpServerConnectionStatus[] = servers.map((config) => ({
    name: config.name,
    state: "connecting",
    toolCount: 0,
  }));

  function snapshot(): McpConnectionReport {
    return { servers: statuses.map((status) => ({ ...status })) };
  }

  async function handshake(
    config: McpServerConfig,
    // Handed back so an abandoned server's client can still be closed. Without
    // it a timed-out stdio server leaves its child process alive for the
    // lifetime of the sidecar -- the timeout would stop us waiting on `npx`
    // while letting `npx` keep running, which is half a fix.
    publish: (client: McpClientLike) => void
  ): Promise<McpToolDescriptor[]> {
    const transport = factories.createTransport(config);
    const client = factories.createClient(config);
    publish(client);
    await client.connect(transport);
    const { tools } = await client.listTools();
    // The client is only published once the whole handshake succeeded, so a
    // half-connected server can never be routed to.
    const { openAiTools: namespaced, routes: toolRoutes } = namespaceMcpTools(
      config.name,
      tools
    );
    for (const [namespacedName, originalName] of toolRoutes) {
      routes.set(namespacedName, { client, originalName });
    }
    openAiTools.push(...namespaced);
    return tools;
  }

  async function connectOne(config: McpServerConfig, index: number): Promise<void> {
    let started: McpClientLike | undefined;
    try {
      // `createTransport`/`createClient` can throw synchronously (a bad command
      // is discovered at spawn time), which inside an async function becomes a
      // rejection this catch owns -- it must never escape as an unhandled one.
      const outcome = await Promise.race([
        handshake(config, (client) => {
          started = client;
        }),
        delay(budgetMs).then(() => TIMED_OUT as typeof TIMED_OUT),
      ]);
      if (outcome === TIMED_OUT) {
        statuses[index] = {
          name: config.name,
          state: "timedOut",
          toolCount: 0,
          error: `No response within ${budgetMs}ms.`,
        };
        console.warn(
          `MCP server "${config.name}" did not answer within ${budgetMs}ms; continuing without its tools.`
        );
        // Closing is what actually ends a hung stdio server's child process.
        // Best-effort: a client stuck mid-handshake may reject or hang here
        // too, and this path must not become the new way to block startup.
        void Promise.resolve()
          .then(() => started?.close?.())
          .catch(() => {});
        return;
      }
      statuses[index] = {
        name: config.name,
        state: "connected",
        toolCount: outcome.length,
      };
    } catch (err) {
      statuses[index] = {
        name: config.name,
        state: "failed",
        toolCount: 0,
        error: err instanceof Error ? err.message : String(err),
      };
      console.warn(`Skipping MCP server "${config.name}": failed to connect or list tools.`, err);
    }
  }

  // Started here, deliberately not awaited: the whole point is that the caller
  // gets its tool set before this settles.
  const ready = Promise.all(servers.map(connectOne)).then(snapshot);

  async function callTool(
    name: string,
    args: unknown,
    signal?: AbortSignal
  ): Promise<{ content: string }> {
    const route = routes.get(name);
    if (!route) {
      throw new Error(`Unknown MCP tool: ${name}`);
    }
    // The MCP SDK takes cancellation through its per-request options, which
    // is how an in-flight remote call is actually abandoned rather than just
    // ignored on return.
    const result = await route.client.callTool(
      {
        name: route.originalName,
        arguments: args as Record<string, unknown> | undefined,
      },
      undefined,
      signal ? { signal } : undefined
    );
    return { content: stringifyToolResultContent(result.content) };
  }

  return { openAiTools, callTool, ready, status: snapshot };
}

function sortedEntries(
  map: Record<string, string> | undefined
): [string, string][] | undefined {
  if (!map) {
    return undefined;
  }
  return Object.entries(map).sort(([a], [b]) => a.localeCompare(b));
}

/**
 * Deep-equality over every field `McpServerConfig` carries -- what
 * `createReloadableMcpToolSet`'s `reload` uses to decide "unchanged" (see its
 * doc comment for why name alone, or a `{command, args}`-only comparison,
 * isn't enough: an `env`-only edit is how a user rotates a leaked
 * credential). `env`/`headers` compare by contents regardless of key order --
 * a config re-saved through a UI that re-serializes the object shouldn't
 * count as a change; `args` compares in order, since argument order is
 * meaningful to the process it starts.
 */
function configsEqual(a: McpServerConfig, b: McpServerConfig): boolean {
  return (
    a.name === b.name &&
    (a.transport ?? "stdio") === (b.transport ?? "stdio") &&
    a.command === b.command &&
    JSON.stringify(a.args ?? []) === JSON.stringify(b.args ?? []) &&
    JSON.stringify(sortedEntries(a.env)) === JSON.stringify(sortedEntries(b.env)) &&
    a.url === b.url &&
    JSON.stringify(sortedEntries(a.headers)) === JSON.stringify(sortedEntries(b.headers))
  );
}

export interface ReloadableMcpToolSet extends LazyMcpToolSet {
  /**
   * Applies a new server list to the running set, in place, and returns
   * **synchronously** -- reload must never reintroduce the boot-blocking
   * hazard `startMcpConnections`'s own doc comment describes, just at a
   * later point in the process's life. `server.ts`'s `onServersChanged`
   * wiring never awaits this, and `mcpConfigRoutes.ts`'s handler never
   * awaits its call into that, for the same reason: a Settings save must
   * not be able to hang against an unreachable server.
   *
   * A server present in both the old and new list, with byte-for-byte the
   * same config (`name`, `transport`, `command`, `args`, `env`, `url`,
   * `headers`), keeps its live connection completely untouched -- same
   * client, no second handshake, no close. Everything else (a server now
   * absent, or present with a changed config) is closed (best-effort,
   * fire-and-forget) and, if still present under the new list, reconnected
   * from scratch with its own budget, concurrently with every other server
   * being (re)connected in the same reload. See the function's own doc
   * comment for why the "leave unchanged servers alone" half of this is
   * load-bearing rather than an optimization that happens to be free.
   */
  reload(servers: McpServerConfig[]): void;
}

interface ReloadEntry {
  config: McpServerConfig;
  status: McpServerConnectionStatus;
  client?: McpClientLike;
  /** This server's own namespaced tools, concatenated across every entry for `openAiTools`. */
  tools: OpenAiFunctionTool[];
  /** namespacedName -> original tool name, this server's own slice of the live routing table. */
  toolNames: Map<string, string>;
}

/**
 * `startMcpConnections` plus the ability to swap the running server list in
 * place -- what makes an MCP server added, edited, enabled, disabled or
 * deleted through the Settings panel take effect immediately instead of at
 * the next sidecar start (`server.ts`'s `onServersChanged` wiring,
 * `mcpConfigRoutes.ts`).
 *
 * Before any `reload()` call this behaves identically to
 * `startMcpConnections`: synchronous construction, `openAiTools` fills in as
 * servers connect, `status()` reports per-server state, `ready` settles and
 * never rejects.
 *
 * `reload(servers)` diffs the new list against the live one *by server
 * name*, then *by value* for a name present in both:
 *
 *  - Absent from the new list: closed (best-effort, fire-and-forget -- same
 *    reasoning as `startMcpConnections`'s own abandoned-timeout close) and
 *    dropped. This is also how a *disabled* server is handled -- `enabled`
 *    is filtered upstream (`resolveMcpServers`/`server.ts` and the config
 *    routes' `onServersChanged` call only ever pass the enabled subset), so
 *    a disabled server reaches here as an absent entry, never as a present
 *    one to special-case.
 *  - Present with an unchanged config (`configsEqual`, deep-equal by value,
 *    not by object reference): left completely alone. A stdio server is an
 *    `npx` child whose cold start already exceeds the sidecar's own 5s
 *    boot-readiness budget (see `MCP_CONNECT_TIMEOUT_MS`'s doc comment), so
 *    a teardown-and-reconnect on every save would cost the user every
 *    *other* server's live connection and blank the agent's whole toolset
 *    for the length of the slowest reconnect, just to apply an edit to one
 *    server.
 *  - Present with a changed config, or new: closed if it was live, then
 *    (re)connected exactly as at boot.
 *
 * A tool call already dispatched before a reload holds its own reference to
 * the client it started on -- `callTool` resolves the route once, at call
 * time, into a local variable -- so a reload that closes that server's
 * connection does not cancel or misroute a call already in flight.
 */
export function createReloadableMcpToolSet(
  servers: McpServerConfig[],
  options: McpConnectOptions = {}
): ReloadableMcpToolSet {
  const factories = options.factories ?? defaultMcpConnectionFactories;
  const budgetMs = options.connectTimeoutMs ?? MCP_CONNECT_TIMEOUT_MS;
  const delay = options.delay ?? defaultDelay;

  const entries = new Map<string, ReloadEntry>();
  const liveRoutes = new Map<string, { client: McpClientLike; originalName: string }>();
  // Bumped per server *name* on every reload that drops or changes it, so a
  // handshake still in flight for that name recognizes -- once it finally
  // settles -- that it has been superseded and must not publish its result
  // into `entries`. Without this, a slow reconnect that finishes after a
  // *second* reload (two Settings saves in quick succession) could stomp a
  // newer entry with a stale one.
  const generationByName = new Map<string, number>();
  let order: string[] = [];
  let ready: Promise<McpConnectionReport> = Promise.resolve({ servers: [] });

  function snapshot(): McpConnectionReport {
    return {
      servers: order.map((name) => ({ ...(entries.get(name) as ReloadEntry).status })),
    };
  }

  function closeClient(client: McpClientLike | undefined): void {
    if (!client) {
      return;
    }
    // Best-effort, fire-and-forget -- same reasoning as
    // `startMcpConnections`'s abandoned-client close: a client that hangs on
    // `close()` must not become a new way to block a reload.
    void Promise.resolve()
      .then(() => client.close?.())
      .catch(() => {});
  }

  /** Replaces (or adds) `name`'s entry, keeping `liveRoutes` in sync with it. */
  function setEntry(name: string, entry: ReloadEntry): void {
    const prev = entries.get(name);
    if (prev) {
      for (const namespacedName of prev.toolNames.keys()) {
        liveRoutes.delete(namespacedName);
      }
    }
    entries.set(name, entry);
    if (entry.client) {
      for (const [namespacedName, originalName] of entry.toolNames) {
        liveRoutes.set(namespacedName, { client: entry.client, originalName });
      }
    }
  }

  /** Removes `name`'s entry and its routes; hands back its client (if any) to close. */
  function dropEntry(name: string): McpClientLike | undefined {
    const prev = entries.get(name);
    if (!prev) {
      return undefined;
    }
    for (const namespacedName of prev.toolNames.keys()) {
      liveRoutes.delete(namespacedName);
    }
    entries.delete(name);
    return prev.client;
  }

  async function connectOne(config: McpServerConfig): Promise<void> {
    const name = config.name;
    const generation = (generationByName.get(name) ?? 0) + 1;
    generationByName.set(name, generation);
    // Set synchronously, before any `await` below -- callers that reload and
    // immediately inspect `status()`/`openAiTools` on the same tick (the
    // "reload returns synchronously" contract) must see "connecting", not a
    // stale or missing entry.
    setEntry(name, {
      config,
      status: { name, state: "connecting", toolCount: 0 },
      tools: [],
      toolNames: new Map(),
    });

    let started: McpClientLike | undefined;
    try {
      const outcome = await Promise.race([
        (async () => {
          const transport = factories.createTransport(config);
          const client = factories.createClient(config);
          started = client;
          await client.connect(transport);
          const { tools } = await client.listTools();
          return { client, tools };
        })(),
        delay(budgetMs).then(() => TIMED_OUT as typeof TIMED_OUT),
      ]);

      const stillCurrent = generationByName.get(name) === generation;

      if (outcome === TIMED_OUT) {
        if (stillCurrent) {
          setEntry(name, {
            config,
            status: {
              name,
              state: "timedOut",
              toolCount: 0,
              error: `No response within ${budgetMs}ms.`,
            },
            tools: [],
            toolNames: new Map(),
          });
        }
        console.warn(
          `MCP server "${config.name}" did not answer within ${budgetMs}ms; continuing without its tools.`
        );
        closeClient(started);
        return;
      }

      if (!stillCurrent) {
        // A later reload already dropped or replaced this name while this
        // handshake was still in flight -- this connection has no entry to
        // publish into. Close it rather than leaking it.
        closeClient(outcome.client);
        return;
      }

      const { openAiTools, routes } = namespaceMcpTools(config.name, outcome.tools);
      setEntry(name, {
        config,
        status: { name, state: "connected", toolCount: outcome.tools.length },
        client: outcome.client,
        tools: openAiTools,
        toolNames: routes,
      });
    } catch (err) {
      const stillCurrent = generationByName.get(name) === generation;
      if (stillCurrent) {
        setEntry(name, {
          config,
          status: {
            name,
            state: "failed",
            toolCount: 0,
            error: err instanceof Error ? err.message : String(err),
          },
          tools: [],
          toolNames: new Map(),
        });
      }
      console.warn(`Skipping MCP server "${config.name}": failed to connect or list tools.`, err);
    }
  }

  function apply(newServers: McpServerConfig[]): void {
    const newByName = new Map(newServers.map((s) => [s.name, s] as const));

    // Pass 1: close and drop anything gone or changed. Snapshotted to an
    // array first so dropping entries mid-loop can't interact with Map
    // iteration.
    for (const [name, entry] of Array.from(entries.entries())) {
      const next = newByName.get(name);
      if (next && configsEqual(entry.config, next)) {
        continue; // unchanged -- left alone entirely, see doc comment above.
      }
      generationByName.set(name, (generationByName.get(name) ?? 0) + 1);
      closeClient(dropEntry(name));
    }

    order = newServers.map((s) => s.name);

    // Pass 2: (re)connect anything new or changed. An unchanged server's
    // entry from before this call is still sitting in `entries` untouched.
    const toConnect: McpServerConfig[] = [];
    for (const config of newServers) {
      const current = entries.get(config.name);
      if (current && configsEqual(current.config, config)) {
        continue;
      }
      toConnect.push(config);
    }

    ready = Promise.all(toConnect.map(connectOne)).then(snapshot);
  }

  apply(servers);

  async function callTool(
    name: string,
    args: unknown,
    signal?: AbortSignal
  ): Promise<{ content: string }> {
    const route = liveRoutes.get(name);
    if (!route) {
      throw new Error(`Unknown MCP tool: ${name}`);
    }
    const result = await route.client.callTool(
      {
        name: route.originalName,
        arguments: args as Record<string, unknown> | undefined,
      },
      undefined,
      signal ? { signal } : undefined
    );
    return { content: stringifyToolResultContent(result.content) };
  }

  return {
    get openAiTools() {
      return order.flatMap((name) => entries.get(name)?.tools ?? []);
    },
    callTool,
    get ready() {
      return ready;
    },
    status: snapshot,
    reload: apply,
  };
}

/** What a server would hand the agent, as reported by "Test Connection". */
export interface McpProbeResult {
  tools: Array<{ name: string; description?: string }>;
}

/**
 * Connects to a single candidate server, lists its tools, and disconnects --
 * backing `POST /config/mcp/test`. Nothing is saved, and the connection is
 * closed again afterwards.
 *
 * Failures propagate: the route turns them into `{success:false, error}`, and
 * the real message ("spawn npx ENOENT", an auth failure) is the whole point of
 * the button. The tools are the decision-relevant part of the result -- an MCP
 * server is an unsandboxed capability grant, so the user should see what they
 * are granting before saving it.
 */
export async function probeMcpServer(
  config: McpServerConfig,
  factories: McpConnectionFactories = defaultMcpConnectionFactories
): Promise<McpProbeResult> {
  const transport = factories.createTransport(config);
  const client = factories.createClient(config);
  await client.connect(transport);
  try {
    const { tools } = await client.listTools();
    return {
      tools: tools.map((tool) => ({ name: tool.name, description: tool.description })),
    };
  } finally {
    try {
      await client.close?.();
    } catch {
      // best-effort teardown: a probe that answered must not fail on cleanup
    }
  }
}
