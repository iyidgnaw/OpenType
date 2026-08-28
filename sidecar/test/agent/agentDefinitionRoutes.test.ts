import { describe, expect, test } from "bun:test";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { buildAgentDefinitionRoutes } from "../../src/agent/agentDefinitionRoutes";
import { createAgentDefinitionStore } from "../../src/agent/agentDefinitions";
import { createRouter } from "../../src/router";
import { parseFrontmatter } from "../../src/resources/frontmatter";

/**
 * Stage-1 TDD (red) for the skill/agent-UI batch's Pipeline A §1.3/§1.4/§1.5
 * (docs/superpowers/specs/2026-08-28-skill-agent-ui-and-step-log-persistence.md):
 * the HTTP surface backing the new Settings "Skill 与 Agent" page's AGENT
 * column (design §3, 8A/8D), and the extended `GET /agent/definitions`
 * bullet in §1.3's first line.
 *
 * `sidecar/src/agent/agentDefinitionRoutes.ts` DOES NOT EXIST YET.
 *
 * CONTRACT DECISIONS (flagged, not guessed silently):
 *
 * - New sibling file, `buildAgentDefinitionRoutes(deps: { store, userRoot,
 *   builtInRoot }): Route[]` -- mirrors `skills/skillRoutes.ts`'s shape
 *   exactly (see that file's header comment for the reasoning shared by
 *   both). `store` is whatever `createAgentDefinitionStore(...)` returns,
 *   extended (this same pipeline, see `agentDefinitions.test.ts`) with
 *   `listAll()`/`invalidate()`.
 * - This is DELIBERATELY a separate file from `agent/routes.ts`'s existing
 *   `buildAgentRoutes`/`handleAgentDefinitions`, NOT an in-place edit to it.
 *   `agent/routes.test.ts`'s existing "GET /agent/definitions returns name/
 *   description/source-root/tools..." test exercises `buildAgentRoutes(...)`
 *   directly and must keep passing unmodified (this stage's instructions:
 *   never weaken an existing test) -- editing `handleAgentDefinitions`
 *   in-place to add the new fields would be fine in isolation, but stacking
 *   this pipeline's `listAll`-shaped `active`/`shadowedBy` data onto
 *   `AgentDefinitionsSource` (which today only has `list()`/
 *   `globalInstructions()`) is exactly the kind of routes.ts-signature
 *   churn the file's own §9.1 comment flags as something later stages
 *   should "reconcile ... into one coherent parameter list" rather than
 *   pile onto ad hoc. Putting the FULL new HTTP surface (including the
 *   extended list endpoint) in its own file sidesteps that churn entirely:
 *   `buildAgentRoutes`'s own internal `GET /agent/definitions` route is left
 *   completely untouched (so the existing test keeps passing against it in
 *   isolation), and this is flagged here as a COORDINATION NOTE for
 *   whichever stage wires `server.ts`: the real `buildApp` route table must
 *   register THIS file's `GET /agent/definitions` (the extended one) ahead
 *   of (or instead of) `buildAgentRoutes`'s own, since `router.ts`'s
 *   `createRouter` returns the FIRST matching route on method+path.
 * - `root` values are the entry's actual filesystem root path (same
 *   reasoning as `skillRoutes.test.ts`).
 * - List rows include `displayName`, `model`, `tools` (still the raw
 *   comma-separated string `AgentDefinition.tools` already carries, NOT
 *   pre-split into an array -- matches the existing GET /agent/definitions
 *   convention), `path`, `active`, `shadowedBy` -- and explicitly NO `body`
 *   field (design §1.3: "列表继续不含 body").
 * - POST/PUT accept `tools` as a JSON array of strings in the request body
 *   (serialized to a comma-joined frontmatter line on write); an omitted
 *   `tools` field writes no `tools:` line at all (inherits every tool,
 *   design §1.2/§4.3 elsewhere in this codebase).
 * - B2's "POST/PUT 不接受 model 字段" is asserted as the load-bearing
 *   invariant the design text actually cares about: a `model` value present
 *   in the request body must never end up in the written file, checked by
 *   reading the raw file off disk directly (bypassing the discovery layer's
 *   own parsing). Whether the route additionally 400s on a submitted
 *   `model` or just silently drops it is left unpinned here -- the
 *   assignment's own wording ("rejected or ignored") says either is
 *   acceptable, so the test only asserts the file-content invariant, not a
 *   specific status code for that one request.
 * - DELETE for a name that resolves in no root at all is asserted as 404,
 *   same inferred-not-specified reasoning as `skillRoutes.test.ts`.
 *
 * Every test uses three injected temp directories for builtin/user/claude --
 * never the real `~/.opentype/agents` or `~/.claude/agents`.
 */

