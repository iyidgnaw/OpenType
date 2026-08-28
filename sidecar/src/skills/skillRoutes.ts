import * as fs from "node:fs";
import * as path from "node:path";
import { ApiError, type Route } from "../router";
import { renderFrontmatter } from "../resources/frontmatter";
import type { Skill, SkillStore, SkillWithStatus } from "./skillStore";

/**
 * HTTP surface backing the Settings "Skill 与 Agent" page's SKILL column
 * (Pipeline A §1.2, docs/superpowers/specs/2026-08-28-skill-agent-ui-and-step-log-persistence.md).
 * `store`/`userRoot`/`builtInRoot` mirror `agent/mcpConfigRoutes.ts`'s
 * store-plus-injected-deps shape: `userRoot` is where every write lands,
 * `builtInRoot` (plus `userRoot` itself) is all the 409/403 matrix needs to
 * tell "built-in" and "user" apart -- a name that resolves to neither is
 * "claude" by elimination (E3: the Claude-Code-compat root never blocks a
 * create, since a user copy already wins that collision by root ordering).
 */
export interface SkillRouteDeps {
  store: SkillStore;
  userRoot: string;
  builtInRoot: string;
}

/** Name charset/length (design §1.4): letters, digits, `-`, not leading with `-`; this alone already rules out `/`/`..` path traversal. */
const NAME_PATTERN = /^[A-Za-z0-9][A-Za-z0-9-]*$/;
const MAX_NAME_LENGTH = 64;

function validateName(name: unknown): string {
  if (
    typeof name !== "string" ||
    name.length === 0 ||
    name.length > MAX_NAME_LENGTH ||
    !NAME_PATTERN.test(name)
  ) {
    throw new ApiError(`Invalid skill name: ${JSON.stringify(name)}`, 400);
  }
  return name;
}

/**
 * Frontmatter is flat `key: value` lines (`resources/frontmatter.ts`) -- an
 * embedded newline would corrupt the file for its line-oriented parser, so a
 * multi-line description is folded to one line before it's ever written
 * (design §1.4: "折叠为单行"), never rejected. Blank lines are dropped rather
 * than joined as empty fragments, so "a\n\nb" becomes "a b", not "a  b".
 */
function collapseDescription(raw: string): string {
  return raw
    .split(/\r\n|\r|\n/)
    .map((line) => line.trim())
    .filter((line) => line.length > 0)
    .join(" ");
}

/** The `:name` segment of `/skills/:name`. */
function nameFromPath(req: Request): string {
  const pathname = new URL(req.url).pathname;
  const last = pathname.split("/").pop() ?? "";
  try {
    return decodeURIComponent(last);
  } catch {
    return last;
  }
}

/**
 * Realpath, for display only -- a temp-dir root used in tests (and, on
 * macOS, `/tmp`/`/var` themselves) commonly traverses a symlink, and the
 * defensive path-safety check this API exposes (`path` in every response) is
 * only meaningful against the canonical location. Falls back to the literal
 * path if the file has just vanished underneath us (a rescan is one
 * `invalidate()`/TTL window away regardless).
 */
function displayPath(rawPath: string): string {
  try {
    return fs.realpathSync(rawPath);
  } catch {
    return rawPath;
  }
}

/**
 * Defense in depth on top of `validateName`'s charset check (which already
 * rules out `/`/`..` in `name` and therefore makes this unreachable in
 * practice): asserts a to-be-written path still resolves inside `root`
 * before anything touches disk (design §1.4's "写路径 resolve 后必须落在对应
 * user root 内").
 */
function assertWithinRoot(root: string, target: string): void {
  const resolvedRoot = path.resolve(root);
  const resolvedTarget = path.resolve(target);
  if (resolvedTarget !== resolvedRoot && !resolvedTarget.startsWith(resolvedRoot + path.sep)) {
    throw new ApiError("resolved path escapes the target root", 400);
  }
}

interface SkillListRow {
  name: string;
  description: string;
  root: string;
  path: string;
  editable: boolean;
  active: boolean;
  shadowedBy?: string;
}

/** `editable` is `root === userRoot`, independent of `active` -- a shadowed user copy stays editable (design §1.2's 8A "被覆盖的「我的」条目也要能点开看"). */
function toRow(entry: SkillWithStatus, userRoot: string): SkillListRow {
  const row: SkillListRow = {
    name: entry.name,
    description: entry.description,
    root: entry.root,
    path: displayPath(entry.path),
    editable: entry.root === userRoot,
    active: entry.active,
  };
  if (entry.shadowedBy) {
    row.shadowedBy = entry.shadowedBy;
  }
  return row;
}

function detailResponse(entry: Skill, userRoot: string) {
  return {
    name: entry.name,
    description: entry.description,
    body: entry.body,
    path: displayPath(entry.path),
    root: entry.root,
    editable: entry.root === userRoot,
  };
}

interface WritableBody {
  description?: unknown;
  body?: unknown;
}

function readDescription(body: WritableBody, fallback: string): string {
  return collapseDescription(typeof body.description === "string" ? body.description : fallback);
}

