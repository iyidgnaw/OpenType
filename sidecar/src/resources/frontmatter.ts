/**
 * Deliberately small hand-rolled parser for the leading
 * `---\n<yaml-ish>\n---\n<body>` block Claude Code's `SKILL.md`/agent `.md`
 * files use (first-party tools/skills/agents design §3.1/§4.1,
 * docs/superpowers/specs/2026-08-28-first-party-tools-skills-and-agents-design.md).
 *
 * There is no YAML dependency in this repo and this batch does not add one
 * (see that design's §0 -- "we already have exactly one runtime dep"), so
 * this only needs to handle what skill/agent frontmatter actually contains:
 * flat `key: value` lines. It is NOT a general YAML parser -- nested or
 * multi-line values are simply whatever text follows the first colon on
 * their line, verbatim. That is enough for `name`/`description`/`tools`/
 * `model`/`displayName`, which is all either consumer (`skillStore.ts`,
 * the eventual `agentDefinitions.ts`) ever reads.
 */
export interface ParsedFrontmatter {
  attrs: Record<string, string>;
  body: string;
}

function unquote(value: string): string {
  if (value.length >= 2) {
    const first = value[0];
    const last = value[value.length - 1];
    if ((first === '"' && last === '"') || (first === "'" && last === "'")) {
      return value.slice(1, -1);
    }
  }
  return value;
}

/**
 * Parses a leading frontmatter block off `input`. Anything that isn't
 * exactly "an opening `---` line, followed eventually by a closing `---`
 * line" is treated as having NO frontmatter at all: `attrs` comes back
 * empty and `body` is the entire original `input`, untouched. This matters
 * most for the unterminated-fence case -- a naive "find the next `---`
 * anywhere" scan would either throw or swallow the rest of the file hunting
 * for a fence that never arrives; the contract here is that nothing is ever
 * lost, only ever left unparsed.
 */
export function parseFrontmatter(input: string): ParsedFrontmatter {
  // CRLF normalization only matters once a fenced block is actually found
  // (see below) -- both early-return branches hand back `input` verbatim,
  // stray \r included, exactly as it arrived.
  const normalized = input.replace(/\r\n/g, "\n");
  const lines = normalized.split("\n");

  if (lines[0] !== "---") {
    return { attrs: {}, body: input };
  }

  let closingIndex = -1;
  for (let i = 1; i < lines.length; i++) {
    if (lines[i] === "---") {
      closingIndex = i;
      break;
    }
  }
  if (closingIndex === -1) {
    return { attrs: {}, body: input };
  }

  const attrs: Record<string, string> = {};
  for (const line of lines.slice(1, closingIndex)) {
    // Split on the FIRST colon only: a value like "Use when: the user asks"
    // must keep everything after that first colon, second colon included.
    const colonIndex = line.indexOf(":");
    if (colonIndex === -1) {
      continue;
    }
    const key = line.slice(0, colonIndex).trim();
    if (key === "") {
      continue;
    }
    const value = unquote(line.slice(colonIndex + 1).trim());
    attrs[key] = value;
  }

  const body = lines.slice(closingIndex + 1).join("\n");
  return { attrs, body };
}

/**
 * The write-side counterpart of `parseFrontmatter` (Pipeline A §1.2/§1.3/§1.4,
 * docs/superpowers/specs/2026-08-28-skill-agent-ui-and-step-log-persistence.md):
 * renders `attrs` (in the given key order -- an `undefined` value omits that
 * key's line entirely, which is how a caller writes "no `tools:` line at
 * all" rather than an empty one) plus `body` back into the same
 * `---\n<flat key: value lines>\n---\n<body>` shape `parseFrontmatter` reads.
 * Round-trips by construction: `parseFrontmatter(renderFrontmatter(attrs,
 * body)).attrs[k] === attrs[k]` for every defined key, and `.body === body`.
 *
 * Deliberately does NOT collapse a multi-line value itself -- a value
 * containing a raw `\n` would break the flat line format, but different
 * callers may want different collapse strategies (or none, for values they
 * already know are single-line), so silently mangling whatever was handed in
 * would be a worse surprise than writing it verbatim. The caller is
 * responsible for pre-collapsing anything that might contain a newline (see
 * `skillRoutes.ts`/`agentDefinitionRoutes.ts`'s `collapseDescription`).
 */
export function renderFrontmatter(attrs: Record<string, string | undefined>, body: string): string {
  const lines = ["---"];
  for (const [key, value] of Object.entries(attrs)) {
    if (value === undefined) {
      continue;
    }
    lines.push(`${key}: ${value}`);
  }
  lines.push("---", body);
  return lines.join("\n");
}
