import * as fs from "node:fs";
import * as path from "node:path";
import { parseFrontmatter } from "../resources/frontmatter";
import { createResourceStore } from "../resources/resourceStore";
import { filterToolSet, type ToolSet } from "./toolSets";

/**
 * One Claude-Code-compatible subagent file: a `.md` file whose frontmatter
 * carries `name`/`description`/optional `tools`/optional `model`, and whose
 * body is the agent's own system-prompt text (first-party tools/skills/agents
 * design §4.1,
 * docs/superpowers/specs/2026-08-28-first-party-tools-skills-and-agents-design.md).
 *
 * `displayName` is OpenType's own addition, not part of the Claude Code
 * format: an optional alias frontmatter can carry (e.g. a Chinese name) so
 * `resolveAgentFromTask` (§4.4) can match a spoken address that isn't the
 * file's own (often English/ASCII) `name`. A file with no `displayName` is
 * still fully usable -- voice matching just has one alias instead of two.
 */
export interface AgentDefinition {
  name: string;
  description: string;
  body: string;
  root: string;
  path: string;
  /** Raw, still-comma-separated frontmatter value; unresolved names and all. */
  tools?: string;
  /** Parsed but deliberately IGNORED (§4.1) -- see `createAgentDefinitionStore`'s doc comment. */
  model?: string;
  displayName?: string;
}

export interface AgentDefinitionStoreOptions {
  /** Ordered; earlier roots win name collisions over later ones (design §4.1/§8). */
  roots: string[];
  /** Same TTL-cache knobs `createResourceStore` takes; forwarded as-is. */
  ttlMs?: number;
  now?: () => number;
}

export interface AgentDefinitionStore {
  list(): AgentDefinition[];
}

/**
 * Discovery for agent definition files, built directly on top of
 * `resources/resourceStore.ts`'s `layout: "file"` mode (design §8) -- root
 * ordering, first-root-wins name collisions, missing-root tolerance, and the
 * short-TTL cache are all `resourceStore`'s job, not reimplemented here.
 *
 * What this layer adds on top of a bare `ResourceEntry` is the extra
 * agent-specific frontmatter fields (`tools`, `model`, `displayName`) that
 * `resourceStore` deliberately doesn't know about, since it's shared with the
 * skill store too. Getting them means re-reading and re-parsing each
 * resolved entry's file -- a small amount of duplicate work against a
 * handful of short markdown files, well within the same TTL window
 * `resourceStore` already caches its own directory scan under, and far
 * cheaper than teaching the shared discovery layer a schema that only one of
 * its two consumers needs.
 *
 * `model` is parsed here (so a Claude-Code-authored file with `model: opus`
 * loads without error) but nothing downstream ever reads it to choose a
 * model -- the product has exactly one, globally-configured LLM provider,
 * and per-agent model switching is out of scope for this batch (design
 * §4.1/§5). Ignoring rather than rejecting the field is what lets a file
 * copied straight from Claude Code work here unmodified.
 */
export function createAgentDefinitionStore(
  options: AgentDefinitionStoreOptions
): AgentDefinitionStore {
  const resourceStore = createResourceStore({
    roots: options.roots,
    layout: "file",
    entryExtension: ".md",
    ttlMs: options.ttlMs,
    now: options.now,
  });

  function list(): AgentDefinition[] {
    return resourceStore.list().map((entry) => {
      let raw = "";
      try {
        raw = fs.readFileSync(entry.path, "utf8");
      } catch {
        // The entry existed when resourceStore scanned it moments ago; a
        // file removed in the gap is simply an agent with no extra fields,
        // not a reason to fail the whole list() call.
      }
      const { attrs } = parseFrontmatter(raw);
      const tools = attrs.tools?.trim() ? attrs.tools.trim() : undefined;
      const model = attrs.model?.trim() ? attrs.model.trim() : undefined;
      const displayName = attrs.displayName?.trim() ? attrs.displayName.trim() : undefined;
      return {
        name: entry.name,
        description: entry.description,
        body: entry.body,
        root: entry.root,
        path: entry.path,
        tools,
        model,
        displayName,
      };
    });
  }

  return { list };
}

