import * as fs from "node:fs";
import * as path from "node:path";
import { parseFrontmatter } from "./frontmatter";

/**
 * Generic multi-root discovery layer shared by the skill store
 * (`skills/skillStore.ts`) and the agent-definition store
 * (`agent/agentDefinitions.ts`) -- first-party tools/skills/agents design
 * §7/§8 (docs/superpowers/specs/2026-08-28-first-party-tools-skills-and-agents-design.md).
 *
 * An ordered list of root directories is searched for "entries" -- what
 * counts as an entry depends on `layout`:
 *
 * - `"directory"` (default, skills): an entry is an immediate subdirectory
 *   of a root that contains a marker file (`entryFileName`, e.g. `SKILL.md`).
 * - `"file"` (agent definitions, design §8): an entry is a file directly
 *   under a root whose name ends in `entryExtension` (e.g. `.md`) -- there
 *   is no marker file or subdirectory involved.
 *
 * Both layouts share the same first-root-wins collision rule, the same
 * silent skip of a missing/unreadable root, and the same short-TTL cache
 * (design §5's substitute for file-watching hot reload) -- the only thing
 * that differs between them is "which file backs one entry", so that is the
 * only thing `layout` changes; everything else below is layout-agnostic.
 */
export interface ResourceEntry {
  name: string;
  description: string;
  body: string;
  root: string;
  path: string;
}

export interface ResourceStoreOptions {
  /** Ordered; earlier roots win name collisions over later ones. */
  roots: string[];
  /** `"directory"` (default) or `"file"` -- see this file's doc comment. */
  layout?: "directory" | "file";
  /** Marker filename inside each entry directory. Used by `"directory"` layout. */
  entryFileName?: string;
  /** File extension (with leading dot) an entry file must end in. Used by `"file"` layout. */
  entryExtension?: string;
  /**
   * How long a computed result is reused before the filesystem is re-read.
   * Defaults to 0 (always re-read) -- a caller that wants caching must pass
   * this explicitly, since without an injected `now` there is no way to
   * exercise or reason about a hidden default TTL in a test.
   */
  ttlMs?: number;
  /** Clock, injected so tests never sleep on a real TTL. Defaults to `Date.now`. */
  now?: () => number;
}

export interface ResourceStore {
  list(): ResourceEntry[];
}

/**
 * Reads one directory-layout entry (a skill directory) rooted at `root`.
 * Returns `null` for anything that isn't a valid entry -- a plain file
 * sitting directly under `root` (not a directory at all), a directory with
 * no marker file, or a marker file that can't be read -- rather than
 * throwing. The `dirent.isDirectory()` check up front is what keeps a loose
 * file from ever reaching a `fs.readFileSync(path.join(fileName, entryFileName))`
 * call, which would otherwise throw ENOTDIR.
 */
function readDirectoryEntry(root: string, dirent: fs.Dirent, entryFileName: string): ResourceEntry | null {
  if (!dirent.isDirectory()) {
    return null;
  }
  const markerPath = path.join(root, dirent.name, entryFileName);
  let raw: string;
  try {
    raw = fs.readFileSync(markerPath, "utf8");
  } catch {
    return null;
  }
  const { attrs, body } = parseFrontmatter(raw);
  const name = attrs.name?.trim() ? attrs.name.trim() : dirent.name;
  return { name, description: attrs.description ?? "", body, root, path: markerPath };
}

/**
 * Reads one file-layout entry (an agent definition `<name>.md`) rooted at
 * `root`. Frontmatter `name` wins over the file's own basename when both
 * are present, matching the directory layout's "frontmatter name wins over
 * the directory name" precedent.
 *
 * A `README.md` (any case) is excluded regardless of what's inside it. A
 * README sitting directly in a flat directory of definitions is a
 * documentation convention -- the shipped `sidecar/agents/README.md`
 * placeholder describes the format, it isn't an agent -- but the "file"
 * layout otherwise treats any `.md` file as an entry, so without this check
 * a user's own README documenting their `~/.opentype/agents/` would
 * silently register as a real agent, its prose read in as the system
 * prompt. This is a check on the FILE'S OWN name, deliberately before
 * frontmatter is even consulted: a README that sets `name: something-else`
 * must still be excluded, since the point is that a file called README.md
 * never becomes an entry no matter what it contains. `"directory"` layout
 * is untouched -- it never enumerates loose files inside an entry
 * directory, so a README next to a `SKILL.md` was never at risk.
 */
function readFileEntry(root: string, dirent: fs.Dirent, entryExtension: string): ResourceEntry | null {
  if (!dirent.isFile() || !dirent.name.endsWith(entryExtension)) {
    return null;
  }
  const basename = dirent.name.slice(0, dirent.name.length - entryExtension.length);
  if (basename.toLowerCase() === "readme") {
    return null;
  }
  const filePath = path.join(root, dirent.name);
  let raw: string;
  try {
    raw = fs.readFileSync(filePath, "utf8");
  } catch {
    return null;
  }
  const { attrs, body } = parseFrontmatter(raw);
  const name = attrs.name?.trim() ? attrs.name.trim() : basename;
  return { name, description: attrs.description ?? "", body, root, path: filePath };
}

export function createResourceStore(options: ResourceStoreOptions): ResourceStore {
  const layout = options.layout ?? "directory";
  const entryFileName = options.entryFileName ?? "SKILL.md";
  const entryExtension = options.entryExtension ?? ".md";
  const ttlMs = options.ttlMs ?? 0;
  const now = options.now ?? (() => Date.now());

  let cached: ResourceEntry[] | null = null;
  let cachedAt = -Infinity;

  function readAll(): ResourceEntry[] {
    // First-root-wins: earlier roots populate this map first, and a later
    // root's entry of the same name is simply never inserted.
    const byName = new Map<string, ResourceEntry>();
    for (const root of options.roots) {
      let dirents: fs.Dirent[];
      try {
        dirents = fs.readdirSync(root, { withFileTypes: true });
      } catch {
        // Missing or unreadable root: skipped silently, not an error --
        // a user's `~/.opentype/skills` not existing yet is the common case,
        // not an exceptional one.
        continue;
      }
      for (const dirent of dirents) {
        const entry =
          layout === "file"
            ? readFileEntry(root, dirent, entryExtension)
            : readDirectoryEntry(root, dirent, entryFileName);
        if (!entry || byName.has(entry.name)) {
          continue;
        }
        byName.set(entry.name, entry);
      }
    }
    return Array.from(byName.values()).sort((a, b) => a.name.localeCompare(b.name));
  }

  function list(): ResourceEntry[] {
    if (cached !== null && now() - cachedAt < ttlMs) {
      return cached;
    }
    cached = readAll();
    cachedAt = now();
    return cached;
  }

  return { list };
}
