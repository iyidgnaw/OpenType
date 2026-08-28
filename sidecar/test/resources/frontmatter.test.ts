import { describe, expect, test } from "bun:test";
import { parseFrontmatter } from "../../src/resources/frontmatter";

/**
 * `parseFrontmatter` is a deliberately small hand-rolled parser for the
 * leading `---\n<yaml-ish>\n---\n<body>` block Claude Code's SKILL.md/agent
 * .md files use (design §3.1/§4.1,
 * docs/superpowers/specs/2026-08-28-first-party-tools-skills-and-agents-design.md).
 * There is no YAML dependency in this repo and this batch does not add one,
 * so these tests hold it to what skill/agent frontmatter actually needs
 * (flat `key: value` lines), not to general YAML (nested/multi-line values
 * may come back as an opaque raw string -- untested here on purpose).
 *
 * Every fixture is built from an array of lines via `.join("\n")` (or
 * `.join("\r\n")` for the CRLF case) so the exact raw input -- and the exact
 * expected body -- is unambiguous from reading the test, not dependent on
 * guessing how a template literal's leading/trailing whitespace behaves.
 */

function raw(lines: string[], eol = "\n"): string {
  return lines.join(eol);
}

describe("parseFrontmatter", () => {
  test("normal parse: keys and body are separated correctly", () => {
    const input = raw([
      "---",
      "name: organize-files",
      "description: Use when the user asks to tidy up a folder",
      "---",
      "Step 1: look at the folder.",
      "Step 2: sort it.",
    ]);

    const { attrs, body } = parseFrontmatter(input);

    expect(attrs.name).toBe("organize-files");
    expect(attrs.description).toBe("Use when the user asks to tidy up a folder");
    expect(body).toBe(raw(["Step 1: look at the folder.", "Step 2: sort it."]));
  });

  test("no frontmatter at all: empty attrs, whole file as body", () => {
    const input = raw(["Just some body text.", "No frontmatter here at all."]);

    const { attrs, body } = parseFrontmatter(input);

    expect(attrs).toEqual({});
    expect(body).toBe(input);
  });

  test("unterminated opening --- is treated as no frontmatter, and must not swallow the file", () => {
    // A naive "find the next --- anywhere" parser would either throw or eat
    // the rest of the file looking for a closing fence that never comes.
    // The contract here is specifically: nothing is lost. `body` must be the
    // ENTIRE original input, opening "---" line included, not a truncation
    // starting after some guessed cutoff.
    const input = raw(["---", "name: incomplete", "there is no closing fence below this line"]);

    const { attrs, body } = parseFrontmatter(input);

    expect(attrs).toEqual({});
    expect(body).toBe(input);
  });

  test("a colon inside a value keeps everything after the FIRST colon", () => {
    const input = raw([
      "---",
      "description: Use when: the user asks",
      "---",
      "body",
    ]);

    const { attrs } = parseFrontmatter(input);

    // Splitting on the first colon must land on "description" as the key and
    // keep the rest -- including the second colon -- verbatim in the value.
    expect(attrs.description).toBe("Use when: the user asks");
  });

  test("quoted values are unquoted (double and single quotes)", () => {
    const input = raw([
      "---",
      'name: "organize-files"',
      "description: 'Use when tidy'",
      "---",
      "body",
    ]);

    const { attrs } = parseFrontmatter(input);

    expect(attrs.name).toBe("organize-files");
    expect(attrs.description).toBe("Use when tidy");
  });

  test("comma-separated list values come back as one raw string, not pre-split", () => {
    // Design §4.3: the `tools` frontmatter field on an agent file is a
    // caller-side allowlist the AGENT layer splits, not this parser -- this
    // parser's job stops at handing back the value verbatim.
    const input = raw(["---", "tools: Bash, Read, Grep", "---", "body"]);

    const { attrs } = parseFrontmatter(input);

    expect(attrs.tools).toBe("Bash, Read, Grep");
  });

  test("unknown keys are preserved, not dropped", () => {
    const input = raw([
      "---",
      "name: x",
      "weirdField: some value",
      "displayName: 别名",
      "---",
      "body",
    ]);

    const { attrs } = parseFrontmatter(input);

    expect(attrs.name).toBe("x");
    expect(attrs.weirdField).toBe("some value");
    expect(attrs.displayName).toBe("别名");
  });

  test("CRLF line endings work: no stray \\r in keys, values, or body", () => {
    const input = raw(["---", "name: x", "description: y", "---", "Body line one.", "Body line two."], "\r\n");

    const { attrs, body } = parseFrontmatter(input);

    expect(attrs.name).toBe("x");
    expect(attrs.description).toBe("y");
    expect(attrs.name).not.toContain("\r");
    expect(attrs.description).not.toContain("\r");
    expect(body).not.toContain("\r");
    expect(body).toBe(raw(["Body line one.", "Body line two."]));
  });

  test("leading/trailing whitespace on keys and values is trimmed", () => {
    const input = raw(["---", "  name  :   organize-files  ", "---", "body"]);

    const { attrs } = parseFrontmatter(input);

    expect(attrs.name).toBe("organize-files");
    // The trimmed key itself must be "name", not "  name  " -- a caller doing
    // `attrs.name` would otherwise never find it.
    expect(Object.keys(attrs)).toContain("name");
  });
});
