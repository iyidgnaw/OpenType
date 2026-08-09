import { describe, expect, test } from "bun:test";
import {
  WhisperClient,
  WhisperClientError,
  augmentPathForFfmpeg,
  type SpawnedProcess,
  type WhisperClientFactories,
} from "../../src/asr/whisperClient";

describe("augmentPathForFfmpeg", () => {
  test("appends common Homebrew/local bin directories not already present", () => {
    const result = augmentPathForFfmpeg("/usr/bin:/bin");
    const entries = result.split(":");
    expect(entries).toContain("/usr/bin");
    expect(entries).toContain("/bin");
    expect(entries).toContain("/opt/homebrew/bin");
    expect(entries).toContain("/usr/local/bin");
  });

  test("does not duplicate a directory already present in PATH", () => {
    const result = augmentPathForFfmpeg("/opt/homebrew/bin:/usr/bin");
    const entries = result.split(":");
    expect(entries.filter((entry) => entry === "/opt/homebrew/bin")).toHaveLength(1);
  });

  test("handles an undefined/empty starting PATH", () => {
    const result = augmentPathForFfmpeg(undefined);
    expect(result.split(":")).toContain("/opt/homebrew/bin");
  });
});

function makeFakeProcess() {
  let killed = false;
  const process: SpawnedProcess = {
    pid: 1234,
    kill: () => {
      killed = true;
    },
  };
  return { process, isKilled: () => killed };
}

/**
 * Builds a factory set with every dependency stubbed and overridable, mirroring
 * `mcpClient.test.ts`'s `makeFactories` helper: production code depends on an
 * injected `WhisperClientFactories`, so none of these tests spawn a real
 * python process or touch a real socket.
 */
function makeFactories(
  overrides: Partial<WhisperClientFactories> = {}
): WhisperClientFactories & { spawnCalls: NodeJS.ProcessEnv[]; sleepCalls: number[] } {
  const spawnCalls: NodeJS.ProcessEnv[] = [];
  const sleepCalls: number[] = [];
  const { process: fakeProcess } = makeFakeProcess();

  return {
    spawnProcess: (env) => {
      spawnCalls.push(env);
      return fakeProcess;
    },
    checkHealth: async () => true,
    postAudio: async () => ({ text: "" }),
    sleep: async (ms) => {
      sleepCalls.push(ms);
    },
    spawnCalls,
    sleepCalls,
    ...overrides,
  };
}

describe("WhisperClient.start", () => {
  test("spawns the python process with the socket path in its environment", async () => {
    const factories = makeFactories();
    const client = new WhisperClient({ socketPath: "/tmp/whisper-test.sock" }, factories);

    await client.start();

    expect(factories.spawnCalls).toHaveLength(1);
    expect(factories.spawnCalls[0]!.OPENTYPE_WHISPER_SOCKET).toBe("/tmp/whisper-test.sock");
  });

  test("polls checkHealth until it reports healthy, sleeping between attempts", async () => {
    let healthCalls = 0;
    const factories = makeFactories({
      checkHealth: async () => {
        healthCalls += 1;
        return healthCalls >= 3;
      },
    });
    const client = new WhisperClient(
      { socketPath: "/tmp/whisper-test.sock", pollIntervalMs: 10 },
      factories
    );

    await client.start();

    expect(healthCalls).toBe(3);
    expect(factories.sleepCalls).toEqual([10, 10]);
  });

  test("throws WhisperClientError and kills the process if never healthy within the timeout", async () => {
    const { process: fakeProcess, isKilled } = makeFakeProcess();
    const factories = makeFactories({
      spawnProcess: () => fakeProcess,
      checkHealth: async () => false,
    });
    const client = new WhisperClient(
      { socketPath: "/tmp/whisper-test.sock", readinessTimeoutMs: 30, pollIntervalMs: 10 },
      factories
    );

    await expect(client.start()).rejects.toBeInstanceOf(WhisperClientError);
    expect(isKilled()).toBe(true);
  });
});

describe("WhisperClient.stop", () => {
  test("kills the process started by start()", async () => {
    const { process: fakeProcess, isKilled } = makeFakeProcess();
    const factories = makeFactories({ spawnProcess: () => fakeProcess });
    const client = new WhisperClient({ socketPath: "/tmp/whisper-test.sock" }, factories);

    await client.start();
    client.stop();

    expect(isKilled()).toBe(true);
  });

  test("is a no-op when the process was never started", () => {
    const factories = makeFactories();
    const client = new WhisperClient({ socketPath: "/tmp/whisper-test.sock" }, factories);

    expect(() => client.stop()).not.toThrow();
  });
});

describe("WhisperClient.transcribe", () => {
  test("posts the audio bytes to the socket and returns the resulting text", async () => {
    let capturedSocketPath: string | undefined;
    let capturedAudio: Uint8Array | undefined;
    const factories = makeFactories({
      postAudio: async (socketPath, audio) => {
        capturedSocketPath = socketPath;
        capturedAudio = audio;
        return { text: "hello world" };
      },
    });
    const client = new WhisperClient({ socketPath: "/tmp/whisper-test.sock" }, factories);
    const audioBytes = new Uint8Array([1, 2, 3, 4]);

    const text = await client.transcribe(audioBytes);

    expect(text).toBe("hello world");
    expect(capturedSocketPath).toBe("/tmp/whisper-test.sock");
    expect(capturedAudio).toEqual(audioBytes);
  });

  test("propagates errors from postAudio", async () => {
    const factories = makeFactories({
      postAudio: async () => {
        throw new Error("whisper server returned HTTP 500: boom");
      },
    });
    const client = new WhisperClient({ socketPath: "/tmp/whisper-test.sock" }, factories);

    await expect(client.transcribe(new Uint8Array([1]))).rejects.toThrow("boom");
  });
});
