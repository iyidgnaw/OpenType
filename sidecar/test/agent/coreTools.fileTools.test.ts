/**
 * Tests for the five first-party file tools (§2/§2.1 of
 * docs/superpowers/specs/2026-08-28-first-party-tools-skills-and-agents-design.md):
 * `opentype__write_file`, `opentype__edit_file`, `opentype__move_file`,
 * `opentype__trash`, `opentype__glob`. All five are expected to land in
 * `sidecar/src/agent/coreTools.ts` alongside the existing eight/nine tools,
 * following the exact same conventions pinned by `coreTools.test.ts`:
 *
 * - deps are injectable (`homeDir` stands in for `~`, never the real home),
 * - every *expected* failure resolves as `{ content: "Error: ..." }`, never
 *   a throw (design §2: "预期失败返回 `{ content: "Error: ..." }` 而不抛"),
 * - `~`-prefixed paths expand against the injected `homeDir`,
 * - only an unknown tool name throws, matching `mergeToolSets`' routing
 *   contract.
 *
 * Until `coreTools.ts` grows these five handlers, every `callTool(...)` call
 * below rejects with "Unknown core tool: opentype__...", which is the
 * expected RED failure mode for every behavioral test in this file.
 */
import { afterAll, describe, expect, test, spyOn } from "bun:test";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { createCoreTools } from "../../src/agent/coreTools";
// Namespace import (not a named one) for GLOB_DEFAULT_LIMIT below: until that
// constant exists, a named `import { GLOB_DEFAULT_LIMIT }` would fail at
// module-load time with a SyntaxError, which aborts this ENTIRE test file --
// hiding every other genuinely-red test in it behind one load-time crash
// instead of one ordinary (and correctly red) assertion failure.
import * as coreToolsModule from "../../src/agent/coreTools";
import type { ToolSet } from "../../src/agent/toolSets";

const tempDirs: string[] = [];

afterAll(() => {
  for (const dir of tempDirs) {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

/** realpathSync so macOS /var -> /private/var symlinks can't break path assertions. */
function makeTempHome(): string {
  const dir = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), "opentype-file-tools-")));
  tempDirs.push(dir);
  return dir;
}

/** A fetch that must never be reached: none of these five tools do network I/O. */
function blockedFetch(): typeof fetch {
  return (async () => {
    throw new Error("network access attempted in a test that must not use the network");
  }) as unknown as typeof fetch;
}

function toolNames(set: ToolSet): string[] {
  return set.openAiTools.map((t) => (t as { function: { name: string } }).function.name);
}

function toolByName(set: ToolSet, name: string): { type: string; function: { name: string; description: string; parameters: { type: string; required?: string[] } } } {
  const found = set.openAiTools.find(
    (t) => (t as { function: { name: string } }).function.name === name
  );
  if (!found) {
    throw new Error(`tool ${name} not found in openAiTools`);
  }
  return found as never;
}

describe("createCoreTools file tools: inventory", () => {
  test("registers all five file tools as well-formed OpenAI function descriptors", () => {
    const tools = createCoreTools({ homeDir: makeTempHome(), fetchFn: blockedFetch() });

    const names = toolNames(tools);
    for (const name of [
      "opentype__write_file",
      "opentype__edit_file",
      "opentype__move_file",
      "opentype__trash",
      "opentype__glob",
    ]) {
      expect(names).toContain(name);
    }

    const writeFile = toolByName(tools, "opentype__write_file");
    expect(writeFile.type).toBe("function");
    expect(typeof writeFile.function.description).toBe("string");
    expect(writeFile.function.description.length).toBeGreaterThan(0);
    expect(writeFile.function.parameters.type).toBe("object");
    expect(writeFile.function.parameters.required).toEqual(
      expect.arrayContaining(["path", "content"])
    );

    const editFile = toolByName(tools, "opentype__edit_file");
    expect(editFile.function.parameters.required).toEqual(
      expect.arrayContaining(["path", "old_string", "new_string"])
    );

    const moveFile = toolByName(tools, "opentype__move_file");
    expect(moveFile.function.parameters.required).toEqual(
      expect.arrayContaining(["source", "destination"])
    );

    const trash = toolByName(tools, "opentype__trash");
    expect(trash.function.parameters.required).toEqual(expect.arrayContaining(["path"]));

    const glob = toolByName(tools, "opentype__glob");
    expect(glob.function.parameters.required).toEqual(expect.arrayContaining(["pattern"]));
  });

  // Pre-existing behavior (passes today, before any of the five tools exist)
  // -- included per the design's own routing contract, not a new claim.
  test("an unknown tool name still throws, matching mergeToolSets' routing contract", async () => {
    const tools = createCoreTools({ homeDir: makeTempHome(), fetchFn: blockedFetch() });

    await expect(tools.callTool("opentype__no_such_tool", {})).rejects.toThrow(/unknown/i);
  });
});

