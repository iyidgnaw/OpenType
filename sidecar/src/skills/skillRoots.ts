import * as path from "node:path";

export interface ResolveSkillRootsInput {
  homeDir: string;
  builtInSkillsDir: string;
  env: Record<string, string | undefined>;
}

/**
 * Skill root order is its own file, on purpose, even though it is barely
 * more than a three-element array literal (first-party tools/skills/agents
 * design §3.2,
 * docs/superpowers/specs/2026-08-28-first-party-tools-skills-and-agents-design.md).
 * The order and the identity of these three roots ARE a product decision --
 * which roots exist, in what priority, and that the Claude-Code-compat root
 * never wins a name collision against anything OpenType-owned -- not an
 * implementation detail. Inlining this in `server.ts` would bury that
 * decision inside boot-time wiring where nothing could exercise it without
 * spinning up a whole server; kept here, pure and side-effect-free (no `fs`,
 * no `os.homedir()`, no `process.env`), it's three `resolveSkillRoots` unit
 * tests instead.
 *
 * Order, and why:
 * 1. Built-in (`builtInSkillsDir`, the bundled `sidecar/skills/`) --
 *    overridable via `OPENTYPE_SKILLS_DIR` for dev/testing without touching
 *    the packaged bundle.
 * 2. User (`~/.opentype/skills`) -- the product's own, writable, per-user
 *    skill directory.
 * 3. Compat (`~/.claude/skills`) -- read-only, always last. This is the
 *    headline feature of §3.2: a skill written for Claude Code should work
 *    here unmodified, but it must never be able to silently shadow a
 *    built-in or user skill of the same name, hence always-last rather than
 *    always-first or configurable.
 */
export function resolveSkillRoots(input: ResolveSkillRootsInput): string[] {
  const { homeDir, builtInSkillsDir, env } = input;
  const builtIn = env.OPENTYPE_SKILLS_DIR ?? builtInSkillsDir;
  return [builtIn, path.join(homeDir, ".opentype", "skills"), path.join(homeDir, ".claude", "skills")];
}
