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
    return tools.map((tool) => {
      const namespacedName = `${config.name}__${tool.name}`;
      routes.set(namespacedName, { client, originalName: tool.name });
      openAiTools.push({
        type: "function",
        function: {
          name: namespacedName,
          description: tool.description ?? "",
          parameters: tool.inputSchema ?? { type: "object", properties: {} },
        },
      });
      return tool;
    });
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