function mkTempDir(): string {
  return fs.mkdtempSync(path.join(os.tmpdir(), "opentype-agentdefroutes-"));
}

function agentFileContent(attrs: Record<string, string | undefined>, body: string): string {
  const lines = ["---"];
  for (const [key, value] of Object.entries(attrs)) {
    if (value !== undefined) {
      lines.push(`${key}: ${value}`);
    }
  }
  lines.push("---", body);
  return lines.join("\n");
}

function writeAgentFile(root: string, filename: string, content: string): string {
  fs.mkdirSync(root, { recursive: true });
  const file = path.join(root, filename);
  fs.writeFileSync(file, content);
  return file;
}

interface Roots {
  builtIn: string;
  userRoot: string;
  claudeRoot: string;
}

function makeRoots(): Roots {
  return { builtIn: mkTempDir(), userRoot: mkTempDir(), claudeRoot: mkTempDir() };
}

function makeRouter(roots: Roots, ttlMs = 0) {
  const store = createAgentDefinitionStore({ roots: [roots.builtIn, roots.userRoot, roots.claudeRoot], ttlMs });
  const router = createRouter(
    buildAgentDefinitionRoutes({ store, userRoot: roots.userRoot, builtInRoot: roots.builtIn })
  );
  return { router, store };
}

function get(url: string): Request {
  return new Request(`http://sidecar${url}`, { method: "GET" });
}

function post(url: string, body: unknown): Request {
  return new Request(`http://sidecar${url}`, { method: "POST", body: JSON.stringify(body) });
}

function put(url: string, body: unknown): Request {
  return new Request(`http://sidecar${url}`, { method: "PUT", body: JSON.stringify(body) });
}

function del(url: string): Request {
  return new Request(`http://sidecar${url}`, { method: "DELETE" });
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
  body?: string;
}

async function listAgents(router: ReturnType<typeof createRouter>): Promise<AgentListRow[]> {
  const res = await router(get("/agent/definitions"));
  const body = (await res.json()) as AgentListRow[];
  return body;
}

describe("GET /agent/definitions (extended row shape, design §1.3)", () => {
  test("rows carry name/description/displayName/model/tools/root/path/editable-free active/shadowedBy, and NO body", async () => {
    const roots = makeRoots();
    writeAgentFile(
      roots.builtIn,
      "helper.md",
      agentFileContent({ name: "helper", description: "builtin helper" }, "BUILTIN BODY")
    );
    writeAgentFile(
      roots.userRoot,
      "writer.md",
      agentFileContent(
        { name: "writer", description: "Writes emails", displayName: "写作助手", tools: "bash, read_file", model: "opus" },
        "USER BODY"
      )
    );
    const { router } = makeRouter(roots);

    const rows = await listAgents(router);
    const byName = Object.fromEntries(rows.map((r) => [r.name, r]));

    expect(byName.helper).toMatchObject({ description: "builtin helper", root: roots.builtIn, active: true });
    expect(byName.writer).toMatchObject({
      description: "Writes emails",
      displayName: "写作助手",
      tools: "bash, read_file",
      model: "opus",
      root: roots.userRoot,
      active: true,
    });
    // No row anywhere carries the full body -- this is the LIST endpoint.
    for (const row of rows) {
      expect((row as { body?: unknown }).body).toBeUndefined();
    }
  });

  test("a shadowed user copy appears with active:false and shadowedBy set to the builtin root", async () => {
    const roots = makeRoots();
    writeAgentFile(roots.builtIn, "writer.md", agentFileContent({ name: "writer", description: "builtin" }, "B"));
    writeAgentFile(roots.userRoot, "writer.md", agentFileContent({ name: "writer", description: "user" }, "U"));
    const { router } = makeRouter(roots);

    const rows = await listAgents(router);
    const copies = rows.filter((r) => r.name === "writer");
    expect(copies).toHaveLength(2);
    const active = copies.find((r) => r.root === roots.builtIn);
    const shadowed = copies.find((r) => r.root === roots.userRoot);
    expect(active?.active).toBe(true);
    expect(shadowed?.active).toBe(false);
    expect(shadowed?.shadowedBy).toBe(roots.builtIn);
  });
});

