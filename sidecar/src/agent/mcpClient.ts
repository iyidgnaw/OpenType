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
  createClient: () => McpClientLike;
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
  factories: McpConnectionFactories = defaultMcpConnectionFactories
): Promise<McpToolSet> {
  const configs = parseServerConfigs(configJson);
  const openAiTools: OpenAiFunctionTool[] = [];
  const routes = new Map<string, { client: McpClientLike; originalName: string }>();

  for (const config of configs) {
    try {
      const transport = factories.createTransport(config);
      const client = factories.createClient();
      await client.connect(transport);
      const { tools } = await client.listTools();
      for (const tool of tools) {
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
      }
    } catch (err) {
      console.warn(`Skipping MCP server "${config.name}": failed to connect or list tools.`, err);
    }
  }

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

  return { openAiTools, callTool };
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
  const client = factories.createClient();
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
