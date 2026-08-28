import { describe, expect, test } from "bun:test";
import * as path from "node:path";
import { resolveAgentRoots, resolveGlobalInstructionRoots } from "../../src/agent/agentRoots";

/**
 * §9.4 of docs/superpowers/specs/2026-08-28-first-party-tools-skills-and-agents-design.md:
 * these two resolvers are pure path logic (no `fs`, no real `~`), mirroring
 * `skills/skillRoots.test.ts`'s precedent for `resolveSkillRoots`. The point
 * of this file is to pin the ONE thing that must never regress silently --
 * `resolveGlobalInstructionRoots` excluding the `~/.claude` compat root --
 * as an assertion, not just a call-site convention in `server.ts`.
 */
describe("resolveAgentRoots", () => {
  test("returns the three roots in built-in -> user -> compat order", () => {
    const roots = resolveAgentRoots({
      homeDir: "/home/diyi",
      builtInAgentsDir: "/app/agents",
      env: {},
    });

    expect(roots).toEqual([
      "/app/agents",
      path.join("/home/diyi", ".opentype", "agents"),
      path.join("/home/diyi", ".claude", "agents"),
    ]);
  });

  test("OPENTYPE_AGENTS_DIR overrides only the built-in root, leaving the other two untouched", () => {
    const roots = resolveAgentRoots({
      homeDir: "/home/diyi",
      builtInAgentsDir: "/app/agents",
      env: { OPENTYPE_AGENTS_DIR: "/dev/agents-override" },
    });

    expect(roots).toEqual([
      "/dev/agents-override",
      path.join("/home/diyi", ".opentype", "agents"),
      path.join("/home/diyi", ".claude", "agents"),
    ]);
  });

  test("an unset OPENTYPE_AGENTS_DIR (key present, value undefined) falls back to the built-in default", () => {
    const roots = resolveAgentRoots({
      homeDir: "/home/diyi",
      builtInAgentsDir: "/app/agents",
      env: { OPENTYPE_AGENTS_DIR: undefined },
    });

    expect(roots[0]).toBe("/app/agents");
  });
});

describe("resolveGlobalInstructionRoots", () => {
  test("returns exactly two roots: built-in and ~/.opentype -- the ~/.claude compat root is ABSENT", () => {
    const roots = resolveGlobalInstructionRoots({
      homeDir: "/home/diyi",
      builtInAgentsDir: "/app/agents",
    });

    expect(roots).toEqual(["/app/agents", path.join("/home/diyi", ".opentype")]);
    expect(roots).toHaveLength(2);
    // The whole point of this test: no path under this list mentions
    // `.claude` at all. A future refactor that reused `resolveAgentRoots`'s
    // three-root list here (e.g. "just call the other resolver") would
    // reintroduce the compat root and this assertion is what catches it.
    expect(roots.some((root) => root.includes(".claude"))).toBe(false);
  });

  test("does not accept an env/override parameter -- the built-in root is whatever the caller passes, verbatim", () => {
    // Unlike resolveAgentRoots, this resolver has no OPENTYPE_AGENTS_DIR
    // knob: the caller (server.ts) decides what "built-in" means for global
    // instructions by what it passes in, not by an env var read here.
    const roots = resolveGlobalInstructionRoots({
      homeDir: "/home/diyi",
      builtInAgentsDir: "/custom/built-in",
    });

    expect(roots[0]).toBe("/custom/built-in");
  });
});
