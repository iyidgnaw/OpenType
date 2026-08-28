import { describe, expect, test } from "bun:test";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { createResourceStore, type ResourceEntry } from "../../src/resources/resourceStore";

/**
 * `listAll()` (§1.1 below) doesn't exist on `ResourceStore` yet, so every
 * call site is written as `(store.listAll() as ResourceEntryWithStatus[])`:
 * the explicit cast keeps every downstream `.filter`/`.map`/`.find`
 * callback parameter properly typed (rather than cascading into an
 * implicit `any`) while still leaving the property-access itself as a
 * genuine, EXPECTED red-state type error (the method really doesn't exist
 * yet) -- exactly the "fails for the right reason" contract this stage's
 * tests are supposed to have.
 */
type ResourceEntryWithStatus = ResourceEntry & { active: boolean; shadowedBy?: string };

/**
 * `resourceStore.ts` is the generic multi-root discovery layer design §7
 * says is shared by the skill store and (eventually) the agent-definition
 * store: an ordered list of root directories, first-root-wins on a name
 * collision, and a short TTL cache so a busy agent loop doesn't re-walk the
 * filesystem on every single iteration (design §5's "no file-watching" call:
 * a short TTL is the chosen substitute for hot reload).
 *
 * An entry is "one immediate subdirectory of a root that contains a marker
 * file" (`entryFileName`) -- this is exactly skillStore's shape (a skill
 * directory containing SKILL.md), and resourceStore is deliberately generic
 * over the marker filename so a future agent-definition store could reuse it
 * with a different one. These tests use "SKILL.md" as that marker since it's
 * the real, immediate consumer, but nothing here is skill-specific.
 *
 * Every root and every clock is injected -- no test may touch the real home
 * directory or the real wall clock (sleeping on a TTL in a test would make
 * the suite slow and flaky for no reason; a fake clock makes it instant and
 * deterministic).
 */

function mkTempDir(): string {
  return fs.mkdtempSync(path.join(os.tmpdir(), "opentype-resourcestore-"));
}

function writeEntry(root: string, dirName: string, frontmatterAndBody: string): void {
  const dir = path.join(root, dirName);
  fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(path.join(dir, "SKILL.md"), frontmatterAndBody);
}

function skillFile(name: string | undefined, description: string | undefined, body: string): string {
  const lines = ["---"];
  if (name !== undefined) {
    lines.push(`name: ${name}`);
  }
  if (description !== undefined) {
    lines.push(`description: ${description}`);
  }
  lines.push("---", body);
  return lines.join("\n");
}

