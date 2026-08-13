/**
 * Generic "a set of callable tools" shape shared by `McpToolSet`
 * (`agent/mcpClient.ts`) and `BuiltInToolSet` (`agent/builtInTools.ts`).
 * Deliberately structural rather than importing either concrete type: this
 * module knows nothing about MCP or built-in tools specifically, only how to
 * combine anything shaped like this into one.
 */
export interface ToolSet {
  openAiTools: unknown[];
  /**
   * `signal` is the run's cancellation (T1). Every combinator below forwards
   * it unchanged: a wrapper may observe it, but none may drop it -- dropping
   * it would silently detach the user's stop button from whatever it wraps.
   */
  callTool: (
    name: string,
    args: unknown,
    signal?: AbortSignal
  ) => Promise<{ content: string }>;
}

function toolNamesIn(set: ToolSet): Set<string> {
  const names = new Set<string>();
  for (const tool of set.openAiTools) {
    const name = (tool as { function?: { name?: unknown } } | undefined)?.function?.name;
    if (typeof name === "string") {
      names.add(name);
    }
  }
  return names;
}

/**
 * Combines any number of tool sets (built-in + however many MCP servers are
 * connected) into one: `openAiTools` is the concatenation of all of them
 * (each set is already responsible for namespace-prefixing its own tool
 * names -- `opentype__...` for built-ins, `serverName__...` for MCP -- so
 * collisions are not expected here), and `callTool` routes a call to
 * whichever set actually owns that tool name.
 */
export function mergeToolSets(...sets: ToolSet[]): ToolSet {
  const openAiTools = sets.flatMap((set) => set.openAiTools);
  const setsByToolName = new Map<string, ToolSet>();
  for (const set of sets) {
    for (const name of toolNamesIn(set)) {
      setsByToolName.set(name, set);
    }
  }

  async function callTool(
    name: string,
    args: unknown,
    signal?: AbortSignal
  ): Promise<{ content: string }> {
    const owningSet = setsByToolName.get(name);
    if (!owningSet) {
      throw new Error(`Unknown tool: ${name}`);
    }
    return owningSet.callTool(name, args, signal);
  }

  return { openAiTools, callTool };
}

/**
 * Narrows a tool set to an allowlist of tool names (open-file + ask-web
 * design, docs/superpowers/specs/2026-08-13-b2-open-file-and-ask-web-design.md
 * §2 -- how `/oneshot/ask` gets its web-only toolset out of the full merged
 * set). `openAiTools` keeps the source's own descriptor objects, unmodified
 * and in source order; `callTool` delegates kept names to the source set and
 * throws the same "Unknown tool" error `mergeToolSets` uses for everything
 * else -- a filtered-out call never reaches the source set, so filtering an
 * approval-wrapped set keeps the gate for what remains.
 */
export function filterToolSet(set: ToolSet, names: string[]): ToolSet {
  const allowed = new Set(names);
  const openAiTools = set.openAiTools.filter((tool) => {
    const name = (tool as { function?: { name?: unknown } } | undefined)?.function?.name;
    return typeof name === "string" && allowed.has(name);
  });

  async function callTool(
    name: string,
    args: unknown,
    signal?: AbortSignal
  ): Promise<{ content: string }> {
    if (!allowed.has(name)) {
      throw new Error(`Unknown tool: ${name}`);
    }
    return set.callTool(name, args, signal);
  }

  return { openAiTools, callTool };
}
