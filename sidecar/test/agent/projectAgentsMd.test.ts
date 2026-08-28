import { describe, expect, test } from "bun:test";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
// A named import of a not-yet-existing export throws at module load and
// silently kills the WHOLE file under bun; `import * as` instead lets a
// missing export fail as an ordinary red assertion when the module itself
// does exist. Right now `src/agent/projectAgentsMd.ts` doesn't exist AT ALL
// yet (stage 1, pre-implementation), so this import will fail module
// resolution entirely and every test below reports red for that reason --
// exactly the right kind of red for a not-yet-built module.
import * as projectAgentsMd from "../../src/agent/projectAgentsMd";

/**
 * Nearest-file resolution for the real agents.md standard (https://agents.md/,
 * design §10, docs/superpowers/specs/2026-08-28-first-party-tools-skills-and-agents-design.md).
 *
 * Three hard rules from the standard, per §10: the file lives at a project
 * root (monorepos may nest one per package); the CLOSEST one to the work
 * wins, with NO merging up the tree; free-form markdown, no schema.
 *
 * `findProjectAgentsMd(startDir, homeDir)` is this batch's own name for the
 * walk-up resolver -- the design doc does not dictate a function name. It
 * walks from `startDir` upward, returning the first `AGENTS.md` found
 * (content + resolved absolute path), stopping at `homeDir` INCLUSIVE or the
 * filesystem root, whichever comes first (§10.2's "绝不读 /AGENTS.md 或
 * /Users/AGENTS.md -- 那不是任何人的项目").
 *
 * Every root is an injected temp dir; `homeDir` is always an explicit
 * parameter, never the real `os.homedir()`.
 */

function mkTempDir(): string {
  return fs.mkdtempSync(path.join(os.tmpdir(), "opentype-projectagentsmd-"));
}

function writeFile(dir: string, name: string, content: string): string {
  fs.mkdirSync(dir, { recursive: true });
  const file = path.join(dir, name);
  fs.writeFileSync(file, content);
  return file;
}

