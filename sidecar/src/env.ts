import { resolve } from "node:path";

export interface SidecarEnv {
  socketPath: string;
  deepSeekApiKey: string;
  deepSeekModel: string;
  deepSeekBaseUrl: string;
  dbPath: string;
  contextLogPath: string;
  whisperSocketPath: string;
  /** Overrides `WhisperClient`'s default relative `whisper-env/bin/python3`;
   *  unset in dev mode, set to an absolute bundled path by the packaged app. */
  whisperPythonBin?: string;
  /** Overrides `WhisperClient`'s default relative `whisper/serve.py`;
   *  unset in dev mode, set to an absolute bundled path by the packaged app. */
  whisperScriptPath?: string;
  /** Root directory for spilled oversized tool results (`agent/spill.ts`). */
  spillRoot: string;
  /** Root directory for durable per-run step logs (`agent/runLog.ts`). */
  runLogRoot: string;
}

export function loadEnv(source: NodeJS.ProcessEnv = process.env): SidecarEnv {
  const socketPath =
    source.OPENTYPE_SIDECAR_SOCKET ?? "/tmp/opentype-sidecar-dev.sock";
  const deepSeekApiKey = source.DEEPSEEK_API_KEY ?? "";
  const deepSeekModel = source.DEEPSEEK_MODEL ?? "deepseek-v4-flash";
  const deepSeekBaseUrl = source.DEEPSEEK_BASE_URL ?? "https://api.deepseek.com";
  // Anchored to the sidecar module directory (src/ -> sidecar/) so the default
  // resolves to the *same* absolute SQLite file regardless of the process cwd
  // -- a cwd-relative default silently split the user's memory store in two
  // depending on whether the sidecar was launched from the repo root or from
  // `sidecar/`. The `OPENTYPE_SIDECAR_DB_PATH` override (set by the packaged
  // app via `SidecarClient.swift`) still wins when present.
  const dbPath =
    source.OPENTYPE_SIDECAR_DB_PATH ??
    resolve(import.meta.dir, "..", ".data", "opentype.sqlite3");
  // Proof-of-context-usage log (see `oneshot/contextDebugLog.ts`): follows
  // the same env-var-override-with-dev-default convention as `dbPath`
  // above. `SidecarClient.swift` sets `OPENTYPE_CONTEXT_LOG_PATH` alongside
  // `OPENTYPE_SIDECAR_SOCKET`/`OPENTYPE_SIDECAR_DB_PATH` for real app runs.
  const contextLogPath =
    source.OPENTYPE_CONTEXT_LOG_PATH ?? "sidecar/.data/context-debug.log";
  // Unix socket the local MLX-Whisper python server (sidecar/whisper/serve.py,
  // managed by `asr/whisperClient.ts`) listens on. Same
  // env-var-override-with-dev-default convention as the other paths above;
  // `SidecarClient.swift` sets this alongside `OPENTYPE_SIDECAR_SOCKET` for
  // real app runs, next to the sidecar's own socket.
  const whisperSocketPath =
    source.OPENTYPE_WHISPER_SOCKET ?? "sidecar/.data/whisper.sock";
  // Bundled-app packaging: `build-app.sh` copies `sidecar/whisper-env/` and
  // `sidecar/whisper/` into the app's Resources directory, and
  // `SidecarClient.swift` points these at the copied, absolute paths for a
  // packaged launch (a `bun build --compile` binary has no reliable way to
  // find the original source checkout at an arbitrary launch-time cwd, same
  // reasoning as `dbPath`/`contextLogPath` above). Left unset in dev mode,
  // where `defaultWhisperClientFactories()`'s relative defaults
  // ("whisper-env/bin/python3", "whisper/serve.py") are correct as-is.
  const whisperPythonBin = source.OPENTYPE_WHISPER_PYTHON_BIN;
  const whisperScriptPath = source.OPENTYPE_WHISPER_SCRIPT_PATH;
  // Root for oversized tool-result artifacts (`agent/spill.ts`, T2). Same
  // env-var-override-with-`.data`-default convention as `dbPath` above, and
  // anchored to the module directory for the same reason: a cwd-relative
  // default would scatter artifacts depending on where the sidecar launched.
  const spillRoot =
    source.OPENTYPE_SPILL_ROOT ?? resolve(import.meta.dir, "..", ".data", "spill");
  // Durable agent step logs (`agent/runLog.ts`, T7); same convention again.
  const runLogRoot =
    source.OPENTYPE_RUN_LOG_ROOT ?? resolve(import.meta.dir, "..", ".data", "run-logs");

  return {
    socketPath,
    deepSeekApiKey,
    deepSeekModel,
    deepSeekBaseUrl,
    dbPath,
    contextLogPath,
    whisperSocketPath,
    whisperPythonBin,
    whisperScriptPath,
    spillRoot,
    runLogRoot,
  };
}