describe("createResourceStore", () => {
  test("discovers entries across an ordered list of root dirs", () => {
    const rootA = mkTempDir();
    const rootB = mkTempDir();
    writeEntry(rootA, "alpha", skillFile("alpha", "desc a", "body a"));
    writeEntry(rootB, "beta", skillFile("beta", "desc b", "body b"));

    const store = createResourceStore({ roots: [rootA, rootB], entryFileName: "SKILL.md" });
    const names = store.list().map((e) => e.name);

    expect(names.sort()).toEqual(["alpha", "beta"]);
  });

  test("first root wins on a name collision and the later one is skipped", () => {
    const rootA = mkTempDir();
    const rootB = mkTempDir();
    // Same resolved name ("dupe") in both roots, different directory names on
    // disk are irrelevant -- what collides is the frontmatter `name`.
    writeEntry(rootA, "dupe-dir", skillFile("dupe", "from A", "BODY FROM A"));
    writeEntry(rootB, "dupe-dir", skillFile("dupe", "from B", "BODY FROM B"));

    const store = createResourceStore({ roots: [rootA, rootB], entryFileName: "SKILL.md" });
    const entries = store.list().filter((e) => e.name === "dupe");

    // Not just "there is one" -- the SURVIVING one's content must be rootA's,
    // proving root order (not e.g. alphabetical or last-write) decides the winner.
    expect(entries).toHaveLength(1);
    expect(entries[0]?.body).toBe("BODY FROM A");
    expect(entries[0]?.root).toBe(rootA);
  });

  test("a missing/unreadable root is skipped silently rather than throwing", () => {
    const missingRoot = path.join(mkTempDir(), "does-not-exist");
    const rootB = mkTempDir();
    writeEntry(rootB, "real", skillFile("real", "d", "b"));

    const store = createResourceStore({ roots: [missingRoot, rootB], entryFileName: "SKILL.md" });

    expect(() => store.list()).not.toThrow();
    expect(store.list().map((e) => e.name)).toEqual(["real"]);
  });

  test("an entry whose frontmatter lacks a name falls back to its directory/file basename", () => {
    const root = mkTempDir();
    writeEntry(root, "my-cool-skill", skillFile(undefined, "does something", "body"));

    const store = createResourceStore({ roots: [root], entryFileName: "SKILL.md" });

    expect(store.list().map((e) => e.name)).toEqual(["my-cool-skill"]);
  });

  test("an entry missing description is still discovered (description defaults to empty)", () => {
    const root = mkTempDir();
    writeEntry(root, "no-desc", skillFile("no-desc", undefined, "body"));

    const store = createResourceStore({ roots: [root], entryFileName: "SKILL.md" });
    const entry = store.list().find((e) => e.name === "no-desc");

    expect(entry).toBeDefined();
    expect(entry?.description).toBe("");
  });

  test("results are stable-sorted", () => {
    const root = mkTempDir();
    writeEntry(root, "zeta-dir", skillFile("zeta", "d", "b"));
    writeEntry(root, "alpha-dir", skillFile("alpha", "d", "b"));
    writeEntry(root, "mid-dir", skillFile("mid", "d", "b"));

    const store = createResourceStore({ roots: [root], entryFileName: "SKILL.md" });

    expect(store.list().map((e) => e.name)).toEqual(["alpha", "mid", "zeta"]);
  });

  test("TTL cache returns the same result within the TTL without re-reading", () => {
    const root = mkTempDir();
    writeEntry(root, "first", skillFile("first", "d", "b"));

    let now = 0;
    const store = createResourceStore({
      roots: [root],
      entryFileName: "SKILL.md",
      ttlMs: 5_000,
      now: () => now,
    });

    expect(store.list().map((e) => e.name)).toEqual(["first"]);

    // A file added after the first list() call, still inside the TTL window --
    // if the store re-read the filesystem, this would appear; it must not.
    writeEntry(root, "second", skillFile("second", "d", "b"));
    now = 1_000;
    expect(store.list().map((e) => e.name)).toEqual(["first"]);
  });

  test("picks up a newly added file after the TTL expires", () => {
    const root = mkTempDir();
    writeEntry(root, "first", skillFile("first", "d", "b"));

    let now = 0;
    const store = createResourceStore({
      roots: [root],
      entryFileName: "SKILL.md",
      ttlMs: 5_000,
      now: () => now,
    });

    expect(store.list().map((e) => e.name)).toEqual(["first"]);

    writeEntry(root, "second", skillFile("second", "d", "b"));
    now = 5_001; // strictly past the TTL window
    expect(store.list().map((e) => e.name).sort()).toEqual(["first", "second"]);
  });
});

/**
 * Added for the first-party tools/skills/agents design's §8 decision
 * (docs/superpowers/specs/2026-08-28-first-party-tools-skills-and-agents-design.md):
 * agent definitions are a flat "<name>.md" file directly under a root --
 * NOT a directory containing a marker file like a skill. `createResourceStore`
 * grows a `layout: "directory" | "file"` option so the agent-definition store
 * (`sidecar/src/agent/agentDefinitions.ts`) can reuse this same
 * first-root-wins / missing-root / TTL-cache machinery rather than
 * duplicating it (§8: "两种布局的差异仅在'一个条目对应哪个文件'这一步，其余
 * 完全共用").
 *
 * These tests only cover what's NEW about "file" layout, plus one regression
 * guard proving the default stays "directory" so skillStore (which never
 * passes `layout` at all) is unaffected by this addition.
 */
