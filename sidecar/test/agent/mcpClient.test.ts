import { describe, expect, test } from "bun:test";
import {
  connectConfiguredMcpServers,
  type McpClientLike,
  type McpConnectionFactories,
  type McpServerConfig,
} from "../../src/agent/mcpClient";

/**
 * Fake standing in for the SDK's Client, per server. Records the transport it
 * was connected with and lets tests script tools/call responses or a
 * connect() failure.
 */
function makeFakeClient(options: {
  tools: Array<{ name: string; description?: string; inputSchema?: unknown }>;
  failConnect?: boolean;
  onCallTool?: (params: { name: string; arguments?: unknown }) => unknown;
}): McpClientLike {
  return {
    async connect() {
      if (options.failConnect) {
        throw new Error("boom: could not connect");
      }
    },
    async listTools() {
      return { tools: options.tools };
    },
    async callTool(params) {
      const content = options.onCallTool
        ? options.onCallTool(params)
        : { called: params.name, arguments: params.arguments };
      return { content: [{ type: "text", text: JSON.stringify(content) }] };
    },
  };
}

function makeFactories(
  clientsByServerName: Record<string, McpClientLike>
): McpConnectionFactories {
  let lastRequestedName: string | undefined;
  return {
    createTransport: (config: McpServerConfig) => {
      lastRequestedName = config.name;
      return { __fakeTransportFor: config.name };
    },
    createClient: () => {
      const name = lastRequestedName;
      if (!name || !clientsByServerName[name]) {
        throw new Error(`no fake client configured for server ${name}`);
      }
      return clientsByServerName[name];
    },
  };
}

describe("connectConfiguredMcpServers", () => {
  test("empty/unset config yields an empty tool set with no connection attempts", async () => {
    let createTransportCalls = 0;
    const factories: McpConnectionFactories = {
      createTransport: () => {
        createTransportCalls += 1;
        return {};
      },
      createClient: () => makeFakeClient({ tools: [] }),
    };

    const resultUndefined = await connectConfiguredMcpServers(undefined, factories);
    const resultEmptyArray = await connectConfiguredMcpServers("[]", factories);
    const resultUnparseable = await connectConfiguredMcpServers("not json", factories);

    expect(resultUndefined.openAiTools).toEqual([]);
    expect(resultEmptyArray.openAiTools).toEqual([]);
    expect(resultUnparseable.openAiTools).toEqual([]);
    expect(createTransportCalls).toBe(0);
  });

  test("a single-server config converts and namespaces its tools", async () => {
    const searchClient = makeFakeClient({
      tools: [
        {
          name: "search",
          description: "Search the web",
          inputSchema: { type: "object", properties: { query: { type: "string" } } },
        },
      ],
    });
    const factories = makeFactories({ search_server: searchClient });

    const config: McpServerConfig[] = [
      { name: "search_server", command: "node", args: ["search-server.js"] },
    ];
    const result = await connectConfiguredMcpServers(JSON.stringify(config), factories);

    expect(result.openAiTools).toEqual([
      {
        type: "function",
        function: {
          name: "search_server__search",
          description: "Search the web",
          parameters: { type: "object", properties: { query: { type: "string" } } },
        },
      },
    ]);
  });

  test("callTool routes a namespaced call back to the right server and original tool name", async () => {
    const clientA = makeFakeClient({
      tools: [{ name: "lookup", description: "look things up" }],
      onCallTool: (params) => ({ from: "A", name: params.name, args: params.arguments }),
    });
    const clientB = makeFakeClient({
      tools: [{ name: "lookup", description: "also look things up" }],
      onCallTool: (params) => ({ from: "B", name: params.name, args: params.arguments }),
    });
    const factories = makeFactories({ serverA: clientA, serverB: clientB });

    const config: McpServerConfig[] = [
      { name: "serverA", command: "node", args: ["a.js"] },
      { name: "serverB", command: "node", args: ["b.js"] },
    ];
    const result = await connectConfiguredMcpServers(JSON.stringify(config), factories);

    const responseA = await result.callTool("serverA__lookup", { q: "x" });
    const responseB = await result.callTool("serverB__lookup", { q: "y" });

    expect(JSON.parse(responseA.content)).toEqual({ from: "A", name: "lookup", args: { q: "x" } });
    expect(JSON.parse(responseB.content)).toEqual({ from: "B", name: "lookup", args: { q: "y" } });
  });

  test("a connection failure for one server doesn't prevent others from connecting", async () => {
    const goodClient = makeFakeClient({
      tools: [{ name: "ok_tool", description: "fine" }],
    });
    const badClient = makeFakeClient({ tools: [], failConnect: true });
    const factories = makeFactories({ goodServer: goodClient, badServer: badClient });

    const config: McpServerConfig[] = [
      { name: "badServer", command: "node", args: ["bad.js"] },
      { name: "goodServer", command: "node", args: ["good.js"] },
    ];
    const result = await connectConfiguredMcpServers(JSON.stringify(config), factories);

    expect(result.openAiTools).toEqual([
      {
        type: "function",
        function: {
          name: "goodServer__ok_tool",
          description: "fine",
          parameters: { type: "object", properties: {} },
        },
      },
    ]);
  });
});
