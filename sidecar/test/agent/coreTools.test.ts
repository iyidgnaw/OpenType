/**
 * Tests for the core tool set (B2 core tools v2 design,
 * docs/superpowers/specs/2026-08-13-b2-agent-core-tools-v2-design.md §3).
 *
 * `createCoreTools(deps)` returns a `ToolSet` whose deps are injectable so
 * these tests never touch the real home directory or the real network:
 * - `homeDir` is a `fs.mkdtempSync` temp dir standing in for `~`,
 * - `fetchFn` is a canned fake (a fetch that throws is injected for tests
 *   that must not hit the network at all),
 * - `execTimeoutMs` overrides the default ~60s exec timeout,
 * - `openRunner` (B2 open-file + ask-web design,
 *   docs/superpowers/specs/2026-08-13-b2-open-file-and-ask-web-design.md §1)
 *   is an optional `(path: string) => Promise<{ exitCode: number }>` that
 *   stands in for launching `/usr/bin/open <path>`, so open_file tests
 *   assert the expanded path handed to the runner and never actually open
 *   an app window. The default (no injection) runs the real /usr/bin/open.
 * Process-execution tests use the real `/bin/bash` and `python3` with
 * trivial commands (both exist on this macOS dev machine).
 *
 * Contract notes (choices the implementation is expected to satisfy):
 * - exec output includes an "exit code" line (asserted as /exit code:?\s*N/i),
 * - list_dir marks directories with a trailing "/" (ls -p convention),
 * - grep-with-no-matches says so via text matching /no match/i,
 * - error paths resolve with content starting "Error" (builtInTools.ts
 *   precedent) rather than rejecting,
 * - source-side clamping keeps any single tool result under 30k chars
 *   (SOURCE_CLAMP_CEILING below) with a visible /truncat/i marker,
 *   independent of the loop's own 20k clampToolResult.
 */
import { afterAll, describe, expect, test } from "bun:test";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { createCoreTools } from "../../src/agent/coreTools";
import { mergeToolSets, type ToolSet } from "../../src/agent/toolSets";
import { withApproval, yoloApprovalPolicy } from "../../src/agent/approval";

/**
 * Upper bound the source-side clamp must keep a single tool result under.
 * The design says "clamped at the source (before the loop's existing 20k
 * clampToolResult)"; 30k leaves the implementation headroom for framing
 * (exit code lines, truncation markers) while still proving a ~200k-char
 * raw output was bounded at the tool itself.
 */
const SOURCE_CLAMP_CEILING = 30_000;

const tempDirs: string[] = [];

afterAll(() => {
  for (const dir of tempDirs) {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

/** realpathSync so macOS /var -> /private/var symlinks can't break pwd/path assertions. */
function makeTempHome(): string {
  const dir = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), "opentype-core-tools-")));
  tempDirs.push(dir);
  return dir;
}

/** A fetch that must never be reached: exec/file tests do no network I/O. */
function blockedFetch(): typeof fetch {
  return (async () => {
    throw new Error("network access attempted in a test that must not use the network");
  }) as unknown as typeof fetch;
}

/** Canned fetch that records every requested URL and serves a fixed response. */
function fakeFetch(handler: (url: string) => Response | Promise<Response>): {
  fetchFn: typeof fetch;
  calls: string[];
} {
  const calls: string[] = [];
  const fetchFn = (async (input: unknown) => {
    const url =
      typeof input === "string"
        ? input
        : input instanceof URL
          ? input.toString()
          : (input as { url: string }).url;
    calls.push(url);
    return handler(url);
  }) as unknown as typeof fetch;
  return { fetchFn, calls };
}

function toolNames(set: ToolSet): string[] {
  return set.openAiTools.map((t) => (t as { function: { name: string } }).function.name);
}

