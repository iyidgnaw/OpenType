import { describe, expect, test } from "bun:test";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
// See projectAgentsMd.test.ts's header comment for why `import * as` is used
// here: `src/agent/projectContext.ts` does not exist yet at all (stage 1),
// so this whole file's tests are expected to be red on module resolution
// until stage 3 creates it.
import * as projectContext from "../../src/agent/projectContext";

/**
 * The mid-run project-context observer (design §10.1/§10.2):
 * "运行中发现: 一个 projectContext 观察器, 形状与既有的 repeatGuard 对称 --
 * 观察每次工具调用, 从 cwd/path 参数解析出目录, 向上找最近的 AGENTS.md,
 * 每个项目只注入一次(去重)。命中时以一条 user message 追加进对话, 正是
 * repeatGuard 已经在用的机制。"
 *
 * Module/function choice for this batch (not dictated by the design doc):
 * `createProjectContextObserver({ homeDir })` lives in a SIBLING module to
 * `projectAgentsMd.ts` (which owns the pure nearest-file walk-up + render),
 * mirroring how `repeatGuard.ts` is its own file separate from the loop
 * that wires it in. `observe(toolName, args)` takes the tool call's ALREADY
 * -PARSED arguments object (not the raw JSON string `repeatGuard.observe`
 * takes) -- `loop.ts` already has `parsedArgs` in scope right where
 * `repeatGuard.observe` is called, and extracting a `cwd`/`path` STRING
 * field is far more natural against a parsed object than against raw JSON
 * text. This is a genuine ambiguity the design doc leaves open (flagged in
 * the report): "shaped like repeatGuard" only pins the two-argument,
 * string-or-undefined-return shape, not what the second argument itself is.
 *
 * Every root is an injected temp dir; `homeDir` is always an explicit
 * parameter, never the real `os.homedir()`.
 */

function mkTempDir(): string {
  return fs.mkdtempSync(path.join(os.tmpdir(), "opentype-projectcontext-"));
}

function makeProject(homeDir: string, name: string, agentsMdContent: string): string {
  const project = path.join(homeDir, name);
  fs.mkdirSync(project, { recursive: true });
  fs.writeFileSync(path.join(project, "AGENTS.md"), agentsMdContent);
  return project;
}

