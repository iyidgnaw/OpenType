import { describe, expect, test } from "bun:test";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { buildSkillRoutes } from "../../src/skills/skillRoutes";
import { createSkillStore } from "../../src/skills/skillStore";
import { createRouter } from "../../src/router";

/**
 * Stage-1 TDD (red) for the skill/agent-UI batch's Pipeline A §1.2/§1.4/§1.5
 * (docs/superpowers/specs/2026-08-28-skill-agent-ui-and-step-log-persistence.md):
 * the HTTP surface backing the new Settings "Skill 与 Agent" page's SKILL
 * column (design §3, 8A/8B/8C).
 *
 * `sidecar/src/skills/skillRoutes.ts` DOES NOT EXIST YET -- this whole file
 * fails to even parse the import at module-load time until stage 3 creates
 * it, which `bun test` reports as a module-resolution error naming the
 * missing path, not a syntax error in THIS file. Every test below is written
 * against the contract this stage is choosing on the implementation's
 * behalf (see the CONTRACT DECISIONS block), since the design doc leaves the
 * exact function signature to whoever builds it ("新文件
 * sidecar/src/skills/skillRoutes.ts, wire 进 buildApp，依赖注入 store 便于测试").
 *
 * CONTRACT DECISIONS (flagged, not guessed silently):
 *
 * - `buildSkillRoutes(deps: { store, userRoot, builtInRoot }): Route[]`.
 *   `store` is whatever `createSkillStore(...)` returns, now extended (this
 *   same pipeline, see `skillStore.test.ts`) with `listAll()`/`invalidate()`
 *   alongside `list()`. `userRoot`/`builtInRoot` are the two root paths the
 *   routes need to know explicitly: `userRoot` to know where to write, and
 *   both to compute `editable` (`root === userRoot`) and the 409/403 rules
 *   (`root === builtInRoot` vs. neither, which is "claude" by elimination).
 *   This mirrors `agent/mcpConfigRoutes.ts`'s existing
 *   store-plus-overridable-deps shape rather than inventing a new one.
 * - `root` in every response row is the entry's actual filesystem root path
 *   (`ResourceEntry.root`/`Skill.root`'s own value) -- per design §1.2's
 *   "root 标识沿用现有 roots 命名", this reuses the identifier the discovery
 *   layer already produces rather than inventing a symbolic id scheme
 *   ("builtin"/"user"/"claude") that doesn't exist anywhere in this codebase
 *   today. `?root=<path>` on `GET /skills/:name` is the same value handed
 *   back.
 * - Success responses use status 200 (this codebase's own convention --
 *   `mcpConfigRoutes.ts`/`memory/routes.ts` never use 201 for a create).
 * - A description containing embedded newlines is COLLAPSED to one line
 *   before being written (spec §1.4: "description 折叠为单行"), not
 *   rejected -- see the collapsing test below for the exact invariant
 *   pinned (no data loss, no raw newline in the stored value).
 * - `model` is not a skills concept at all (that's agent-definitions-only,
 *   §1.3/B2); nothing here concerns it.
 * - DELETE for a name that resolves in NO root at all is asserted as 404 --
 *   the design doc only states the builtin/claude -> 403 rule explicitly;
 *   404-for-truly-unknown is this stage's inference from the rest of the
 *   404/403 matrix (403 means "exists, but not somewhere you can delete
 *   from"; 404 means "does not exist to delete"), flagged here as an
 *   assumption stage 3/4 should confirm rather than silently rely on.
 *
 * Every test uses three injected temp directories for builtin/user/claude --
 * never the real `~/.opentype/skills` or `~/.claude/skills`.
 */

function mkTempDir(): string {
  return fs.mkdtempSync(path.join(os.tmpdir(), "opentype-skillroutes-"));
}