describe("opentype__write_file", () => {
  test("writes a new file, creating missing parent directories, and reports the byte count with no overwrite", async () => {
    const home = makeTempHome();
    const target = path.join(home, "sub", "dir", "notes.txt");
    const tools = createCoreTools({ homeDir: home, fetchFn: blockedFetch() });

    const result = await tools.callTool("opentype__write_file", {
      path: target,
      content: "hello world",
    });

    expect(fs.readFileSync(target, "utf8")).toBe("hello world");
    expect(result.content).not.toMatch(/^Error/);
    // "hello world" is 11 bytes; the report must name the byte count.
    expect(result.content).toMatch(/\b11\b/);
    // No prior file existed at this path -- must not claim an overwrite.
    expect(result.content).not.toMatch(/overwrit/i);
  });

  test("byte count is UTF-8 bytes, not JS string length, for multi-byte content", async () => {
    const home = makeTempHome();
    const target = path.join(home, "chinese.txt");
    const tools = createCoreTools({ homeDir: home, fetchFn: blockedFetch() });

    // "你好" is 2 JS characters but 6 UTF-8 bytes -- catches a naive
    // `.length`-based byte count.
    const result = await tools.callTool("opentype__write_file", {
      path: target,
      content: "你好",
    });

    expect(fs.readFileSync(target, "utf8")).toBe("你好");
    expect(result.content).toMatch(/\b6\b/);
  });

  test("overwriting an existing file reports the overwrite and replaces the content", async () => {
    const home = makeTempHome();
    const target = path.join(home, "existing.txt");
    fs.writeFileSync(target, "old content");
    const tools = createCoreTools({ homeDir: home, fetchFn: blockedFetch() });

    const result = await tools.callTool("opentype__write_file", {
      path: target,
      content: "new content",
    });

    expect(fs.readFileSync(target, "utf8")).toBe("new content");
    expect(result.content).not.toMatch(/^Error/);
    expect(result.content).toMatch(/overwrit/i);
  });

  test("a ~-prefixed path expands against the injected home", async () => {
    const home = makeTempHome();
    const tools = createCoreTools({ homeDir: home, fetchFn: blockedFetch() });

    await tools.callTool("opentype__write_file", { path: "~/tilde-write.txt", content: "tilde-ok" });

    expect(fs.readFileSync(path.join(home, "tilde-write.txt"), "utf8")).toBe("tilde-ok");
  });

  test("a missing path arg resolves with Error content, no throw", async () => {
    const tools = createCoreTools({ homeDir: makeTempHome(), fetchFn: blockedFetch() });

    const result = await tools.callTool("opentype__write_file", { content: "x" });

    expect(result.content).toMatch(/^Error/);
  });

  test("an empty path arg resolves with Error content", async () => {
    const tools = createCoreTools({ homeDir: makeTempHome(), fetchFn: blockedFetch() });

    const result = await tools.callTool("opentype__write_file", { path: "", content: "x" });

    expect(result.content).toMatch(/^Error/);
  });

  test("a non-string content arg resolves with Error content, no throw", async () => {
    const home = makeTempHome();
    const tools = createCoreTools({ homeDir: home, fetchFn: blockedFetch() });

    const result = await tools.callTool("opentype__write_file", {
      path: path.join(home, "should-not-exist.txt"),
      content: 12345,
    });

    expect(result.content).toMatch(/^Error/);
    expect(fs.existsSync(path.join(home, "should-not-exist.txt"))).toBe(false);
  });
});