describe("createCoreTools tool inventory", () => {
  // Contract extension (first-party-tools-skills-and-agents design §2): the
  // inventory grows from nine to exactly fourteen -- the five file tools
  // (`opentype__write_file`, `opentype__edit_file`, `opentype__move_file`,
  // `opentype__trash`, `opentype__glob`) join the set. Same precedent as the
  // eight-to-nine change this comment used to describe: the list itself
  // legitimately changes here; every other assertion is untouched.
  test("exposes exactly the fourteen namespaced core tools, all type 'function'", () => {
    const tools = createCoreTools({ homeDir: makeTempHome(), fetchFn: blockedFetch() });

    for (const tool of tools.openAiTools) {
      expect((tool as { type: string }).type).toBe("function");
    }
    expect(toolNames(tools).sort()).toEqual(
      [
        "opentype__bash",
        "opentype__python",
        "opentype__read_file",
        "opentype__list_dir",
        "opentype__grep",
        "opentype__web_search",
        "opentype__web_fetch",
        "opentype__open_file",
        "opentype__write_file",
        "opentype__edit_file",
        "opentype__move_file",
        "opentype__trash",
        "opentype__glob",
        "opentype__read_history",
      ].sort()
    );
  });
});

describe("opentype__bash", () => {
  test("echo hello returns the output and indicates exit code 0", async () => {
    const tools = createCoreTools({ homeDir: makeTempHome(), fetchFn: blockedFetch() });

    const result = await tools.callTool("opentype__bash", { command: "echo hello" });

    expect(result.content).toContain("hello");
    expect(result.content).toMatch(/exit code:?\s*0/i);
  });

  test("a failing command indicates its nonzero exit code without rejecting", async () => {
    const tools = createCoreTools({ homeDir: makeTempHome(), fetchFn: blockedFetch() });

    const result = await tools.callTool("opentype__bash", { command: "exit 3" });

    expect(result.content).toMatch(/exit code:?\s*3/i);
  });

  test("cwd defaults to the injected home directory", async () => {
    const home = makeTempHome();
    const tools = createCoreTools({ homeDir: home, fetchFn: blockedFetch() });

    const result = await tools.callTool("opentype__bash", { command: "pwd" });

    expect(result.content).toContain(home);
  });

  test("an explicit cwd arg runs the command there instead", async () => {
    const home = makeTempHome();
    const elsewhere = path.join(home, "elsewhere");
    fs.mkdirSync(elsewhere);
    const tools = createCoreTools({ homeDir: home, fetchFn: blockedFetch() });

    const result = await tools.callTool("opentype__bash", { command: "pwd", cwd: elsewhere });

    expect(result.content).toContain(elsewhere);
  });

  test("a ~-prefixed cwd expands against the injected home", async () => {
    const home = makeTempHome();
    fs.mkdirSync(path.join(home, "sub"));
    const tools = createCoreTools({ homeDir: home, fetchFn: blockedFetch() });

    const result = await tools.callTool("opentype__bash", { command: "pwd", cwd: "~/sub" });

    expect(result.content).toContain(path.join(home, "sub"));
  });

  test(
    "a command exceeding the injected execTimeoutMs resolves with a timeout mention instead of hanging",
    async () => {
      const tools = createCoreTools({
        homeDir: makeTempHome(),
        fetchFn: blockedFetch(),
        execTimeoutMs: 200,
      });

      const result = await tools.callTool("opentype__bash", { command: "sleep 5" });

      expect(result.content).toMatch(/timed out|timeout/i);
    },
    4000
  );

  test("huge output is clamped at the source with a visible truncation marker", async () => {
    const tools = createCoreTools({ homeDir: makeTempHome(), fetchFn: blockedFetch() });

    // ~220k chars of raw stdout, an order of magnitude past the loop's 20k clamp.
    const result = await tools.callTool("opentype__bash", {
      command: "yes abcdefghij | head -n 20000",
    });

    expect(result.content.length).toBeLessThanOrEqual(SOURCE_CLAMP_CEILING);
    expect(result.content).toMatch(/truncat/i);
  });
});