describe("GET /agent/definitions/:name", () => {
  test("returns the full record including body and editable for the active copy by default", async () => {
    const roots = makeRoots();
    writeAgentFile(
      roots.builtIn,
      "helper.md",
      agentFileContent({ name: "helper", description: "d" }, "BUILTIN BODY")
    );
    const { router } = makeRouter(roots);

    const res = await router(get("/agent/definitions/helper"));
    expect(res.status).toBe(200);
    const body = (await res.json()) as { name: string; body: string; editable: boolean; root: string };
    expect(body).toMatchObject({ name: "helper", body: "BUILTIN BODY", editable: false, root: roots.builtIn });
  });

  test("?root=<path> selects a specific (e.g. shadowed) copy", async () => {
    const roots = makeRoots();
    writeAgentFile(roots.builtIn, "writer.md", agentFileContent({ name: "writer", description: "d" }, "BUILTIN"));
    writeAgentFile(roots.userRoot, "writer.md", agentFileContent({ name: "writer", description: "d" }, "USER"));
    const { router } = makeRouter(roots);

    const res = await router(get(`/agent/definitions/writer?root=${encodeURIComponent(roots.userRoot)}`));
    expect(res.status).toBe(200);
    const body = (await res.json()) as { body: string; editable: boolean };
    expect(body.body).toBe("USER");
    expect(body.editable).toBe(true);
  });

  test("404 for an unknown name", async () => {
    const roots = makeRoots();
    const { router } = makeRouter(roots);

    const res = await router(get("/agent/definitions/nowhere"));
    expect(res.status).toBe(404);
  });
});