describe("opentype__edit_file", () => {
  test("replaces old_string with new_string when it appears exactly once", async () => {
    const home = makeTempHome();
    const target = path.join(home, "doc.txt");
    fs.writeFileSync(target, "Hello World\nGoodbye World\n");
    const tools = createCoreTools({ homeDir: home, fetchFn: blockedFetch() });

    const result = await tools.callTool("opentype__edit_file", {
      path: target,
      old_string: "Hello World",
      new_string: "Hi World",
    });

    expect(fs.readFileSync(target, "utf8")).toBe("Hi World\nGoodbye World\n");
    expect(result.content).not.toMatch(/^Error/);
  });

  test("old_string not found resolves with Error content, file left unchanged", async () => {
    const home = makeTempHome();
    const target = path.join(home, "doc.txt");
    fs.writeFileSync(target, "original content, unchanged\n");
    const tools = createCoreTools({ homeDir: home, fetchFn: blockedFetch() });

    const result = await tools.callTool("opentype__edit_file", {
      path: target,
      old_string: "definitely not present anywhere",
      new_string: "replacement",
    });

    expect(result.content).toMatch(/^Error/);
    expect(fs.readFileSync(target, "utf8")).toBe("original content, unchanged\n");
  });

  test("old_string found more than once without replace_all resolves with Error stating the match count", async () => {
    const home = makeTempHome();
    const target = path.join(home, "dup.txt");
    fs.writeFileSync(target, "dup dup dup\n");
    const tools = createCoreTools({ homeDir: home, fetchFn: blockedFetch() });

    const result = await tools.callTool("opentype__edit_file", {
      path: target,
      old_string: "dup",
      new_string: "sub",
    });

    expect(result.content).toMatch(/^Error/);
    // Three occurrences of "dup" -- the message must report the count (3).
    expect(result.content).toMatch(/\b3\b/);
    expect(fs.readFileSync(target, "utf8")).toBe("dup dup dup\n");
  });

  test("replace_all: true replaces every occurrence", async () => {
    const home = makeTempHome();
    const target = path.join(home, "dup.txt");
    fs.writeFileSync(target, "dup dup dup\n");
    const tools = createCoreTools({ homeDir: home, fetchFn: blockedFetch() });

    const result = await tools.callTool("opentype__edit_file", {
      path: target,
      old_string: "dup",
      new_string: "sub",
      replace_all: true,
    });

    expect(result.content).not.toMatch(/^Error/);
    expect(fs.readFileSync(target, "utf8")).toBe("sub sub sub\n");
  });

  test("a nonexistent file resolves with Error content", async () => {
    const home = makeTempHome();
    const tools = createCoreTools({ homeDir: home, fetchFn: blockedFetch() });

    const result = await tools.callTool("opentype__edit_file", {
      path: path.join(home, "does-not-exist.txt"),
      old_string: "a",
      new_string: "b",
    });

    expect(result.content).toMatch(/^Error/);
  });

  test("a missing old_string arg resolves with Error content, no throw", async () => {
    const home = makeTempHome();
    const target = path.join(home, "doc.txt");
    fs.writeFileSync(target, "content\n");
    const tools = createCoreTools({ homeDir: home, fetchFn: blockedFetch() });

    const result = await tools.callTool("opentype__edit_file", {
      path: target,
      new_string: "b",
    });

    expect(result.content).toMatch(/^Error/);
  });
});

