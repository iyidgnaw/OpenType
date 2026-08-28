import * as fs from "node:fs";
import * as path from "node:path";
import { ApiError, type Route } from "../router";
import { parseFrontmatter, renderFrontmatter } from "../resources/frontmatter";
import type { AgentDefinition, AgentDefinitionStore, AgentDefinitionWithStatus } from "./agentDefinitions";

/**
 * HTTP surface backing the Settings "Skill 与 Agent" page's AGENT column
 * (Pipeline A §1.3, docs/superpowers/specs/2026-08-28-skill-agent-ui-and-step-log-persistence.md).
 *
 * Deliberately a SEPARATE file from `agent/routes.ts`'s `buildAgentRoutes` --
 * not an in-place edit to its existing (deliberately minimal) `GET
 * /agent/definitions` handler. `server.ts` registers this file's routes
 * BEFORE `buildAgentRoutes`'s own in the route table, so this file's
 * extended `GET /agent/definitions` shadows the old one (`router.ts`'s
 * `createRouter` returns the first method+path match) while
 * `agent/routes.test.ts`'s existing test against `buildAgentRoutes` in
 * isolation keeps passing unmodified (decision A-1).
 */
export interface AgentDefinitionRouteDeps {
  store: AgentDefinitionStore;
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
    throw new ApiError(`Invalid agent name: ${JSON.stringify(name)}`, 400);
  }
  if (name.toLowerCase() === "readme") {
    // The discovery layer (`resources/resourceStore.ts`'s `readFileEntry`)
    // silently excludes any file named README.md, whatever it contains --
    // rejecting the name at creation time means a save is never accepted
    // only to become invisible to the very next GET.
    throw new ApiError(`"${name}" is a reserved filename and cannot be used as an agent name`, 400);
  }
  return name;
}

/**
 * Frontmatter is flat `key: value` lines -- an embedded newline in ANY
 * free-text value that reaches `renderFrontmatter` is read back by
 * `parseFrontmatter`'s line-oriented parser as one or more SEPARATE,
 * caller-controlled frontmatter lines, not as part of the original value
 * (`renderFrontmatter`'s own doc comment: "Deliberately does NOT collapse a
 * multi-line value itself ... The caller is responsible"). So EVERY
 * free-text value handed to `renderFrontmatter` here -- `description`,
 * `displayName`, and each individual `tools[]` element before it's
 * comma-joined -- MUST go through this first, not just `description`: a
 * stage-4 review PoC demonstrated that an unsanitized `displayName` (or
 * `tools[]` element) containing `"\nmodel: injected-model-xyz"` forges a
 * `model:` line even though `model` itself is never accepted from a request
 * body at all (B2) -- see the regression describe block in
 * `agentDefinitionRoutes.test.ts`. Folded to one line, never rejected,
 * exactly as design §1.4 already specifies for `description`.
 */
function collapseToSingleLine(raw: string): string {
  return raw
    .split(/\r\n|\r|\n/)
    .map((line) => line.trim())
    .filter((line) => line.length > 0)
    .join(" ");
}

/** `undefined` for a non-string input or one that collapses to nothing (all blank/newlines) -- used for `displayName`, which is optional either way. */
function optionalSingleLine(value: unknown): string | undefined {
  if (typeof value !== "string") {
    return undefined;
  }
  const collapsed = collapseToSingleLine(value);
  return collapsed.length > 0 ? collapsed : undefined;
}

/**
 * `tools` arrives as a JSON array of strings and is written back as the same
 * comma-separated form `AgentDefinition.tools` already carries elsewhere in
 * this codebase. Each element is run through `collapseToSingleLine` BEFORE
 * being joined -- an embedded newline inside one array element must not be
 * able to split the eventual comma-joined value across multiple written
 * frontmatter lines (see this function's call sites' doc comment above for
 * why this is load-bearing, not cosmetic). `undefined` (absent from the
 * request body) means "leave whatever's there" to a PUT and "no line at
 * all" to a POST -- both callers distinguish "the field was omitted" from
 * "the field resolved to nothing" by checking `body.tools !== undefined`
 * themselves before calling this; an empty (or all-blank/newline-only)
 * array is treated the same as "resolves to nothing" -- an empty allowlist
 * is meaningless, so it writes no `tools:` line rather than one that would
 * narrow the agent to zero tools.
 */
function joinTools(tools: unknown): string | undefined {
  if (!Array.isArray(tools)) {
    return undefined;
  }
  const names = tools
    .filter((t): t is string => typeof t === "string")
    .map((t) => collapseToSingleLine(t))
    .filter((t) => t.length > 0);
  return names.length > 0 ? names.join(", ") : undefined;
}

/** The `:name` segment of `/agent/definitions/:name`. */
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
 * Realpath, for display only -- see `skills/skillRoutes.ts`'s identical
 * helper for why (temp-dir/`/tmp`/`/var` symlink traversal on macOS).
 */
