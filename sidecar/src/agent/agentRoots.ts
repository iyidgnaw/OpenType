import * as path from "node:path";

export interface ResolveAgentRootsInput {
  homeDir: string;
  builtInAgentsDir: string;
  env: Record<string, string | undefined>;
}

/**
 * Agent-definition root order, the direct counterpart of
 * `skills/skillRoots.ts`'s `resolveSkillRoots` (first-party
 * tools/skills/agents design §4.1/§8/§9.4,
 * docs/superpowers/specs/2026-08-28-first-party-tools-skills-and-agents-design.md).
 * Same reasoning for why this is its own pure, side-effect-free function
 * (no `fs`, no `os.homedir()`, no `process.env` read directly) rather than
 * inlined at `server.ts`'s boot-time wiring: which roots exist, in what
 * order, and that the Claude-Code-compat root never wins a name collision,
 * is a product decision that deserves its own unit tests, not something
 * only exercisable by spinning up a whole server.
 *
 * Order, and why (identical shape to `resolveSkillRoots`):
 * 1. Built-in (`builtInAgentsDir`, the bundled `sidecar/agents/`) --
 *    overridable via `OPENTYPE_AGENTS_DIR` for dev/testing.
 * 2. User (`~/.opentype/agents`) -- this product's own, writable, per-user
 *    agent directory.
 * 3. Compat (`~/.claude/agents`) -- read-only, always last, never
 *    overridable. An agent file written for Claude Code should work here
 *    unmodified, but it must never be able to shadow a built-in or user
 *    agent of the same name.
 *
 * This is NOT the root list `AGENTS.md` global instructions use -- see
 * `resolveGlobalInstructionRoots` below, and its doc comment, for why that
 * is a deliberately different (and shorter) list.
 */
export function resolveAgentRoots(input: ResolveAgentRootsInput): string[] {
  const { homeDir, builtInAgentsDir, env } = input;
  const builtIn = env.OPENTYPE_AGENTS_DIR ?? builtInAgentsDir;
  return [builtIn, path.join(homeDir, ".opentype", "agents"), path.join(homeDir, ".claude", "agents")];
}

export interface ResolveGlobalInstructionRootsInput {
  homeDir: string;
  builtInAgentsDir: string;
}

/**
 * Root list for `AGENTS.md` global-instructions discovery
 * (`agentDefinitions.ts`'s `loadGlobalInstructions`) -- deliberately
 * SHORTER than `resolveAgentRoots` above: built-in + `~/.opentype` only, the
 * `~/.claude` compat root is EXCLUDED (design §9.2, pinned by §9.4 as a
 * tested fact rather than a call-site convention).
 *
 * Do not "fix" this into matching `resolveAgentRoots`'s three roots -- the
 * two lists differ on purpose, because an imported skill or agent and an
 * imported `AGENTS.md` have different consent models even though they can
 * live in the very same `~/.claude` directory:
 *
 * - A skill or agent imported from `~/.claude` is OPT-IN: the model has to
 *   name it (a voice prefix, an explicit `agentName`, a deliberate
 *   `load_skill` call) before it ever reaches a request. A file just
 *   sitting in `~/.claude/skills` or `~/.claude/agents` costs nothing until
 *   named.
 * - `AGENTS.md` is ALWAYS-ON and UNNAMED. If `~/.claude/AGENTS.md` were
 *   included here, every single voice-dictation Agent-mode task would
 *   silently get the user's *coding* instructions (written for Claude Code,
 *   about a completely different kind of work) appended to its system
 *   prompt -- something the user never agreed to just by having a
 *   `~/.claude` directory at all.
 *
 * Same directory tree, two different rules, and the line between them is
 * "does it require being named". `loadGlobalInstructions` itself has no
 * concept of "compat root" and will happily read whatever it's given
 * (`agentDefinitions.test.ts` proves that with plain injected temp dirs) --
 * this function is the one place that decides `~/.claude` never appears in
 * that list for real.
 */
export function resolveGlobalInstructionRoots(input: ResolveGlobalInstructionRootsInput): string[] {
  const { homeDir, builtInAgentsDir } = input;
  return [builtInAgentsDir, path.join(homeDir, ".opentype")];
}
