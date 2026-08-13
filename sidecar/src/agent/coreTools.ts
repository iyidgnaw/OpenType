import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import type { ToolSet } from "./toolSets";

/**
 * Product-owned "hands and feet" for the Agent runtime (B2 core tools v2,
 * docs/superpowers/specs/2026-08-13-b2-agent-core-tools-v2-design.md §3):
 * shell, Python, file read/list/search, internet (search + fetch), and
 * opening a file with the system default app -- the baseline toolset general
 * coding agents converge on. Built-in like
 * `builtInTools.ts` (namespaced `opentype__`, merged via `mergeToolSets`),
 * not MCP -- and gated, like everything else, only by the approval seam in
 * `approval.ts` (YOLO by default; the v1 "no-side-effect tools only" policy
 * is retired).
 *
 * Deps are injectable so tests never depend on the real home directory or
 * the real network: `homeDir` stands in for `~` in every path default and
 * `~`-expansion, `fetchFn` replaces global `fetch` for the two web tools,
 * `execTimeoutMs` overrides the ~60s process timeout, and `openRunner`
 * (open-file + ask-web design,
 * docs/superpowers/specs/2026-08-13-b2-open-file-and-ask-web-design.md §1)
 * stands in for launching `/usr/bin/open <path>` so open_file tests never
 * actually open an app window.
 *
 * Every *expected* failure (bad path, non-2xx response, nonzero exit,
 * timeout) resolves as `{ content: "Error: ..." }` per the `builtInTools.ts`
 * precedent; only an unknown tool name throws, matching `mergeToolSets`'s
 * routing contract.
 */
export interface CoreToolsDeps {
  homeDir?: string;
  fetchFn?: typeof fetch;
  execTimeoutMs?: number;
  /** Launches the system opener for an (already `~`-expanded) absolute path. */
  openRunner?: (path: string) => Promise<{ exitCode: number }>;
}

const BASH_TOOL_NAME = "opentype__bash";
const PYTHON_TOOL_NAME = "opentype__python";
const READ_FILE_TOOL_NAME = "opentype__read_file";
const LIST_DIR_TOOL_NAME = "opentype__list_dir";
const GREP_TOOL_NAME = "opentype__grep";
const WEB_SEARCH_TOOL_NAME = "opentype__web_search";
const WEB_FETCH_TOOL_NAME = "opentype__web_fetch";
const OPEN_FILE_TOOL_NAME = "opentype__open_file";

const DEFAULT_EXEC_TIMEOUT_MS = 60_000;

/**
 * Source-side clamp, applied inside each tool before the result ever reaches
 * the loop's own 20k `clampToolResult` (loop.ts): a runaway `cat` or a huge
 * page must be bounded at the tool itself so a multi-MB string is never
 * built into the progress log/messages. Kept under the tests' 30k ceiling
 * with headroom for framing (exit-code line, truncation marker).
 */
const SOURCE_CLAMP_MAX_CHARS = 25_000;

const MAX_SEARCH_RESULTS = 8;

/** Browser-ish UA: DDG's html endpoint (and many sites) reject bare fetch UAs. */
const USER_AGENT =
  "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36";

function clampAtSource(text: string): string {
  if (text.length <= SOURCE_CLAMP_MAX_CHARS) {
    return text;
  }
  return `${text.slice(0, SOURCE_CLAMP_MAX_CHARS)}\n...[truncated]`;
}

function expandTilde(p: string, homeDir: string): string {
  if (p === "~") {
    return homeDir;
  }
  if (p.startsWith("~/")) {
    return path.join(homeDir, p.slice(2));
  }
  return p;
}

function errorContent(err: unknown): { content: string } {
  const message = err instanceof Error ? err.message : String(err);
  return { content: message.startsWith("Error") ? message : `Error: ${message}` };
}

interface ExecOutcome {
  stdout: string;
  stderr: string;
  exitCode: number;
  timedOut: boolean;
}

/**
 * Spawns `argv`, draining stdout/stderr concurrently from the start (a full
 * 64KB pipe would otherwise deadlock a chatty child -- the same failure mode
 * the Swift-side curl transport hardening closed). On timeout the child is
 * SIGTERM'd, escalating to SIGKILL if it ignores that.
 */
