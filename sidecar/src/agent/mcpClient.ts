import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";

/**
 * Config shape for one MCP server, as read from the OPENTYPE_MCP_SERVERS env
 * var. There is no configuration UI for this yet -- setting this env var
 * before starting the sidecar is the only way to attach an MCP server
 * tonight.
 */
export interface McpServerConfig {
  name: string;
  command: string;
  args: string[];
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
  return new StdioClientTransport({ command: config.command, args: config.args });
}

function defaultCreateClient(): McpClientLike {
  return new Client({ name: "opentype-sidecar", version: "0.1.0" }) as unknown as McpClientLike;
}

export const defaultMcpConnectionFactories: McpConnectionFactories = {
  createTransport: defaultCreateTransport,
  createClient: defaultCreateClient,
};

function parseServerConfigs(configJson: string | undefined): McpServerConfig[] {
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
 * Connects to every MCP server named in `OPENTYPE_MCP_SERVERS` -- a JSON
 * array of `{name, command, args}` -- over stdio, lists each server's tools,
 * and converts them into one combined OpenAI-style tool list plus a
 * dispatcher that routes a call back to the right server/original tool name.
 *
 * Per spec (docs/superpowers/specs/2026-08-09-b2-agent-runtime-v1-design.md
 * §1), only no-side-effect (search/read/lookup/compute) MCP servers are
 * expected to be connected here; this is a policy the user is trusted to
 * follow, not something this module enforces.
 *
 * Unset/unparseable config defaults to no servers (logged, not thrown). A
 * server that fails to connect is logged and skipped -- it never prevents
 * the other configured servers from connecting.
 */
export async function connectConfiguredMcpServers(
  configJson: string | undefined,
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