describe("createResourceStore: layout: \"file\" (design §8, agent definitions)", () => {
  function writeFlatFile(root: string, filename: string, content: string): void {
    fs.mkdirSync(root, { recursive: true });
    fs.writeFileSync(path.join(root, filename), content);
  }

  test("enumerates <name>.md files directly under a root -- no subdirectory involved", () => {
    const root = mkTempDir();
    writeFlatFile(root, "alpha.md", skillFile("alpha", "desc a", "body a"));
    writeFlatFile(root, "beta.md", skillFile("beta", "desc b", "body b"));

    const store = createResourceStore({ roots: [root], layout: "file", entryExtension: ".md" });
    const names = store.list().map((e) => e.name);

    expect(names.sort()).toEqual(["alpha", "beta"]);
  });

  test("entry name defaults to the basename without extension when frontmatter has no name", () => {
    const root = mkTempDir();
    // Frontmatter deliberately omits `name` -- only `description` is set.
    writeFlatFile(root, "researcher.md", skillFile(undefined, "does research", "body"));

    const store = createResourceStore({ roots: [root], layout: "file", entryExtension: ".md" });

    expect(store.list().map((e) => e.name)).toEqual(["researcher"]);
  });

  test("frontmatter `name` wins over the file's basename when both are present", () => {
    const root = mkTempDir();
    // Filename says "foo", frontmatter says "custom-name" -- the frontmatter
    // value must win, exactly like the directory-layout tests above already
    // establish for a skill's directory name vs. its frontmatter `name`.
    writeFlatFile(root, "foo.md", skillFile("custom-name", "d", "body"));

    const store = createResourceStore({ roots: [root], layout: "file", entryExtension: ".md" });

    expect(store.list().map((e) => e.name)).toEqual(["custom-name"]);
  });

  test("non-.md files under the root are ignored", () => {
    const root = mkTempDir();
    writeFlatFile(root, "notes.txt", "this is not an agent definition");
    writeFlatFile(root, "real.md", skillFile("real", "d", "body"));

    const store = createResourceStore({ roots: [root], layout: "file", entryExtension: ".md" });

    expect(store.list().map((e) => e.name)).toEqual(["real"]);
  });

  /**
   * A README.md placed directly under a "file"-layout root (e.g. the shipped
   * `sidecar/agents/README.md` placeholder, or a user documenting their own
   * `~/.opentype/agents/`) must NOT register as an entry. A README inside a
   * directory of definitions is a documentation convention, not a
   * definition -- `resourceStore.ts`'s `readFileEntry` currently has no
   * concept of this and treats it exactly like any other `.md` file, which
   * silently turns the README's own prose into a fake agent's system prompt.
   *
   * This is a NAME check, not a "does it have frontmatter" check: a
   * no-frontmatter `.md` file must otherwise keep loading with its whole
   * content as the body (see `agentDefinitions.test.ts`'s "a file with no
   * frontmatter at all still loads" test, and `frontmatter.test.ts`'s "no
   * frontmatter at all" test) -- that is deliberate Claude Code
   * compatibility and this exclusion must not touch it. Only the name
   * "README" (case-insensitively) is excluded.
   */
  test("a file named README.md (any case) is not treated as an entry, matched case-insensitively", () => {
    const root = mkTempDir();
    writeFlatFile(root, "README.md", "This directory holds agent definitions. See the design doc for the format.");
    writeFlatFile(root, "real-agent.md", skillFile("real-agent", "d", "body"));

    const store = createResourceStore({ roots: [root], layout: "file", entryExtension: ".md" });

    // Only the real agent registers -- the README does not appear under any
    // name at all (not "README", not the empty string, nothing).
    expect(store.list().map((e) => e.name)).toEqual(["real-agent"]);

    // Lowercase and mixed-case variants are excluded too, each checked in
    // its own root so one casing can't accidentally shadow another under
    // first-root-wins if the exclusion were only partially implemented.
    const rootLower = mkTempDir();
    writeFlatFile(rootLower, "readme.md", "lowercase variant");
    expect(createResourceStore({ roots: [rootLower], layout: "file", entryExtension: ".md" }).list()).toEqual([]);

    const rootMixed = mkTempDir();
    writeFlatFile(rootMixed, "Readme.md", "mixed-case variant");
    expect(createResourceStore({ roots: [rootMixed], layout: "file", entryExtension: ".md" }).list()).toEqual([]);
  });

  test("a same-named README with frontmatter that sets an explicit `name` is still excluded by its filename", () => {
    // The exclusion is about the FILE's own name, not the resolved entry
    // name -- a README.md that happens to carry `name: something-else` in
    // its frontmatter must still be excluded, since the whole point is that
    // dropping a file called README.md into the directory should never
    // silently become an entry, regardless of what's inside it.
    const root = mkTempDir();
    writeFlatFile(root, "README.md", skillFile("something-else", "d", "body"));

    const store = createResourceStore({ roots: [root], layout: "file", entryExtension: ".md" });

    expect(store.list()).toEqual([]);
  });

  test("layout \"directory\" is unaffected: a skill directory containing a README.md alongside SKILL.md keeps working", () => {
    // Directory layout only ever looks at the marker file (SKILL.md) inside
    // each entry directory -- a README.md sitting alongside it is just an
    // ordinary file in that directory and directory-layout discovery never
    // enumerates loose files inside an entry dir at all, so this must be a
    // no-op change for skills.
    const root = mkTempDir();
    writeEntry(root, "my-skill", skillFile("my-skill", "does things", "body"));
    fs.writeFileSync(path.join(root, "my-skill", "README.md"), "human-facing notes about this skill");

    const store = createResourceStore({ roots: [root], entryFileName: "SKILL.md" });

    expect(store.list().map((e) => e.name)).toEqual(["my-skill"]);
  });

  test("first-root-wins still applies across roots for file layout", () => {
    const rootA = mkTempDir();
    const rootB = mkTempDir();
    writeFlatFile(rootA, "dupe.md", skillFile("dupe", "from A", "BODY FROM A"));
    writeFlatFile(rootB, "dupe.md", skillFile("dupe", "from B", "BODY FROM B"));

    const store = createResourceStore({ roots: [rootA, rootB], layout: "file", entryExtension: ".md" });
    const entries = store.list().filter((e) => e.name === "dupe");

    expect(entries).toHaveLength(1);
    expect(entries[0]?.body).toBe("BODY FROM A");
    expect(entries[0]?.root).toBe(rootA);
  });

  test("a missing root is still skipped silently for file layout", () => {
    const missingRoot = path.join(mkTempDir(), "does-not-exist");
    const rootB = mkTempDir();
    writeFlatFile(rootB, "real.md", skillFile("real", "d", "b"));

    const store = createResourceStore({ roots: [missingRoot, rootB], layout: "file", entryExtension: ".md" });

    expect(() => store.list()).not.toThrow();
    expect(store.list().map((e) => e.name)).toEqual(["real"]);
  });

  test("default layout (option omitted) stays \"directory\" -- skillStore's behavior is unchanged by this addition", () => {
    // Same shape as the very first test in this file (directory + marker
    // file), deliberately NOT passing `layout` at all -- this is the
    // regression guard the design explicitly calls for: skillStore never
    // passes `layout`, so its behavior must be identical after this option
    // is added as it was before.
    const root = mkTempDir();
    writeEntry(root, "a-skill-dir", skillFile("a-skill", "d", "b"));
    // A flat file directly under the root (no directory) must NOT be picked
    // up under the default directory layout -- proves the default really is
    // "directory", not some layout-agnostic fallback that would accidentally
    // pass this test either way.
    writeFlatFile(root, "not-picked-up.md", skillFile("flat-file", "d", "b"));

    const store = createResourceStore({ roots: [root], entryFileName: "SKILL.md" });

    expect(store.list().map((e) => e.name)).toEqual(["a-skill"]);
  });
});