function writeSkillFile(root: string, dirName: string, name: string, description: string, body: string): string {
  const dir = path.join(root, dirName);
  fs.mkdirSync(dir, { recursive: true });
  const file = path.join(dir, "SKILL.md");
  fs.writeFileSync(file, ["---", `name: ${name}`, `description: ${description}`, "---", body].join("\n"));
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
  const store = createSkillStore({ roots: [roots.builtIn, roots.userRoot, roots.claudeRoot], ttlMs });
  const router = createRouter(buildSkillRoutes({ store, userRoot: roots.userRoot, builtInRoot: roots.builtIn }));
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

interface SkillListRow {
  name: string;
  description: string;
  root: string;
  path: string;
  editable: boolean;
  active: boolean;
  shadowedBy?: string;
}

async function listSkills(router: ReturnType<typeof createRouter>): Promise<SkillListRow[]> {
  const res = await router(get("/skills"));
  const body = (await res.json()) as { skills: SkillListRow[] };
  return body.skills;
}

describe("GET /skills", () => {
  test("lists entries from all three roots with the full row shape, editable true only for the user root", async () => {
    const roots = makeRoots();
    writeSkillFile(roots.builtIn, "dictate", "dictate", "builtin desc", "b");
    writeSkillFile(roots.userRoot, "my-skill", "my-skill", "user desc", "b");
    writeSkillFile(roots.claudeRoot, "claude-skill", "claude-skill", "claude desc", "b");
    const { router } = makeRouter(roots);

    const res = await router(get("/skills"));
    expect(res.status).toBe(200);
    const skills = await listSkills(router);
    const byName = Object.fromEntries(skills.map((s) => [s.name, s]));

    expect(byName["dictate"]).toMatchObject({
      description: "builtin desc",
      root: roots.builtIn,
      editable: false,
      active: true,
    });
    expect(byName["my-skill"]).toMatchObject({
      description: "user desc",
      root: roots.userRoot,
      editable: true,
      active: true,
    });
    expect(byName["claude-skill"]).toMatchObject({
      description: "claude desc",
      root: roots.claudeRoot,
      editable: false,
      active: true,
    });
  });

  test("a user copy shadowed by a same-named builtin skill appears with active:false and shadowedBy set to the builtin root, but stays editable", async () => {
    const roots = makeRoots();
    writeSkillFile(roots.builtIn, "dictate", "dictate", "builtin desc", "BUILTIN BODY");
    writeSkillFile(roots.userRoot, "dictate", "dictate", "user desc", "USER BODY");
    const { router } = makeRouter(roots);

    const skills = await listSkills(router);
    const copies = skills.filter((s) => s.name === "dictate");

    expect(copies).toHaveLength(2);
    const active = copies.find((s) => s.root === roots.builtIn);
    const shadowed = copies.find((s) => s.root === roots.userRoot);
    expect(active).toMatchObject({ active: true, editable: false });
    expect(active?.shadowedBy).toBeFalsy();
    expect(shadowed).toMatchObject({ active: false, editable: true, shadowedBy: roots.builtIn });
  });
});

describe("GET /skills/:name", () => {
  test("returns the active copy's full body by default", async () => {
    const roots = makeRoots();
    writeSkillFile(roots.builtIn, "dictate", "dictate", "builtin desc", "BUILTIN BODY");
    const { router } = makeRouter(roots);

    const res = await router(get("/skills/dictate"));
    expect(res.status).toBe(200);
    const body = (await res.json()) as { name: string; description: string; body: string; path: string; root: string; editable: boolean };
    expect(body).toMatchObject({
      name: "dictate",
      description: "builtin desc",
      body: "BUILTIN BODY",
      root: roots.builtIn,
      editable: false,
    });
  });

  test("?root=<path> selects a specific (e.g. shadowed) copy rather than the active one", async () => {
    const roots = makeRoots();
    writeSkillFile(roots.builtIn, "dictate", "dictate", "builtin desc", "BUILTIN BODY");
    writeSkillFile(roots.userRoot, "dictate", "dictate", "user desc", "USER BODY");
    const { router } = makeRouter(roots);

    const res = await router(get(`/skills/dictate?root=${encodeURIComponent(roots.userRoot)}`));
    expect(res.status).toBe(200);
    const body = (await res.json()) as { body: string; root: string; editable: boolean };
    expect(body.body).toBe("USER BODY");
    expect(body.root).toBe(roots.userRoot);
    expect(body.editable).toBe(true);
  });

  test("404 for a name that exists in no root at all", async () => {
    const roots = makeRoots();
    const { router } = makeRouter(roots);

    const res = await router(get("/skills/does-not-exist"));
    expect(res.status).toBe(404);
    const body = (await res.json()) as { error: string };
    expect(typeof body.error).toBe("string");
  });

  test("404 when ?root= names a root that has no copy of this skill", async () => {
    const roots = makeRoots();
    writeSkillFile(roots.builtIn, "dictate", "dictate", "d", "b");
    const { router } = makeRouter(roots);

    const res = await router(get(`/skills/dictate?root=${encodeURIComponent(roots.userRoot)}`));
    expect(res.status).toBe(404);
  });
});

describe("POST /skills: create", () => {
  test("creates a user-root skill; the written file round-trips through the discovery layer and is visible on the very next GET without waiting for the TTL", async () => {
    const roots = makeRoots();
    // A long TTL, deliberately: if this passes only because the TTL happens
    // to be short/zero, it would not prove `invalidate()` is actually being
    // called by the write handler.
    const { router } = makeRouter(roots, 60_000);

    const createRes = await router(
      post("/skills", { name: "my-new-skill", description: "Does a thing", body: "Step 1. Step 2." })
    );
    expect(createRes.status).toBe(200);

    const skills = await listSkills(router);
    const created = skills.find((s) => s.name === "my-new-skill");
    expect(created).toBeDefined();
    expect(created?.description).toBe("Does a thing");
    expect(created?.root).toBe(roots.userRoot);
    expect(created?.editable).toBe(true);
    expect(created?.active).toBe(true);

    const getRes = await router(get("/skills/my-new-skill"));
    expect(getRes.status).toBe(200);
    const body = (await getRes.json()) as { body: string };
    expect(body.body).toBe("Step 1. Step 2.");

    // The file genuinely landed on disk at the expected location, not just
    // in some in-memory echo of the request.
    expect(fs.existsSync(path.join(roots.userRoot, "my-new-skill", "SKILL.md"))).toBe(true);
  });

  test("resolves the written path inside the user root -- no escape (path-safety defensive assertion)", async () => {
    const roots = makeRoots();
    const { router } = makeRouter(roots);

    await router(post("/skills", { name: "safe-name", description: "d", body: "b" }));

    const res = await router(get("/skills/safe-name"));
    const body = (await res.json()) as { path: string };
    const resolvedUserRoot = fs.realpathSync(roots.userRoot);
    expect(path.resolve(body.path).startsWith(resolvedUserRoot + path.sep)).toBe(true);
  });

  test("collapses a multi-line description to a single line, and it round-trips correctly (no data loss)", async () => {
    const roots = makeRoots();
    const { router } = makeRouter(roots);

    const res = await router(
      post("/skills", { name: "multi-desc", description: "Line one\nLine two\nLine three", body: "b" })
    );
    expect(res.status).toBe(200);

    const skills = await listSkills(router);
    const entry = skills.find((s) => s.name === "multi-desc");
    expect(entry).toBeDefined();
    // No raw newline survives in the stored/discovered value -- a raw
    // newline embedded in a flat `key: value` frontmatter line would corrupt
    // the file for `frontmatter.ts`'s line-oriented parser.
    expect(entry?.description).not.toContain("\n");
    // But nothing was silently dropped either -- all three fragments must
    // still be present, in order.
    expect(entry?.description).toContain("Line one");
    expect(entry?.description).toContain("Line two");
    expect(entry?.description).toContain("Line three");
    expect(entry!.description.indexOf("Line one")).toBeLessThan(entry!.description.indexOf("Line two"));
    expect(entry!.description.indexOf("Line two")).toBeLessThan(entry!.description.indexOf("Line three"));
  });

  describe("name charset/length validation (design §1.4: ^[A-Za-z0-9][A-Za-z0-9-]*$, max 64)", () => {
    const invalidNames = ["../x", "a b", "-x", "", "a".repeat(65)];
    for (const name of invalidNames) {
      test(`rejects ${JSON.stringify(name)} with 400`, async () => {
        const roots = makeRoots();
        const { router } = makeRouter(roots);

        const res = await router(post("/skills", { name, description: "d", body: "b" }));
        expect(res.status).toBe(400);
        const body = (await res.json()) as { error: string };
        expect(typeof body.error).toBe("string");

        // And, crucially, nothing was written anywhere a rejected name could
        // have landed.
        expect(fs.readdirSync(roots.userRoot)).toEqual([]);
      });
    }

    test("accepts a valid 64-character name (boundary case)", async () => {
      const roots = makeRoots();
      const { router } = makeRouter(roots);
      const name = "a".repeat(64);

      const res = await router(post("/skills", { name, description: "d", body: "b" }));
      expect(res.status).toBe(200);
    });
  });

  test("409 when the name collides with an existing BUILTIN skill", async () => {
    const roots = makeRoots();
    writeSkillFile(roots.builtIn, "dictate", "dictate", "builtin desc", "b");
    const { router } = makeRouter(roots);

    const res = await router(post("/skills", { name: "dictate", description: "d", body: "b" }));
    expect(res.status).toBe(409);
    const body = (await res.json()) as { error: string };
    expect(typeof body.error).toBe("string");
    // Nothing was written to the user root as a side effect of the conflict.
    expect(fs.existsSync(path.join(roots.userRoot, "dictate"))).toBe(false);
  });

  test("409 when the name already exists in the user root (use PUT to update instead)", async () => {
    const roots = makeRoots();
    writeSkillFile(roots.userRoot, "mine", "mine", "old desc", "old body");
    const { router } = makeRouter(roots);

    const res = await router(post("/skills", { name: "mine", description: "new desc", body: "new body" }));
    expect(res.status).toBe(409);

    // The original content is untouched by the rejected create.
    const getRes = await router(get("/skills/mine"));
    const body = (await getRes.json()) as { description: string; body: string };
    expect(body.description).toBe("old desc");
    expect(body.body).toBe("old body");
  });

  test("does NOT conflict with a same-named CLAUDE-root skill (E3: user root already wins that collision by ordering)", async () => {
    const roots = makeRoots();
    writeSkillFile(roots.claudeRoot, "shared-name", "shared-name", "claude desc", "claude body");
    const { router } = makeRouter(roots);

    const res = await router(post("/skills", { name: "shared-name", description: "new desc", body: "new body" }));
    expect(res.status).toBe(200);

    const skills = await listSkills(router);
    const copies = skills.filter((s) => s.name === "shared-name");
    expect(copies).toHaveLength(2);
    const active = copies.find((s) => s.active);
    expect(active?.root).toBe(roots.userRoot);
  });
});

describe("PUT /skills/:name: update", () => {
  test("updates description and body of a user-root skill", async () => {
    const roots = makeRoots();
    writeSkillFile(roots.userRoot, "mine", "mine", "old desc", "old body");
    const { router } = makeRouter(roots);

    const res = await router(put("/skills/mine", { description: "new desc", body: "new body" }));
    expect(res.status).toBe(200);

    const getRes = await router(get("/skills/mine"));
    const body = (await getRes.json()) as { description: string; body: string };
    expect(body.description).toBe("new desc");
    expect(body.body).toBe("new body");
  });

  test("name is immutable: a name field in the body (if sent) is ignored, the skill stays addressable at the same URL", async () => {
    const roots = makeRoots();
    writeSkillFile(roots.userRoot, "mine", "mine", "old desc", "old body");
    const { router } = makeRouter(roots);

    await router(put("/skills/mine", { name: "renamed", description: "new desc", body: "new body" }));

    // Still reachable under the ORIGINAL name.
    const getRes = await router(get("/skills/mine"));
    expect(getRes.status).toBe(200);
    const body = (await getRes.json()) as { name: string; description: string };
    expect(body.name).toBe("mine");
    expect(body.description).toBe("new desc");

    // And no second skill was created under the attempted new name.
    const skills = await listSkills(router);
    expect(skills.some((s) => s.name === "renamed")).toBe(false);
  });

  test("403 when the name exists only as a BUILTIN skill (PUT is user-root only)", async () => {
    const roots = makeRoots();
    const builtInFile = writeSkillFile(roots.builtIn, "dictate", "dictate", "d", "b");
    const originalContent = fs.readFileSync(builtInFile, "utf8");
    const { router } = makeRouter(roots);

    const res = await router(put("/skills/dictate", { description: "new", body: "new" }));
    expect(res.status).toBe(403);
    // Nothing was overwritten -- the builtin file on disk is byte-for-byte unchanged.
    expect(fs.readFileSync(builtInFile, "utf8")).toBe(originalContent);
  });

  test("403 when the name exists only as a CLAUDE-root skill", async () => {
    const roots = makeRoots();
    const claudeFile = writeSkillFile(roots.claudeRoot, "claude-only", "claude-only", "d", "b");
    const originalContent = fs.readFileSync(claudeFile, "utf8");
    const { router } = makeRouter(roots);

    const res = await router(put("/skills/claude-only", { description: "new", body: "new" }));
    expect(res.status).toBe(403);
    // Nothing was overwritten -- the claude-root file on disk is byte-for-byte unchanged.
    expect(fs.readFileSync(claudeFile, "utf8")).toBe(originalContent);
  });

  test("404 when the name does not exist anywhere", async () => {
    const roots = makeRoots();
    const { router } = makeRouter(roots);

    const res = await router(put("/skills/nowhere", { description: "new", body: "new" }));
    expect(res.status).toBe(404);
  });

  test("write-then-read is immediate: an update is visible on the very next GET without waiting for the TTL", async () => {
    const roots = makeRoots();
    writeSkillFile(roots.userRoot, "mine", "mine", "old desc", "old body");
    const { router } = makeRouter(roots, 60_000);

    await router(put("/skills/mine", { description: "brand new", body: "brand new body" }));

    const getRes = await router(get("/skills/mine"));
    const body = (await getRes.json()) as { description: string };
    expect(body.description).toBe("brand new");
  });
});

describe("DELETE /skills/:name", () => {
  test("removes the entire user-root skill directory, including extra files inside it", async () => {
    const roots = makeRoots();
    writeSkillFile(roots.userRoot, "mine", "mine", "d", "b");
    fs.writeFileSync(path.join(roots.userRoot, "mine", "extra-notes.txt"), "some extra file");
    const { router } = makeRouter(roots);

    const res = await router(del("/skills/mine"));
    expect(res.status).toBe(200);

    expect(fs.existsSync(path.join(roots.userRoot, "mine"))).toBe(false);
    const skills = await listSkills(router);
    expect(skills.some((s) => s.name === "mine")).toBe(false);
  });

  test("403 when the name resolves to a BUILTIN-only skill", async () => {
    const roots = makeRoots();
    writeSkillFile(roots.builtIn, "dictate", "dictate", "d", "b");
    const { router } = makeRouter(roots);

    const res = await router(del("/skills/dictate"));
    expect(res.status).toBe(403);
    // Nothing was deleted.
    expect(fs.existsSync(path.join(roots.builtIn, "dictate"))).toBe(true);
  });

  test("403 when the name resolves to a CLAUDE-root-only skill", async () => {
    const roots = makeRoots();
    writeSkillFile(roots.claudeRoot, "claude-only", "claude-only", "d", "b");
    const { router } = makeRouter(roots);

    const res = await router(del("/skills/claude-only"));
    expect(res.status).toBe(403);
    expect(fs.existsSync(path.join(roots.claudeRoot, "claude-only"))).toBe(true);
  });

  test("404 when the name does not exist anywhere (assumption, see file header)", async () => {
    const roots = makeRoots();
    const { router } = makeRouter(roots);

    const res = await router(del("/skills/nowhere"));
    expect(res.status).toBe(404);
  });

  test("deleting a user copy that was shadowing a builtin skill leaves the builtin copy intact and now-active", async () => {
    const roots = makeRoots();
    writeSkillFile(roots.builtIn, "dictate", "dictate", "builtin desc", "BUILTIN BODY");
    writeSkillFile(roots.userRoot, "dictate", "dictate", "user desc", "USER BODY");
    const { router } = makeRouter(roots);

    const res = await router(del("/skills/dictate"));
    expect(res.status).toBe(200);

    const getRes = await router(get("/skills/dictate"));
    const body = (await getRes.json()) as { body: string; root: string };
    expect(body.body).toBe("BUILTIN BODY");
    expect(body.root).toBe(roots.builtIn);
  });
});