async function runProcess(argv: string[], cwd: string, timeoutMs: number): Promise<ExecOutcome> {
  const proc = Bun.spawn(argv, { cwd, stdin: "ignore", stdout: "pipe", stderr: "pipe" });
  const stdoutPromise = new Response(proc.stdout).text();
  const stderrPromise = new Response(proc.stderr).text();

  let timedOut = false;
  let killTimer: ReturnType<typeof setTimeout> | undefined;
  const timeoutTimer = setTimeout(() => {
    timedOut = true;
    proc.kill();
    killTimer = setTimeout(() => proc.kill(9), 2000);
  }, timeoutMs);

  let exitCode: number;
  try {
    exitCode = await proc.exited;
  } finally {
    clearTimeout(timeoutTimer);
    if (killTimer !== undefined) {
      clearTimeout(killTimer);
    }
  }
  const [stdout, stderr] = await Promise.all([stdoutPromise, stderrPromise]);
  return { stdout, stderr, exitCode, timedOut };
}

function formatExecResult(outcome: ExecOutcome, timeoutMs: number): { content: string } {
  const merged = clampAtSource((outcome.stdout + outcome.stderr).trimEnd());
  if (outcome.timedOut) {
    return {
      content:
        `Error: the command timed out after ${timeoutMs}ms and was killed.` +
        (merged.length > 0 ? `\nPartial output:\n${merged}` : ""),
    };
  }
  return {
    content: merged.length > 0 ? `${merged}\n[exit code: ${outcome.exitCode}]` : `[exit code: ${outcome.exitCode}]`,
  };
}