describe("POST /agent/definitions: create", () => {
  test("creates a user-root agent definition, visible immediately (invalidate, no TTL wait)", async () => {
    const roots = makeRoots();
    const { router } = makeRouter(roots, 60_000);

    const res = await router(
      post("/agent/definitions", {
        name: "researcher",
        displayName: "研究员",
        description: "Looks things up",
        tools: ["bash", "web_search"],
        body: "You research things carefully.",
      })
    );
    expect(res.status).toBe(200);

    const rows = await listAgents(router);
    const created = rows.find((r) => r.name === "researcher");
    expect(created).toBeDefined();
    expect(created?.displayName).toBe("研究员");
    expect(created?.description).toBe("Looks things up");
    expect(created?.tools).toContain("bash");
    expect(created?.tools).toContain("web_search");
    expect(created?.root).toBe(roots.userRoot);

    const getRes = await router(get("/agent/definitions/researcher"));
    const body = (await getRes.json()) as { body: string };
    expect(body.body).toBe("You research things carefully.");

    expect(fs.existsSync(path.join(roots.userRoot, "researcher.md"))).toBe(true);
  });

  test("resolves the written path inside the user root -- no escape", async () => {
    const roots = makeRoots();
    const { router } = makeRouter(roots);

    await router(post("/agent/definitions", { name: "safe-name", description: "d", body: "b" }));

    const res = await router(get("/agent/definitions/safe-name"));
    const body = (await res.json()) as { path: string };
    const resolvedUserRoot = fs.realpathSync(roots.userRoot);
    expect(path.resolve(body.path).startsWith(resolvedUserRoot + path.sep)).toBe(true);
  });

  test("omitted tools writes no tools line -- the discovered entry has tools undefined (inherits everything)", async () => {
    const roots = makeRoots();
    const { router } = makeRouter(roots);

    await router(post("/agent/definitions", { name: "no-tools-agent", description: "d", body: "b" }));

    const rows = await listAgents(router);
    const created = rows.find((r) => r.name === "no-tools-agent");
    expect(created?.tools).toBeUndefined();

    const raw = fs.readFileSync(path.join(roots.userRoot, "no-tools-agent.md"), "utf8");
    expect(raw).not.toContain("tools:");
  });

  test("a `model` field in the POST body never ends up in the written file (design §0 B2)", async () => {
    const roots = makeRoots();
    const { router } = makeRouter(roots);

    const res = await router(
      post("/agent/definitions", { name: "model-agent", description: "d", body: "b", model: "opus" })
    );

    // Either a 400 rejection or a silent-drop 200 is acceptable per this
    // stage's instructions -- but the response MUST be one of the two (not,
    // say, a 404 from an unregistered route slipping through unnoticed) --
    // what's NOT acceptable, under either accepted status, is the model
    // value reaching disk.
    expect([200, 400]).toContain(res.status);
    if (res.status === 200) {
      const raw = fs.readFileSync(path.join(roots.userRoot, "model-agent.md"), "utf8");
      expect(raw).not.toContain("model:");
      expect(raw).not.toContain("opus");
    }
  });

  test("collapses a multi-line description to a single line", async () => {
    const roots = makeRoots();
    const { router } = makeRouter(roots);

    const res = await router(
      post("/agent/definitions", { name: "multi-desc", description: "Line one\nLine two", body: "b" })
    );
    expect(res.status).toBe(200);

    const rows = await listAgents(router);
    const entry = rows.find((r) => r.name === "multi-desc");
    expect(entry?.description).not.toContain("\n");
    expect(entry?.description).toContain("Line one");
    expect(entry?.description).toContain("Line two");
  });

  describe("name charset/length validation (design §1.4)", () => {
    const invalidNames = ["../x", "a b", "-x", "", "a".repeat(65)];
    for (const name of invalidNames) {
      test(`rejects ${JSON.stringify(name)} with 400`, async () => {
        const roots = makeRoots();
        const { router } = makeRouter(roots);

        const res = await router(post("/agent/definitions", { name, description: "d", body: "b" }));
        expect(res.status).toBe(400);
        expect(fs.readdirSync(roots.userRoot)).toEqual([]);
      });
    }
  });

  describe("the reserved name \"readme\" (design §1.4, case-insensitive)", () => {
    for (const name of ["readme", "README", "ReadMe"]) {
      test(`rejects ${JSON.stringify(name)} with 400`, async () => {
        const roots = makeRoots();
        const { router } = makeRouter(roots);

        const res = await router(post("/agent/definitions", { name, description: "d", body: "b" }));
        expect(res.status).toBe(400);
      });
    }
  });

  test("409 when the name collides with an existing BUILTIN agent (using a temp builtin root containing one)", async () => {
    const roots = makeRoots();
    writeAgentFile(roots.builtIn, "helper.md", agentFileContent({ name: "helper", description: "d" }, "b"));
    const { router } = makeRouter(roots);

    const res = await router(post("/agent/definitions", { name: "helper", description: "d2", body: "b2" }));
    expect(res.status).toBe(409);
    expect(fs.existsSync(path.join(roots.userRoot, "helper.md"))).toBe(false);
  });

  test("409 when the name already exists in the user root (use PUT to update instead)", async () => {
    const roots = makeRoots();
    writeAgentFile(roots.userRoot, "mine.md", agentFileContent({ name: "mine", description: "old" }, "old body"));
    const { router } = makeRouter(roots);

    const res = await router(post("/agent/definitions", { name: "mine", description: "new", body: "new body" }));
    expect(res.status).toBe(409);

    const getRes = await router(get("/agent/definitions/mine"));
    const body = (await getRes.json()) as { description: string; body: string };
    expect(body.description).toBe("old");
    expect(body.body).toBe("old body");
  });

  test("does NOT conflict with a same-named CLAUDE-root agent (E3)", async () => {
    const roots = makeRoots();
    writeAgentFile(roots.claudeRoot, "shared.md", agentFileContent({ name: "shared", description: "claude" }, "c"));
    const { router } = makeRouter(roots);

    const res = await router(post("/agent/definitions", { name: "shared", description: "new", body: "new" }));
    expect(res.status).toBe(200);

    const rows = await listAgents(router);
    const copies = rows.filter((r) => r.name === "shared");
    expect(copies).toHaveLength(2);
    const active = copies.find((r) => r.active);
    expect(active?.root).toBe(roots.userRoot);
  });
});