function displayPath(rawPath: string): string {
  try {
    return fs.realpathSync(rawPath);
  } catch {
    return rawPath;
  }
}

/**
 * Defense in depth on top of `validateName`'s charset check (design §1.4's
 * "写路径 resolve 后必须落在对应 user root 内") -- unreachable in practice since
 * the charset already rules out `/`/`..`, but asserted anyway before
 * anything touches disk.
 */
function assertWithinRoot(root: string, target: string): void {
  const resolvedRoot = path.resolve(root);
  const resolvedTarget = path.resolve(target);
  if (resolvedTarget !== resolvedRoot && !resolvedTarget.startsWith(resolvedRoot + path.sep)) {
    throw new ApiError("resolved path escapes the target root", 400);
  }
}

interface AgentListRow {
  name: string;
  description: string;
  displayName?: string;
  model?: string;
  tools?: string;
  root: string;
  path: string;
  active: boolean;
  shadowedBy?: string;
}

/**
 * List rows carry NO `body` (design §1.3: "列表继续不含 body") and no
 * `editable` (unlike skills' list row -- the design bullet for this endpoint
 * never mentions one; a client that needs it uses the detail endpoint).
 */
function toRow(entry: AgentDefinitionWithStatus): AgentListRow {
  const row: AgentListRow = {
    name: entry.name,
    description: entry.description,
    root: entry.root,
    path: displayPath(entry.path),
    active: entry.active,
  };
  if (entry.displayName) row.displayName = entry.displayName;
  if (entry.model) row.model = entry.model;
  if (entry.tools) row.tools = entry.tools;
  if (entry.shadowedBy) row.shadowedBy = entry.shadowedBy;
  return row;
}

function detailResponse(entry: AgentDefinition, userRoot: string) {
  return {
    name: entry.name,
    description: entry.description,
    displayName: entry.displayName,
    model: entry.model,
    tools: entry.tools,
    body: entry.body,
    path: displayPath(entry.path),
    root: entry.root,
    editable: entry.root === userRoot,
  };
}

interface CreateBody {
  name?: unknown;
  displayName?: unknown;
  description?: unknown;
  tools?: unknown;
  body?: unknown;
  // `model` is intentionally NOT part of this interface (B2): there is
  // nowhere for a submitted value to go, by construction, not by filtering.
}

interface UpdateBody {
  displayName?: unknown;
  description?: unknown;
  tools?: unknown;
  body?: unknown;
}