describe("createProjectContextObserver: mid-run discovery (design §10.1/§10.2)", () => {
  test("a tool call carrying a cwd inside a project resolves that project's AGENTS.md and returns rendered content", () => {
    const homeDir = mkTempDir();
    const project = makeProject(homeDir, "proj", "PROJECT A CONVENTIONS");
    const observer = projectContext.createProjectContextObserver({ homeDir });

    const result = observer.observe("opentype__bash", { cwd: project });

    expect(result).toBeDefined();
    expect(result).toContain("PROJECT A CONVENTIONS");
    // Provenance path must be traceable too, per §10.5, same as the bare
    // render function -- this is the observer's own return value, not a
    // separate render call the caller has to remember to make.
    expect(result).toContain(path.join(project, "AGENTS.md"));
  });

  test("a tool call carrying a path (not cwd) does the same, resolving from the path's containing directory when the path is a file", () => {
    const homeDir = mkTempDir();
    const project = makeProject(homeDir, "proj", "PROJECT B CONVENTIONS");
    const filePath = path.join(project, "src", "index.ts");
    fs.mkdirSync(path.dirname(filePath), { recursive: true });
    fs.writeFileSync(filePath, "// some file contents");
    const observer = projectContext.createProjectContextObserver({ homeDir });

    const result = observer.observe("opentype__read_file", { path: filePath });

    expect(result).toBeDefined();
    expect(result).toContain("PROJECT B CONVENTIONS");
  });

  // Stage-1 flagged this case as untested (design owner review, adjudication
  // #2): `opentype__list_dir` and `opentype__glob` pass a `path` that IS a
  // directory, not a file. An observer that unconditionally takes the
  // parent of `path` would resolve `list_dir({ path: "~/proj" })` starting
  // from `~` -- MISSING `~/proj/AGENTS.md`, which is the single most
  // typical case this feature exists for (a tool call scoped directly at a
  // project's own root). The rule (pinned here): if `path` exists on disk
  // AND is a directory, use it AS-IS; otherwise (a file, or nothing there
  // at all) use its containing directory.
  test("a tool call carrying a path that IS a directory resolves from that directory itself, not its parent", () => {
    const homeDir = mkTempDir();
    const project = makeProject(homeDir, "proj", "PROJECT DIR CONVENTIONS");
    const observer = projectContext.createProjectContextObserver({ homeDir });

    // path names the project directory itself (e.g. opentype__list_dir's
    // own `path` argument) -- not a file inside it.
    const result = observer.observe("opentype__list_dir", { path: project });

    expect(result).toBeDefined();
    expect(result).toContain("PROJECT DIR CONVENTIONS");
  });

  test("a tool call carrying a path that does not exist at all falls back to its containing directory, without throwing", () => {
    const homeDir = mkTempDir();
    const project = makeProject(homeDir, "proj", "PROJECT NONEXISTENT-PATH CONVENTIONS");
    const missingPath = path.join(project, "not-a-real-file.ts");
    const observer = projectContext.createProjectContextObserver({ homeDir });

    let result: string | undefined;
    expect(() => {
      result = observer.observe("opentype__read_file", { path: missingPath });
    }).not.toThrow();
    expect(result).toBeDefined();
    expect(result).toContain("PROJECT NONEXISTENT-PATH CONVENTIONS");
  });

  test("each project is injected at most once: a second call within the SAME project returns undefined", () => {
    // This dedup is what stops the block being re-pushed on every tool
    // call -- without it, a long-running agent working in one project would
    // get the same AGENTS.md block appended after every single tool call.
    const homeDir = mkTempDir();
    const project = makeProject(homeDir, "proj", "PROJECT CONVENTIONS");
    const subDir = path.join(project, "sub", "dir");
    fs.mkdirSync(subDir, { recursive: true });
    const observer = projectContext.createProjectContextObserver({ homeDir });

    const first = observer.observe("opentype__bash", { cwd: project });
    // Different cwd, but resolves to the SAME project/AGENTS.md file --
    // dedup must key on the resolved project, not on exact argument
    // equality.
    const second = observer.observe("opentype__bash", { cwd: subDir });

    expect(first).toBeDefined();
    expect(second).toBeUndefined();
  });

  test("entering a DIFFERENT project later in the same run DOES return that project's content (dedup is per-project, not once-per-run)", () => {
    const homeDir = mkTempDir();
    const projectA = makeProject(homeDir, "projA", "PROJECT A CONVENTIONS");
    const projectB = makeProject(homeDir, "projB", "PROJECT B CONVENTIONS");
    const observer = projectContext.createProjectContextObserver({ homeDir });

    const first = observer.observe("opentype__bash", { cwd: projectA });
    const second = observer.observe("opentype__bash", { cwd: projectB });

    expect(first).toContain("PROJECT A CONVENTIONS");
    expect(second).toBeDefined();
    expect(second).toContain("PROJECT B CONVENTIONS");
  });

  test("a tool call with no cwd/path returns undefined", () => {
    const homeDir = mkTempDir();
    const observer = projectContext.createProjectContextObserver({ homeDir });

    expect(observer.observe("opentype__grep", { pattern: "needle" })).toBeUndefined();
    expect(observer.observe("opentype__grep", {})).toBeUndefined();
    expect(observer.observe("opentype__grep", undefined)).toBeUndefined();
  });

  // Design owner review, adjudication #1: `observe` takes PARSED args
  // because `projectContext` extracts `cwd`/`path` fields, unlike
  // `repeatGuard.observe`, which hashes the raw JSON string. But in
  // `loop.ts`, `parsedArgs` is computed INSIDE the try block around
  // `JSON.parse(toolCall.function.arguments)`, while the observer call
  // sits OUTSIDE that try -- so when a tool call's arguments are malformed
  // JSON, there is no `parsedArgs` in scope at all by the time the observer
  // would be invoked. The observer must tolerate being handed `undefined`,
  // `null`, or a non-object value (a bare string) and return `undefined`
  // rather than throwing: a throw here over one malformed tool-call payload
  // would take down the ENTIRE run, not just this one observation.
  test("observe tolerates undefined/null/non-object args without throwing, returning undefined", () => {
    const homeDir = mkTempDir();
    // A project WITH an AGENTS.md exists, to prove these calls return
    // undefined because the args themselves are unusable, not merely
    // because there was nothing to find.
    makeProject(homeDir, "proj", "PROJECT CONVENTIONS");
    const observer = projectContext.createProjectContextObserver({ homeDir });

    expect(() => observer.observe("opentype__bash", undefined)).not.toThrow();
    expect(observer.observe("opentype__bash", undefined)).toBeUndefined();

    expect(() => observer.observe("opentype__bash", null)).not.toThrow();
    expect(observer.observe("opentype__bash", null)).toBeUndefined();

    expect(() => observer.observe("opentype__bash", "a string, not an object")).not.toThrow();
    expect(observer.observe("opentype__bash", "a string, not an object")).toBeUndefined();

    expect(() => observer.observe("opentype__bash", {})).not.toThrow();
    expect(observer.observe("opentype__bash", {})).toBeUndefined();
  });

  test("a tool call whose cwd resolves to no AGENTS.md anywhere up to homeDir returns undefined", () => {
    const homeDir = mkTempDir();
    const emptyProject = path.join(homeDir, "no-agents-md-anywhere");
    fs.mkdirSync(emptyProject, { recursive: true });
    const observer = projectContext.createProjectContextObserver({ homeDir });

    expect(observer.observe("opentype__bash", { cwd: emptyProject })).toBeUndefined();
  });

  test("one observer instance per run: two observers do not share dedup state (mirrors repeatGuard's per-run rule)", () => {
    // A chain/dedup state leaking between runs would be a real bug -- each
    // agent run must get a fresh observer, exactly as each run gets its own
    // `createRepeatGuard()` call in routes.ts.
    const homeDir = mkTempDir();
    const project = makeProject(homeDir, "proj", "PROJECT CONVENTIONS");
    const first = projectContext.createProjectContextObserver({ homeDir });
    const second = projectContext.createProjectContextObserver({ homeDir });

    first.observe("opentype__bash", { cwd: project });

    // A SEPARATE observer instance seeing the same project for the first
    // time must still return content -- it has never seen this project
    // before, regardless of what `first` has already observed.
    expect(second.observe("opentype__bash", { cwd: project })).toBeDefined();
  });
});
