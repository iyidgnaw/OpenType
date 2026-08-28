import { describe, expect, test } from "bun:test";
import { filterToolSet, mergeToolSets, type ToolSet } from "../../src/agent/toolSets";

function makeSet(toolNames: string[], onCall?: (name: string, args: unknown) => string): ToolSet {
  return {
    openAiTools: toolNames.map((name) => ({ type: "function", function: { name } })),
    callTool: async (name, args) => ({ content: onCall ? onCall(name, args) : `called ${name}` }),
  };
}

describe("mergeToolSets", () => {
  test("concatenates openAiTools from every set", () => {
    const a = makeSet(["opentype__remember_fact"]);
    const b = makeSet(["search_server__search"]);

    const merged = mergeToolSets(a, b);

    expect(merged.openAiTools).toEqual([
      { type: "function", function: { name: "opentype__remember_fact" } },
      { type: "function", function: { name: "search_server__search" } },
    ]);
  });

  test("routes callTool to the set that owns the tool name", async () => {
    const a = makeSet(["opentype__remember_fact"], (name) => `A handled ${name}`);
    const b = makeSet(["search_server__search"], (name) => `B handled ${name}`);
    const merged = mergeToolSets(a, b);

    const resultA = await merged.callTool("opentype__remember_fact", {});
    const resultB = await merged.callTool("search_server__search", {});

    expect(resultA.content).toBe("A handled opentype__remember_fact");
    expect(resultB.content).toBe("B handled search_server__search");
  });

  test("throws for a tool name owned by none of the sets", async () => {
    const merged = mergeToolSets(makeSet(["a__tool"]));
    await expect(merged.callTool("unknown__tool", {})).rejects.toThrow(/unknown/i);
  });

  test("merging zero sets yields an empty, still-callable tool set", async () => {
    const merged = mergeToolSets();
    expect(merged.openAiTools).toEqual([]);
    await expect(merged.callTool("anything", {})).rejects.toThrow();
  });

  test("merging a single set is a no-op passthrough", async () => {
    const a = makeSet(["only__tool"], () => "ok");
    const merged = mergeToolSets(a);
    expect(merged.openAiTools).toEqual(a.openAiTools);
    const result = await merged.callTool("only__tool", {});
    expect(result.content).toBe("ok");
  });

  // Stage-4 review fix (first-party-tools-skills-and-agents design §4.3's
  // `applyAgentToolAllowlist` wraps this in `filterToolSet` -- an agent's
  // `tools` allowlist is applied to a `mergeToolSets` result that keeps
  // growing as MCP servers finish connecting, exactly the scenario this test
  // is for): a tool added to a source set AFTER `mergeToolSets` runs is
  // still visible through it, because `openAiTools` re-reads its sources on
  // every access rather than snapshotting them once at merge time.
  test("a tool set that grows after merging (e.g. an MCP server connecting late) is still visible through the merge", () => {
    const growable: ToolSet = {
      openAiTools: [{ type: "function", function: { name: "opentype__bash" } }],
      callTool: async () => ({ content: "" }),
    };
    const merged = mergeToolSets(growable);
    expect(merged.openAiTools).toEqual([{ type: "function", function: { name: "opentype__bash" } }]);

    (growable.openAiTools as unknown[]).push({
      type: "function",
      function: { name: "search_server__search" },
    });

    expect(merged.openAiTools).toEqual([
      { type: "function", function: { name: "opentype__bash" } },
      { type: "function", function: { name: "search_server__search" } },
    ]);
  });
});

describe("filterToolSet", () => {
  test("keeps only the named tools, in source order", () => {
    const set = makeSet(["opentype__bash", "opentype__grep", "opentype__python"]);
    const filtered = filterToolSet(set, ["opentype__bash", "opentype__python"]);

    expect(filtered.openAiTools).toEqual([
      { type: "function", function: { name: "opentype__bash" } },
      { type: "function", function: { name: "opentype__python" } },
    ]);
  });

  test("callTool delegates a kept name to the source set and rejects an excluded one", async () => {
    const set = makeSet(["opentype__bash", "opentype__grep"], (name) => `ran ${name}`);
    const filtered = filterToolSet(set, ["opentype__bash"]);

    const result = await filtered.callTool("opentype__bash", {});
    expect(result.content).toBe("ran opentype__bash");
    await expect(filtered.callTool("opentype__grep", {})).rejects.toThrow(/unknown/i);
  });

  // The bug this pins: `filterToolSet` used to filter `set.openAiTools`
  // once, at construction time, into a plain array. Composed on top of
  // `mergeToolSets` (as `applyAgentToolAllowlist` does for a tools-
  // restricted agent, design §4.3), that snapshot silently hid any tool
  // (e.g. an MCP server) that connected after the filter was built, even
  // though it's on the allowlist and the underlying merged set already has
  // it -- exactly the staleness `mergeToolSets`'s own live getter exists to
  // avoid one layer down. Fixed by making `filterToolSet`'s `openAiTools` a
  // getter too, so it re-filters the live source on every access.
  test("a source tool that appears after filtering (e.g. late-connecting MCP, composed with mergeToolSets) is still visible if it's on the allowlist", () => {
    const growable: ToolSet = {
      openAiTools: [{ type: "function", function: { name: "opentype__bash" } }],
      callTool: async () => ({ content: "" }),
    };
    const merged = mergeToolSets(growable);
    const filtered = filterToolSet(merged, ["opentype__bash", "search_server__search"]);

    expect(filtered.openAiTools).toEqual([{ type: "function", function: { name: "opentype__bash" } }]);

    (growable.openAiTools as unknown[]).push({
      type: "function",
      function: { name: "search_server__search" },
    });

    expect(filtered.openAiTools).toEqual([
      { type: "function", function: { name: "opentype__bash" } },
      { type: "function", function: { name: "search_server__search" } },
    ]);
  });
});
