import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import type { ToolSet } from "./toolSets";
import type { MemoryStore } from "../memory/MemoryStore";
import type { ConversationStore } from "../memory/conversations";
import {
  handleReadHistory,
  READ_HISTORY_TOOL_NAME,
  READ_HISTORY_TOOL_SCHEMA,
} from "./readHistoryTool";

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
  openRunner?: (path: string, signal?: AbortSignal) => Promise<{ exitCode: number }>;
  /**
   * Backing stores for `opentype__read_history` (readHistoryTool.ts).
   * Optional like every other dep here: the tool is always listed in
   * `openAiTools` regardless of whether memory is wired up, and its handler
   * degrades to a readable explanation rather than throwing when either is
   * absent.
   */
  memoryStore?: MemoryStore;
  conversations?: ConversationStore;
}

const BASH_TOOL_NAME = "opentype__bash";
const PYTHON_TOOL_NAME = "opentype__python";
const READ_FILE_TOOL_NAME = "opentype__read_file";
const LIST_DIR_TOOL_NAME = "opentype__list_dir";
const GREP_TOOL_NAME = "opentype__grep";
const WEB_SEARCH_TOOL_NAME = "opentype__web_search";
const WEB_FETCH_TOOL_NAME = "opentype__web_fetch";
const OPEN_FILE_TOOL_NAME = "opentype__open_file";
const WRITE_FILE_TOOL_NAME = "opentype__write_file";
const EDIT_FILE_TOOL_NAME = "opentype__edit_file";
const MOVE_FILE_TOOL_NAME = "opentype__move_file";
const TRASH_TOOL_NAME = "opentype__trash";
const GLOB_TOOL_NAME = "opentype__glob";

const DEFAULT_EXEC_TIMEOUT_MS = 60_000;

/**
 * §2 of docs/superpowers/specs/2026-08-28-first-party-tools-skills-and-agents-design.md:
 * "默认上限 200 条" for `opentype__glob`. Exported (not just inlined) so the
 * number can't silently drift out of sync with the design doc, and so a
 * caller/test can pin it without hardcoding a magic number of its own.
 */
export const GLOB_DEFAULT_LIMIT = 200;

/** Directory names `opentype__glob` never descends into, plus any other dot-directory. */
const GLOB_SKIPPED_DIR_NAMES = new Set([".git", "node_modules", "Library"]);

/**
 * Source-side clamp, applied inside each tool before the result ever reaches
 * the loop's own 20k `clampToolResult` (loop.ts): a runaway `cat` or a huge
 * page must be bounded at the tool itself so a multi-MB string is never
 * built into the progress log/messages. Kept under the tests' 30k ceiling
 * with headroom for framing (exit-code line, truncation marker).
 */
export const SOURCE_CLAMP_MAX_CHARS = 25_000;

const MAX_SEARCH_RESULTS = 8;

/** Browser-ish UA: DDG's html endpoint (and many sites) reject bare fetch UAs. */
const USER_AGENT =
  "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36";

export function clampAtSource(text: string): string {
  if (text.length <= SOURCE_CLAMP_MAX_CHARS) {
    return text;
  }
  return `${text.slice(0, SOURCE_CLAMP_MAX_CHARS)}\n...[truncated]`;
}

/**
 * Turns a shell-ish filename pattern (`*`/`?` wildcards, everything else
 * literal) into a `RegExp` anchored to the whole basename. Deliberately not
 * a full glob engine (no `**`, no brace expansion, no character classes) --
 * `opentype__glob` matches by *filename*, not by path segments, so this is
 * all the design's "按文件名模式递归查找" needs.
 */
