import { createResourceStore } from "../resources/resourceStore";

/**
 * A skill: one directory containing a `SKILL.md` (design §3.1). Structurally
 * identical to `resourceStore.ts`'s generic `ResourceEntry` -- this type
 * exists as its own name so skill-specific code (`skillTool.ts`,
 * `agent/routes.ts`) reads "Skill", not "some generic resource entry that
 * happens to be a skill".
 */
export interface Skill {
  name: string;
  description: string;
  body: string;
  root: string;
  path: string;
}

export interface SkillStoreOptions {
  /** Ordered roots -- see `skillRoots.ts` for how the real default is assembled. */
  roots: string[];
  ttlMs?: number;
  now?: () => number;
}

export interface SkillStore {
  list(): Skill[];
}

/**
 * Skill discovery is `resourceStore.ts`'s generic multi-root/first-root-wins/
 * TTL-cache machinery, configured for the directory-layout shape
 * (`entryFileName: "SKILL.md"`) skills use. This module adds nothing to that
 * machinery except the "SKILL.md" convention and `renderSkillIndex` below --
 * see `resourceStore.test.ts` for first-root-wins/TTL/missing-root coverage,
 * which this module deliberately does not re-test.
 */
export function createSkillStore(options: SkillStoreOptions): SkillStore {
  const store = createResourceStore({
    roots: options.roots,
    layout: "directory",
    entryFileName: "SKILL.md",
    ttlMs: options.ttlMs,
    now: options.now,
  });
  return { list: () => store.list() };
}

/** At most this many skills appear in the rendered index. */
const MAX_SKILLS_IN_INDEX = 40;
/** Soft character budget for the rendered index (design §3.3, "~4000 字符"). */
const MAX_INDEX_CHARS = 4_000;

/**
 * Renders the always-resident skill index: one `name: description` line per
 * skill (design §3.3's progressive-disclosure summary -- the full
 * `SKILL.md` body only reaches the model via `opentype__load_skill`).
 *
 * Two independent clamps apply -- count (at most 40 skills) and total size
 * (~4000 chars, since even a handful of long descriptions could blow the
 * budget well under the count cap) -- and BOTH must fail visibly rather than
 * silently: an index that quietly dropped skills would look, to the model,
 * exactly like a system with fewer skills installed than it actually has,
 * which is a worse failure than a index that says "there's more, but I'm not
 * showing you" (design §3.3's whole reason for existing as separate section
 * from "there is an index").
 *
 * Returns `undefined` (not an empty string, and not a header with no
 * entries) for zero skills, so a caller can gate injection with a plain
 * `if (skills) { ... }` the same way `RunAgentLoopInput`'s other optional
 * context fields do -- see `agent/loop.ts`.
 */
export function renderSkillIndex(skills: Skill[]): string | undefined {
  if (skills.length === 0) {
    return undefined;
  }

  const countCapped = skills.slice(0, MAX_SKILLS_IN_INDEX);
  const omittedByCount = skills.length - countCapped.length;

  const lines: string[] = [];
  let omittedByChars = 0;
  for (let i = 0; i < countCapped.length; i++) {
    const skill = countCapped[i]!;
    const line = `${skill.name}: ${skill.description}`;
    const projected = [...lines, line].join("\n").length;
    if (projected > MAX_INDEX_CHARS) {
      omittedByChars = countCapped.length - i;
      break;
    }
    lines.push(line);
  }

  const totalOmitted = omittedByCount + omittedByChars;
  if (totalOmitted > 0) {
    lines.push(`... (+${totalOmitted} more, truncated)`);
  }

  return lines.join("\n");
}