describe("opentype__move_file", () => {
  test("moves/renames a file, creating the destination's missing parent directories", async () => {
    const home = makeTempHome();
    const source = path.join(home, "src.txt");
    const destination = path.join(home, "newdir", "dest.txt");
    fs.writeFileSync(source, "move-me");
    const tools = createCoreTools({ homeDir: home, fetchFn: blockedFetch() });

    const result = await tools.callTool("opentype__move_file", { source, destination });

    expect(fs.existsSync(source)).toBe(false);
    expect(fs.readFileSync(destination, "utf8")).toBe("move-me");
    expect(result.content).not.toMatch(/^Error/);
  });

  // The one hard rule this batch keeps (design §2 "move_file 不覆盖"): a
  // destination that already exists as a file must never be silently
  // clobbered, and the source must survive the failed attempt.
  test("destination already exists as a file: Error, no overwrite, source still present afterwards", async () => {
    const home = makeTempHome();
    const source = path.join(home, "src.txt");
    const destination = path.join(home, "dest.txt");
    fs.writeFileSync(source, "SOURCE-CONTENT");
    fs.writeFileSync(destination, "PRE-EXISTING-DEST-CONTENT");
    const tools = createCoreTools({ homeDir: home, fetchFn: blockedFetch() });

    const result = await tools.callTool("opentype__move_file", { source, destination });

    expect(result.content).toMatch(/^Error/);
    // The source must still be there -- no silent overwrite is the one hard
    // rule in this batch (design §2).
    expect(fs.existsSync(source)).toBe(true);
    expect(fs.readFileSync(source, "utf8")).toBe("SOURCE-CONTENT");
    // The pre-existing destination content must be untouched too.
    expect(fs.readFileSync(destination, "utf8")).toBe("PRE-EXISTING-DEST-CONTENT");
  });

  test("destination is an existing directory: the source moves INTO it, keeping its basename", async () => {
    const home = makeTempHome();
    const source = path.join(home, "report.txt");
    const archiveDir = path.join(home, "archive");
    fs.writeFileSync(source, "report-content");
    fs.mkdirSync(archiveDir);
    const tools = createCoreTools({ homeDir: home, fetchFn: blockedFetch() });

    const result = await tools.callTool("opentype__move_file", {
      source,
      destination: archiveDir,
    });

    expect(result.content).not.toMatch(/^Error/);
    expect(fs.existsSync(source)).toBe(false);
    expect(fs.readFileSync(path.join(archiveDir, "report.txt"), "utf8")).toBe("report-content");
  });

  test("a missing source resolves with Error content", async () => {
    const home = makeTempHome();
    const tools = createCoreTools({ homeDir: home, fetchFn: blockedFetch() });

    const result = await tools.callTool("opentype__move_file", {
      source: path.join(home, "does-not-exist.txt"),
      destination: path.join(home, "dest.txt"),
    });

    expect(result.content).toMatch(/^Error/);
    expect(fs.existsSync(path.join(home, "dest.txt"))).toBe(false);
  });
});

