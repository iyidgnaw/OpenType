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
  /**
   * Read through to the sets on every access rather than snapshotting them
   * here. MCP tools arrive *after* this merge runs: `startMcpConnections`
   * returns a set immediately and fills it in as servers finish connecting, so
   * a merge that flattened once at assembly time would hand the model a list
   * that could only ever be empty of MCP tools -- the set would look present
   * and be permanently useless, which is worse than the boot hang it replaced
   * because nothing would appear broken.
   */
  function currentTools(): unknown[] {
    return sets.flatMap((set) => set.openAiTools);
  }

  /** Resolved per call for the same reason: ownership is not known up front. */
  function owner(name: string): ToolSet | undefined {
    return sets.find((set) => toolNamesIn(set).has(name));
  }

  async function callTool(
    name: string,
    args: unknown,
    signal?: AbortSignal
  ): Promise<{ content: string }> {
    const owningSet = owner(name);
    if (!owningSet) {
      throw new Error(`Unknown tool: ${name}`);
    }
    return owningSet.callTool(name, args, signal);
  }

  return {
    get openAiTools() {
      return currentTools();
    },
    callTool,
  };
}

/**
 * Narrows a tool set to an allowlist of tool names (open-file + ask-web
 * design, docs/superpowers/specs/2026-08-13-b2-open-file-and-ask-web-design.md
 * §2 -- how `/oneshot/ask` gets its web-only toolset out of the full merged
 * set; reused since the 2026-08-28 first-party-tools-skills-and-agents
 * design §4.3 by `agentDefinitions.ts`'s `applyAgentToolAllowlist` to narrow
 * to a selected agent's own `tools` frontmatter). `openAiTools` re-filters
 * `set.openAiTools` on every access (a getter, not a snapshot taken once at
 * call time) for the same reason `mergeToolSets` above reads its sources
 * live: `set` itself may be a `mergeToolSets` result whose own tool list
 * grows as MCP servers finish connecting AFTER this filter was constructed
 * (e.g. mid-run, while a single `/agent/run` call with a `tools`-restricted
 * agent is still executing several tool-calling turns) -- a one-time
 * `.filter()` here would freeze that list at construction time and silently
 * hide any such tool for the rest of the run, even though it is on the
 * allowlist and the underlying set already has it. `callTool` delegates
 * kept names to the source set and throws the same "Unknown tool" error
 * `mergeToolSets` uses for everything else -- a filtered-out call never
 * reaches the source set, so filtering an approval-wrapped set keeps the
 * gate for what remains.
 */
export function filterToolSet(set: ToolSet, names: string[]): ToolSet {
  const allowed = new Set(names);

  function currentOpenAiTools(): unknown[] {
    return set.openAiTools.filter((tool) => {
      const name = (tool as { function?: { name?: unknown } } | undefined)?.function?.name;
      return typeof name === "string" && allowed.has(name);
    });
  }

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

  return {
    get openAiTools() {
      return currentOpenAiTools();
    },
    callTool,
  };
}
