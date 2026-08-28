import { describe, expect, test } from "bun:test";
import { createSkillTool } from "../../src/skills/skillTool";
import type { Skill } from "../../src/skills/skillStore";

/**
 * `opentype__load_skill` (design §3.3): the second half of progressive
 * disclosure -- the index is a name+description line, this tool is how the
 * model expands one of those names into the skill's full SKILL.md body
 * (frontmatter stripped, since the model needs the procedure, not the
 * metadata that routed it there).
 *
 * `createSkillTool` takes an injected store lookup (`{ list(): Skill[] }`,
 * the same shape `createSkillStore` returns) rather than reading real disk --
 * consistent with `builtInTools.test.ts`'s pattern of injecting the backing
 * store directly instead of constructing the real one.
 */

function skill(patch: Partial<Skill>): Skill {
  return {
    name: "s",
    description: "d",
    body: "b",
    root: "/tmp/root",
    path: "/tmp/root/s/SKILL.md",
    ...patch,
  };
}

function storeWith(skills: Skill[]): { list(): Skill[] } {
  return { list: () => skills };
}

describe("createSkillTool", () => {
  test("openAiTools contains exactly one well-formed opentype__load_skill descriptor with a required name string param", () => {
    const tool = createSkillTool({ store: storeWith([]) });

    expect(tool.openAiTools).toHaveLength(1);
    const descriptor = tool.openAiTools[0] as {
      type: string;
      function: { name: string; parameters: { properties: Record<string, { type: string }>; required: string[] } };
    };
    expect(descriptor.type).toBe("function");
    expect(descriptor.function.name).toBe("opentype__load_skill");
    expect(descriptor.function.parameters.properties.name?.type).toBe("string");
    expect(descriptor.function.parameters.required).toContain("name");
  });

  test("calling it returns the matching skill's SKILL.md body, frontmatter stripped", async () => {
    const tool = createSkillTool({
      store: storeWith([
        skill({ name: "organize-files", description: "d", body: "Step 1.\nStep 2." }),
      ]),
    });

    const result = await tool.callTool("opentype__load_skill", { name: "organize-files" });

    expect(result.content).toBe("Step 1.\nStep 2.");
    // The frontmatter block itself must not leak through.
    expect(result.content).not.toContain("---");
    expect(result.content).not.toContain("description:");
  });

  test("unknown skill name returns an Error listing the available names", async () => {
    const tool = createSkillTool({
      store: storeWith([skill({ name: "find-and-open" }), skill({ name: "organize-files" })]),
    });

    const result = await tool.callTool("opentype__load_skill", { name: "does-not-exist" });

    expect(result.content.startsWith("Error:")).toBe(true);
    expect(result.content).toContain("find-and-open");
    expect(result.content).toContain("organize-files");
  });

  test("missing or empty name argument returns an Error", async () => {
    const tool = createSkillTool({ store: storeWith([skill({ name: "a" })]) });

    const missing = await tool.callTool("opentype__load_skill", {});
    expect(missing.content.startsWith("Error:")).toBe(true);

    const empty = await tool.callTool("opentype__load_skill", { name: "" });
    expect(empty.content.startsWith("Error:")).toBe(true);

    const whitespace = await tool.callTool("opentype__load_skill", { name: "   " });
    expect(whitespace.content.startsWith("Error:")).toBe(true);
  });

  test("an oversized body is clamped the same way coreTools.ts's clampAtSource clamps (25,000 chars + truncation marker)", async () => {
    // Design §3.3 says the body is returned "过 clampAtSource" -- the exact
    // same source-side clamp `coreTools.ts` uses for every other tool result
    // (25,000 chars, then "\n...[truncated]"), not a bespoke limit.
    const longBody = "x".repeat(30_000);
    const tool = createSkillTool({ store: storeWith([skill({ name: "big", body: longBody })]) });

    const result = await tool.callTool("opentype__load_skill", { name: "big" });

    expect(result.content).toBe(`${"x".repeat(25_000)}\n...[truncated]`);
  });

  test("an unknown tool name throws (routing contract)", async () => {
    const tool = createSkillTool({ store: storeWith([]) });

    await expect(tool.callTool("opentype__not_a_real_tool", {})).rejects.toThrow();
  });
});