/**
 * Stage-1 TDD (red) for the skill/agent-UI + step-log-persistence batch's
 * Pipeline A §1.1 (docs/superpowers/specs/2026-08-28-skill-agent-ui-and-step-log-persistence.md):
 *
 * `listAll()` -- a new method on `ResourceStore`, sitting beside `list()` --
 * returns EVERY discovered entry across every root (shadowed copies
 * included), each tagged `active: boolean` (true for the first-root-wins
 * survivor) and `shadowedBy` (the WINNING entry's `root` identifier -- per
 * this codebase's existing convention, `root` is simply the entry's resolved
 * root path, exactly the value `ResourceEntry.root` already carries; nothing
 * here invents a new symbolic id scheme). An active entry's `shadowedBy` is
 * absent/falsy. `list()` itself is UNCHANGED -- still active-only -- and
 * `listAll()` shares list()'s own scan + TTL cache rather than doing a
 * second independent read of disk.
 *
 * `invalidate()` -- also new -- clears that shared cache so a write endpoint
 * (skills/agent-definitions POST/PUT/DELETE, Pipeline A §1.2/§1.3) can call
 * it right after a successful write and have the very next `list()`/
 * `listAll()` call see the change immediately, without waiting out the TTL.
 *
 * RED-STATE NOTE: `createResourceStore`'s returned object has no `listAll`
 * or `invalidate` property yet, so every test below fails with "is not a
 * function" -- the right kind of failure for an unbuilt contract, not a
 * parse/import error.
 */