describe("findProjectAgentsMd: nearest-file resolution (design §10.1/§10.2)", () => {
  test("finds AGENTS.md in the start directory itself", () => {
    const homeDir = mkTempDir();
    const project = path.join(homeDir, "project");
    const expectedPath = writeFile(project, "AGENTS.md", "PROJECT CONVENTIONS");

    const result = projectAgentsMd.findProjectAgentsMd(project, homeDir);

    expect(result).toBeDefined();
    expect(result?.content).toContain("PROJECT CONVENTIONS");
    expect(result?.path).toBe(expectedPath);
  });

  test("walks UP to find one in an ancestor when the start directory has none", () => {
    const homeDir = mkTempDir();
    const project = path.join(homeDir, "project");
    const expectedPath = writeFile(project, "AGENTS.md", "ROOT-LEVEL CONVENTIONS");
    const startDir = path.join(project, "src", "components");
    fs.mkdirSync(startDir, { recursive: true });

    const result = projectAgentsMd.findProjectAgentsMd(startDir, homeDir);

    expect(result?.content).toContain("ROOT-LEVEL CONVENTIONS");
    expect(result?.path).toBe(expectedPath);
  });

  test("closest wins and does NOT merge: a nested package's AGENTS.md fully shadows the repo root's (design §10.2)", () => {
    // A merging implementation (e.g. "join every AGENTS.md from startDir up
    // to the root") must fail this test: the root's content is asserted
    // ABSENT, not just "the nested content is also present somewhere".
    const homeDir = mkTempDir();
    const repoRoot = path.join(homeDir, "monorepo");
    writeFile(repoRoot, "AGENTS.md", "ROOT CONVENTIONS -- MUST NOT APPEAR");
    const nestedPackage = path.join(repoRoot, "packages", "widgets");
    const nestedPath = writeFile(nestedPackage, "AGENTS.md", "NESTED PACKAGE CONVENTIONS");
    const startDir = path.join(nestedPackage, "src");
    fs.mkdirSync(startDir, { recursive: true });

    const result = projectAgentsMd.findProjectAgentsMd(startDir, homeDir);

    expect(result?.content).toContain("NESTED PACKAGE CONVENTIONS");
    expect(result?.path).toBe(nestedPath);
    // Explicit absence check -- this is the assertion a merging
    // implementation would fail.
    expect(result?.content).not.toContain("ROOT CONVENTIONS");
  });

  test("stops at the injected homeDir INCLUSIVE: an AGENTS.md at homeDir IS found", () => {
    // Everything lives inside one self-contained outer temp dir so no real
    // system path (e.g. the shared /tmp root) is ever written to.
    const outer = mkTempDir();
    const homeDir = path.join(outer, "home");
    fs.mkdirSync(homeDir, { recursive: true });
    // A decoy ABOVE homeDir, in the same self-contained outer dir -- must
    // never be read (see the next test, which asserts this decoy is never
    // returned when homeDir itself has no AGENTS.md).
    writeFile(outer, "AGENTS.md", "DECOY ABOVE HOME -- MUST NEVER APPEAR");
    const homeAgentsPath = writeFile(homeDir, "AGENTS.md", "HOME-LEVEL CONVENTIONS");
    const startDir = path.join(homeDir, "some", "project", "dir");
    fs.mkdirSync(startDir, { recursive: true });

    const result = projectAgentsMd.findProjectAgentsMd(startDir, homeDir);

    expect(result?.content).toContain("HOME-LEVEL CONVENTIONS");
    expect(result?.path).toBe(homeAgentsPath);
    expect(result?.content).not.toContain("DECOY ABOVE HOME");
  });

  test("an AGENTS.md ABOVE homeDir is never read when homeDir itself has none (the rule that keeps us from reading /AGENTS.md)", () => {
    const outer = mkTempDir();
    const homeDir = path.join(outer, "home");
    fs.mkdirSync(homeDir, { recursive: true });
    // Decoy one level above homeDir; homeDir itself carries NO AGENTS.md.
    writeFile(outer, "AGENTS.md", "DECOY ABOVE HOME -- MUST NEVER APPEAR");
    const startDir = path.join(homeDir, "some", "project", "dir");
    fs.mkdirSync(startDir, { recursive: true });

    const result = projectAgentsMd.findProjectAgentsMd(startDir, homeDir);

    // The walk must stop AT homeDir and go no further, even though a real
    // file exists one level up -- that file belongs to nobody's project.
    expect(result).toBeUndefined();
  });

  // REVISED (owner correction, 2026-08-28, following stage-4 review priority
  // item #2): originally this test's own comment described the walk as
  // "falling through to the filesystem-root boundary" when startDir and
  // homeDir share no ancestry -- and flagged, as an open ASSUMPTION, that
  // nothing between startDir and the real filesystem root happened to have
  // an AGENTS.md in the test environment. That assumption was covering for
  // a real defect: §10.2's original text ("home dir inclusive OR filesystem
  // root, whichever comes first") licensed exactly that walk-to-root
  // fallback, which means reading whatever AGENTS.md sits in ANY shared
  // ancestor above an unrelated startDir -- including a world-writable
  // directory like `/tmp` that any local process can plant a file in, for
  // an agent with no sandbox and no default approval prompt (§2.1). The
  // rule is now: a startDir outside homeDir is out of scope, full stop --
  // no walk happens at all, so there is no "assume nothing exists up
  // there" caveat left to make. See the dedicated test below, which proves
  // this with planted decoys rather than an absence-of-evidence assumption.
  test("a start directory outside/unrelated to homeDir returns undefined immediately, without throwing or hanging", () => {
    const startTree = mkTempDir();
    const startDir = path.join(startTree, "unrelated", "deeply", "nested", "dir");
    fs.mkdirSync(startDir, { recursive: true });
    const unrelatedHome = mkTempDir();

    let result: unknown;
    expect(() => {
      result = projectAgentsMd.findProjectAgentsMd(startDir, unrelatedHome);
    }).not.toThrow();
    expect(result).toBeUndefined();
  });

  // The proof for the correction above: decoys planted at EVERY ancestor
  // level between startDir and the filesystem root (modelling a
  // world-writable location like `/tmp` that an attacker or any other local
  // process controls) must never be picked up when startDir shares no
  // ancestry with homeDir at all. Under the pre-correction behaviour (walk
  // up to the filesystem root as a fallback), this test would have found
  // "PLANTED ONE LEVEL UP" or "PLANTED AT STARTTREE ROOT" instead of
  // returning `undefined`.
  test("a startDir entirely outside homeDir never reads a planted AGENTS.md at any ancestor level (owner correction, 2026-08-28)", () => {
    const startTree = mkTempDir();
    const startDir = path.join(startTree, "somewhere", "deep");
    fs.mkdirSync(startDir, { recursive: true });
    writeFile(startTree, "AGENTS.md", "PLANTED AT STARTTREE ROOT -- MUST NEVER APPEAR");
    writeFile(path.join(startTree, "somewhere"), "AGENTS.md", "PLANTED ONE LEVEL UP -- MUST NEVER APPEAR");
    const homeDir = mkTempDir(); // a completely separate tree, no shared ancestry with startTree

    const result = projectAgentsMd.findProjectAgentsMd(startDir, homeDir);

    expect(result).toBeUndefined();
  });

  // Companion to the outside-home test above: a startDir that LOOKS like it
  // might be outside home (it's reached through a symlink whose literal
  // spelling lives elsewhere) but whose real location genuinely IS inside
  // home must resolve normally -- the containment check must not
  // over-correct into spuriously rejecting a legitimate in-home path.
  //
  // Provenance note: the returned `path` reflects the CALLER's own literal
  // spelling (`.../project-link/AGENTS.md`, through the symlink), not the
  // symlink's real target (`.../project/AGENTS.md`) -- `findProjectAgentsMd`
  // canonicalises paths only for the boundary DECISION, never for what it
  // reports back (see its own doc comment). `fs.readFileSync` follows the
  // symlink transparently at the OS level, so the CONTENT read is still the
  // real target file's.
  test("a startDir reached via a symlink that resolves to somewhere INSIDE home is correctly treated as inside, not spuriously rejected", () => {
    const homeDir = mkTempDir();
    const project = path.join(homeDir, "project");
    writeFile(project, "AGENTS.md", "PROJECT CONVENTIONS");
    const startDirSymlink = path.join(homeDir, "project-link");
    fs.symlinkSync(project, startDirSymlink, "dir");

    const result = projectAgentsMd.findProjectAgentsMd(startDirSymlink, homeDir);

    expect(result?.content).toContain("PROJECT CONVENTIONS");
    expect(result?.path).toBe(path.join(startDirSymlink, "AGENTS.md"));
  });

  test("a missing AGENTS.md file that turns out to be unreadable (a directory of that name, not a file) is skipped, not thrown", () => {
    const homeDir = mkTempDir();
    const project = path.join(homeDir, "project");
    fs.mkdirSync(project, { recursive: true });
    // A directory named AGENTS.md, not a file -- reading it as a file
    // throws (EISDIR). The resolver must treat this the same as "no
    // AGENTS.md here" rather than propagating the error.
    fs.mkdirSync(path.join(project, "AGENTS.md"));

    expect(() => projectAgentsMd.findProjectAgentsMd(project, homeDir)).not.toThrow();
    expect(projectAgentsMd.findProjectAgentsMd(project, homeDir)).toBeUndefined();
  });

  test("a start directory that does not exist on disk at all returns undefined, never throws", () => {
    const homeDir = mkTempDir();
    const startDir = path.join(homeDir, "does", "not", "exist", "anywhere");

    expect(() => projectAgentsMd.findProjectAgentsMd(startDir, homeDir)).not.toThrow();
    expect(projectAgentsMd.findProjectAgentsMd(startDir, homeDir)).toBeUndefined();
  });

  // Stage-4 review, priority item #2: the home-boundary check in
  // `findProjectAgentsMd` compares `dir` against `resolvedHome`. `path.resolve`
  // normalizes `..` segments and trailing slashes, so those two cases are
  // ALREADY handled correctly on their own -- these two tests pin that as a
  // fact rather than leaving it unverified. The third case, a symlinked path
  // into the home tree, is the one `path.resolve` genuinely cannot fix (it
  // never touches symlinks) -- see the dedicated `describe` block below.
  test("a workingDirectory containing a `..` segment that resolves inside home is still bounded at homeDir", () => {
    const homeDir = mkTempDir();
    const project = path.join(homeDir, "project");
    writeFile(project, "AGENTS.md", "PROJECT CONVENTIONS");
    // Walks OUT of "sibling" and back INTO "project" -- resolves to the same
    // directory as `project` itself once normalized.
    const startDir = path.join(homeDir, "sibling", "..", "project");
    fs.mkdirSync(path.join(homeDir, "sibling"), { recursive: true });

    const result = projectAgentsMd.findProjectAgentsMd(startDir, homeDir);

    expect(result?.content).toContain("PROJECT CONVENTIONS");
  });

  test("a trailing slash on homeDir does not defeat the boundary check", () => {
    const outer = mkTempDir();
    const homeDir = path.join(outer, "home");
    fs.mkdirSync(homeDir, { recursive: true });
    writeFile(outer, "AGENTS.md", "DECOY ABOVE HOME -- MUST NEVER APPEAR");
    const homeAgentsPath = writeFile(homeDir, "AGENTS.md", "HOME-LEVEL CONVENTIONS");
    const startDir = path.join(homeDir, "project");
    fs.mkdirSync(startDir, { recursive: true });

    // homeDir passed with a trailing slash, unlike every other test above.
    const result = projectAgentsMd.findProjectAgentsMd(startDir, `${homeDir}${path.sep}`);

    expect(result?.content).toContain("HOME-LEVEL CONVENTIONS");
    expect(result?.path).toBe(homeAgentsPath);
    expect(result?.content).not.toContain("DECOY ABOVE HOME");
  });

  // Stage-4 review, priority item #2, the one case `path.resolve` genuinely
  // cannot fix: a symlinked path into the home tree. This is not
  // hypothetical on macOS -- `/tmp`, `/var`, and `/etc` are all symlinks
  // into `/private/...`, which is exactly where `os.tmpdir()` (and so every
  // other test file's `mkdtempSync` root) actually lives. A plain `dir ===
  // resolvedHome` string comparison would never match when the SAME
  // directory is reached through its symlinked spelling on one side and its
  // real spelling on the other, letting the walk sail past the home
  // boundary entirely. The symlink here is built explicitly, inside this
  // test's own temp tree, so the assertion does not depend on whether the
  // host's own tmp root happens to be symlinked.
  test("a symlinked path into the home tree does not defeat the home boundary (§10.2)", () => {
    const outer = fs.realpathSync(mkTempDir());
    const realHome = path.join(outer, "real-home");
    fs.mkdirSync(realHome, { recursive: true });
    const homeDirSymlink = path.join(outer, "home-symlink");
    fs.symlinkSync(realHome, homeDirSymlink, "dir");

    // A decoy one level ABOVE home -- reachable only if the boundary check
    // is defeated and the walk escapes past home.
    writeFile(outer, "AGENTS.md", "DECOY ABOVE HOME -- MUST NEVER APPEAR");
    const homeAgentsPath = writeFile(realHome, "AGENTS.md", "HOME-LEVEL CONVENTIONS");
    // Built directly under the REAL (non-symlinked) spelling of home --
    // modelling a tool call whose cwd/path came back already realpath'd,
    // which never literally passes through `homeDirSymlink`'s own spelling
    // while walking up via `path.dirname`.
    const startDir = path.join(realHome, "project");
    fs.mkdirSync(startDir, { recursive: true });

    // `homeDir` is passed as the SYMLINK spelling -- the mismatch this test
    // exists to catch.
    const result = projectAgentsMd.findProjectAgentsMd(startDir, homeDirSymlink);

    expect(result?.content).toContain("HOME-LEVEL CONVENTIONS");
    expect(result?.path).toBe(homeAgentsPath);
    expect(result?.content).not.toContain("DECOY ABOVE HOME");
  });

  test("returns both the content AND the resolved absolute path (needed for provenance, §10.5)", () => {
    const homeDir = mkTempDir();
    const project = path.join(homeDir, "project");
    const expectedPath = writeFile(project, "AGENTS.md", "SOME CONVENTIONS");

    const result = projectAgentsMd.findProjectAgentsMd(project, homeDir);

    expect(result).toEqual({ content: expect.stringContaining("SOME CONVENTIONS"), path: expectedPath });
    expect(path.isAbsolute(result!.path)).toBe(true);
  });
});

