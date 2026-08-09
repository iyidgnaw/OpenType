import { describe, expect, test } from "bun:test";
import { mergeToolSets, type ToolSet } from "../../src/agent/toolSets";

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
});
