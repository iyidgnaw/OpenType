/**
 * STAGE-1 (red) tests pinning P1-5: the local MLX-Whisper python process must
 * be respawned (bounded retries) if it dies at runtime, instead of leaving
 * local ASR permanently dead until the sidecar is restarted.
 *
 * Desired seam additions to `src/asr/whisperClient.ts` (implement stage):
 *
 *   export interface SpawnedProcess {
 *     readonly pid?: number;
 *     kill(): void;
 *     // NEW: register a handler invoked when the child exits unexpectedly.
 *     onExit?(cb: (code: number | null) => void): void;
 *   }
 *
 *   export interface WhisperClientOptions {
 *     ...
 *     // NEW: cap on how many times a dead child is respawned before giving up.
 *     maxRespawnAttempts?: number;
 *   }
 *
 * After `start()` succeeds, WhisperClient is expected to register an exit
 * handler on the spawned process. On an unexpected exit it respawns (a fresh
 * `spawnProcess` call) up to `maxRespawnAttempts` times, then gives up.
 *
 * These tests drive a fully controllable fake process so nothing real is
 * spawned; each fake exposes `triggerExit()` to simulate the python process
 * dying. RED today because the current WhisperClient never observes child
 * exit, so no respawn is ever attempted.
 */
import { describe, expect, test } from "bun:test";
import {
  WhisperClient,
  type WhisperClientFactories,
} from "../../src/asr/whisperClient";

interface FakeProcess {
  pid: number;
  killed: boolean;
  exitHandlers: Array<(code: number | null) => void>;
  triggerExit: (code?: number | null) => void;
  kill: () => void;
  onExit: (cb: (code: number | null) => void) => void;
}

/**
 * Builds a factory set whose `spawnProcess` records and returns a fresh
 * controllable fake each time. `processes` lets the test inspect how many
 * spawns happened and drive an exit on whichever process is "current".
 */
function makeRespawnFactories(
  overrides: Partial<WhisperClientFactories> = {}
): {
  factories: WhisperClientFactories;
  processes: FakeProcess[];
} {
  const processes: FakeProcess[] = [];

  const factories: WhisperClientFactories = {
    spawnProcess: () => {
      const exitHandlers: Array<(code: number | null) => void> = [];
      const fake: FakeProcess = {
        pid: 1000 + processes.length,
        killed: false,
        exitHandlers,
        triggerExit: (code = 1) => {
          for (const handler of exitHandlers) handler(code);
        },
        kill: () => {
          fake.killed = true;
        },
        onExit: (cb) => {
          exitHandlers.push(cb);
        },
      };
      processes.push(fake);
      // The desired `SpawnedProcess` shape (pid/kill/onExit); returned as the
      // factory's SpawnedProcess. Extra fields are ignored by production code.
      return fake as unknown as ReturnType<WhisperClientFactories["spawnProcess"]>;
    },
    checkHealth: async () => true,
    postAudio: async () => ({ text: "" }),
    sleep: async () => {},
    ...overrides,
  };

  return { factories, processes };
}

/** Let any microtasks/timers scheduled by a respawn settle. */
async function flush(): Promise<void> {
  for (let i = 0; i < 3; i++) {
    await new Promise((resolve) => setTimeout(resolve, 5));
  }
}

describe("WhisperClient respawn (P1-5 whisper process death)", () => {
  test("respawns the python process when it exits unexpectedly", async () => {
    const { factories, processes } = makeRespawnFactories();
    const client = new WhisperClient(
      { socketPath: "/tmp/whisper-respawn.sock", pollIntervalMs: 1, maxRespawnAttempts: 3 },
      factories
    );

    await client.start();
    expect(processes).toHaveLength(1);

    // Simulate the python process dying at runtime.
    processes[0]!.triggerExit(1);
    await flush();

    // A replacement process should have been spawned.
    expect(processes.length).toBeGreaterThanOrEqual(2);
  });

  test("respawns up to the cap and then gives up", async () => {
    const { factories, processes } = makeRespawnFactories();
    const client = new WhisperClient(
      { socketPath: "/tmp/whisper-respawn.sock", pollIntervalMs: 1, maxRespawnAttempts: 2 },
      factories
    );

    await client.start();
    expect(processes).toHaveLength(1);

    // Kill the current process repeatedly; each death should trigger a respawn
    // until the cap (2) is reached, after which no further spawn happens.
    for (let i = 0; i < 5; i++) {
      processes[processes.length - 1]!.triggerExit(1);
      await flush();
    }

    // 1 initial spawn + at most 2 respawns.
    expect(processes).toHaveLength(3);
  });

  test("does not respawn after an intentional stop()", async () => {
    const { factories, processes } = makeRespawnFactories();
    const client = new WhisperClient(
      { socketPath: "/tmp/whisper-respawn.sock", pollIntervalMs: 1, maxRespawnAttempts: 3 },
      factories
    );

    await client.start();
    expect(processes).toHaveLength(1);

    client.stop();
    // An exit that arrives as a consequence of our own stop() must not respawn —
    // even when it carries the SAME code as an unexpected death (a real kill()
    // reports a signal/null code, not 0), so suppression must key off the
    // intentional-stop flag, not the exit code.
    processes[0]!.triggerExit(1);
    await flush();

    expect(processes).toHaveLength(1);
  });
});
