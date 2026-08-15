/**
 * Manages the local MLX-Whisper Python subprocess and talks to it over a
 * Unix domain socket. Mirrors two existing patterns in this codebase:
 *  - `SidecarClient.swift`'s lifecycle shape (spawn -> poll `/health` with a
 *    timeout -> ready; `stop()` kills the child) for how Swift manages this
 *    TS sidecar itself.
 *  - `agent/mcpClient.ts`'s dependency-injected factories (`McpConnectionFactories`)
 *    so the spawn/health-check/proxy logic is unit-testable without a real
 *    child process or socket.
 */

import { decideReadinessAction } from "../lifecycle";

export interface SpawnedProcess {
  readonly pid?: number;
  kill(): void;
  /**
   * Register a handler invoked when the child exits. Optional so the real
   * Bun-backed factory can wire it to `proc.exited` while fakes push into an
   * array. When absent, `WhisperClient` simply can't observe exits (older
   * behavior) -- present in production so runtime death triggers a respawn.
   */
  onExit?(cb: (code: number | null) => void): void;
}

/**
 * Everything `WhisperClient` needs from the outside world, factored out so
 * tests can inject fakes. `defaultWhisperClientFactories()` below provides
 * the real, Bun-backed implementation used in production.
 */
export interface WhisperClientFactories {
  spawnProcess: (env: NodeJS.ProcessEnv) => SpawnedProcess;
  checkHealth: (socketPath: string) => Promise<boolean>;
  /**
   * `initialPrompt` is the entity-dictionary bias (see `dictionaryBias.ts`);
   * `language` is the user's transcription-language setting as an ISO-639-1
   * code. Both are optional and omitted rather than empty when unset, so the
   * decoder falls back to its own defaults instead of being handed "".
   *
   * These stay positional (rather than following `transcribe` into an options
   * bag) because each is purely additive here: every existing fake keeps
   * working by simply not declaring the parameter it doesn't care about.
   */
  postAudio: (
    socketPath: string,
    audio: Uint8Array,
    initialPrompt?: string,
    language?: string
  ) => Promise<{ text: string }>;
  sleep: (ms: number) => Promise<void>;
}

/**
 * The decode options a single transcription can carry. An options bag rather
 * than a second and third positional optional: two same-typed trailing
 * `string?` parameters are the shape that eventually gets called in the wrong
 * order, and nothing in the type system would notice.
 */
export interface WhisperTranscribeOptions {
  /** Entity-dictionary decoding bias; omitted when the dictionary is empty. */
  initialPrompt?: string;
  /**
   * ISO-639-1 code (Whisper's own `LANGUAGES` keys — `"zh"`, `"en"`, `"ja"`),
   * not a BCP-47 locale. Omitted means Whisper detects the language itself,
   * which is what the setting's "自动识别" entry promises.
   */
  language?: string;
}

export interface WhisperClientOptions {
  /** Unix socket path the python server listens on and this client talks to. */
  socketPath: string;
  /** Extra environment variables merged into the spawned process's env. */
  extraEnv?: NodeJS.ProcessEnv;
  /** Total time to wait for `/health` to report healthy before giving up. */
  readinessTimeoutMs?: number;
  /** Delay between readiness poll attempts. */
  pollIntervalMs?: number;
  /**
   * Cap on how many times a dead child is respawned before giving up. The
   * count is over the lifetime of this client, not per unexpected exit, so a
   * process that keeps crashing eventually stops being restarted rather than
   * spin-looping forever. Defaults to `DEFAULT_MAX_RESPAWN_ATTEMPTS`.
   */
  maxRespawnAttempts?: number;
}

export class WhisperClientError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "WhisperClientError";
  }
}

const DEFAULT_READINESS_TIMEOUT_MS = 30_000;
const DEFAULT_POLL_INTERVAL_MS = 200;
const DEFAULT_MAX_RESPAWN_ATTEMPTS = 3;

export class WhisperClient {
  private readonly socketPath: string;
  private readonly extraEnv: NodeJS.ProcessEnv;
  private readonly readinessTimeoutMs: number;
  private readonly pollIntervalMs: number;
  private readonly maxRespawnAttempts: number;
  private readonly factories: WhisperClientFactories;
  private process: SpawnedProcess | null = null;
  /** Set by `stop()` (or a readiness abort) so an ensuing exit never respawns. */
  private stopped = false;
  /** How many times a dead child has been respawned over this client's life. */
  private respawnCount = 0;

  constructor(options: WhisperClientOptions, factories: WhisperClientFactories) {
    this.socketPath = options.socketPath;
    this.extraEnv = options.extraEnv ?? {};
    this.readinessTimeoutMs = options.readinessTimeoutMs ?? DEFAULT_READINESS_TIMEOUT_MS;
    this.pollIntervalMs = options.pollIntervalMs ?? DEFAULT_POLL_INTERVAL_MS;
    this.maxRespawnAttempts = options.maxRespawnAttempts ?? DEFAULT_MAX_RESPAWN_ATTEMPTS;
    this.factories = factories;
  }