export function buildAgentDefinitionRoutes(deps: AgentDefinitionRouteDeps): Route[] {
  const { store, userRoot, builtInRoot } = deps;

  /** Default (no `?root=`): the active copy. With `?root=`: that exact root's copy, active or shadowed. */
  function findEntry(name: string, root: string | undefined): AgentDefinitionWithStatus | undefined {
    const all = store.listAll();
    if (root) {
      return all.find((e) => e.name === name && e.root === root);
    }
    return all.find((e) => e.name === name && e.active);
  }

  return [
    {
      method: "GET",
      path: "/agent/definitions",
      handler: () => Response.json(store.listAll().map(toRow)),
    },
    {
      method: "GET",
      path: "/agent/definitions/:name",
      handler: (req) => {
        const name = nameFromPath(req);
        const root = new URL(req.url).searchParams.get("root") ?? undefined;
        const entry = findEntry(name, root);
        if (!entry) {
          return Response.json({ error: `No agent named "${name}"` }, { status: 404 });
        }
        return Response.json(detailResponse(entry, userRoot));
      },
    },
    {
      method: "POST",
      path: "/agent/definitions",
      handler: async (req) => {
        const body = (await req.json()) as CreateBody;
        const name = validateName(body.name);
        const description = collapseToSingleLine(
          typeof body.description === "string" ? body.description : ""
        );
        const definitionBody = typeof body.body === "string" ? body.body : "";
        const displayName = optionalSingleLine(body.displayName);
        const tools = joinTools(body.tools);

        const all = store.listAll();
        if (all.some((e) => e.name === name && e.root === builtInRoot)) {
          throw new ApiError(`A built-in agent named "${name}" already exists`, 409);
        }
        if (all.some((e) => e.name === name && e.root === userRoot)) {
          throw new ApiError(`An agent named "${name}" already exists -- use PUT to update it`, 409);
        }

        const targetFile = path.join(userRoot, `${name}.md`);
        assertWithinRoot(userRoot, targetFile);
        fs.mkdirSync(userRoot, { recursive: true });
        // `model` never reaches this write (B2) -- `CreateBody` above has no
        // field for it, so there is no `body.model` to even read. That
        // alone is NOT sufficient by itself, though: `displayName` and each
        // `tools[]` element above are free-text values that DO reach the
        // file, and an embedded newline in either could otherwise forge an
        // extra `model:` (or any other) frontmatter line once written raw
        // (a stage-4 review PoC did exactly this before `displayName`/
        // `joinTools` were routed through `collapseToSingleLine`/
        // `optionalSingleLine` above) -- that sanitization, not the mere
        // absence of a `model` field, is what actually keeps this invariant
        // safe.
        fs.writeFileSync(
          targetFile,
          renderFrontmatter({ name, displayName, description, tools }, definitionBody)
        );
        store.invalidate();

        return Response.json({
          name,
          description,
          displayName,
          tools,
          body: definitionBody,
          root: userRoot,
          path: displayPath(targetFile),
          editable: true,
        });
      },
    },
    {
      method: "PUT",
      path: "/agent/definitions/:name",
      handler: async (req) => {
        const name = nameFromPath(req);
        const all = store.listAll();
        const existingUser = all.find((e) => e.name === name && e.root === userRoot);
        if (!existingUser) {
          // 403 means "exists, but not somewhere PUT can reach" (builtin/claude);
          // 404 means "does not exist anywhere" (design §1.4/A-4).
          const existsSomewhere = all.some((e) => e.name === name);
          return Response.json(
            { error: `"${name}" is not an editable (user-root) agent` },
            { status: existsSomewhere ? 403 : 404 }
          );
        }

        const body = (await req.json()) as UpdateBody;

        // Preserve every unmanaged frontmatter key (design §1.3: "必须保留
        // 未管理的 frontmatter 键", e.g. a Claude-Code-authored `model:` line) --
        // read the RAW file directly rather than starting from the
        // discovered `AgentDefinition`, which only ever surfaces the
        // handful of fields this layer knows how to parse. `model` is never
        // read from `body` here (B2): whatever the file already has for it
        // is carried forward untouched. That, by itself, is NOT what keeps
        // a client from setting/changing `model` -- `displayName` and
        // `tools` below are free-text values that DO get merged in, and
        // without `collapseToSingleLine`/`joinTools` sanitizing them first,
        // an embedded newline in either could forge an extra `model:` line
        // of its own (the stage-4 review PoC this fixed). The actual
        // invariant holds because every value merged into `mergedAttrs`
        // below is single-line by construction, not because `model` is
        // merely absent from `UpdateBody`.
        let existingRawAttrs: Record<string, string> = {};
        try {
          existingRawAttrs = parseFrontmatter(fs.readFileSync(existingUser.path, "utf8")).attrs;
        } catch {
          // The discovered entry's own file vanished in the gap -- proceed
          // with just the managed fields below rather than failing the PUT.
        }

        const mergedAttrs: Record<string, string | undefined> = { ...existingRawAttrs, name };
        if (typeof body.description === "string") {
          mergedAttrs.description = collapseToSingleLine(body.description);
        }
        if (body.displayName !== undefined) {
          const displayName = typeof body.displayName === "string" ? collapseToSingleLine(body.displayName) : "";
          if (displayName) {
            mergedAttrs.displayName = displayName;
          } else {
            delete mergedAttrs.displayName;
          }
        }
        if (body.tools !== undefined) {
          const tools = joinTools(body.tools);
          if (tools) {
            mergedAttrs.tools = tools;
          } else {
            delete mergedAttrs.tools;
          }
        }
        const definitionBody = typeof body.body === "string" ? body.body : existingUser.body;

        assertWithinRoot(userRoot, existingUser.path);
        fs.writeFileSync(existingUser.path, renderFrontmatter(mergedAttrs, definitionBody));
        store.invalidate();

        return Response.json({
          name,
          description: mergedAttrs.description ?? "",
          displayName: mergedAttrs.displayName,
          model: mergedAttrs.model,
          tools: mergedAttrs.tools,
          body: definitionBody,
          root: userRoot,
          path: displayPath(existingUser.path),
          editable: true,
        });
      },
    },
    {
      method: "DELETE",
      path: "/agent/definitions/:name",
      handler: (req) => {
        const name = nameFromPath(req);
        const all = store.listAll();
        const existingUser = all.find((e) => e.name === name && e.root === userRoot);
        if (!existingUser) {
          const existsSomewhere = all.some((e) => e.name === name);
          return Response.json(
            { error: `"${name}" is not a deletable (user-root) agent` },
            { status: existsSomewhere ? 403 : 404 }
          );
        }
        // Same defense-in-depth posture as POST/PUT (reviewer-requested
        // consistency fix): `existingUser.path` is always root-scanned from
        // `userRoot` itself, so this is unreachable in practice, but a
        // destructive `fs.rmSync` call is exactly the place to assert it
        // anyway rather than trust that invariant silently.
        assertWithinRoot(userRoot, existingUser.path);
        fs.rmSync(existingUser.path, { force: true });
        store.invalidate();
        return Response.json({ deleted: true });
      },
    },
  ];
}
