import { describe, expect, test } from "bun:test";
import * as path from "node:path";
import { resolveSkillRoots } from "../../src/skills/skillRoots";

/**
 * Design §3.2 pins a SPECIFIC three-root default order for skill discovery:
 *
 *   1. built-in (bundled `skills/`, overridable via `OPENTYPE_SKILLS_DIR`)
 *   2. user (`~/.opentype/skills/`)
 *   3. compat (`~/.claude/skills/`) -- read-only, never written to
 *
 * skillStore.test.ts deliberately only proves the generic "roots are
 * consulted in whatever order they're given" behavior using temp dirs (see
 * its own docstring) -- it explicitly leaves the real default assembly out
 * of scope. Nothing else in this batch pins the actual three real paths or
 * their order, and §3.2 calls the `~/.claude/skills` compat root "the
 * headline feature" of this section, so an implementation that silently
 * drops or reorders it would ship with no test catching it.
 *
 * `resolveSkillRoots` is a pure function (no filesystem access) so this is
 * testable without touching the developer's real home directory: `homeDir`
 * and `env` are both injected inputs, never read from `os.homedir()` or
 * `process.env` directly.
 */

describe("resolveSkillRoots", () => {
  test("default order is built-in, then ~/.opentype/skills, then ~/.claude/skills (compat)", () => {
    const roots = resolveSkillRoots({
      homeDir: "/Users/test",
      builtInSkillsDir: "/app/Resources/skills",
      env: {},
    });

    expect(roots).toEqual([
      "/app/Resources/skills",
      path.join("/Users/test", ".opentype", "skills"),
      path.join("/Users/test", ".claude", "skills"),
    ]);
  });

  test("OPENTYPE_SKILLS_DIR overrides only the built-in root's position, not the order", () => {
    const roots = resolveSkillRoots({
      homeDir: "/Users/test",
      builtInSkillsDir: "/app/Resources/skills",
      env: { OPENTYPE_SKILLS_DIR: "/custom/skills" },
    });

    expect(roots).toEqual([
      "/custom/skills",
      path.join("/Users/test", ".opentype", "skills"),
      path.join("/Users/test", ".claude", "skills"),
    ]);
  });

  test("the compat root (~/.claude/skills) is always present and always last", () => {
    // This is the specific regression §3.2 calls out by name: it must not be
    // possible to lose the compat root by omitting env, by overriding the
    // built-in dir, or by any other input combination this function accepts.
    const withOverride = resolveSkillRoots({
      homeDir: "/h",
      builtInSkillsDir: "/b",
      env: { OPENTYPE_SKILLS_DIR: "/o" },
    });
    const withoutOverride = resolveSkillRoots({ homeDir: "/h", builtInSkillsDir: "/b", env: {} });

    for (const roots of [withOverride, withoutOverride]) {
      expect(roots[roots.length - 1]).toBe(path.join("/h", ".claude", "skills"));
    }
  });
});