  /**
   * Spawns the python whisper server and blocks until it answers `/health`
   * healthily. Readiness is governed by `decideReadinessAction` (see
   * `lifecycle.ts`): a still-alive process that hasn't gone healthy yet keeps
   * being waited on -- even past `readinessTimeoutMs` -- rather than being
   * killed, so a slow first-launch model download isn't aborted mid-flight.
   * We only give up (kill + throw `WhisperClientError`) once the process is
   * observed to be dead, or -- for a `SpawnedProcess` that can't report exit
   * (`onExit` absent, e.g. legacy fakes) -- once the readiness timeout elapses,
   * preserving the original timeout semantics for that case.
   */
  async start(): Promise<void> {
    this.stopped = false;
    this.respawnCount = 0;

    const process = this.spawnAndTrack();
    // Whether this process can tell us when it dies. Without an `onExit` hook
    // we can't distinguish "still downloading" from "already dead", so we fall
    // back to the original behavior: treat it as alive until the readiness
    // timeout, then abort.
    const canObserveExit = typeof process.onExit === "function";

    const maxAttempts = Math.max(
      1,
      Math.ceil(this.readinessTimeoutMs / this.pollIntervalMs)
    );

    for (let attempt = 0; ; attempt++) {
      const healthy = await this.factories.checkHealth(this.socketPath);
      const timedOut = attempt + 1 >= maxAttempts;
      const processAlive = canObserveExit ? this.process !== null : !timedOut;

      const action = decideReadinessAction({ healthy, processAlive, timedOut });
      if (action === "ready") {
        return;
      }
      if (action === "abort") {
        this.stop();
        throw new WhisperClientError(
          "The local MLX-Whisper server exited or timed out before becoming ready."
        );
      }
      // "wait": still alive and not yet healthy -- keep polling. When the
      // readiness timeout has elapsed but the process is genuinely alive
      // (e.g. downloading the model on first launch) surface progress once
      // rather than killing it.
      if (timedOut && !this.warnedSlowStartup) {
        this.warnedSlowStartup = true;
        console.warn(
          "local MLX-Whisper server is taking longer than expected to become ready " +
            "(likely downloading the model on first launch); still waiting."
        );
      }
      await this.factories.sleep(this.pollIntervalMs);
    }
  }

  private warnedSlowStartup = false;

  /**
   * Spawns a fresh python process, records it as current, and -- if the
   * spawned process supports it -- registers an exit hook so an unexpected
   * runtime death triggers a bounded respawn (P1-5).
   */
  private spawnAndTrack(): SpawnedProcess {
    const env: NodeJS.ProcessEnv = {
      ...this.extraEnv,
      OPENTYPE_WHISPER_SOCKET: this.socketPath,
    };
    const process = this.factories.spawnProcess(env);
    this.process = process;
    process.onExit?.(() => this.handleUnexpectedExit(process));
    return process;
  }

  /**
   * Called when a spawned child exits. Respawns (up to `maxRespawnAttempts`)
   * only when the exit was unexpected -- an exit that follows an intentional
   * `stop()` never respawns, keyed off the `stopped` flag rather than the exit
   * code (a real `kill()` reports a signal/null, not a clean 0).
   */
  private handleUnexpectedExit(process: SpawnedProcess): void {
    // A stale exit from a child we already replaced or killed -- ignore.
    if (this.process !== process) return;
    this.process = null;
    if (this.stopped) return;
    if (this.respawnCount >= this.maxRespawnAttempts) return;
    this.respawnCount += 1;
    this.spawnAndTrack();
  }

  /** Kills the running python process, if any. Safe to call multiple times. */
  stop(): void {
    this.stopped = true;
    this.process?.kill();
    this.process = null;
  }

  /**
   * Sends raw WAV bytes to the running whisper server and returns the
   * transcript. Both options end up as `mlx_whisper.transcribe` keyword
   * arguments (`initial_prompt=` for decoding bias, `language=` to pin the
   * spoken language); each is independent, so setting one never drops the
   * other.
   */
  async transcribe(
    audio: Uint8Array,
    options: WhisperTranscribeOptions = {}
  ): Promise<string> {
    const { text } = await this.factories.postAudio(
      this.socketPath,
      audio,
      options.initialPrompt,
      options.language
    );
    return text;
  }
}

interface DefaultFactoryOptions {
  /** Path to the venv's python3 binary. Relative paths resolve against `cwd`. */
  pythonBin?: string;
  /** Path to `serve.py`. Relative paths resolve against `cwd`. */
  scriptPath?: string;
}