describe("opentype__trash", () => {
  test("moves a file into <home>/.Trash rather than deleting it, preserving content, creating .Trash if absent", async () => {
    const home = makeTempHome();
    const target = path.join(home, "todelete.txt");
    fs.writeFileSync(target, "trash-me");
    // .Trash does not exist yet in this fresh temp home.
    expect(fs.existsSync(path.join(home, ".Trash"))).toBe(false);
    const tools = createCoreTools({ homeDir: home, fetchFn: blockedFetch() });

    const result = await tools.callTool("opentype__trash", { path: target });

    expect(result.content).not.toMatch(/^Error/);
    // Not a real delete: the original path is gone, but the bytes survive
    // under .Trash (design §2: "不做真删除").
    expect(fs.existsSync(target)).toBe(false);
    expect(fs.readFileSync(path.join(home, ".Trash", "todelete.txt"), "utf8")).toBe("trash-me");
  });

  test("works for directories too", async () => {
    const home = makeTempHome();
    const dir = path.join(home, "folder-to-trash");
    fs.mkdirSync(dir);
    fs.writeFileSync(path.join(dir, "inner.txt"), "inner-content");
    const tools = createCoreTools({ homeDir: home, fetchFn: blockedFetch() });

    await tools.callTool("opentype__trash", { path: dir });

    expect(fs.existsSync(dir)).toBe(false);
    expect(fs.readFileSync(path.join(home, ".Trash", "folder-to-trash", "inner.txt"), "utf8")).toBe(
      "inner-content"
    );
  });

  test("a name collision in .Trash gets a suffixed name and does not clobber the file already there", async () => {
    const home = makeTempHome();
    // Simulate a prior deletion already sitting in .Trash under the same name.
    fs.mkdirSync(path.join(home, ".Trash"), { recursive: true });
    fs.writeFileSync(path.join(home, ".Trash", "notes.txt"), "OLD-IN-TRASH");
    const target = path.join(home, "notes.txt");
    fs.writeFileSync(target, "NEW-TO-TRASH");
    const tools = createCoreTools({ homeDir: home, fetchFn: blockedFetch() });

    const result = await tools.callTool("opentype__trash", { path: target });

    expect(result.content).not.toMatch(/^Error/);
    // The pre-existing trashed file must survive untouched...
    expect(fs.readFileSync(path.join(home, ".Trash", "notes.txt"), "utf8")).toBe("OLD-IN-TRASH");
    // ...and the newly trashed one gets a suffixed name (design §2's own
    // example: "notes.txt" -> "notes 2.txt").
    expect(fs.readFileSync(path.join(home, ".Trash", "notes 2.txt"), "utf8")).toBe("NEW-TO-TRASH");
    expect(fs.existsSync(target)).toBe(false);
  });

  test("a missing path resolves with Error content", async () => {
    const home = makeTempHome();
    const tools = createCoreTools({ homeDir: home, fetchFn: blockedFetch() });

    const result = await tools.callTool("opentype__trash", {
      path: path.join(home, "does-not-exist.txt"),
    });

    expect(result.content).toMatch(/^Error/);
  });

  // Design §2's own example only shows one collision ("notes.txt" ->
  // "notes 2.txt"). A second collision must not stop there -- an
  // implementation that always appends " 2" regardless of what's already in
  // .Trash would clobber this "notes 2.txt", which is exactly the kind of
  // data loss `trash` exists to prevent. This pins the sequential dedup
  // logic the single-collision test above cannot distinguish from a
  // hardcoded " 2".
  test("a second collision in .Trash advances the suffix to ' 3' rather than clobbering ' 2'", async () => {
    const home = makeTempHome();
    fs.mkdirSync(path.join(home, ".Trash"), { recursive: true });
    fs.writeFileSync(path.join(home, ".Trash", "notes.txt"), "OLDEST-IN-TRASH");
    fs.writeFileSync(path.join(home, ".Trash", "notes 2.txt"), "SECOND-IN-TRASH");
    const target = path.join(home, "notes.txt");
    fs.writeFileSync(target, "THIRD-TO-TRASH");
    const tools = createCoreTools({ homeDir: home, fetchFn: blockedFetch() });

    const result = await tools.callTool("opentype__trash", { path: target });

    expect(result.content).not.toMatch(/^Error/);
    // Both pre-existing trashed files must survive untouched...
    expect(fs.readFileSync(path.join(home, ".Trash", "notes.txt"), "utf8")).toBe("OLDEST-IN-TRASH");
    expect(fs.readFileSync(path.join(home, ".Trash", "notes 2.txt"), "utf8")).toBe(
      "SECOND-IN-TRASH"
    );
    // ...and the newly trashed one advances to " 3", not stuck re-trying " 2".
    expect(fs.readFileSync(path.join(home, ".Trash", "notes 3.txt"), "utf8")).toBe(
      "THIRD-TO-TRASH"
    );
    expect(fs.existsSync(target)).toBe(false);
  });
});

/**
 * `moveEntry` (coreTools.ts, shared by `move_file` and `trash`) falls back
 * from `fs.renameSync` to a copy-then-remove when the source and
 * destination straddle two filesystems (`EXDEV` -- e.g. moving something
 * onto/off of an external drive, or a real `~/.Trash` on a different volume
 * than the file being trashed). Real cross-device mounts aren't available in
 * a CI temp dir, so these tests fake the `EXDEV` condition by spying on
 * `fs.renameSync` and making IT throw that error -- everything downstream
 * (the actual `fs.cpSync`/`fs.rmSync` fallback) runs for real against the
 * temp home, so the assertions below are exercising the real fallback code
 * path, not a mocked one.
 */