describe("createResourceStore: listAll() (design doc 2026-08-28-skill-agent-ui-and-step-log-persistence.md §1.1)", () => {
  test("no collision: every entry is active:true with no shadowedBy", () => {
    const rootA = mkTempDir();
    const rootB = mkTempDir();
    writeEntry(rootA, "alpha", skillFile("alpha", "d", "b"));
    writeEntry(rootB, "beta", skillFile("beta", "d", "b"));

    const store = createResourceStore({ roots: [rootA, rootB], entryFileName: "SKILL.md" });
    const all = store.listAll() as ResourceEntryWithStatus[];

    expect(all).toHaveLength(2);
    for (const entry of all) {
      expect(entry.active).toBe(true);
      expect(entry.shadowedBy).toBeFalsy();
    }
  });

  test("a name collision: the first-root-wins survivor is active:true, the later one is active:false with shadowedBy set to the winner's root", () => {
    const rootA = mkTempDir();
    const rootB = mkTempDir();
    writeEntry(rootA, "dupe-dir", skillFile("dupe", "from A", "BODY FROM A"));
    writeEntry(rootB, "dupe-dir", skillFile("dupe", "from B", "BODY FROM B"));

    const store = createResourceStore({ roots: [rootA, rootB], entryFileName: "SKILL.md" });
    const dupes = (store.listAll() as ResourceEntryWithStatus[]).filter((e) => e.name === "dupe");

    expect(dupes).toHaveLength(2);
    const winner = dupes.find((e) => e.root === rootA);
    const loser = dupes.find((e) => e.root === rootB);
    expect(winner).toBeDefined();
    expect(loser).toBeDefined();
    expect(winner?.active).toBe(true);
    expect(winner?.shadowedBy).toBeFalsy();
    expect(loser?.active).toBe(false);
    expect(loser?.shadowedBy).toBe(rootA);
    // The shadowed copy's own content must still be readable (design §1.2's
    // "8A 里被覆盖的「我的」条目也要能点开看" -- the UI needs the loser's real
    // body, not a stub).
    expect(loser?.body).toBe("BODY FROM B");
  });

  test("three-way collision: only the first root's entry is active, both later ones are shadowed by it", () => {
    const rootA = mkTempDir();
    const rootB = mkTempDir();
    const rootC = mkTempDir();
    writeEntry(rootA, "d", skillFile("dupe", "from A", "A"));
    writeEntry(rootB, "d", skillFile("dupe", "from B", "B"));
    writeEntry(rootC, "d", skillFile("dupe", "from C", "C"));

    const store = createResourceStore({ roots: [rootA, rootB, rootC], entryFileName: "SKILL.md" });
    const dupes = (store.listAll() as ResourceEntryWithStatus[]).filter((e) => e.name === "dupe");

    expect(dupes).toHaveLength(3);
    expect(dupes.filter((e) => e.active)).toHaveLength(1);
    for (const entry of dupes.filter((e) => !e.active)) {
      expect(entry.shadowedBy).toBe(rootA);
    }
  });

  test("list() stays active-only and unaffected by listAll() existing", () => {
    const rootA = mkTempDir();
    const rootB = mkTempDir();
    writeEntry(rootA, "dupe-dir", skillFile("dupe", "from A", "BODY FROM A"));
    writeEntry(rootB, "dupe-dir", skillFile("dupe", "from B", "BODY FROM B"));
    writeEntry(rootB, "solo", skillFile("solo", "d", "b"));

    const store = createResourceStore({ roots: [rootA, rootB], entryFileName: "SKILL.md" });

    // Exactly today's list() contract: one "dupe" (the winner), plus "solo".
    // No `active`/`shadowedBy` noise leaking into list()'s own result shape
    // is not asserted here (harmless extra fields would be fine) -- what
    // matters is the SET of entries returned is unchanged.
    expect(store.list().map((e) => e.name).sort()).toEqual(["dupe", "solo"]);
    const dupe = store.list().find((e) => e.name === "dupe");
    expect(dupe?.body).toBe("BODY FROM A");
  });

  test("listAll() shares list()'s own scan + TTL cache -- a file added within the TTL window is invisible to a subsequent listAll() call", () => {
    const root = mkTempDir();
    writeEntry(root, "first", skillFile("first", "d", "b"));

    let now = 0;
    const store = createResourceStore({
      roots: [root],
      entryFileName: "SKILL.md",
      ttlMs: 5_000,
      now: () => now,
    });

    // Populate the cache via list().
    expect(store.list().map((e) => e.name)).toEqual(["first"]);

    // A file added after that first read, still inside the TTL window --
    // listAll() must NOT see it, proving it reads the same cached scan
    // list() just populated rather than re-walking the filesystem itself.
    writeEntry(root, "second", skillFile("second", "d", "b"));
    now = 1_000;
    expect((store.listAll() as ResourceEntryWithStatus[]).map((e) => e.name)).toEqual(["first"]);

    // Once the TTL elapses, a fresh scan (triggered by either method) picks
    // it up.
    now = 5_001;
    expect((store.listAll() as ResourceEntryWithStatus[]).map((e) => e.name).sort()).toEqual(["first", "second"]);
  });
});

