import { describe, expect, test } from "bun:test";
import { renderToolCatalog, GENERATED_MARKER } from "../../src/agent/toolCatalog";

/**
 * T9 of the dsh-borrowings plan
 * (docs/superpowers/specs/2026-08-13-dsh-borrowings-plan.md §10).
 *
 * The point of a GENERATED catalog is that it cannot drift, so these tests
 * pin the two properties that make that true: it is derived from the actual
 * `openAiTools` descriptors (not a hand-kept list), and it is byte-stable for
 * unchanged input so `--check` is meaningful.
 */

const SAMPLE: unknown[] = [
  {
    type: "function",
    function: {
      name: "opentype__bash",
      description: "Run a shell command with /bin/bash.",
      parameters: {
        type: "object",
        properties: { command: { type: "string", description: "The bash command line to run." } },
        required: ["command"],
      },
    },
  },
  {
    type: "function",
    function: {
      name: "opentype__list_dir",
      description: "List a directory.",
      parameters: { type: "object", properties: {} },
    },
  },
];

describe("renderToolCatalog", () => {
  test("renders every tool's name and description", () => {
    const markdown = renderToolCatalog(SAMPLE);

    expect(markdown).toContain("opentype__bash");
    expect(markdown).toContain("Run a shell command with /bin/bash.");
    expect(markdown).toContain("opentype__list_dir");
    expect(markdown).toContain("List a directory.");
  });

  test("renders each tool's parameter schema", () => {
    const markdown = renderToolCatalog(SAMPLE);

    expect(markdown).toContain("command");
    expect(markdown).toContain("The bash command line to run.");
  });

  test("carries the do-not-edit marker", () => {
    expect(renderToolCatalog(SAMPLE)).toContain(GENERATED_MARKER);
  });

  test("states that user-configured MCP tools are NOT in the catalog", () => {
    // Without this, a reader takes the catalog for the full set the model
    // sees, which it never is: MCP servers are user config resolved at run
    // time (docs/model-context-inventory.md §3.5).
    expect(renderToolCatalog(SAMPLE).toUpperCase()).toContain("MCP");
  });

  test("is byte-stable for the same input, so --check is meaningful", () => {
    expect(renderToolCatalog(SAMPLE)).toBe(renderToolCatalog(SAMPLE));
  });

  test("orders tools deterministically regardless of input order", () => {
    const reversed = [...SAMPLE].reverse();

    expect(renderToolCatalog(reversed)).toBe(renderToolCatalog(SAMPLE));
  });

  test("ignores non-function entries instead of throwing", () => {
    const withJunk = [...SAMPLE, { type: "not_a_function" }, null, "nonsense"];

    expect(() => renderToolCatalog(withJunk)).not.toThrow();
    expect(renderToolCatalog(withJunk)).toContain("opentype__bash");
  });

  test("renders an explicit empty state rather than a bare header", () => {
    const markdown = renderToolCatalog([]);

    expect(markdown).toContain(GENERATED_MARKER);
    expect(markdown.toLowerCase()).toContain("no tools");
  });
});

describe("the real built-in tool set", () => {
  test("every shipped core tool appears in the generated catalog", async () => {
    const { createCoreTools } = await import("../../src/agent/coreTools");
    const markdown = renderToolCatalog(createCoreTools({}).openAiTools);

    for (const name of [
      "opentype__bash",
      "opentype__python",
      "opentype__read_file",
      "opentype__list_dir",
      "opentype__grep",
      "opentype__web_search",
      "opentype__web_fetch",
      "opentype__open_file",
    ]) {
      expect(markdown).toContain(name);
    }
  });
});
