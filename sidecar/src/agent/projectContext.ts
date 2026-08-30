import * as fs from "node:fs";
import * as path from "node:path";
import { findProjectAgentsMd, renderProjectAgentsMd } from "./projectAgentsMd";

/**
 * Mid-run discovery of a project's `AGENTS.md` (design §10.1/§10.2,
 * docs/superpowers/specs/2026-08-28-first-party-tools-skills-and-agents-design.md).
 *
 * The run-start resolution in `agent/routes.ts` (from `workingDirectory`)
 * only covers the directory the agent started in -- but a task is often
 * discovered to be about a *different* project only partway through the
 * run ("帮我看看这个项目的测试为什么挂了" starting from the home directory).
 * This observer is the mid-run half of that same rule: shaped like
 * `agent/repeatGuard.ts`'s `RepeatGuard` on purpose (an `observe(...)`
 * method the loop calls after every tool call, returning text to inject or
 * `undefined`), because the loop already has exactly this seam wired in and
 * proven -- "observe a tool call, maybe append a message" -- and a second,
 * parallel mechanism for the same shape would be the real cost, not reuse.
 *
 * Unlike `RepeatGuard.observe` (which hashes the tool call's raw, unparsed
 * arguments JSON), this `observe` takes the ALREADY-PARSED arguments object,
 * because extracting a `cwd`/`path` string field is naturally done against a
 * parsed object, not raw JSON text.
 */
export interface ProjectContextObserver {
  /**
   * Records one tool call and returns a rendered `AGENTS.md` block when it
   * resolves to a project this observer has not yet reported on, or
   * `undefined` otherwise (nothing found, or already reported once).
   *
   * `args` is deliberately untyped and untrusted: in `loop.ts`,
   * `toolCall.function.arguments` is parsed inside a `try` block, and this
   * observer is invoked outside it, so a tool call whose arguments failed
   * `JSON.parse` reaches here with no parsed object at all. `undefined`,
   * `null`, a bare string, or an object with neither `cwd` nor `path` must
   * all resolve to `undefined`, never throw -- a crash here over one
   * malformed tool call would take down the whole run, not just this one
   * observation.
   */
  observe(toolName: string, args: unknown): string | undefined;
}

export interface CreateProjectContextObserverOptions {
  /** The §10.2 upward-walk boundary -- see `findProjectAgentsMd`. */
  homeDir: string;
  /**
   * Optional per-run default directory: relative first-party `cwd` / `path`
   * args are resolved against it before project discovery.
   */
  defaultWorkingDirectory?: string;
}

function isTildePath(value: string): boolean {
  return value === "~" || value.startsWith("~/");
}

/** Pulls a `cwd` or `path` string out of a tool call's parsed arguments, if either is usable. */
function extractPathArg(args: unknown): string | undefined {
  if (!args || typeof args !== "object") {
    return undefined;
  }
  const record = args as Record<string, unknown>;
  if (typeof record.cwd === "string" && record.cwd.length > 0) {
    return record.cwd;
  }
  if (typeof record.path === "string" && record.path.length > 0) {
    return record.path;
  }
  return undefined;
}

function resolveObservedPath(
  rawPath: string,
  defaultWorkingDirectory?: string
): string {
  if (
    !defaultWorkingDirectory ||
    path.isAbsolute(rawPath) ||
    isTildePath(rawPath)
  ) {
    return rawPath;
  }
  return path.resolve(defaultWorkingDirectory, rawPath);
}

/**
 * Resolves the directory a raw `cwd`/`path` argument implies: if it exists
 * on disk and IS a directory, it is used as-is; otherwise (a file, or
 * nothing there at all) its containing directory is used instead.
 *
 * This is load-bearing, not a convenience: `opentype__list_dir` and
 * `opentype__glob` pass a `path` that already IS the directory to scope
 * from. Unconditionally taking the parent would resolve
 * `list_dir({ path: "~/proj" })` starting from `~`, missing
 * `~/proj/AGENTS.md` -- the single most typical case this feature exists
 * for (a tool call scoped directly at a project's own root).
 */
function resolveDirFromArg(rawPath: string): string {
  try {
    if (fs.statSync(rawPath).isDirectory()) {
      return rawPath;
    }
  } catch {
    // Doesn't exist, or unreadable for any other reason -- fall through to
    // the containing directory, same as a plain file path would.
  }
  return path.dirname(rawPath);
}

/**
 * Creates one observer. State (which projects have already been reported)
 * is per-instance and in-memory only, exactly as `createRepeatGuard`'s
 * chain state is -- a caller must construct a fresh observer per run, never
 * share one across runs.
 */
export function createProjectContextObserver(
  options: CreateProjectContextObserverOptions
): ProjectContextObserver {
  const { homeDir, defaultWorkingDirectory } = options;
  const reportedPaths = new Set<string>();

  return {
    observe(_toolName, args) {
      const rawPath = extractPathArg(args);
      if (!rawPath) {
        return undefined;
      }
      const dir = resolveDirFromArg(resolveObservedPath(rawPath, defaultWorkingDirectory));
      const found = findProjectAgentsMd(dir, homeDir);
      if (!found) {
        return undefined;
      }
      if (reportedPaths.has(found.path)) {
        // Dedup is per PROJECT (keyed on the resolved AGENTS.md path), not
        // per exact cwd/path argument -- two different tool calls that
        // resolve into the same project must not re-inject the same block.
        return undefined;
      }
      reportedPaths.add(found.path);
      return renderProjectAgentsMd(found);
    },
  };
}