describe("createResourceStore: invalidate() (design doc 2026-08-28-skill-agent-ui-and-step-log-persistence.md §1.1)", () => {
  test("clears the cache so the very next list() call rescans, even still inside the TTL window", () => {
    const root = mkTempDir();
    writeEntry(root, "first", skillFile("first", "d", "b"));

    let now = 0;
    const store = createResourceStore({
      roots: [root],
      entryFileName: "SKILL.md",
      ttlMs: 5_000,
      now: () => now,
    });

    expect(store.list().map((e) => e.name)).toEqual(["first"]);

    // Still well inside the 5s TTL window (now unchanged) -- without
    // invalidate(), the cached result would hide this newly written entry
    // (proven by the "TTL cache returns the same result within the TTL"
    // test earlier in this file).
    writeEntry(root, "second", skillFile("second", "d", "b"));
    store.invalidate();
    expect(store.list().map((e) => e.name).sort()).toEqual(["first", "second"]);
  });

  test("also clears listAll()'s shared cache, not just list()'s", () => {
    const root = mkTempDir();
    writeEntry(root, "first", skillFile("first", "d", "b"));

    let now = 0;
    const store = createResourceStore({
      roots: [root],
      entryFileName: "SKILL.md",
      ttlMs: 5_000,
      now: () => now,
    });

    expect((store.listAll() as ResourceEntryWithStatus[]).map((e) => e.name)).toEqual(["first"]);

    writeEntry(root, "second", skillFile("second", "d", "b"));
    store.invalidate();
    expect((store.listAll() as ResourceEntryWithStatus[]).map((e) => e.name).sort()).toEqual(["first", "second"]);
  });

  test("invalidate() on an otherwise-untouched store does not throw and a subsequent list() still works", () => {
    const root = mkTempDir();
    writeEntry(root, "only", skillFile("only", "d", "b"));
    const store = createResourceStore({ roots: [root], entryFileName: "SKILL.md" });

    expect(() => store.invalidate()).not.toThrow();
    expect(store.list().map((e) => e.name)).toEqual(["only"]);
  });
});