describe("PUT /agent/definitions/:name: update", () => {
  test("updates description, displayName, tools and body of a user-root agent", async () => {
    const roots = makeRoots();
    writeAgentFile(roots.userRoot, "mine.md", agentFileContent({ name: "mine", description: "old" }, "old body"));
    const { router } = makeRouter(roots);

    const res = await router(
      put("/agent/definitions/mine", {
        displayName: "我的助手",
        description: "new desc",
        tools: ["bash"],
        body: "new body",
      })
    );
    expect(res.status).toBe(200);

    const getRes = await router(get("/agent/definitions/mine"));
    const body = (await getRes.json()) as { description: string; body: string; displayName?: string; tools?: string };
    expect(body.description).toBe("new desc");
    expect(body.body).toBe("new body");
    expect(body.displayName).toBe("我的助手");
    expect(body.tools).toContain("bash");
  });

  test("preserves an unmanaged frontmatter key (`model:`) already present in the file (design §1.3: 'must round-trip')", async () => {
    const roots = makeRoots();
    writeAgentFile(
      roots.userRoot,
      "mine.md",
      agentFileContent({ name: "mine", description: "old", model: "opus" }, "old body")
    );
    const { router } = makeRouter(roots);

    const res = await router(put("/agent/definitions/mine", { description: "new desc", body: "new body" }));
    expect(res.status).toBe(200);

    // Read the raw file directly off disk -- the model line must have
    // survived the PUT untouched, even though the PUT body never mentioned
    // it and the API deliberately never lets a client SET model (B2).
    const raw = fs.readFileSync(path.join(roots.userRoot, "mine.md"), "utf8");
    expect(raw).toContain("model: opus");
    expect(raw).toContain("new body");

    const getRes = await router(get("/agent/definitions/mine"));
    const body = (await getRes.json()) as { model?: string; description: string };
    expect(body.model).toBe("opus");
    expect(body.description).toBe("new desc");
  });

  test("name is immutable: a name field in the body is ignored", async () => {
    const roots = makeRoots();
    writeAgentFile(roots.userRoot, "mine.md", agentFileContent({ name: "mine", description: "old" }, "old body"));
    const { router } = makeRouter(roots);

    await router(put("/agent/definitions/mine", { name: "renamed", description: "new", body: "new body" }));

    const getRes = await router(get("/agent/definitions/mine"));
    expect(getRes.status).toBe(200);
    const rows = await listAgents(router);
    expect(rows.some((r) => r.name === "renamed")).toBe(false);
  });

  test("403 when the name exists only as a BUILTIN agent", async () => {
    const roots = makeRoots();
    const builtInFile = writeAgentFile(
      roots.builtIn,
      "helper.md",
      agentFileContent({ name: "helper", description: "d" }, "b")
    );
    const originalContent = fs.readFileSync(builtInFile, "utf8");
    const { router } = makeRouter(roots);

    const res = await router(put("/agent/definitions/helper", { description: "new", body: "new" }));
    expect(res.status).toBe(403);
    // Nothing was overwritten -- the builtin file on disk is byte-for-byte unchanged.
    expect(fs.readFileSync(builtInFile, "utf8")).toBe(originalContent);
  });

  test("403 when the name exists only as a CLAUDE-root agent", async () => {
    const roots = makeRoots();
    const claudeFile = writeAgentFile(
      roots.claudeRoot,
      "claude-only.md",
      agentFileContent({ name: "claude-only", description: "d" }, "b")
    );
    const originalContent = fs.readFileSync(claudeFile, "utf8");
    const { router } = makeRouter(roots);

    const res = await router(put("/agent/definitions/claude-only", { description: "new", body: "new" }));
    expect(res.status).toBe(403);
    // Nothing was overwritten -- the claude-root file on disk is byte-for-byte unchanged.
    expect(fs.readFileSync(claudeFile, "utf8")).toBe(originalContent);
  });

  test("404 when the name does not exist anywhere", async () => {
    const roots = makeRoots();
    const { router } = makeRouter(roots);

    const res = await router(put("/agent/definitions/nowhere", { description: "new", body: "new" }));
    expect(res.status).toBe(404);
  });

  test("a `model` field sent in the PUT body cannot be used to set/change model (B2)", async () => {
    const roots = makeRoots();
    writeAgentFile(roots.userRoot, "mine.md", agentFileContent({ name: "mine", description: "old" }, "old body"));
    const { router } = makeRouter(roots);

    const res = await router(put("/agent/definitions/mine", { description: "new", body: "new body", model: "sonnet" }));
    // The PUT itself must actually have succeeded -- otherwise the "no model
    // line" check below would hold vacuously (the file untouched) without
    // ever exercising the model-stripping behavior this test is for.
    expect(res.status).toBe(200);

    const raw = fs.readFileSync(path.join(roots.userRoot, "mine.md"), "utf8");
    expect(raw).toContain("new body");
    // The file had NO model line before this PUT -- one must not have been
    // introduced by a client-submitted model value.
    expect(raw).not.toContain("model:");
  });
});

