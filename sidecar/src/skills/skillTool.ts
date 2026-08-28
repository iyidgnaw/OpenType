import type { Skill } from "./skillStore";
import type { ToolSet } from "../agent/toolSets";
import { clampAtSource } from "../agent/coreTools";

/**
 * `opentype__load_skill` -- the second half of progressive disclosure
 * (design §3.3,
 * docs/superpowers/specs/2026-08-28-first-party-tools-skills-and-agents-design.md):
 * the always-resident index (`renderSkillIndex`) is one `name: description`
 * line per skill; this tool is how the model turns one of those names into
 * the skill's full `SKILL.md` body -- frontmatter stripped, since by the
 * time the model calls this it already has the description from the index
 * and needs the procedure, not the metadata that routed it there.
 *
 * Follows `coreTools.ts`'s conventions exactly, per that file's own doc
 * comment: `opentype__` prefix, every *expected* failure (missing/empty
 * name, unknown skill name) resolves as `{ content: "Error: ..." }` rather
 * than throwing, and only an unknown TOOL name throws (the routing contract
 * `mergeToolSets`/`filterToolSet` rely on). `store` is injected as a plain
 * `{ list(): Skill[] }` -- the same shape `createSkillStore` returns --
 * rather than this module constructing its own store, so tests never touch
 * real disk (matches `builtInTools.test.ts`'s pattern of injecting the
 * backing store directly).
 */
const LOAD_SKILL_TOOL_NAME = "opentype__load_skill";

export interface SkillToolDeps {
  store: { list(): Skill[] };
}

export function createSkillTool(deps: SkillToolDeps): ToolSet {
  const openAiTools: unknown[] = [
    {
      type: "function",
      function: {
        name: LOAD_SKILL_TOOL_NAME,
        description:
          "Load the full step-by-step procedure for one skill by name, exactly as listed in the " +
          "skill index above. Call this before attempting a task the index says a skill covers -- " +
          "the index line alone is not enough to follow the procedure.",
        parameters: {
          type: "object",
          properties: {
            name: {
              type: "string",
              description: "The skill's name, exactly as it appears before the colon in the skill index.",
            },
          },
          required: ["name"],
        },
      },
    },
  ];

  async function callTool(name: string, args: unknown): Promise<{ content: string }> {
    if (name !== LOAD_SKILL_TOOL_NAME) {
      throw new Error(`Unknown tool: ${name}`);
    }

    const rawName = (args as { name?: unknown } | undefined)?.name;
    if (typeof rawName !== "string" || rawName.trim().length === 0) {
      return { content: "Error: name is required." };
    }
    const skillName = rawName.trim();

    const skills = deps.store.list();
    const skill = skills.find((s) => s.name === skillName);
    if (!skill) {
      // The unknown-name error lists every available name so the model can
      // recover in one more call instead of guessing blind or giving up.
      const available = skills.map((s) => s.name).join(", ");
      return {
        content: `Error: no skill named "${skillName}". Available skills: ${available}`,
      };
    }

    return { content: clampAtSource(skill.body) };
  }

  return { openAiTools, callTool };
}