/**
 * §10.5's security-relevant rendering: project AGENTS.md content is
 * attacker-controlled (a cloned malicious repo's own file), and the current
 * agent runtime has no sandbox and yolo-mode approval by default. The
 * rendered block therefore must not be bare content -- it must carry the
 * source path (provenance, traceable in the step log) and an explicit
 * precedence statement.
 *
 * Assertions below use LOOSE matching on purpose (design owner explicitly
 * left phrasing to the implementer) -- only the load-bearing facts are
 * pinned: the source path is present, and *some* precedence statement is
 * present asserting the user's task wins and that project conventions
 * cannot authorise destructive actions or lift safety rules.
 */
describe("renderProjectAgentsMd: the rendered form models actually see (design §10.5)", () => {
  test("includes the resolved content and the source path (provenance)", () => {
    const rendered = projectAgentsMd.renderProjectAgentsMd({
      content: "Use tabs, not spaces.",
      path: "/repo/AGENTS.md",
    });

    expect(rendered).toContain("Use tabs, not spaces.");
    expect(rendered).toContain("/repo/AGENTS.md");
  });

  test("includes an explicit precedence statement: the user's task always wins over project conventions", () => {
    const rendered = projectAgentsMd.renderProjectAgentsMd({
      content: "Some project convention.",
      path: "/repo/AGENTS.md",
    });
    const lower = rendered.toLowerCase();

    // Loose matching: don't pin exact wording, just that SOME statement
    // asserts the user's spoken task takes priority over these conventions.
    expect(lower).toContain("task");
    expect(lower).toMatch(/wins|priorit|override|precedence|takes precedence over/);
  });

  test("includes an explicit statement that project conventions cannot authorise destructive actions or lift safety rules", () => {
    const rendered = projectAgentsMd.renderProjectAgentsMd({
      content: "Some project convention.",
      path: "/repo/AGENTS.md",
    });
    const lower = rendered.toLowerCase();

    expect(lower).toContain("destructive");
    expect(lower).toMatch(/safety|safe/);
  });

  test("different source paths produce visibly different provenance in the rendered output", () => {
    const renderedA = projectAgentsMd.renderProjectAgentsMd({ content: "X", path: "/repo/a/AGENTS.md" });
    const renderedB = projectAgentsMd.renderProjectAgentsMd({ content: "X", path: "/repo/b/AGENTS.md" });

    expect(renderedA).toContain("/repo/a/AGENTS.md");
    expect(renderedB).toContain("/repo/b/AGENTS.md");
    expect(renderedA).not.toContain("/repo/b/AGENTS.md");
  });
});
