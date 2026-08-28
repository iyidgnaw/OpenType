import { describe, expect, test } from "bun:test";
import * as fs from "node:fs";
import * as path from "node:path";
import { parseFrontmatter } from "../../src/resources/frontmatter";

/**
 * The six shipped skills from design §3.5. This is deliberately a CONTENT
 * test, loose on wording (we don't assert anything about what the procedure
 * actually says) and strict on structure (the file exists, parses, and has
 * the fields/length a real skill needs to be worth the `load_skill` round
 * trip -- a one-line body would not be).
 */

const SKILLS_DIR = path.join(import.meta.dir, "../../skills");

const EXPECTED_SKILLS = [
  "find-and-open",
  "organize-files",
  "meeting-notes-to-todos",
  "data-analysis",
  "document-summary",
  "draft-message",
];

describe("built-in skills (design §3.5)", () => {
  test("sidecar/skills/ directory exists", () => {
    expect(fs.existsSync(SKILLS_DIR)).toBe(true);
  });

  for (const name of EXPECTED_SKILLS) {
    test(`${name}/SKILL.md exists, parses, and has a non-trivial body`, () => {
      const skillPath = path.join(SKILLS_DIR, name, "SKILL.md");
      expect(fs.existsSync(skillPath)).toBe(true);

      const raw = fs.readFileSync(skillPath, "utf8");
      const { attrs, body } = parseFrontmatter(raw);

      expect(attrs.name?.trim()).toBe(name);
      expect(attrs.description?.trim().length ?? 0).toBeGreaterThan(0);
      expect(body.trim().length).toBeGreaterThan(200);
    });
  }
});