describe("EXDEV (cross-device) fallback in move_file/trash", () => {
  test("move_file: falls back to copy+remove, preserving content, when rename reports EXDEV", async () => {
    const home = makeTempHome();
    const source = path.join(home, "src.txt");
    const destination = path.join(home, "dest.txt");
    fs.writeFileSync(source, "EXDEV-CONTENT");
    const tools = createCoreTools({ homeDir: home, fetchFn: blockedFetch() });

    const renameSpy = spyOn(fs, "renameSync").mockImplementation(() => {
      throw Object.assign(new Error("cross-device link"), { code: "EXDEV" });
    });
    try {
      const result = await tools.callTool("opentype__move_file", { source, destination });

      expect(result.content).not.toMatch(/^Error/);
      // The fallback must have actually run (rename never succeeds in this test).
      expect(renameSpy).toHaveBeenCalled();
      // Content survives the copy...
      expect(fs.readFileSync(destination, "utf8")).toBe("EXDEV-CONTENT");
      // ...and the source is gone only because the copy succeeded first.
      expect(fs.existsSync(source)).toBe(false);
    } finally {
      renameSpy.mockRestore();
    }
  });

  test("move_file: EXDEV fallback copies a directory recursively", async () => {
    const home = makeTempHome();
    const source = path.join(home, "srcdir");
    const destination = path.join(home, "destdir");
    fs.mkdirSync(path.join(source, "nested"), { recursive: true });
    fs.writeFileSync(path.join(source, "top.txt"), "TOP");
    fs.writeFileSync(path.join(source, "nested", "inner.txt"), "INNER");
    const tools = createCoreTools({ homeDir: home, fetchFn: blockedFetch() });

    const renameSpy = spyOn(fs, "renameSync").mockImplementation(() => {
      throw Object.assign(new Error("cross-device link"), { code: "EXDEV" });
    });
    try {
      const result = await tools.callTool("opentype__move_file", { source, destination });

      expect(result.content).not.toMatch(/^Error/);
      expect(fs.readFileSync(path.join(destination, "top.txt"), "utf8")).toBe("TOP");
      expect(fs.readFileSync(path.join(destination, "nested", "inner.txt"), "utf8")).toBe("INNER");
      expect(fs.existsSync(source)).toBe(false);
    } finally {
      renameSpy.mockRestore();
    }
  });

  test("move_file: if the fallback copy itself fails, the source is left untouched (no half-move)", async () => {
    const home = makeTempHome();
    const source = path.join(home, "src.txt");
    const destination = path.join(home, "dest.txt");
    fs.writeFileSync(source, "MUST-SURVIVE");
    const tools = createCoreTools({ homeDir: home, fetchFn: blockedFetch() });

    const renameSpy = spyOn(fs, "renameSync").mockImplementation(() => {
      throw Object.assign(new Error("cross-device link"), { code: "EXDEV" });
    });
    const cpSpy = spyOn(fs, "cpSync").mockImplementation(() => {
      throw new Error("disk full (simulated)");
    });
    const rmSpy = spyOn(fs, "rmSync");
    try {
      const result = await tools.callTool("opentype__move_file", { source, destination });

      // The tool call itself never throws (errorContent wraps it)...
      expect(result.content).toMatch(/^Error/);
      // ...but critically, remove must never have been reached: copy failing
      // must not be followed by deleting the only surviving copy of the data.
      expect(rmSpy).not.toHaveBeenCalled();
      expect(fs.existsSync(source)).toBe(true);
      expect(fs.readFileSync(source, "utf8")).toBe("MUST-SURVIVE");
    } finally {
      renameSpy.mockRestore();
      cpSpy.mockRestore();
      rmSpy.mockRestore();
    }
  });

  test("trash: EXDEV fallback also applies to trashing (moveEntry is shared)", async () => {
    const home = makeTempHome();
    const target = path.join(home, "todelete.txt");
    fs.writeFileSync(target, "TRASH-EXDEV-CONTENT");
    const tools = createCoreTools({ homeDir: home, fetchFn: blockedFetch() });

    const renameSpy = spyOn(fs, "renameSync").mockImplementation(() => {
      throw Object.assign(new Error("cross-device link"), { code: "EXDEV" });
    });
    try {
      const result = await tools.callTool("opentype__trash", { path: target });

      expect(result.content).not.toMatch(/^Error/);
      expect(fs.existsSync(target)).toBe(false);
      expect(fs.readFileSync(path.join(home, ".Trash", "todelete.txt"), "utf8")).toBe(
        "TRASH-EXDEV-CONTENT"
      );
    } finally {
      renameSpy.mockRestore();
    }
  });
});

