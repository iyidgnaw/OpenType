/**
 * STAGE-1 (red) tests pinning three sidecar-lifecycle decision seams the
 * implementer is expected to introduce in a new `src/lifecycle.ts` module.
 * These are deliberately *pure/injectable* decision functions -- the real
 * side effects (probing a live unix socket, spawning/killing the python
 * process, actually calling `Bun.serve`) stay out of the unit under test so
 * no test here touches a real socket or process.
 *
 * Desired seam (to be created by the implement stage):
 *
 *   // P1-9 single-instance guard
 *   export interface SocketStartupProbes {
 *     exists: (path: string) => boolean;
 *     // true iff a live listener is currently accepting connections on `path`
 *     isServed: (path: string) => Promise<boolean>;
 *   }
 *   export function decideSocketStartup(
 *     socketPath: string,
 *     probes: SocketStartupProbes
 *   ): Promise<"proceed" | "refuse">;
 *
 *   // P1-8 readiness/liveness during first-launch model download
 *   export type ReadinessAction = "ready" | "wait" | "abort";
 *   export function decideReadinessAction(input: {
 *     healthy: boolean;
 *     processAlive: boolean;
 *     timedOut: boolean;
 *   }): ReadinessAction;
 *
 *   // P2 skip local MLX when remote whisper is configured
 *   export function shouldStartLocalWhisper(input: {
 *     whisperConfigured: boolean;
 *     mode?: "local" | "remote";
 *   }): boolean;
 */
import { describe, expect, test } from "bun:test";
import {
  decideReadinessAction,
  decideSocketStartup,
  shouldStartLocalWhisper,
  type SocketStartupProbes,
} from "../src/lifecycle";

describe("decideSocketStartup (P1-9 single-instance guard)", () => {
  test("refuses to unlink/bind when the socket is already being served by a live instance", async () => {
    const probes: SocketStartupProbes = {
      exists: () => true,
      isServed: async () => true, // a live listener is accepting connections
    };

    const decision = await decideSocketStartup("/tmp/opentype.sock", probes);

    expect(decision).toBe("refuse");
  });

  test("proceeds when the socket file exists but is stale (no live listener)", async () => {
    const probes: SocketStartupProbes = {
      exists: () => true,
      isServed: async () => false, // leftover file from a crashed instance
    };

    const decision = await decideSocketStartup("/tmp/opentype.sock", probes);

    expect(decision).toBe("proceed");
  });

  test("proceeds when the socket file does not exist at all", async () => {
    let probedLiveness = false;
    const probes: SocketStartupProbes = {
      exists: () => false,
      isServed: async () => {
        probedLiveness = true;
        return false;
      },
    };

    const decision = await decideSocketStartup("/tmp/opentype.sock", probes);

    expect(decision).toBe("proceed");
    // No need to probe liveness when the file is absent.
    expect(probedLiveness).toBe(false);
  });
});

describe("decideReadinessAction (P1-8 first-launch download vs readiness timeout)", () => {
  test("returns 'ready' as soon as health reports healthy", () => {
    expect(
      decideReadinessAction({ healthy: true, processAlive: true, timedOut: false })
    ).toBe("ready");
  });

  test("keeps waiting (does NOT abort) when the timeout elapsed but the process is still alive and downloading", () => {
    // This is the crux of the bug: today the 30s timeout kills a live process
    // that is merely still downloading the model on first launch.
    expect(
      decideReadinessAction({ healthy: false, processAlive: true, timedOut: true })
    ).toBe("wait");
  });

  test("keeps waiting when not yet healthy, process alive, and not yet timed out", () => {
    expect(
      decideReadinessAction({ healthy: false, processAlive: true, timedOut: false })
    ).toBe("wait");
  });

  test("aborts when the process has actually died before becoming healthy", () => {
    expect(
      decideReadinessAction({ healthy: false, processAlive: false, timedOut: false })
    ).toBe("abort");
  });

  test("aborts when the process died even if the timeout also elapsed", () => {
    expect(
      decideReadinessAction({ healthy: false, processAlive: false, timedOut: true })
    ).toBe("abort");
  });
});

describe("shouldStartLocalWhisper (P2 skip local MLX when remote configured)", () => {
  test("does NOT start local MLX when whisper is explicitly configured as remote", () => {
    expect(
      shouldStartLocalWhisper({ whisperConfigured: true, mode: "remote" })
    ).toBe(false);
  });

  test("starts local MLX when whisper is explicitly configured as local", () => {
    expect(
      shouldStartLocalWhisper({ whisperConfigured: true, mode: "local" })
    ).toBe(true);
  });

  test("starts local MLX when nothing is configured yet (zero-config default)", () => {
    expect(shouldStartLocalWhisper({ whisperConfigured: false })).toBe(true);
  });

  test("starts local MLX when remote mode is present but was never actually saved/configured", () => {
    // `whisperConfigured` is the explicit-save flag; an un-saved remote-ish
    // config must not suppress the always-available local default.
    expect(
      shouldStartLocalWhisper({ whisperConfigured: false, mode: "remote" })
    ).toBe(true);
  });
});