describe("DELETE /agent/definitions/:name", () => {
  test("removes the user-root agent definition file", async () => {
    const roots = makeRoots();
    writeAgentFile(roots.userRoot, "mine.md", agentFileContent({ name: "mine", description: "d" }, "b"));
    const { router } = makeRouter(roots);

    const res = await router(del("/agent/definitions/mine"));
    expect(res.status).toBe(200);

    expect(fs.existsSync(path.join(roots.userRoot, "mine.md"))).toBe(false);
    const rows = await listAgents(router);
    expect(rows.some((r) => r.name === "mine")).toBe(false);
  });

  test("403 when the name resolves to a BUILTIN-only agent", async () => {
    const roots = makeRoots();
    writeAgentFile(roots.builtIn, "helper.md", agentFileContent({ name: "helper", description: "d" }, "b"));
    const { router } = makeRouter(roots);

    const res = await router(del("/agent/definitions/helper"));
    expect(res.status).toBe(403);
    expect(fs.existsSync(path.join(roots.builtIn, "helper.md"))).toBe(true);
  });

  test("403 when the name resolves to a CLAUDE-root-only agent", async () => {
    const roots = makeRoots();
    writeAgentFile(roots.claudeRoot, "claude-only.md", agentFileContent({ name: "claude-only", description: "d" }, "b"));
    const { router } = makeRouter(roots);

    const res = await router(del("/agent/definitions/claude-only"));
    expect(res.status).toBe(403);
    expect(fs.existsSync(path.join(roots.claudeRoot, "claude-only.md"))).toBe(true);
  });

  test("404 when the name does not exist anywhere", async () => {
    const roots = makeRoots();
    const { router } = makeRouter(roots);

    const res = await router(del("/agent/definitions/nowhere"));
    expect(res.status).toBe(404);
  });

  test("deleting a user copy that was shadowing a builtin agent leaves the builtin copy intact and now-active", async () => {
    const roots = makeRoots();
    writeAgentFile(roots.builtIn, "writer.md", agentFileContent({ name: "writer", description: "builtin" }, "BUILTIN"));
    writeAgentFile(roots.userRoot, "writer.md", agentFileContent({ name: "writer", description: "user" }, "USER"));
    const { router } = makeRouter(roots);

    const res = await router(del("/agent/definitions/writer"));
    expect(res.status).toBe(200);

    const getRes = await router(get("/agent/definitions/writer"));
    const body = (await getRes.json()) as { body: string; root: string };
    expect(body.body).toBe("BUILTIN");
    expect(body.root).toBe(roots.builtIn);
  });
});