function decodeEntities(text: string): string {
  return text
    .replace(/&#x([0-9a-fA-F]+);/g, (_, hex: string) => String.fromCodePoint(parseInt(hex, 16)))
    .replace(/&#(\d+);/g, (_, dec: string) => String.fromCodePoint(parseInt(dec, 10)))
    .replace(/&nbsp;/g, " ")
    .replace(/&quot;/g, '"')
    .replace(/&#39;|&apos;/g, "'")
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&amp;/g, "&");
}

/** Strips markup down to readable text: scripts/styles dropped bodily, block ends become newlines. */
function stripHtmlToText(html: string): string {
  const text = html
    .replace(/<script\b[\s\S]*?<\/script\s*>/gi, " ")
    .replace(/<style\b[\s\S]*?<\/style\s*>/gi, " ")
    .replace(/<!--[\s\S]*?-->/g, " ")
    .replace(/<\/(?:p|div|h[1-6]|li|tr|table|section|article|header|footer|blockquote|pre)\s*>/gi, "\n")
    .replace(/<br\s*\/?\s*>/gi, "\n")
    .replace(/<[^>]+>/g, " ");
  return decodeEntities(text)
    .replace(/[ \t]+/g, " ")
    .replace(/ ?\n ?/g, "\n")
    .replace(/\n{3,}/g, "\n\n")
    .trim();
}

/** DDG result hrefs are often redirect links carrying the real URL in `uddg=`. */
function resolveDdgUrl(href: string): string {
  const match = href.match(/[?&]uddg=([^&]+)/);
  if (!match || match[1] === undefined) {
    return href;
  }
  try {
    return decodeURIComponent(match[1]);
  } catch {
    return href;
  }
}

interface SearchResult {
  title: string;
  url: string;
  snippet: string;
}

/**
 * Regex-level extraction of DDG's html-endpoint result markup (`result__a`
 * title anchors, `result__snippet` bodies) -- deliberately no HTML-parser
 * dependency. Attribute order is not assumed; snippets are paired with
 * titles by document order.
 */
function parseDdgResults(html: string): SearchResult[] {
  const results: SearchResult[] = [];
  const anchorRe = /<a\b[^>]*class="[^"]*\bresult__a\b[^"]*"[^>]*>([\s\S]*?)<\/a>/gi;
  const snippetRe = /class="[^"]*\bresult__snippet\b[^"]*"[^>]*>([\s\S]*?)<\/(?:a|div|span|td)>/gi;

  const snippets: string[] = [];
  for (let m = snippetRe.exec(html); m !== null; m = snippetRe.exec(html)) {
    snippets.push(stripHtmlToText(m[1] ?? ""));
  }

  for (let m = anchorRe.exec(html); m !== null && results.length < MAX_SEARCH_RESULTS; m = anchorRe.exec(html)) {
    const hrefMatch = m[0].match(/href="([^"]*)"/);
    if (!hrefMatch || hrefMatch[1] === undefined) {
      continue;
    }
    results.push({
      title: stripHtmlToText(m[1] ?? ""),
      url: resolveDdgUrl(decodeEntities(hrefMatch[1])),
      snippet: snippets[results.length] ?? "",
    });
  }
  return results;
}

export function createCoreTools(deps: CoreToolsDeps): ToolSet {
  const homeDir = deps.homeDir ?? os.homedir();
  const fetchFn = deps.fetchFn ?? fetch;
  const execTimeoutMs = deps.execTimeoutMs ?? DEFAULT_EXEC_TIMEOUT_MS;
  // Default open runner execs the real macOS opener; tests inject a fake so
  // no app window ever appears during a run.
  const openRunner =
    deps.openRunner ??
    (async (targetPath: string): Promise<{ exitCode: number }> => {
      const outcome = await runProcess(["/usr/bin/open", targetPath], homeDir, execTimeoutMs);
      return { exitCode: outcome.exitCode };
    });

  function resolveCwd(rawCwd: unknown): string {
    if (typeof rawCwd === "string" && rawCwd.trim().length > 0) {
      return expandTilde(rawCwd, homeDir);
    }
    return homeDir;
  }

  async function handleBash(rawArgs: unknown): Promise<{ content: string }> {
    const args = (rawArgs ?? {}) as { command?: unknown; cwd?: unknown };
    if (typeof args.command !== "string" || args.command.trim().length === 0) {
      return { content: 'Error: bash requires a non-empty "command" string.' };
    }
    const outcome = await runProcess(
      ["/bin/bash", "-lc", args.command],
      resolveCwd(args.cwd),
      execTimeoutMs
    );
    return formatExecResult(outcome, execTimeoutMs);
  }

  async function handlePython(rawArgs: unknown): Promise<{ content: string }> {
    const args = (rawArgs ?? {}) as { code?: unknown; cwd?: unknown };
    if (typeof args.code !== "string" || args.code.trim().length === 0) {
      return { content: 'Error: python requires a non-empty "code" string.' };
    }
    const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "opentype-python-"));
    try {
      const scriptPath = path.join(tempDir, "script.py");
      fs.writeFileSync(scriptPath, args.code);
      const outcome = await runProcess(
        ["python3", scriptPath],
        resolveCwd(args.cwd),
        execTimeoutMs
      );
      return formatExecResult(outcome, execTimeoutMs);
    } finally {
      fs.rmSync(tempDir, { recursive: true, force: true });
    }
  }

  async function handleReadFile(rawArgs: unknown): Promise<{ content: string }> {
    const args = (rawArgs ?? {}) as { path?: unknown };
    if (typeof args.path !== "string" || args.path.trim().length === 0) {
      return { content: 'Error: read_file requires a non-empty "path" string.' };
    }
    const filePath = expandTilde(args.path, homeDir);
    return { content: clampAtSource(fs.readFileSync(filePath, "utf8")) };
  }

  async function handleListDir(rawArgs: unknown): Promise<{ content: string }> {
    const args = (rawArgs ?? {}) as { path?: unknown };
    const dirPath = typeof args.path === "string" && args.path.trim().length > 0
      ? expandTilde(args.path, homeDir)
      : homeDir;
    const entries = fs.readdirSync(dirPath, { withFileTypes: true });
    if (entries.length === 0) {
      return { content: `${dirPath} is empty.` };
    }
    const lines = entries
      .map((entry) => (entry.isDirectory() ? `${entry.name}/` : entry.name))
      .sort((a, b) => a.localeCompare(b));
    return { content: clampAtSource(lines.join("\n")) };
  }

  async function handleGrep(rawArgs: unknown): Promise<{ content: string }> {
    const args = (rawArgs ?? {}) as { pattern?: unknown; path?: unknown; caseInsensitive?: unknown };
    if (typeof args.pattern !== "string" || args.pattern.length === 0) {
      return { content: 'Error: grep requires a non-empty "pattern" string.' };
    }
    // Default scope is Desktop+Downloads, NOT all of home: recursive grep
    // over the whole home directory is pathologically slow (design §3); the
    // model passes an explicit path for anything else.
    const roots =
      typeof args.path === "string" && args.path.trim().length > 0
        ? [expandTilde(args.path, homeDir)]
        : [path.join(homeDir, "Desktop"), path.join(homeDir, "Downloads")].filter((dir) =>
            fs.existsSync(dir)
          );
    if (roots.length === 0) {
      return {
        content:
          "Error: no existing directory to search (neither ~/Desktop nor ~/Downloads exists; pass an explicit path).",
      };
    }
    const argv = ["grep", "-rn", "-I"];
    if (args.caseInsensitive === true) {
      argv.push("-i");
    }
    argv.push("--", args.pattern, ...roots);
    const outcome = await runProcess(argv, homeDir, execTimeoutMs);
    if (outcome.timedOut) {
      return { content: `Error: grep timed out after ${execTimeoutMs}ms and was killed.` };
    }
    // grep exit codes: 0 = matches, 1 = no matches (not an error), >=2 = real error.
    if (outcome.exitCode === 1) {
      return { content: `No matches found for "${args.pattern}" in ${roots.join(", ")}.` };
    }
    if (outcome.exitCode !== 0) {
      return { content: `Error: grep failed (exit code ${outcome.exitCode}): ${outcome.stderr.trim()}` };
    }
    return { content: clampAtSource(outcome.stdout.trimEnd()) };
  }

  async function handleWebSearch(rawArgs: unknown): Promise<{ content: string }> {
    const args = (rawArgs ?? {}) as { query?: unknown };
    if (typeof args.query !== "string" || args.query.trim().length === 0) {
      return { content: 'Error: web_search requires a non-empty "query" string.' };
    }
    const url = `https://html.duckduckgo.com/html/?q=${encodeURIComponent(args.query)}`;
    const response = await fetchFn(url, {
      headers: { "User-Agent": USER_AGENT },
      redirect: "follow",
    });
    if (!response.ok) {
      return { content: `Error: web search failed with HTTP ${response.status}.` };
    }
    const results = parseDdgResults(await response.text());
    if (results.length === 0) {
      return { content: `No search results found for "${args.query}".` };
    }
    const lines = results.map(
      (result, index) =>
        `${index + 1}. ${result.title}\n   ${result.url}${result.snippet ? `\n   ${result.snippet}` : ""}`
    );
    return { content: clampAtSource(lines.join("\n")) };
  }

  async function handleWebFetch(rawArgs: unknown): Promise<{ content: string }> {
    const args = (rawArgs ?? {}) as { url?: unknown };
    if (typeof args.url !== "string" || args.url.trim().length === 0) {
      return { content: 'Error: web_fetch requires a non-empty "url" string.' };
    }
    const response = await fetchFn(args.url, {
      headers: { "User-Agent": USER_AGENT },
      redirect: "follow",
    });
    if (!response.ok) {
      return { content: `Error: fetch of ${args.url} failed with HTTP ${response.status}.` };
    }
    const text = stripHtmlToText(await response.text());
    return { content: clampAtSource(text) };
  }

  /**
   * Opens a file with the macOS system default application (open-file +
   * ask-web design §1): Preview for PDFs/images, QuickTime for audio/video,
   * Word/Pages for documents. A deliberate UI side effect the agent may take
   * directly under the YOLO posture -- opening the preview IS the requested
   * outcome. Existence is verified before the runner is ever invoked.
   */
  async function handleOpenFile(rawArgs: unknown): Promise<{ content: string }> {
    const args = (rawArgs ?? {}) as { path?: unknown };
    if (typeof args.path !== "string" || args.path.trim().length === 0) {
      return { content: 'Error: open_file requires a non-empty "path" string.' };
    }
    const filePath = expandTilde(args.path, homeDir);
    if (!fs.existsSync(filePath)) {
      return { content: `Error: no file exists at ${filePath}.` };
    }
    const { exitCode } = await openRunner(filePath);
    if (exitCode !== 0) {
      return {
        content: `Error: failed to open ${filePath} (opener finished with exit code ${exitCode}).`,
      };
    }
    return { content: `Opened ${filePath} with its default application.` };
  }

  const handlers = new Map<string, (rawArgs: unknown) => Promise<{ content: string }>>([
    [BASH_TOOL_NAME, handleBash],
    [PYTHON_TOOL_NAME, handlePython],
    [READ_FILE_TOOL_NAME, handleReadFile],
    [LIST_DIR_TOOL_NAME, handleListDir],
    [GREP_TOOL_NAME, handleGrep],
    [WEB_SEARCH_TOOL_NAME, handleWebSearch],
    [WEB_FETCH_TOOL_NAME, handleWebFetch],
    [OPEN_FILE_TOOL_NAME, handleOpenFile],
  ]);

  const openAiTools: unknown[] = [
    {
      type: "function",
      function: {
        name: BASH_TOOL_NAME,
        description:
          "Run a shell command with /bin/bash. The working directory defaults to the user's home " +
          "directory; pass cwd (~ is expanded) to run somewhere else. Returns the command's output " +
          "and exit code. Long-running commands are killed after a timeout.",
        parameters: {
          type: "object",
          properties: {
            command: { type: "string", description: "The bash command line to run." },
            cwd: {
              type: "string",
              description: "Working directory for the command; defaults to the user's home directory.",
            },
          },
          required: ["command"],
        },
      },
    },
    {
      type: "function",
      function: {
        name: PYTHON_TOOL_NAME,
        description:
          "Run a Python 3 snippet (executed with python3). Use print() to produce output. The " +
          "working directory defaults to the user's home directory; pass cwd (~ is expanded) to " +
          "run somewhere else.",
        parameters: {
          type: "object",
          properties: {
            code: { type: "string", description: "The Python source code to execute." },
            cwd: {
              type: "string",
              description: "Working directory for the script; defaults to the user's home directory.",
            },
          },
          required: ["code"],
        },
      },
    },
    {
      type: "function",
      function: {
        name: READ_FILE_TOOL_NAME,
        description:
          "Read a text file and return its contents (long files are truncated). ~ is expanded to " +
          "the user's home directory.",
        parameters: {
          type: "object",
          properties: {
            path: { type: "string", description: "Path of the file to read; ~ is expanded." },
          },
          required: ["path"],
        },
      },
    },
    {
      type: "function",
      function: {
        name: LIST_DIR_TOOL_NAME,
        description:
          "List a directory's entries; subdirectories are marked with a trailing \"/\". Defaults " +
          "to the user's home directory when no path is given. ~ is expanded.",
        parameters: {
          type: "object",
          properties: {
            path: {
              type: "string",
              description: "Directory to list; defaults to the user's home directory. ~ is expanded.",
            },
          },
        },
      },
    },
    {
      type: "function",
      function: {
        name: GREP_TOOL_NAME,
        description:
          "Search file contents recursively for a pattern (system grep; results as file:line:text). " +
          "With no path it searches the user's Desktop and Downloads folders -- pass an explicit " +
          "path (~ is expanded) to search anywhere else.",
        parameters: {
          type: "object",
          properties: {
            pattern: { type: "string", description: "The grep pattern to search for." },
            path: {
              type: "string",
              description:
                "Directory (or file) to search; defaults to ~/Desktop and ~/Downloads. ~ is expanded.",
            },
            caseInsensitive: {
              type: "boolean",
              description: "Match case-insensitively (grep -i).",
            },
          },
          required: ["pattern"],
        },
      },
    },
    {
      type: "function",
      function: {
        name: WEB_SEARCH_TOOL_NAME,
        description:
          "Search the web (DuckDuckGo) and return the top results as a numbered list of title, URL, " +
          "and snippet. Use web_fetch to read a promising result's page.",
        parameters: {
          type: "object",
          properties: {
            query: { type: "string", description: "The search query." },
          },
          required: ["query"],
        },
      },
    },
    {
      type: "function",
      function: {
        name: WEB_FETCH_TOOL_NAME,
        description:
          "Fetch a URL (following redirects) and return the page as readable plain text with markup " +
          "stripped; long pages are truncated.",
        parameters: {
          type: "object",
          properties: {
            url: { type: "string", description: "The URL to fetch." },
          },
          required: ["url"],
        },
      },
    },
    {
      type: "function",
      function: {
        name: OPEN_FILE_TOOL_NAME,
        description:
          "Open a file on screen with the user's macOS default application (Preview for PDFs and " +
          "images, QuickTime for audio/video, Word/Pages for documents). Use this when the user asks " +
          "to open, preview, play, or look at a file -- opening it for them is the action itself, " +
          "not just reporting the path. ~ is expanded.",
        parameters: {
          type: "object",
          properties: {
            path: { type: "string", description: "Path of the file to open; ~ is expanded." },
          },
          required: ["path"],
        },
      },
    },
  ];

  async function callTool(name: string, args: unknown): Promise<{ content: string }> {
    const handler = handlers.get(name);
    if (!handler) {
      throw new Error(`Unknown core tool: ${name}`);
    }
    try {
      return await handler(args);
    } catch (err) {
      return errorContent(err);
    }
  }

  return { openAiTools, callTool };
}