/**
 * Directories `mlx_whisper.transcribe()` needs on `PATH` at runtime that a
 * GUI-launched app doesn't reliably have: it shells out to `ffmpeg` for
 * every transcription (via openai-whisper's `load_audio`, which mlx-whisper
 * reuses), unconditionally, regardless of input format. When OpenType.app is
 * launched via LaunchServices (`open`, Finder double-click, Dock), it
 * inherits macOS's minimal default PATH (roughly `/usr/bin:/bin:/usr/sbin:
 * /sbin` plus a couple of Apple entries) rather than an interactive shell's
 * PATH, which is where Homebrew's `ffmpeg` normally lives on Apple Silicon
 * (`/opt/homebrew/bin`) -- this bit a real transcription request in testing:
 * `{"error": "[Errno 2] No such file or directory: 'ffmpeg'"}`, even though
 * the exact same binary transcribed correctly moments earlier when a
 * differently-launched (dev-mode) sidecar process happened to inherit a
 * richer PATH. Appending these directories (only if not already present)
 * fixes it regardless of how the app was launched.
 */
const FFMPEG_SEARCH_DIRECTORIES = [
  "/opt/homebrew/bin",
  "/opt/homebrew/sbin",
  "/usr/local/bin",
];

/** Pure/exported so the augmentation logic is directly unit-testable. */
export function augmentPathForFfmpeg(existingPath: string | undefined): string {
  const entries = (existingPath ?? "").split(":").filter((entry) => entry.length > 0);
  for (const directory of FFMPEG_SEARCH_DIRECTORIES) {
    if (!entries.includes(directory)) {
      entries.push(directory);
    }
  }
  return entries.join(":");
}

/**
 * Real, Bun-backed factories: spawns `whisper-env/bin/python3 whisper/serve.py`
 * (paths relative to the sidecar source directory, matching how
 * `sidecar/whisper-env/` and `sidecar/whisper/serve.py` are laid out next to
 * `sidecar/src/`) and talks HTTP-over-unix-socket via Bun's `fetch(url, {unix})`
 * extension -- Bun can speak to unix sockets directly, unlike `URLSession` on
 * the Swift side, which is why `SidecarClient.swift` has to shell out to `curl`
 * but this client doesn't need to.
 */
export function defaultWhisperClientFactories(
  options: DefaultFactoryOptions = {}
): WhisperClientFactories {
  const pythonBin = options.pythonBin ?? "whisper-env/bin/python3";
  const scriptPath = options.scriptPath ?? "whisper/serve.py";

  return {
    spawnProcess: (env) => {
      const mergedEnv = { ...process.env, ...env } as Record<string, string>;
      mergedEnv.PATH = augmentPathForFfmpeg(mergedEnv.PATH);
      const proc = Bun.spawn([pythonBin, scriptPath], {
        env: mergedEnv,
        stdout: "inherit",
        stderr: "inherit",
      });
      return {
        pid: proc.pid,
        kill: () => proc.kill(),
        // Bun exposes the child's termination as the `exited` promise; bridge
        // it to the `SpawnedProcess.onExit` hook `WhisperClient` uses to detect
        // an unexpected death and respawn.
        onExit: (cb) => {
          proc.exited.then((code) => cb(code)).catch(() => cb(null));
        },
      };
    },
    checkHealth: async (socketPath) => {
      try {
        const response = await fetch("http://localhost/health", {
          unix: socketPath,
        } as RequestInit);
        if (!response.ok) return false;
        const body = (await response.json()) as { status?: string };
        return body.status === "ok";
      } catch {
        return false;
      }
    },
    postAudio: async (socketPath, audio, initialPrompt, language) => {
      // Both decode options travel as percent-encoded query parameters rather
      // than headers because headers must be latin-1 safe and the dictionary is
      // full of CJK terms. `serve.py`'s `_path_only()` already strips the query
      // before routing, so this doesn't disturb path matching. An unset option
      // contributes no parameter at all -- `?initial_prompt=` / `?language=`
      // would reach mlx_whisper as "" instead of the default None, and for
      // language that is the difference between "detect it yourself" and a
      // language literally named "".
      const params: string[] = [];
      if (initialPrompt) {
        params.push(`initial_prompt=${encodeURIComponent(initialPrompt)}`);
      }
      if (language) {
        params.push(`language=${encodeURIComponent(language)}`);
      }
      const url =
        params.length > 0
          ? `http://localhost/transcribe?${params.join("&")}`
          : "http://localhost/transcribe";
      const response = await fetch(url, {
        method: "POST",
        body: audio,
        unix: socketPath,
        headers: { "Content-Type": "audio/wav" },
      } as RequestInit);
      if (!response.ok) {
        const errorText = await response.text().catch(() => "");
        throw new WhisperClientError(
          `Whisper server returned HTTP ${response.status}: ${errorText}`
        );
      }
      return (await response.json()) as { text: string };
    },
    sleep: (ms) => new Promise((resolve) => setTimeout(resolve, ms)),
  };
}