function readBody(body: WritableBody, fallback: string): string {
  return typeof body.body === "string" ? body.body : fallback;
}

export function buildSkillRoutes(deps: SkillRouteDeps): Route[] {
  const { store, userRoot, builtInRoot } = deps;

  /** Default (no `?root=`): the active copy. With `?root=`: that exact root's copy, active or shadowed. */
  function findEntry(name: string, root: string | undefined): SkillWithStatus | undefined {
    const all = store.listAll();
    if (root) {
      return all.find((e) => e.name === name && e.root === root);
    }
    return all.find((e) => e.name === name && e.active);
  }

  return [
    {
      method: "GET",
      path: "/skills",
      handler: () => Response.json({ skills: store.listAll().map((entry) => toRow(entry, userRoot)) }),
    },
    {
      method: "GET",
      path: "/skills/:name",
      handler: (req) => {
        const name = nameFromPath(req);
        const root = new URL(req.url).searchParams.get("root") ?? undefined;
        const entry = findEntry(name, root);
        if (!entry) {
          return Response.json({ error: `No skill named "${name}"` }, { status: 404 });
        }
        return Response.json(detailResponse(entry, userRoot));
      },
    },
    {
      method: "POST",
      path: "/skills",
      handler: async (req) => {
        const body = (await req.json()) as { name?: unknown } & WritableBody;
        const name = validateName(body.name);
        const description = readDescription(body, "");
        const skillBody = readBody(body, "");

        const all = store.listAll();
        if (all.some((e) => e.name === name && e.root === builtInRoot)) {
          throw new ApiError(`A built-in skill named "${name}" already exists`, 409);
        }
        if (all.some((e) => e.name === name && e.root === userRoot)) {
          throw new ApiError(`A skill named "${name}" already exists -- use PUT to update it`, 409);
        }

        const targetDir = path.join(userRoot, name);
        assertWithinRoot(userRoot, targetDir);
        fs.mkdirSync(targetDir, { recursive: true });
        const targetFile = path.join(targetDir, "SKILL.md");
        fs.writeFileSync(targetFile, renderFrontmatter({ name, description }, skillBody));
        // Write-then-read must be immediate (design §1.1/§1.5) -- without
        // this, the very next GET could still answer from the pre-write
        // scan for up to the store's own TTL.
        store.invalidate();

        return Response.json({
          name,
          description,
          body: skillBody,
          root: userRoot,
          path: displayPath(targetFile),
          editable: true,
        });
      },
    },
    {
      method: "PUT",
      path: "/skills/:name",
      handler: async (req) => {
        const name = nameFromPath(req);
        const all = store.listAll();
        const existingUser = all.find((e) => e.name === name && e.root === userRoot);
        if (!existingUser) {
          // 403 means "exists, but not somewhere PUT can reach" (builtin/claude);
          // 404 means "does not exist anywhere" (design §1.4/A-4).
          const existsSomewhere = all.some((e) => e.name === name);
          return Response.json(
            { error: `"${name}" is not an editable (user-root) skill` },
            { status: existsSomewhere ? 403 : 404 }
          );
        }

        const body = (await req.json()) as WritableBody;
        const description = readDescription(body, existingUser.description);
        const skillBody = readBody(body, existingUser.body);

        // `existingUser.path` (not a re-derived `userRoot/name/SKILL.md`) is
        // the actual discovered file -- name is immutable (E1), so these are
        // always the same location, but this stays correct even if that
        // ever stops being true.
        assertWithinRoot(userRoot, existingUser.path);
        fs.writeFileSync(existingUser.path, renderFrontmatter({ name, description }, skillBody));
        store.invalidate();

        return Response.json({
          name,
          description,
          body: skillBody,
          root: userRoot,
          path: displayPath(existingUser.path),
          editable: true,
        });
      },
    },
    {
      method: "DELETE",
      path: "/skills/:name",
      handler: (req) => {
        const name = nameFromPath(req);
        const all = store.listAll();
        const existingUser = all.find((e) => e.name === name && e.root === userRoot);
        if (!existingUser) {
          const existsSomewhere = all.some((e) => e.name === name);
          return Response.json(
            { error: `"${name}" is not a deletable (user-root) skill` },
            { status: existsSomewhere ? 403 : 404 }
          );
        }
        // The whole skill directory, not just SKILL.md -- a skill may carry
        // extra reference files alongside its marker file.
        const targetDir = path.dirname(existingUser.path);
        // Same defense-in-depth posture as POST/PUT (reviewer-requested
        // consistency fix): `targetDir` is always root-scanned from
        // `userRoot` itself, so this is unreachable in practice, but a
        // recursive destructive `fs.rmSync` call is exactly the place to
        // assert it anyway rather than trust that invariant silently.
        assertWithinRoot(userRoot, targetDir);
        fs.rmSync(targetDir, { recursive: true, force: true });
        store.invalidate();
        return Response.json({ deleted: true });
      },
    },
  ];
}