describe("opentype__glob", () => {
  /** Builds a tree containing a decoy inside each skipped directory kind, plus a visible positive control. */
  function makeGlobHome(): string {
    const home = makeTempHome();
    fs.mkdirSync(path.join(home, "a"), { recursive: true });
    fs.mkdirSync(path.join(home, "b", "c"), { recursive: true });
    fs.mkdirSync(path.join(home, "visible"), { recursive: true });
    fs.mkdirSync(path.join(home, ".git"), { recursive: true });
    fs.mkdirSync(path.join(home, "node_modules"), { recursive: true });
    fs.mkdirSync(path.join(home, "Library"), { recursive: true });
    fs.mkdirSync(path.join(home, ".hidden"), { recursive: true });

    fs.writeFileSync(path.join(home, "a", "report.pdf"), "x");
    fs.writeFileSync(path.join(home, "b", "c", "notes.pdf"), "x");
    fs.writeFileSync(path.join(home, "other.txt"), "x");
    fs.writeFileSync(path.join(home, "visible", "decoy.pdf"), "visible-copy");
    fs.writeFileSync(path.join(home, ".git", "decoy.pdf"), "should-not-appear");
    fs.writeFileSync(path.join(home, "node_modules", "decoy.pdf"), "should-not-appear");
    fs.writeFileSync(path.join(home, "Library", "decoy.pdf"), "should-not-appear");
    fs.writeFileSync(path.join(home, ".hidden", "decoy.pdf"), "should-not-appear");
    return home;
  }

  test("finds files by name pattern recursively, defaulting the root to homeDir", async () => {
    const home = makeGlobHome();
    const tools = createCoreTools({ homeDir: home, fetchFn: blockedFetch() });

    const result = await tools.callTool("opentype__glob", { pattern: "*.pdf" });

    expect(result.content).toContain(path.join(home, "a", "report.pdf"));
    expect(result.content).toContain(path.join(home, "b", "c", "notes.pdf"));
    expect(result.content).not.toContain("other.txt");
  });

  test("skips .git, node_modules, Library, and other dot-directories", async () => {
    const home = makeGlobHome();
    const tools = createCoreTools({ homeDir: home, fetchFn: blockedFetch() });

    const result = await tools.callTool("opentype__glob", { pattern: "decoy.pdf" });

    // Exactly the one, non-skipped copy should be found.
    expect(result.content).toContain(path.join(home, "visible", "decoy.pdf"));
    expect(result.content).not.toContain(path.join(home, ".git", "decoy.pdf"));
    expect(result.content).not.toContain(path.join(home, "node_modules", "decoy.pdf"));
    expect(result.content).not.toContain(path.join(home, "Library", "decoy.pdf"));
    expect(result.content).not.toContain(path.join(home, ".hidden", "decoy.pdf"));
  });

  test("an explicit path root searches only there", async () => {
    const home = makeGlobHome();
    const tools = createCoreTools({ homeDir: home, fetchFn: blockedFetch() });

    const result = await tools.callTool("opentype__glob", {
      pattern: "*.pdf",
      path: path.join(home, "a"),
    });

    expect(result.content).toContain(path.join(home, "a", "report.pdf"));
    expect(result.content).not.toContain(path.join(home, "b", "c", "notes.pdf"));
  });

  test("honours an explicit limit, capping the number of results returned", async () => {
    const home = makeTempHome();
    const dir = path.join(home, "many");
    fs.mkdirSync(dir);
    for (let i = 0; i < 5; i++) {
      fs.writeFileSync(path.join(dir, `match-${i}.pdf`), "x");
    }
    const tools = createCoreTools({ homeDir: home, fetchFn: blockedFetch() });

    const result = await tools.callTool("opentype__glob", { pattern: "*.pdf", path: dir, limit: 2 });

    const matchCount = (result.content.match(/match-\d\.pdf/g) ?? []).length;
    expect(matchCount).toBeLessThanOrEqual(2);
  });

  test("with no limit given, a moderate number of matches all come back (default cap is not overly aggressive)", async () => {
    const home = makeTempHome();
    const dir = path.join(home, "many");
    fs.mkdirSync(dir);
    for (let i = 0; i < 5; i++) {
      fs.writeFileSync(path.join(dir, `match-${i}.pdf`), "x");
    }
    const tools = createCoreTools({ homeDir: home, fetchFn: blockedFetch() });

    const result = await tools.callTool("opentype__glob", { pattern: "*.pdf", path: dir });

    const matchCount = (result.content.match(/match-\d\.pdf/g) ?? []).length;
    expect(matchCount).toBe(5);
  });

  test("no match resolves with a readable 'no match' content, not an Error", async () => {
    const home = makeGlobHome();
    const tools = createCoreTools({ homeDir: home, fetchFn: blockedFetch() });

    const result = await tools.callTool("opentype__glob", { pattern: "nonexistent-xyzzy-*.pdf" });

    expect(result.content).not.toMatch(/^Error/);
    expect(result.content).toMatch(/no match/i);
  });

  // Design §2: "默认上限 200 条". Per stage-1 report adjudication: the
  // number must live as an exported named constant, not only inside the
  // implementation, so a future change to it can't silently drift out of
  // sync with the design doc (or with this pin). `GLOB_DEFAULT_LIMIT` is
  // this reviewer's assumption about where/what the implementation exports
  // it as -- coreTools.ts, since that's where the other four file tools and
  // every existing tool constant (e.g. `BASH_TOOL_NAME`) already live. If
  // stage 3 exports it under a different name or from a different module,
  // this import needs updating to match, but the *number* (200) is not
  // negotiable.
  test("the default result cap is a named constant pinned to 200", () => {
    expect(coreToolsModule.GLOB_DEFAULT_LIMIT).toBe(200);
  });

  // Every other tool in this file source-clamps its result through
  // `clampAtSource` before it ever reaches the loop's own 20k
  // `clampToolResult` -- 200 absolute home-directory paths, one per line,
  // can comfortably exceed that on their own. This pins glob to the same
  // convention rather than letting it be the one tool that can hand back an
  // unbounded string.
  test("a large result set is source-clamped rather than returned unbounded", async () => {
    const home = makeTempHome();
    const dir = path.join(home, "many");
    fs.mkdirSync(dir);
    // Long directory-name components keep each matched path itself long, so
    // even GLOB_DEFAULT_LIMIT (200) short filenames add up to a multi-tens-
    // of-KB result comfortably past coreTools.ts's 25k clamp.
    const longSegment = "x".repeat(200);
    fs.mkdirSync(path.join(dir, longSegment), { recursive: true });
    for (let i = 0; i < coreToolsModule.GLOB_DEFAULT_LIMIT; i++) {
      fs.writeFileSync(path.join(dir, longSegment, `match-${i}.pdf`), "x");
    }
    const tools = createCoreTools({ homeDir: home, fetchFn: blockedFetch() });

    const result = await tools.callTool("opentype__glob", { pattern: "*.pdf", path: dir });

    expect(result.content.length).toBeLessThanOrEqual(25_000 + 20); // clamp + "...[truncated]"
    expect(result.content).toContain("...[truncated]");
  });

  // §2's own convention for this file: "signal 一路透传". A directory walk
  // rooted at `~` can run long even after skipping the noisy trees, so glob
  // must actually stop rather than run the cancelled call to completion.
  test("an already-aborted signal short-circuits the walk instead of returning matches", async () => {
    const home = makeGlobHome();
    const tools = createCoreTools({ homeDir: home, fetchFn: blockedFetch() });
    const controller = new AbortController();
    controller.abort();

    const result = await tools.callTool(
      "opentype__glob",
      { pattern: "*.pdf" },
      controller.signal
    );

    expect(result.content).toMatch(/cancelled/i);
  });
});