function filenamePatternToRegExp(pattern: string): RegExp {
  let source = "";
  for (const ch of pattern) {
    if (ch === "*") {
      source += ".*";
    } else if (ch === "?") {
      source += ".";
    } else {
      source += ch.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
    }
  }
  return new RegExp(`^${source}$`);
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

/**
 * Renames `src` to `dest`, falling back to a recursive copy + remove when
 * they straddle two filesystems (`EXDEV` -- e.g. an external drive), which
 * a bare `fs.renameSync` cannot do. Shared by `opentype__move_file` and
 * `opentype__trash`, since "trash" is just "move into `.Trash`".
 */
function moveEntry(src: string, dest: string): void {
  try {
    fs.renameSync(src, dest);
  } catch (err) {
    if ((err as NodeJS.ErrnoException).code !== "EXDEV") {
      throw err;
    }
    fs.cpSync(src, dest, { recursive: true });
    fs.rmSync(src, { recursive: true, force: true });
  }
}

/**
 * Finds a free name for `baseName` inside `trashDir`, walking " 2", " 3", ...
 * SEQUENTIALLY rather than always trying " 2": once a first collision has
 * already claimed " 2", a second one that just retried " 2" would clobber
 * it -- real data loss, and the exact failure mode `opentype__trash` exists
 * to prevent.
 */
function uniqueTrashDestination(trashDir: string, baseName: string): string {
  const candidate = path.join(trashDir, baseName);
  if (!fs.existsSync(candidate)) {
    return candidate;
  }
  const ext = path.extname(baseName);
  const stem = baseName.slice(0, baseName.length - ext.length);
  for (let n = 2; ; n++) {
    const next = path.join(trashDir, `${stem} ${n}${ext}`);
    if (!fs.existsSync(next)) {
      return next;
    }
  }
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
async function runProcess(
  argv: string[],
  cwd: string,
  timeoutMs: number,
  signal?: AbortSignal
): Promise<ExecOutcome> {
  const proc = Bun.spawn(argv, { cwd, stdin: "ignore", stdout: "pipe", stderr: "pipe" });
  const stdoutPromise = new Response(proc.stdout).text();
  const stderrPromise = new Response(proc.stderr).text();

  let timedOut = false;
  let killTimer: ReturnType<typeof setTimeout> | undefined;
  // Cancellation reuses the timeout's own escalation (SIGTERM, then SIGKILL
  // after 2s) rather than adding a second kill path: a cancelled child and a
  // timed-out child need identical treatment, and one path is one thing to
  // get right.
  const terminate = (): void => {
    proc.kill();
    killTimer = setTimeout(() => proc.kill(9), 2000);
  };
  const timeoutTimer = setTimeout(() => {
    timedOut = true;
    terminate();
  }, timeoutMs);
  const onAbort = (): void => terminate();
  signal?.addEventListener("abort", onAbort, { once: true });
  if (signal?.aborted) {
    terminate();
  }

  let exitCode: number;
  try {
    exitCode = await proc.exited;
  } finally {
    clearTimeout(timeoutTimer);
    signal?.removeEventListener("abort", onAbort);
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
    (async (targetPath: string, signal?: AbortSignal): Promise<{ exitCode: number }> => {
      const outcome = await runProcess(
        ["/usr/bin/open", targetPath],
        homeDir,
        execTimeoutMs,
        signal
      );
      return { exitCode: outcome.exitCode };
    });

  function resolveCwd(rawCwd: unknown): string {
    if (typeof rawCwd === "string" && rawCwd.trim().length > 0) {
      return expandTilde(rawCwd, homeDir);
    }
    return homeDir;
  }

  async function handleBash(rawArgs: unknown, signal?: AbortSignal): Promise<{ content: string }> {
    const args = (rawArgs ?? {}) as { command?: unknown; cwd?: unknown };
    if (typeof args.command !== "string" || args.command.trim().length === 0) {
      return { content: 'Error: bash requires a non-empty "command" string.' };
    }
    const outcome = await runProcess(
      ["/bin/bash", "-lc", args.command],
      resolveCwd(args.cwd),
      execTimeoutMs,
      signal
    );
    return formatExecResult(outcome, execTimeoutMs);
  }

  async function handlePython(rawArgs: unknown, signal?: AbortSignal): Promise<{ content: string }> {
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
        execTimeoutMs,
        signal
      );
      return formatExecResult(outcome, execTimeoutMs);
    } finally {
      fs.rmSync(tempDir, { recursive: true, force: true });
    }
  }

  async function handleReadFile(rawArgs: unknown, signal?: AbortSignal): Promise<{ content: string }> {
    const args = (rawArgs ?? {}) as { path?: unknown };
    if (typeof args.path !== "string" || args.path.trim().length === 0) {
      return { content: 'Error: read_file requires a non-empty "path" string.' };
    }
    const filePath = expandTilde(args.path, homeDir);
    return { content: clampAtSource(fs.readFileSync(filePath, "utf8")) };
  }

  async function handleListDir(rawArgs: unknown, signal?: AbortSignal): Promise<{ content: string }> {
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

  async function handleGrep(rawArgs: unknown, signal?: AbortSignal): Promise<{ content: string }> {
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
    const outcome = await runProcess(argv, homeDir, execTimeoutMs, signal);
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

  async function handleWebSearch(rawArgs: unknown, signal?: AbortSignal): Promise<{ content: string }> {
    const args = (rawArgs ?? {}) as { query?: unknown };
    if (typeof args.query !== "string" || args.query.trim().length === 0) {
      return { content: 'Error: web_search requires a non-empty "query" string.' };
    }
    const url = `https://html.duckduckgo.com/html/?q=${encodeURIComponent(args.query)}`;
    const response = await fetchFn(url, {
      headers: { "User-Agent": USER_AGENT },
      redirect: "follow",
      signal,
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

  async function handleWebFetch(rawArgs: unknown, signal?: AbortSignal): Promise<{ content: string }> {
    const args = (rawArgs ?? {}) as { url?: unknown };
    if (typeof args.url !== "string" || args.url.trim().length === 0) {
      return { content: 'Error: web_fetch requires a non-empty "url" string.' };
    }
    const response = await fetchFn(args.url, {
      headers: { "User-Agent": USER_AGENT },
      redirect: "follow",
      signal,
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
  async function handleOpenFile(rawArgs: unknown, signal?: AbortSignal): Promise<{ content: string }> {
    const args = (rawArgs ?? {}) as { path?: unknown };
    if (typeof args.path !== "string" || args.path.trim().length === 0) {
      return { content: 'Error: open_file requires a non-empty "path" string.' };
    }
    const filePath = expandTilde(args.path, homeDir);
    if (!fs.existsSync(filePath)) {
      return { content: `Error: no file exists at ${filePath}.` };
    }
    const { exitCode } = await openRunner(filePath, signal);
    if (exitCode !== 0) {
      return {
        content: `Error: failed to open ${filePath} (opener finished with exit code ${exitCode}).`,
      };
    }
    return { content: `Opened ${filePath} with its default application.` };
  }

  /**
   * Full-file write (§2). Creates missing parent directories -- "整理文件"
   * tasks routinely target a path that doesn't exist yet -- and reports
   * both the UTF-8 byte count (not `.length`, which undercounts multi-byte
   * text) and whether an existing file was overwritten, since silently
   * clobbering something is the one failure mode this tool's caller most
   * needs surfaced back to it.
   */
  async function handleWriteFile(
    rawArgs: unknown,
    signal?: AbortSignal
  ): Promise<{ content: string }> {
    if (signal?.aborted) {
      return { content: "Error: cancelled." };
    }
    const args = (rawArgs ?? {}) as { path?: unknown; content?: unknown };
    if (typeof args.path !== "string" || args.path.trim().length === 0) {
      return { content: 'Error: write_file requires a non-empty "path" string.' };
    }
    if (typeof args.content !== "string") {
      return { content: 'Error: write_file requires a "content" string.' };
    }
    const filePath = expandTilde(args.path, homeDir);
    const existedBefore = fs.existsSync(filePath);
    fs.mkdirSync(path.dirname(filePath), { recursive: true });
    fs.writeFileSync(filePath, args.content, "utf8");
    const byteCount = Buffer.byteLength(args.content, "utf8");
    return {
      content: existedBefore
        ? `Overwritten ${filePath} (${byteCount} bytes).`
        : `Wrote ${filePath} (${byteCount} bytes).`,
    };
  }

  /**
   * Exact-string find/replace (§2). `old_string` not found, or found more
   * than once without `replace_all: true`, resolves as an Error with the
   * match count named -- and, critically, the file is left byte-unchanged
   * in both cases: this handler never writes until it knows the edit is
   * unambiguous.
   */
  async function handleEditFile(
    rawArgs: unknown,
    signal?: AbortSignal
  ): Promise<{ content: string }> {
    if (signal?.aborted) {
      return { content: "Error: cancelled." };
    }
    const args = (rawArgs ?? {}) as {
      path?: unknown;
      old_string?: unknown;
      new_string?: unknown;
      replace_all?: unknown;
    };
    if (typeof args.path !== "string" || args.path.trim().length === 0) {
      return { content: 'Error: edit_file requires a non-empty "path" string.' };
    }
    if (typeof args.old_string !== "string" || args.old_string.length === 0) {
      return { content: 'Error: edit_file requires a non-empty "old_string" string.' };
    }
    if (typeof args.new_string !== "string") {
      return { content: 'Error: edit_file requires a "new_string" string.' };
    }
    const filePath = expandTilde(args.path, homeDir);
    if (!fs.existsSync(filePath)) {
      return { content: `Error: no file exists at ${filePath}.` };
    }
    const original = fs.readFileSync(filePath, "utf8");
    const occurrences = original.split(args.old_string).length - 1;
    if (occurrences === 0) {
      return { content: `Error: old_string not found in ${filePath}.` };
    }
    if (occurrences > 1 && args.replace_all !== true) {
      return {
        content:
          `Error: old_string matches ${occurrences} times in ${filePath}; ` +
          'pass replace_all: true to replace all of them, or narrow old_string to a unique match.',
      };
    }
    const updated =
      occurrences > 1
        ? original.split(args.old_string).join(args.new_string)
        : original.replace(args.old_string, args.new_string);
    fs.writeFileSync(filePath, updated, "utf8");
    return { content: `Edited ${filePath} (${occurrences} replacement${occurrences === 1 ? "" : "s"}).` };
  }

  /**
   * Move/rename (§2). The one hard-refusal this batch keeps (design's own
   * words: "move_file 不覆盖"): an existing destination *file* is an Error,
   * full stop, with the source left untouched -- silently clobbering a
   * same-named file is the one mistake here that can't be undone by
   * `opentype__trash`. An existing destination *directory* is not a
   * collision; the source moves into it under its own basename, same as
   * `mv src dir/`.
   */
  async function handleMoveFile(
    rawArgs: unknown,
    signal?: AbortSignal
  ): Promise<{ content: string }> {
    if (signal?.aborted) {
      return { content: "Error: cancelled." };
    }
    const args = (rawArgs ?? {}) as { source?: unknown; destination?: unknown };
    if (typeof args.source !== "string" || args.source.trim().length === 0) {
      return { content: 'Error: move_file requires a non-empty "source" string.' };
    }
    if (typeof args.destination !== "string" || args.destination.trim().length === 0) {
      return { content: 'Error: move_file requires a non-empty "destination" string.' };
    }
    const source = expandTilde(args.source, homeDir);
    let destination = expandTilde(args.destination, homeDir);
    if (!fs.existsSync(source)) {
      return { content: `Error: no file exists at ${source}.` };
    }
    if (fs.existsSync(destination) && fs.statSync(destination).isDirectory()) {
      destination = path.join(destination, path.basename(source));
    }
    if (fs.existsSync(destination)) {
      return { content: `Error: destination already exists at ${destination}.` };
    }
    fs.mkdirSync(path.dirname(destination), { recursive: true });
    moveEntry(source, destination);
    return { content: `Moved ${source} to ${destination}.` };
  }

  /**
   * Recoverable "delete" (§2/§0): moves into `<homeDir>/.Trash` rather than
   * removing anything, dedup'ing a name collision by walking " 2", " 3", ...
   * SEQUENTIALLY rather than always trying " 2" -- a fixed " 2" suffix would
   * clobber whatever a *previous* trash already parked there once a second
   * collision came in, which is exactly the data loss this tool exists to
   * rule out. This is the product's answer to `bash rm`: give the model a
   * delete that's always undoable so it has no reason to reach for the real
   * thing.
   */
  async function handleTrash(
    rawArgs: unknown,
    signal?: AbortSignal
  ): Promise<{ content: string }> {
    if (signal?.aborted) {
      return { content: "Error: cancelled." };
    }
    const args = (rawArgs ?? {}) as { path?: unknown };
    if (typeof args.path !== "string" || args.path.trim().length === 0) {
      return { content: 'Error: trash requires a non-empty "path" string.' };
    }
    const target = expandTilde(args.path, homeDir);
    if (!fs.existsSync(target)) {
      return { content: `Error: no file or directory exists at ${target}.` };
    }
    const trashDir = path.join(homeDir, ".Trash");
    fs.mkdirSync(trashDir, { recursive: true });
    const destination = uniqueTrashDestination(trashDir, path.basename(target));
    moveEntry(target, destination);
    return { content: `Moved ${target} to ${destination}.` };
  }

  /**
   * Recursive filename-pattern search (§2), skipping `.git`/`node_modules`/
   * `Library` and any other dot-directory -- "找一下那个 PDF" is the
   * highest-frequency voice task and none of those trees are ever what the
   * user means by "my files". Defaults the root to `homeDir` and the result
   * cap to `GLOB_DEFAULT_LIMIT`.
   */
  async function handleGlob(
    rawArgs: unknown,
    signal?: AbortSignal
  ): Promise<{ content: string }> {
    if (signal?.aborted) {
      return { content: "Error: cancelled." };
    }
    const args = (rawArgs ?? {}) as { pattern?: unknown; path?: unknown; limit?: unknown };
    if (typeof args.pattern !== "string" || args.pattern.length === 0) {
      return { content: 'Error: glob requires a non-empty "pattern" string.' };
    }
    const root =
      typeof args.path === "string" && args.path.trim().length > 0
        ? expandTilde(args.path, homeDir)
        : homeDir;
    if (!fs.existsSync(root)) {
      return { content: `Error: no directory exists at ${root}.` };
    }
    const limit =
      typeof args.limit === "number" && Number.isFinite(args.limit) && args.limit > 0
        ? Math.floor(args.limit)
        : GLOB_DEFAULT_LIMIT;
    const matcher = filenamePatternToRegExp(args.pattern);
    const matches: string[] = [];
    let cancelled = false;

    // `~` can contain hundreds of thousands of entries even after skipping
    // .git/node_modules/Library/dot-directories, so this walk can run long --
    // checking `signal` only at entry (like the other four handlers) would
    // leave a cancelled agent run stuck until the whole tree finishes. Every
    // other tool here delegates cancellation to `runProcess`'s child-process
    // kill; a synchronous recursive walk has no such point, so it polls
    // `signal.aborted` itself between directory entries instead.
    function walk(dir: string): void {
      if (matches.length >= limit || cancelled) {
        return;
      }
      if (signal?.aborted) {
        cancelled = true;
        return;
      }
      let entries: fs.Dirent[];
      try {
        entries = fs.readdirSync(dir, { withFileTypes: true });
      } catch {
        return;
      }
      for (const entry of entries) {
        if (matches.length >= limit || cancelled) {
          return;
        }
        const entryPath = path.join(dir, entry.name);
        if (entry.isDirectory()) {
          if (entry.name.startsWith(".") || GLOB_SKIPPED_DIR_NAMES.has(entry.name)) {
            continue;
          }
          walk(entryPath);
        } else if (matcher.test(entry.name)) {
          matches.push(entryPath);
        }
      }
    }
    walk(root);

    if (cancelled) {
      return { content: "Error: cancelled." };
    }
    if (matches.length === 0) {
      return { content: `No matches found for "${args.pattern}" under ${root}.` };
    }
    // Source-side clamp like every other tool in this file (§2's own
    // convention): `limit` bounds the number of *matches*, not their total
    // rendered length, and `GLOB_DEFAULT_LIMIT` (200) absolute home-directory
    // paths can comfortably exceed `SOURCE_CLAMP_MAX_CHARS` on its own.
    return { content: clampAtSource(matches.join("\n")) };
  }

  async function handleReadHistoryTool(rawArgs: unknown): Promise<{ content: string }> {
    const args = (rawArgs ?? {}) as {
      eventId?: unknown;
      conversationId?: unknown;
      limit?: unknown;
    };
    const content = await handleReadHistory(
      {
        eventId: typeof args.eventId === "number" ? args.eventId : undefined,
        conversationId: typeof args.conversationId === "number" ? args.conversationId : undefined,
        limit: typeof args.limit === "number" ? args.limit : undefined,
      },
      { store: deps.memoryStore, conversations: deps.conversations }
    );
    return { content };
  }

  const handlers = new Map<
    string,
    (rawArgs: unknown, signal?: AbortSignal) => Promise<{ content: string }>
  >([
    [BASH_TOOL_NAME, handleBash],
    [PYTHON_TOOL_NAME, handlePython],
    [READ_FILE_TOOL_NAME, handleReadFile],
    [LIST_DIR_TOOL_NAME, handleListDir],
    [GREP_TOOL_NAME, handleGrep],
    [WEB_SEARCH_TOOL_NAME, handleWebSearch],
    [WEB_FETCH_TOOL_NAME, handleWebFetch],
    [OPEN_FILE_TOOL_NAME, handleOpenFile],
    [WRITE_FILE_TOOL_NAME, handleWriteFile],
    [EDIT_FILE_TOOL_NAME, handleEditFile],
    [MOVE_FILE_TOOL_NAME, handleMoveFile],
    [TRASH_TOOL_NAME, handleTrash],
    [GLOB_TOOL_NAME, handleGlob],
    [READ_HISTORY_TOOL_NAME, handleReadHistoryTool],
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
          "Show a file to the user by opening it with their macOS default application (Preview for " +
          "PDFs and images, QuickTime for audio/video, Word/Pages for documents). Use this whenever " +
          "the point of the task is for the user to SEE a file -- being asked to find or locate one " +
          "counts, not just being told to open it. Opening it is the deliverable; reporting the path " +
          "alone is not. ~ is expanded.",
        parameters: {
          type: "object",
          properties: {
            path: { type: "string", description: "Path of the file to open; ~ is expanded." },
          },
          required: ["path"],
        },
      },
    },
    {
      type: "function",
      function: {
        name: WRITE_FILE_TOOL_NAME,
        description:
          "Write content to a file, creating it (and any missing parent directories) if needed, or " +
          "overwriting it if it already exists. Reports the byte count written and whether an " +
          "existing file was overwritten. ~ is expanded.",
        parameters: {
          type: "object",
          properties: {
            path: { type: "string", description: "Path of the file to write; ~ is expanded." },
            content: { type: "string", description: "The full text content to write." },
          },
          required: ["path", "content"],
        },
      },
    },
    {
      type: "function",
      function: {
        name: EDIT_FILE_TOOL_NAME,
        description:
          "Replace an exact string in a file with another. old_string must match exactly once " +
          "unless replace_all is true; if it matches zero or (without replace_all) more than once, " +
          "the edit is refused and the file is left unchanged. ~ is expanded.",
        parameters: {
          type: "object",
          properties: {
            path: { type: "string", description: "Path of the file to edit; ~ is expanded." },
            old_string: { type: "string", description: "The exact text to find." },
            new_string: { type: "string", description: "The text to replace it with." },
            replace_all: {
              type: "boolean",
              description: "Replace every occurrence instead of requiring exactly one match.",
            },
          },
          required: ["path", "old_string", "new_string"],
        },
      },
    },
    {
      type: "function",
      function: {
        name: MOVE_FILE_TOOL_NAME,
        description:
          "Move or rename a file or directory, creating the destination's missing parent " +
          "directories. If destination is an existing directory, source moves into it under its own " +
          "name. Refuses (with no changes made) if destination already exists as a file -- it never " +
          "overwrites silently. ~ is expanded in both paths.",
        parameters: {
          type: "object",
          properties: {
            source: { type: "string", description: "Path of the file/directory to move; ~ is expanded." },
            destination: {
              type: "string",
              description: "Destination path, or an existing directory to move into; ~ is expanded.",
            },
          },
          required: ["source", "destination"],
        },
      },
    },
    {
      type: "function",
      function: {
        name: TRASH_TOOL_NAME,
        description:
          "Move a file or directory to the user's Trash (~/.Trash) instead of deleting it -- always " +
          "recoverable, never a permanent delete. A name collision in Trash gets a numbered suffix " +
          "rather than clobbering what's already there. ~ is expanded.",
        parameters: {
          type: "object",
          properties: {
            path: { type: "string", description: "Path of the file/directory to trash; ~ is expanded." },
          },
          required: ["path"],
        },
      },
    },
    {
      type: "function",
      function: {
        name: GLOB_TOOL_NAME,
        description:
          "Find files by filename pattern (supports * and ? wildcards), searching recursively. " +
          `Defaults to the user's home directory and a cap of ${GLOB_DEFAULT_LIMIT} results; skips ` +
          ".git, node_modules, Library, and other dot-directories. Use this to locate a file by name " +
          "-- for searching file CONTENTS use grep instead. ~ is expanded.",
        parameters: {
          type: "object",
          properties: {
            pattern: { type: "string", description: "Filename pattern to match, e.g. \"*.pdf\"." },
            path: {
              type: "string",
              description: "Directory to search; defaults to the user's home directory. ~ is expanded.",
            },
            limit: {
              type: "number",
              description: `Maximum number of results to return (default ${GLOB_DEFAULT_LIMIT}).`,
            },
          },
          required: ["pattern"],
        },
      },
    },
    READ_HISTORY_TOOL_SCHEMA,
  ];

  async function callTool(
    name: string,
    args: unknown,
    signal?: AbortSignal
  ): Promise<{ content: string }> {
    const handler = handlers.get(name);
    if (!handler) {
      throw new Error(`Unknown core tool: ${name}`);
    }
    try {
      return await handler(args, signal);
    } catch (err) {
      return errorContent(err);
    }
  }

  return { openAiTools, callTool };
}