/**
 * Stage-4 review regression (PoC-verified, real vulnerability): unlike
 * `description`, neither `displayName` nor an individual `tools[]` element
 * is run through anything equivalent to `collapseDescription` before
 * reaching `renderFrontmatter` (`src/agent/agentDefinitionRoutes.ts`'s
 * `joinTools`/POST and PUT handlers only `.trim()` them, which strips
 * leading/trailing whitespace but leaves an EMBEDDED `\n` intact).
 * `renderFrontmatter` (`src/resources/frontmatter.ts`) does not escape
 * newlines either -- its own doc comment says so explicitly ("Deliberately
 * does NOT collapse a multi-line value itself ... The caller is responsible
 * for pre-collapsing anything that might contain a newline"). So a
 * `displayName` (or a `tools[]` element) containing
 * `"\nmodel: injected-model-xyz"` is written into the file as a literal
 * embedded newline, which `parseFrontmatter`'s line-oriented parser then
 * reads back as a SEPARATE, forged `model:` (or `tools:`) frontmatter line
 * -- directly violating B2 ("POST/PUT 不接受 model 字段"), since the
 * attacker never had to name the `model` field at all, only smuggle it
 * through a field that IS accepted.
 *
 * PoC (stage-4 review): POST with
 * `displayName: "Evil\nmodel: injected-model-xyz\ntools: opentype__bash"`
 * produces a file whose re-parse yields `model === "injected-model-xyz"`.
 *
 * Every test below accepts either a 200 (silently sanitized) or a 400
 * (rejected outright) response -- exactly as this stage's own B2 tests
 * already do for a direct `model` field -- because the BINDING invariant is
 * the FILE CONTENT on disk and what `parseFrontmatter` reads back from it,
 * never the status code. A test that only checked "conditionally, if 200"
 * with no assertion outside that guard would pass vacuously against the
 * current 200-and-injected behavior; every assertion below either runs
 * unconditionally or is guarded by first requiring `res.status` to actually
 * be one of the two accepted values, which the current (vulnerable) 200
 * response also satisfies.
 */