describe("opentype__python", () => {
  test("runs the given code and returns its output", async () => {
    const tools = createCoreTools({ homeDir: makeTempHome(), fetchFn: blockedFetch() });

    const result = await tools.callTool("opentype__python", { code: 'print("py-ok")' });

    expect(result.content).toContain("py-ok");
  });

  test("runs via python3 (sys.version_info reports major version 3)", async () => {
    const tools = createCoreTools({ homeDir: makeTempHome(), fetchFn: blockedFetch() });

    const result = await tools.callTool("opentype__python", {
      code: 'import sys; print(f"major={sys.version_info.major}")',
    });

    expect(result.content).toContain("major=3");
  });
});

describe("opentype__read_file", () => {
  test("returns a file's exact content", async () => {
    const home = makeTempHome();
    const text = "line one\nline two with a UNIQUE-READ-SENTINEL\n";
    fs.writeFileSync(path.join(home, "sample.txt"), text);
    const tools = createCoreTools({ homeDir: home, fetchFn: blockedFetch() });

    const result = await tools.callTool("opentype__read_file", {
      path: path.join(home, "sample.txt"),
    });

    expect(result.content).toContain("line one\nline two with a UNIQUE-READ-SENTINEL");
  });

  test("a ~-prefixed path expands against the injected home", async () => {
    const home = makeTempHome();
    fs.writeFileSync(path.join(home, "notes.txt"), "tilde-expanded-content");
    const tools = createCoreTools({ homeDir: home, fetchFn: blockedFetch() });

    const result = await tools.callTool("opentype__read_file", { path: "~/notes.txt" });

    expect(result.content).toContain("tilde-expanded-content");
  });

  test("a nonexistent path resolves with an Error content string, no throw", async () => {
    const home = makeTempHome();
    const tools = createCoreTools({ homeDir: home, fetchFn: blockedFetch() });

    const result = await tools.callTool("opentype__read_file", {
      path: path.join(home, "does-not-exist.txt"),
    });

    expect(result.content).toMatch(/^Error/);
  });
});

