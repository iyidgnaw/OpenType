/**
 * Pure/injectable decision seams for the sidecar's process lifecycle. These
 * hold the *policy* (what to do) while the actual side effects (probing a live
 * unix socket, spawning/killing the python process, calling `Bun.serve`) stay
 * in `server.ts`/`asr/whisperClient.ts`. Keeping the decisions here makes them
 * directly unit-testable without touching a real socket or process -- the same
 * dependency-injection pattern `agent/mcpClient.ts` and `asr/whisperClient.ts`
 * already use.
 */

/** Probes `decideSocketStartup` needs to inspect an existing socket path. */
export interface SocketStartupProbes {
  /** Whether a file (socket or leftover) exists at `path`. */
  exists: (path: string) => boolean;
  /** True iff a live listener is currently accepting connections on `path`. */
  isServed: (path: string) => Promise<boolean>;
}

/**
 * P1-9 single-instance guard: decide whether it's safe to unlink + bind the
 * sidecar's unix socket.
 *
 *  - No file present            -> "proceed" (nothing to probe or stomp).
 *  - File present, live listener -> "refuse" (another instance owns it).
 *  - File present, no listener   -> "proceed" (stale file from a crash).
 *
 * Only probes liveness when the file actually exists, so an absent path never
 * incurs a connect attempt.
 */
export async function decideSocketStartup(
  socketPath: string,
  probes: SocketStartupProbes
): Promise<"proceed" | "refuse"> {
  if (!probes.exists(socketPath)) {
    return "proceed";
  }
  const served = await probes.isServed(socketPath);
  return served ? "refuse" : "proceed";
}

/** P1-8 readiness outcome while a slow first-launch model download is underway. */
export type ReadinessAction = "ready" | "wait" | "abort";

/**
 * P1-8 readiness/liveness decision during first-launch model download.
 *
 *  - healthy                        -> "ready".
 *  - not healthy, process dead      -> "abort" (nothing left to wait for).
 *  - not healthy, process alive     -> "wait" (keep waiting / report progress),
 *    *even if the readiness timeout already elapsed*: the crux of the bug this
 *    fixes is that a still-alive process merely downloading the model on first
 *    launch must not be killed just because the timeout fired.
 */
export function decideReadinessAction(input: {
  healthy: boolean;
  processAlive: boolean;
  timedOut: boolean;
}): ReadinessAction {
  if (input.healthy) {
    return "ready";
  }
  if (!input.processAlive) {
    return "abort";
  }
  return "wait";
}

/**
 * P2: decide whether to spawn the local MLX-Whisper python process.
 *
 * Local MLX is the always-available zero-config default, so it starts whenever
 * whisper isn't *explicitly* configured for remote. `whisperConfigured` is the
 * explicit-save flag (see `provider/configStore.ts`): only when the user
 * actually saved a config selecting `mode: "remote"` do we skip local. An
 * unsaved remote-ish mode (`whisperConfigured: false`) never suppresses the
 * local default.
 */
export function shouldStartLocalWhisper(input: {
  whisperConfigured: boolean;
  mode?: "local" | "remote";
}): boolean {
  return !(input.whisperConfigured && input.mode === "remote");
}
