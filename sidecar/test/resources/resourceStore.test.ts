import { describe, expect, test } from "bun:test";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { createResourceStore } from "../../src/resources/resourceStore";

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
