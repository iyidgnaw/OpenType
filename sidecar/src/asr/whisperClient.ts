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

export interface SpawnedProcess {
  readonly pid?: number;
  kill(): void;
}

/**
 * Everything `WhisperClient` needs from the outside world, factored out so
 * tests can inject fakes. `defaultWhisperClientFactories()` below provides
 * the real, Bun-backed implementation used in production.
 */
export interface WhisperClientFactories {
  spawnProcess: (env: NodeJS.ProcessEnv) => SpawnedProcess;
  checkHealth: (socketPath: string) => Promise<boolean>;
  postAudio: (socketPath: string, audio: Uint8Array) => Promise<{ text: string }>;
  sleep: (ms: number) => Promise<void>;
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
}

export class WhisperClientError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "WhisperClientError";
  }
}

const DEFAULT_READINESS_TIMEOUT_MS = 30_000;
const DEFAULT_POLL_INTERVAL_MS = 200;

export class WhisperClient {
  private readonly socketPath: string;
  private readonly extraEnv: NodeJS.ProcessEnv;
  private readonly readinessTimeoutMs: number;
  private readonly pollIntervalMs: number;
  private readonly factories: WhisperClientFactories;
  private process: SpawnedProcess | null = null;

  constructor(options: WhisperClientOptions, factories: WhisperClientFactories) {
    this.socketPath = options.socketPath;
    this.extraEnv = options.extraEnv ?? {};
    this.readinessTimeoutMs = options.readinessTimeoutMs ?? DEFAULT_READINESS_TIMEOUT_MS;
    this.pollIntervalMs = options.pollIntervalMs ?? DEFAULT_POLL_INTERVAL_MS;
    this.factories = factories;
  }

  /**
   * Spawns the python whisper server (if not already running) and blocks
   * until it answers `/health` healthily, or throws `WhisperClientError`
   * after `readinessTimeoutMs`. On timeout, the spawned process is killed
   * rather than left running unsupervised.
   */
  async start(): Promise<void> {
    const env: NodeJS.ProcessEnv = {
      ...this.extraEnv,
      OPENTYPE_WHISPER_SOCKET: this.socketPath,
    };
    const process = this.factories.spawnProcess(env);
    this.process = process;

    const maxAttempts = Math.max(1, Math.ceil(this.readinessTimeoutMs / this.pollIntervalMs));
    for (let attempt = 0; attempt < maxAttempts; attempt++) {
      if (await this.factories.checkHealth(this.socketPath)) {
        return;
      }
      await this.factories.sleep(this.pollIntervalMs);
    }

    process.kill();
    this.process = null;
    throw new WhisperClientError(
      "Timed out waiting for the local MLX-Whisper server to become ready."
    );
  }

  /** Kills the running python process, if any. Safe to call multiple times. */
  stop(): void {
    this.process?.kill();
    this.process = null;
  }

  /** Sends raw WAV bytes to the running whisper server and returns the transcript. */
  async transcribe(audio: Uint8Array): Promise<string> {
    const { text } = await this.factories.postAudio(this.socketPath, audio);
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
    postAudio: async (socketPath, audio) => {
      const response = await fetch("http://localhost/transcribe", {
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