/**
 * Reads every root's `AGENTS.md`, if present, and joins them in root order
 * (design §4.5). Deliberately role-agnostic: this function has no concept of
 * "built-in" vs. "compat" roots and simply reads whatever list it is given --
 * the `~/.claude` compat root's exclusion (§9.2/§9.4) is entirely a
 * CALLER-SIDE contract, enforced by which roots `resolveGlobalInstructionRoots`
 * (`agentRoots.ts`) hands this function, never by anything in here. See that
 * module's doc comment for why the exclusion exists.
 *
 * Multiple roots each carrying an `AGENTS.md` are additive, not
 * first-root-wins: unlike a named skill/agent (which is opt-in -- the model
 * has to name it), a global instructions file is unnamed and always-on, and
 * a shipped built-in default plausibly coexists with a user's own override
 * rather than one silently shadowing the other.
 */
export function loadGlobalInstructions(roots: string[]): string | undefined {
  const parts: string[] = [];
  for (const root of roots) {
    try {
      const raw = fs.readFileSync(path.join(root, "AGENTS.md"), "utf8");
      parts.push(raw.trim());
    } catch {
      // Missing root or missing AGENTS.md within it: not every root has
      // one, and that's the common case, not an error.
      continue;
    }
  }
  return parts.length > 0 ? parts.join("\n\n") : undefined;
}

/**
 * Composes the final agent system prompt as base -> agent body -> global
 * instructions, by APPENDING each present piece -- never replacing anything
 * (design §4.2, security-critical). The base prompt is always the literal
 * prefix of the result: a user-authored (or downloaded, or Claude-Code-
 * imported) agent `.md` file is UNTRUSTED input from the harness's point of
 * view, and appending rather than substituting is what makes it structurally
 * impossible for that file to switch off the base prompt's own
 * UNTRUSTED-data defense, no matter what its body says.
 */
export function buildAgentSystemPrompt(
  base: string,
  definition?: AgentDefinition,
  globalInstructions?: string
): string {
  const parts = [base];
  if (definition) {
    parts.push(definition.body);
  }
  if (globalInstructions) {
    parts.push(globalInstructions);
  }
  return parts.join("\n\n");
}

/**
 * Claude Code's own capitalised tool names, mapped to the OpenType tool-name
 * suffix they mean (design §4.3: "frontmatter 的 tools ... 名字支持带前缀与
 * 不带两种写法 ... 我们做一次宽松映射而不是要求用户改文件"). Lowercased keys
 * so lookup is case-insensitive; only the handful Claude Code's own subagent
 * docs actually use, plus a couple of obvious synonyms -- an unmapped name
 * simply fails to resolve rather than guessing.
 */
const CLAUDE_CODE_TOOL_ALIASES: Record<string, string> = {
  bash: "bash",
  read: "read_file",
  write: "write_file",
  edit: "edit_file",
  glob: "glob",
  grep: "grep",
  ls: "list_dir",
  websearch: "web_search",
  webfetch: "web_fetch",
};

/**
 * Resolves one bare tool-name token (already trimmed) against the tool names
 * actually available on this run's set, trying the forms a real-world agent
 * file mixes, in order: already-prefixed (`opentype__grep`), our own bare
 * suffix (`bash` -> `opentype__bash`), and Claude Code's capitalised
 * convention (`Read` -> `opentype__read_file`). Returns `undefined` for
 * anything none of those forms resolve to an available tool.
 */
function resolveOneToolName(token: string, availableNames: readonly string[]): string | undefined {
  if (availableNames.includes(token)) {
    return token;
  }
  const prefixed = `opentype__${token}`;
  if (availableNames.includes(prefixed)) {
    return prefixed;
  }
  const alias = CLAUDE_CODE_TOOL_ALIASES[token.toLowerCase()];
  if (alias) {
    const aliasPrefixed = `opentype__${alias}`;
    if (availableNames.includes(aliasPrefixed)) {
      return aliasPrefixed;
    }
  }
  return undefined;
}

/**
 * Parses frontmatter's raw comma-separated `tools` string into the actual
 * `opentype__*` tool names it names, in the order given. `undefined` input
 * (the field was never set) returns `undefined`, NOT an empty array -- "no
 * restriction at all" and "narrowed to nothing" are different things a
 * caller must be able to tell apart. An unrecognised token is skipped, not
 * fatal: the rest of the list still applies.
 */