describe("opentype__list_dir", () => {
  test("lists a directory's entries and marks subdirectories distinguishably", async () => {
    const home = makeTempHome();
    const target = path.join(home, "stuff");
    fs.mkdirSync(target);
    fs.writeFileSync(path.join(target, "file.txt"), "x");
    fs.mkdirSync(path.join(target, "subdir"));
    const tools = createCoreTools({ homeDir: home, fetchFn: blockedFetch() });

    const result = await tools.callTool("opentype__list_dir", { path: target });

    expect(result.content).toContain("file.txt");
    // Contract: directories carry a trailing "/" marker (ls -p convention)...
    expect(result.content).toContain("subdir/");
    // ...and plain files do not.
    expect(result.content).not.toMatch(/file\.txt\//);
  });

  test("with no path arg it lists the injected home directory", async () => {
    const home = makeTempHome();
    fs.writeFileSync(path.join(home, "home-marker.txt"), "x");
    const tools = createCoreTools({ homeDir: home, fetchFn: blockedFetch() });

    const result = await tools.callTool("opentype__list_dir", {});

    expect(result.content).toContain("home-marker.txt");
  });
});

describe("opentype__grep", () => {
  const NEEDLE = "GREPNEEDLE42";

  function makeGrepHome(): string {
    const home = makeTempHome();
    fs.mkdirSync(path.join(home, "Desktop"));
    fs.mkdirSync(path.join(home, "Downloads"));
    // Needle on line 2 of Desktop/a.txt and line 3 of Downloads/b.txt.
    fs.writeFileSync(path.join(home, "Desktop", "a.txt"), `first line\nhas ${NEEDLE} here\n`);
    fs.writeFileSync(path.join(home, "Downloads", "b.txt"), `one\ntwo\n${NEEDLE} three\n`);
    // A file with no match: must not show up in results.
    fs.writeFileSync(path.join(home, "Desktop", "other.txt"), "nothing to see\n");
    // A match OUTSIDE Desktop/Downloads: the default scope must not find it.
    fs.writeFileSync(path.join(home, "elsewhere.txt"), `${NEEDLE} but out of default scope\n`);
    return home;
  }

  test("with no path arg it searches ~/Desktop and ~/Downloads, reporting filename and line number", async () => {
    const home = makeGrepHome();
    const tools = createCoreTools({ homeDir: home, fetchFn: blockedFetch() });

    const result = await tools.callTool("opentype__grep", { pattern: NEEDLE });

    expect(result.content).toMatch(/a\.txt:2/);
    expect(result.content).toMatch(/b\.txt:3/);
    expect(result.content).not.toContain("other.txt");
    // Default scope is Desktop+Downloads, NOT all of home (design §3).
    expect(result.content).not.toContain("elsewhere.txt");
  });

  test("an explicit path arg (with ~) searches that path instead of the default scope", async () => {
    const home = makeGrepHome();
    fs.mkdirSync(path.join(home, "Projects"));
    fs.writeFileSync(path.join(home, "Projects", "notes.txt"), `${NEEDLE} at top\n`);
    const tools = createCoreTools({ homeDir: home, fetchFn: blockedFetch() });

    const result = await tools.callTool("opentype__grep", {
      pattern: NEEDLE,
      path: "~/Projects",
    });

    expect(result.content).toMatch(/notes\.txt:1/);
    expect(result.content).not.toContain("a.txt");
    expect(result.content).not.toContain("b.txt");
  });

  test("caseInsensitive: true matches differing case", async () => {
    const home = makeGrepHome();
    fs.writeFileSync(path.join(home, "Desktop", "case.txt"), "the zebra sleeps\n");
    const tools = createCoreTools({ homeDir: home, fetchFn: blockedFetch() });

    const result = await tools.callTool("opentype__grep", {
      pattern: "ZEBRA",
      caseInsensitive: true,
    });

    expect(result.content).toContain("case.txt");
  });

  test("a pattern found nowhere resolves with a clear no-matches content, no throw", async () => {
    const home = makeGrepHome();
    const tools = createCoreTools({ homeDir: home, fetchFn: blockedFetch() });

    const result = await tools.callTool("opentype__grep", {
      pattern: "definitely-not-present-xyzzy",
    });

    expect(typeof result.content).toBe("string");
    expect(result.content).toMatch(/no match/i);
  });
});

/**
 * B2 open-file + ask-web design §1: opens a file with the macOS system
 * default app (Preview/Word/QuickTime...) -- a UI side effect the agent may
 * take directly under the YOLO posture. Contract choices these tests pin:
 * - the injected `openRunner` receives the fully `~`-expanded absolute path
 *   (the real default runner would exec `/usr/bin/open <path>`),
 * - existence is verified BEFORE the runner: a missing path resolves as
 *   `Error: ...` content and the runner is never invoked,
 * - success content names the opened path (so the model can report what
 *   happened) and does not start with "Error",
 * - a runner reporting a nonzero exit resolves as `Error: ...` content
 *   carrying the exit code (matching the exec tools' /exit code:?\s*N/i
 *   convention), never a throw.
 */
describe("opentype__open_file", () => {
  function recordingOpenRunner(exitCode = 0): {
    openRunner: (path: string) => Promise<{ exitCode: number }>;
    calls: string[];
  } {
    const calls: string[] = [];
    return {
      openRunner: async (openedPath: string) => {
        calls.push(openedPath);
        return { exitCode };
      },
      calls,
    };
  }

  test("opens an existing file: the runner gets the absolute path once, content reports success", async () => {
    const home = makeTempHome();
    const filePath = path.join(home, "report.pdf");
    fs.writeFileSync(filePath, "%PDF-fake");
    const { openRunner, calls } = recordingOpenRunner(0);
    const tools = createCoreTools({ homeDir: home, fetchFn: blockedFetch(), openRunner });

    const result = await tools.callTool("opentype__open_file", { path: filePath });

    expect(calls).toEqual([filePath]);
    expect(result.content).not.toMatch(/^Error/);
    // Success content names what was opened, so the model can tell the user.
    expect(result.content).toContain(filePath);
  });

  test("a ~-prefixed path expands against the injected home before reaching the runner", async () => {
    const home = makeTempHome();
    fs.writeFileSync(path.join(home, "song.mp3"), "ID3-fake");
    const { openRunner, calls } = recordingOpenRunner(0);
    const tools = createCoreTools({ homeDir: home, fetchFn: blockedFetch(), openRunner });

    const result = await tools.callTool("opentype__open_file", { path: "~/song.mp3" });

    expect(calls).toEqual([path.join(home, "song.mp3")]);
    expect(result.content).not.toMatch(/^Error/);
  });

  test("a nonexistent path resolves with Error content and never invokes the runner", async () => {
    const home = makeTempHome();
    const { openRunner, calls } = recordingOpenRunner(0);
    const tools = createCoreTools({ homeDir: home, fetchFn: blockedFetch(), openRunner });

    const result = await tools.callTool("opentype__open_file", {
      path: path.join(home, "does-not-exist.docx"),
    });

    expect(result.content).toMatch(/^Error/);
    expect(calls).toEqual([]);
  });

  test("a runner reporting a nonzero exit resolves with Error content naming the exit code, no throw", async () => {
    const home = makeTempHome();
    fs.writeFileSync(path.join(home, "broken.bin"), "x");
    const { openRunner, calls } = recordingOpenRunner(1);
    const tools = createCoreTools({ homeDir: home, fetchFn: blockedFetch(), openRunner });

    const result = await tools.callTool("opentype__open_file", { path: "~/broken.bin" });

    expect(calls).toHaveLength(1);
    expect(result.content).toMatch(/^Error/);
    expect(result.content).toMatch(/exit code:?\s*1/i);
  });

  test('a missing "path" arg resolves with Error content, runner untouched', async () => {
    const { openRunner, calls } = recordingOpenRunner(0);
    const tools = createCoreTools({ homeDir: makeTempHome(), fetchFn: blockedFetch(), openRunner });

    const result = await tools.callTool("opentype__open_file", {});

    expect(result.content).toMatch(/^Error/);
    expect(calls).toEqual([]);
  });
});

describe("opentype__web_search", () => {
  const CANNED_DDG_HTML = `<html><body>
<div class="result results_links results_links_deep web-result">
  <h2 class="result__title"><a rel="nofollow" class="result__a" href="https://example.com/first-hit">First Canned Result</a></h2>
  <a class="result__snippet" href="https://example.com/first-hit">Snippet text for the first result.</a>
</div>
<div class="result results_links results_links_deep web-result">
  <h2 class="result__title"><a rel="nofollow" class="result__a" href="https://example.org/second-hit">Second Canned Result</a></h2>
  <a class="result__snippet" href="https://example.org/second-hit">Another snippet.</a>
</div>
</body></html>`;

  test("hits the DuckDuckGo html endpoint with the URL-encoded query and parses title + url", async () => {
    const { fetchFn, calls } = fakeFetch(
      () => new Response(CANNED_DDG_HTML, { status: 200, headers: { "content-type": "text/html" } })
    );
    const tools = createCoreTools({ homeDir: makeTempHome(), fetchFn });

    const result = await tools.callTool("opentype__web_search", { query: "opentype sidecar" });

    expect(calls).toHaveLength(1);
    expect(calls[0]).toMatch(/duckduckgo\.com\/html/);
    // URLSearchParams encodes the space as "+", encodeURIComponent as "%20";
    // either satisfies "URL-encoded query".
    expect(calls[0]).toMatch(/opentype(\+|%20)sidecar/);

    expect(result.content).toContain("First Canned Result");
    expect(result.content).toContain("https://example.com/first-hit");
  });
});

describe("opentype__web_fetch", () => {
  test("fetches the url and strips HTML down to readable text", async () => {
    const page = `<html><head><title>Fetched Page</title><script>var secret = "should-not-appear";</script><style>.x{color:red}</style></head>
<body><h1>Visible Heading</h1><p>Readable paragraph body text.</p></body></html>`;
    const { fetchFn, calls } = fakeFetch(
      () => new Response(page, { status: 200, headers: { "content-type": "text/html" } })
    );
    const tools = createCoreTools({ homeDir: makeTempHome(), fetchFn });

    const result = await tools.callTool("opentype__web_fetch", {
      url: "https://example.com/page",
    });

    expect(calls[0]).toContain("https://example.com/page");
    expect(result.content).toContain("Visible Heading");
    expect(result.content).toContain("Readable paragraph body text.");
    expect(result.content).not.toContain("<h1");
    expect(result.content).not.toContain("<script");
    expect(result.content).not.toContain("should-not-appear");
  });

  test("a huge body is clamped at the source with a truncation marker", async () => {
    const hugePage = `<html><body><p>${"wordy ".repeat(40_000)}</p></body></html>`;
    const { fetchFn } = fakeFetch(
      () => new Response(hugePage, { status: 200, headers: { "content-type": "text/html" } })
    );
    const tools = createCoreTools({ homeDir: makeTempHome(), fetchFn });

    const result = await tools.callTool("opentype__web_fetch", { url: "https://example.com/big" });

    expect(result.content.length).toBeLessThanOrEqual(SOURCE_CLAMP_CEILING);
    expect(result.content).toMatch(/truncat/i);
  });

  test("a non-2xx response resolves with an Error content string", async () => {
    const { fetchFn } = fakeFetch(() => new Response("nope", { status: 404 }));
    const tools = createCoreTools({ homeDir: makeTempHome(), fetchFn });

    const result = await tools.callTool("opentype__web_fetch", {
      url: "https://example.com/missing",
    });

    expect(result.content).toMatch(/^Error/);
  });

  test("a fetch that throws (network failure) resolves with an Error content string, no reject", async () => {
    const tools = createCoreTools({ homeDir: makeTempHome(), fetchFn: blockedFetch() });

    const result = await tools.callTool("opentype__web_fetch", {
      url: "https://unreachable.example.com/",
    });

    expect(result.content).toMatch(/^Error/);
  });
});

describe("core tools integration at the ToolSet level", () => {
  function makeFakeBuiltIns(): ToolSet {
    return {
      openAiTools: [{ type: "function", function: { name: "opentype__remember_fact" } }],
      callTool: async (name) => ({ content: `fake built-in handled ${name}` }),
    };
  }

  test("bash works end to end through mergeToolSets + withApproval(yolo)", async () => {
    const home = makeTempHome();
    const core = createCoreTools({ homeDir: home, fetchFn: blockedFetch() });
    const wrapped = withApproval(mergeToolSets(makeFakeBuiltIns(), core), yoloApprovalPolicy);

    const result = await wrapped.callTool("opentype__bash", { command: "echo integration-ok" });

    expect(result.content).toContain("integration-ok");
  });

  test("an unknown tool still throws 'Unknown tool' through the wrapped merged set", async () => {
    const core = createCoreTools({ homeDir: makeTempHome(), fetchFn: blockedFetch() });
    const wrapped = withApproval(mergeToolSets(makeFakeBuiltIns(), core), yoloApprovalPolicy);

    await expect(wrapped.callTool("opentype__no_such_tool", {})).rejects.toThrow(/unknown tool/i);
  });
});