describe("frontmatter-injection via embedded newlines in displayName/tools (stage-4 regression, PoC-verified)", () => {
  test("POST: a newline-embedded displayName cannot forge a model: line, and the parsed tools equal exactly the legit request tools", async () => {
    const roots = makeRoots();
    const { router } = makeRouter(roots);

    const res = await router(
      post("/agent/definitions", {
        name: "injected-agent-1",
        displayName: "Evil\nmodel: injected-model-xyz\ntools: opentype__bash",
        description: "d",
        tools: ["opentype__read_file"],
        body: "b",
      })
    );

    expect([200, 400]).toContain(res.status);
    if (res.status !== 200) {
      return;
    }

    const filePath = path.join(roots.userRoot, "injected-agent-1.md");
    const raw = fs.readFileSync(filePath, "utf8");
    // No line in the written file may declare `model:` -- the request never
    // named that field at all, so nothing should ever be able to introduce it.
    expect(raw.split("\n").some((line) => line.startsWith("model:"))).toBe(false);

    const { attrs } = parseFrontmatter(raw);
    expect(attrs.model).toBeUndefined();
    // The parsed tools must be EXACTLY the legit request's tools -- not the
    // "opentype__bash" smuggled in via displayName.
    const parsedTools = (attrs.tools ?? "").split(",").map((t) => t.trim()).filter(Boolean);
    expect(parsedTools).toEqual(["opentype__read_file"]);
  });

  test("POST: a newline embedded inside a tools[] element cannot forge a model: line, and the tools line carries no newline-born extra lines", async () => {
    const roots = makeRoots();
    const { router } = makeRouter(roots);

    const res = await router(
      post("/agent/definitions", {
        name: "injected-agent-2",
        description: "d",
        tools: ["opentype__read_file\nmodel: injected-y"],
        body: "b",
      })
    );

    expect([200, 400]).toContain(res.status);
    if (res.status !== 200) {
      return;
    }

    const filePath = path.join(roots.userRoot, "injected-agent-2.md");
    const raw = fs.readFileSync(filePath, "utf8");
    expect(raw.split("\n").some((line) => line.startsWith("model:"))).toBe(false);

    const { attrs } = parseFrontmatter(raw);
    expect(attrs.model).toBeUndefined();
    // At most one line may declare `tools:` -- a newline embedded inside the
    // array element must not have split into a second, forged `tools:` (or
    // any other) frontmatter line.
    const toolsLines = raw.split("\n").filter((line) => line.startsWith("tools:"));
    expect(toolsLines.length).toBeLessThanOrEqual(1);
  });

  test("POST: omitted tools + a newline-embedded displayName cannot forge a tools: line (inherit-all must stay inherit-all)", async () => {
    const roots = makeRoots();
    const { router } = makeRouter(roots);

    const res = await router(
      post("/agent/definitions", {
        name: "injected-agent-3",
        displayName: "Evil\ntools: opentype__bash",
        description: "d",
        body: "b",
        // `tools` deliberately OMITTED -- the created agent should inherit
        // every tool, exactly as if displayName had no embedded newline.
      })
    );

    expect([200, 400]).toContain(res.status);
    if (res.status !== 200) {
      return;
    }

    const filePath = path.join(roots.userRoot, "injected-agent-3.md");
    const raw = fs.readFileSync(filePath, "utf8");
    expect(raw.split("\n").some((line) => line.startsWith("tools:"))).toBe(false);

    const { attrs } = parseFrontmatter(raw);
    expect(attrs.tools).toBeUndefined();
  });

  test("PUT: a newline-embedded displayName cannot forge a model: line -- unmanaged-key preservation must not become an injection vector", async () => {
    const roots = makeRoots();
    writeAgentFile(roots.userRoot, "mine.md", agentFileContent({ name: "mine", description: "old" }, "old body"));
    const { router } = makeRouter(roots);

    const res = await router(
      put("/agent/definitions/mine", {
        displayName: "Evil\nmodel: injected-model-xyz",
        description: "new desc",
        body: "new body",
      })
    );

    // Unlike POST, PUT against an already-existing user-root file has no
    // legitimate reason to reject the request outright (the file exists and
    // the request shape is otherwise valid) -- so this one IS pinned to 200,
    // matching every other non-injection PUT-success test in this file.
    expect(res.status).toBe(200);

    const raw = fs.readFileSync(path.join(roots.userRoot, "mine.md"), "utf8");
    expect(raw.split("\n").some((line) => line.startsWith("model:"))).toBe(false);

    const { attrs } = parseFrontmatter(raw);
    expect(attrs.model).toBeUndefined();
    // The file must contain EXACTLY the original unmanaged/managed keys
    // (name, description) plus this update's managed field (displayName) --
    // nothing forged, nothing extra smuggled in alongside them.
    expect(Object.keys(attrs).sort()).toEqual(["description", "displayName", "name"]);
  });
});
