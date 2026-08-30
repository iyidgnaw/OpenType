import { isAbsolute, resolve } from "node:path";
import type { ToolSet } from "./toolSets";

function isTildePath(value: string): boolean {
  return value === "~" || value.startsWith("~/");
}

function resolveFromWorkingDirectory(value: unknown, workingDirectory: string): string | undefined {
  if (typeof value !== "string" || value.trim().length === 0) {
    return undefined;
  }
  if (isAbsolute(value) || isTildePath(value)) {
    return value;
  }
  return resolve(workingDirectory, value);
}

function withResolvedPath(
  record: Record<string, unknown>,
  key: string,
  workingDirectory: string,
  defaultToWorkingDirectory = false
): boolean {
  const current = record[key];
  const next =
    resolveFromWorkingDirectory(current, workingDirectory) ??
    (defaultToWorkingDirectory ? workingDirectory : undefined);
  if (next === undefined || next === current) {
    return false;
  }
  record[key] = next;
  return true;
}

function rewriteFirstPartyArgs(name: string, args: unknown, workingDirectory: string): unknown {
  if (!name.startsWith("opentype__") || !args || typeof args !== "object" || Array.isArray(args)) {
    return args;
  }

  const record = { ...(args as Record<string, unknown>) };
  let changed = false;

  switch (name) {
    case "opentype__bash":
    case "opentype__python":
      changed = withResolvedPath(record, "cwd", workingDirectory, true);
      break;
    case "opentype__open_file":
    case "opentype__read_file":
    case "opentype__write_file":
    case "opentype__edit_file":
    case "opentype__trash":
      changed = withResolvedPath(record, "path", workingDirectory);
      break;
    case "opentype__list_dir":
    case "opentype__glob":
      changed = withResolvedPath(record, "path", workingDirectory, true);
      break;
    case "opentype__grep":
      changed = withResolvedPath(record, "path", workingDirectory, true);
      break;
    case "opentype__move_file": {
      const sourceChanged = withResolvedPath(record, "source", workingDirectory);
      const destinationChanged = withResolvedPath(record, "destination", workingDirectory);
      changed = sourceChanged || destinationChanged;
      break;
    }
    default:
      break;
  }

  return changed ? record : args;
}

export function withWorkingDirectoryDefaults(tools: ToolSet, workingDirectory: string): ToolSet {
  return {
    get openAiTools() {
      return tools.openAiTools;
    },
    callTool(name, args, signal) {
      return tools.callTool(name, rewriteFirstPartyArgs(name, args, workingDirectory), signal);
    },
  };
}