export function resolveAgentToolNames(
  raw: string | undefined,
  availableNames: readonly string[]
): string[] | undefined {
  if (raw === undefined) {
    return undefined;
  }
  const resolved: string[] = [];
  for (const rawToken of raw.split(",")) {
    const token = rawToken.trim();
    if (token === "") {
      continue;
    }
    const name = resolveOneToolName(token, availableNames);
    if (name) {
      resolved.push(name);
    }
  }
  return resolved;
}

function toolNamesIn(set: ToolSet): string[] {
  return set.openAiTools
    .map((tool) => (tool as { function?: { name?: unknown } } | undefined)?.function?.name)
    .filter((name): name is string => typeof name === "string");
}

/**
 * Narrows `toolSet` to the definition's `tools` allowlist (design §4.3),
 * delegating the actual filtering to `filterToolSet` (`toolSets.ts`) rather
 * than reimplementing it -- so a filtered-out call fails with exactly the
 * same "Unknown tool" wording every other narrowing in this codebase uses.
 * No `tools` field on the definition means no restriction: returns the same
 * `toolSet` reference, unmodified, rather than rebuilding an equivalent
 * "everything" set -- identity is what keeps a live getter (e.g. MCP tools
 * that fill in after boot, see `mergeToolSets`) working unchanged when there
 * is nothing to narrow.
 */
export function applyAgentToolAllowlist(toolSet: ToolSet, definition: AgentDefinition): ToolSet {
  const resolvedNames = resolveAgentToolNames(definition.tools, toolNamesIn(toolSet));
  if (resolvedNames === undefined) {
    return toolSet;
  }
  return filterToolSet(toolSet, resolvedNames);
}

export interface ResolveAgentFromTaskResult {
  definition?: AgentDefinition;
  /**
   * The task text to actually run with -- the original `task` verbatim when
   * nothing matched, or `task` with the matched leading address stripped off
   * when it did. Always safe to use as the effective task regardless of
   * whether a match happened.
   */
  task: string;
}

/**
 * Chinese verb prefixes design §4.4 lists as leading-address forms
 * (用/使用/让/叫<name>). Tried as literal, unspaced prefixes -- and,
 * deliberately, WITHOUT the boundary check `matchAtForm` applies to the
 * ASCII/CJK `@name` form. This is a real, KNOWN, and currently unfixed
 * false-positive source, not an oversight the old version of this comment
 * claimed away: Chinese carries no whitespace between words, so a
 * registered alias (e.g. "小明") that happens to be a literal prefix of a
 * longer, unrelated word appearing right after a verb (e.g. "用小明星辨认一下
 * 这个人" -- "小明星" is an ordinary word, not an address to an agent named
 * "小明") DOES falsely match today, swapping in that agent's system prompt
 * and leaving a garbled task ("星辨认一下这个人"). Applying the same
 * boundary check used for `@name` is not a fix here, because it would also
 * reject the intended, common, tested case -- a real address is immediately
 * followed by more Chinese task text with no gap at all ("用写作助手帮我写
 * 封邮件" -- "帮" is just as much a CJK "word char" as "星" is above). Telling
 * an intended continuation apart from an unintended one needs real Chinese
 * word segmentation, which is out of scope for this batch (design §0: no
 * new runtime dependency). Longest-alias-first sorting bounds the damage to
 * "an unregistered word starting with a registered alias", not "any two
 * registered aliases colliding" -- but that residual risk is real and the
 * design owner should know it exists, not read this comment and believe it
 * doesn't.
 */
const VOICE_PREFIX_VERBS = ["使用", "用", "让", "叫"];

/**
 * `@name`'s required non-word boundary right after the matched alias -- see
 * `matchAtForm`. Covers ASCII word characters AND CJK ideographs, not just
 * the former: an earlier version only recognised `[a-zA-Z0-9_]`, which meant
 * a CJK character immediately after the alias was always treated as a
 * "boundary" (since it isn't an ASCII word char), so `@小明` would falsely
 * match inside an unrelated longer word like `@小明星` ("Xiao Ming Xing", a
 * different name/word entirely) -- the same false-positive class the
 * ASCII `@writerly` test already guards against, just missed for CJK
 * because the original regex only ever looked at the Latin alphabet. CJK
 * Unified Ideographs (一-鿿) plus Extension A (㐀-䶿) covers
 * the range OpenType's own display names realistically use.
 */
function isWordChar(char: string): boolean {
  if (/[a-zA-Z0-9_]/.test(char)) {
    return true;
  }
  const code = char.codePointAt(0) ?? 0;
  return (code >= 0x4e00 && code <= 0x9fff) || (code >= 0x3400 && code <= 0x4dbf);
}

/**
 * Matches the `@<alias>` leading-address form (design §4.4): case- and
 * whitespace-insensitive (`@Writer`, `@ writer` both match `writer`), and
 * requires a non-word boundary (or end of string) immediately after the
 * alias -- without that boundary check, `@writerly` would misread as
 * `@writer` plus a stray `ly`, a false positive AND a garbled remainder in
 * one bug (design §4.4's own false-positive concern).
 */
function matchAtForm(task: string, alias: string): string | undefined {
  if (!task.startsWith("@")) {
    return undefined;
  }
  const afterAt = task.slice(1);
  const leadingSpace = afterAt.match(/^\s*/)?.[0] ?? "";
  const rest = afterAt.slice(leadingSpace.length);
  if (!rest.toLowerCase().startsWith(alias.toLowerCase())) {
    return undefined;
  }
  const afterAlias = rest.slice(alias.length);
  if (afterAlias.length > 0 && isWordChar(afterAlias[0]!)) {
    return undefined;
  }
  return afterAlias.trimStart();
}

/** Tries every leading-address form for one candidate alias; `undefined` if none match. */
function tryStripPrefix(task: string, alias: string): string | undefined {
  for (const verb of VOICE_PREFIX_VERBS) {
    const prefix = verb + alias;
    if (task.startsWith(prefix)) {
      return task.slice(prefix.length).trimStart();
    }
  }
  for (const separator of ["，", ","]) {
    const prefix = alias + separator;
    if (task.startsWith(prefix)) {
      return task.slice(prefix.length).trimStart();
    }
  }
  const atMatch = matchAtForm(task, alias);
  if (atMatch !== undefined) {
    return atMatch;
  }
  return undefined;
}

/**
 * Deterministic voice-prefix agent selection (design §4.4 -- the primary,
 * zero-UI path): does the task's own leading text address one of
 * `definitions` by name? Matched forms: `用<name>` / `使用<name>` /
 * `让<name>` / `叫<name>` / `<name>，` / `@<name>`, case- and
 * whitespace-insensitive, against both `name` and `displayName`.
 *
 * A match is deliberately conservative: it must be a LEADING address, not a
 * mention anywhere else in the task. The name showing up mid-sentence
 * ("帮我问问写作助手怎么写") or at the end ("这封邮件应该找谁写作助手") is a
 * mention, not an address, and must not swap the user's entire system
 * prompt -- a false positive here is worse than a false negative on a real
 * address, since the user never asked for a different agent at all. Because
 * every form above only ever matches at the START of the (untrimmed) task
 * string, a name anywhere else in the text simply never reaches any of the
 * prefix checks.
 *
 * Candidates are tried longest-alias-first across every definition and both
 * of its aliases, so a name that is itself a prefix of another candidate's
 * name (e.g. "写作" vs. "写作助手") never wins a match that actually
 * addresses the longer, more specific one.
 */
export function resolveAgentFromTask(
  task: string,
  definitions: AgentDefinition[]
): ResolveAgentFromTaskResult {
  if (!task) {
    return { task };
  }

  const candidates: Array<{ definition: AgentDefinition; alias: string }> = [];
  for (const definition of definitions) {
    candidates.push({ definition, alias: definition.name });
    if (definition.displayName) {
      candidates.push({ definition, alias: definition.displayName });
    }
  }
  candidates.sort((a, b) => b.alias.length - a.alias.length);

  for (const { definition, alias } of candidates) {
    const stripped = tryStripPrefix(task, alias);
    if (stripped !== undefined) {
      return { definition, task: stripped };
    }
  }

  return { task };
}
