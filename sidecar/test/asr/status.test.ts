/**
 * STAGE-1 (red) tests for §E-2 of
 * `docs/superpowers/specs/2026-08-15-product-batch-plan.md`: `GET /asr/status`,
 * the sidecar's proxy over `serve.py`'s model-load state.
 *
 * ---------------------------------------------------------------------------
 * Why the sidecar needs its own endpoint rather than Swift talking to serve.py
 * ---------------------------------------------------------------------------
 *
 * Two facts Swift cannot observe and serve.py cannot answer:
 *
 *  - **The python child may not exist yet.** `main()` spawns it and does not
 *     await readiness (see `server.ts`'s `whisperReady` comment). During that
 *     window a request to serve.py's socket is a connection refused, which is
 *     not an error — it is `"starting"`, a fifth state that only the parent can
 *     report because the child is not there to report it.
 *  - **The user may have configured remote Whisper**, in which case there is no
 *     local model, no download, and nothing to wait for. `{"state":"ready",
 *     "backend":"remote"}` is the whole answer, and a remote user must never be
 *     shown a 460 MB progress bar for a file they will never fetch.
 *
 * ---------------------------------------------------------------------------
 * The contract stage 3 must implement, in `sidecar/src/asr/statusRoutes.ts`
 * ---------------------------------------------------------------------------
 *
 *   export type WhisperBackend = "local" | "remote";
 *   export type WhisperModelState =
 *     | "starting" | "downloading" | "loading" | "ready" | "failed";
 *
 *   // Exactly serve.py's GET /status body.
 *   export interface LocalWhisperStatus {
 *     state: "downloading" | "loading" | "ready" | "failed";
 *     model: string;
 *     downloadedBytes: number;
 *     totalBytes: number | null;
 *     error: string | null;
 *   }
 *
 *   export interface AsrStatusDeps {
 *     // "remote" iff `shouldStartLocalWhisper` (src/lifecycle.ts) says no python
 *     // child was spawned — i.e. the user explicitly SAVED `mode: "remote"`.
 *     // Reuse that predicate rather than writing a second one: this endpoint
 *     // answers 「有没有一个本地模型在起来」, and that function is what decided it.
 *     // NOT `resolveTranscribe`'s rule, which additionally requires a baseUrl +
 *     // apiKey — keying off that one would report "local", and poll for a
 *     // download, for a saved remote config with a missing key, when there is
 *     // no local child in existence to ask.
 *     backend(): WhisperBackend;
 *     // serve.py's GET /status over the whisper unix socket. Rejects when the
 *     // child is not up (connection refused) or answers unusably.
 *     localStatus(): Promise<LocalWhisperStatus>;
 *   }
 *
 *   export function buildAsrStatusRoutes(deps: AsrStatusDeps): Route[];
 *
 * A NEW module rather than a `buildAsrRoutes` addition, for the ordinary
 * reason: `asr/routes.ts` is the transcription request path and this is a
 * polled status read with entirely different dependencies. Same split as
 * `provider/routes.ts` vs `agent/mcpConfigRoutes.ts`.
 *
 * Three decisions this file makes on stage 3's behalf, deliberately:
 *
 * 1. **It always answers 200.** Every branch — child down, load failed,
 *    unparseable body — is a *state*, not an HTTP failure. The Swift poller
 *    backs off on transport failure (`WhisperStatusPolling.decide`), so a 500
 *    here would make 「python 还没起来」 indistinguishable from 「sidecar 挂了」 and
 *    push the poller into backoff during the exact seconds it should be
 *    counting bytes.
 * 2. **`backend: "remote"` short-circuits before `localStatus()` is called.**
 *    Not just "returns the right body" — it must not touch the local socket at
 *    all. `shouldStartLocalWhisper` means there is no child process to ask, so
 *    asking buys a guaranteed connection-refused round trip on every poll.
 * 3. **`totalBytes: null` survives as `null`, never as `0` or a missing key.**
 *    §E-1 is explicit that an unknown total degrades the *bar*, not the state
 *    machine. `0` renders as a bar frozen at 0%, which is the blank screen this
 *    whole section exists to remove, wearing a progress indicator.
 */
import { describe, expect, test } from "bun:test";
import { createRouter } from "../../src/router";
import {
  buildAsrStatusRoutes,
  type AsrStatusDeps,
  type LocalWhisperStatus,
} from "../../src/asr/statusRoutes";

function makeApp(deps: Partial<AsrStatusDeps> = {}) {
  const full: AsrStatusDeps = {
    backend: () => "local",
    localStatus: async () => localStatus(),
    ...deps,
  };
  return createRouter(buildAsrStatusRoutes(full));
}

function localStatus(
  overrides: Partial<LocalWhisperStatus> = {}
): LocalWhisperStatus {
  return {
    state: "ready",
    model: "mlx-community/whisper-small-mlx",
    downloadedBytes: 460_000_000,
    totalBytes: 460_000_000,
    error: null,
    ...overrides,
  };
}

async function get(app: ReturnType<typeof createRouter>) {
  const response = await app(new Request("http://localhost/asr/status"));
  return { status: response.status, json: (await response.json()) as Record<string, unknown> };
}

// ---------------------------------------------------------------------------
// Remote: never a progress bar
// ---------------------------------------------------------------------------

describe("GET /asr/status with remote Whisper configured", () => {
  test("answers ready/remote and nothing else", async () => {
    const { status, json } = await get(makeApp({ backend: () => "remote" }));

    expect(status).toBe(200);
    // Strict: no model, no byte counts, no error key. A remote user has no
    // local model, and any of those fields present is something the UI could
    // render as a download they are not doing.
    expect(json).toEqual({ state: "ready", backend: "remote" });
  });

  test("does not consult the local whisper socket at all", async () => {
    let localCalls = 0;
    const app = makeApp({
      backend: () => "remote",
      localStatus: async () => {
        localCalls += 1;
        return localStatus();
      },
    });

    await get(app);

    // There is no python child in a remote configuration
    // (`shouldStartLocalWhisper`), so this call could only ever be a
    // connection-refused round trip — once per poll, forever.
    expect(localCalls).toBe(0);
  });

  test("re-reads the backend per request rather than capturing it at build time", async () => {
    // The routes are built once at boot; the user can switch to remote Whisper
    // from Settings at any moment afterwards. A captured value would report the
    // boot-time backend for the life of the process.
    let backend: "local" | "remote" = "local";
    const app = makeApp({
      backend: () => backend,
      localStatus: async () => localStatus({ state: "downloading" }),
    });

    expect((await get(app)).json.backend).toBe("local");
    backend = "remote";
    expect((await get(app)).json).toEqual({ state: "ready", backend: "remote" });
  });
});

// ---------------------------------------------------------------------------
// Local: proxy serve.py
// ---------------------------------------------------------------------------

describe("GET /asr/status with local Whisper", () => {
  test("proxies a download in progress, byte counts intact", async () => {
    const app = makeApp({
      localStatus: async () =>
        localStatus({
          state: "downloading",
          downloadedBytes: 123_456_789,
          totalBytes: 460_000_000,
        }),
    });

    const { status, json } = await get(app);

    expect(status).toBe(200);
    expect(json).toEqual({
      state: "downloading",
      backend: "local",
      model: "mlx-community/whisper-small-mlx",
      downloadedBytes: 123_456_789,
      totalBytes: 460_000_000,
    });
  });

  test("keeps an unknown total as null rather than 0", async () => {
    const app = makeApp({
      localStatus: async () =>
        localStatus({ state: "downloading", downloadedBytes: 8_192, totalBytes: null }),
    });

    const { json } = await get(app);

    expect(json.totalBytes).toBeNull();
    expect(json.downloadedBytes).toBe(8_192);
    expect(json.state).toBe("downloading");
  });

  test("proxies the loading state", async () => {
    const app = makeApp({ localStatus: async () => localStatus({ state: "loading" }) });

    const { json } = await get(app);

    expect(json.state).toBe("loading");
    expect(json.backend).toBe("local");
  });

  test("proxies ready without inventing an error key", async () => {
    const app = makeApp({ localStatus: async () => localStatus({ state: "ready" }) });

    const { json } = await get(app);

    expect(json.state).toBe("ready");
    expect(json.backend).toBe("local");
    expect("error" in json).toBe(false);
  });

  test("passes a failed load's real error text through verbatim", async () => {
    // Same stance as a failed MCP server's `lastStartupError`: 「No space left on
    // device」 tells the user what to fix, 「模型加载失败」 does not — and §E-3's
    // failure surface (重试 / 改用远程识别) is chosen by the user, so it has to
    // say what went wrong.
    const app = makeApp({
      localStatus: async () =>
        localStatus({
          state: "failed",
          downloadedBytes: 300_000_000,
          error: "OSError: [Errno 28] No space left on device",
        }),
    });

    const { status, json } = await get(app);

    expect(status).toBe(200);
    expect(json.state).toBe("failed");
    expect(json.error).toContain("No space left on device");
    // The partial download is kept: 「下到 300 MB 断了」 and 「一个字节都没下到」
    // are different problems.
    expect(json.downloadedBytes).toBe(300_000_000);
  });

  test("reports starting — not an error — while the python child is not up yet", async () => {
    // `main()` spawns whisper without awaiting readiness, so a connection
    // refused here is the ordinary first second of every launch.
    const app = makeApp({
      localStatus: async () => {
        throw new Error("connect ECONNREFUSED /tmp/opentype-whisper.sock");
      },
    });

    const { status, json } = await get(app);

    expect(status).toBe(200);
    expect(json).toEqual({ state: "starting", backend: "local" });
  });

  test("reports starting when serve.py answers something unusable", async () => {
    // An old serve.py without /status 404s, and the fetch wrapper rejects. That
    // is a child that is up but not answering this contract yet — same user-
    // visible situation as not up at all, and never a 5xx out of this route.
    const app = makeApp({
      localStatus: async () => {
        throw new SyntaxError("Unexpected token < in JSON at position 0");
      },
    });

    const { status, json } = await get(app);

    // Note the router maps a raw SyntaxError to 400; this handler must catch it
    // before it gets there.
    expect(status).toBe(200);
    expect(json.state).toBe("starting");
  });

  test("re-reads serve.py's status per request", async () => {
    const states: LocalWhisperStatus["state"][] = ["downloading", "loading", "ready"];
    let index = 0;
    const app = makeApp({
      localStatus: async () => localStatus({ state: states[index++]! }),
    });

    expect((await get(app)).json.state).toBe("downloading");
    expect((await get(app)).json.state).toBe("loading");
    expect((await get(app)).json.state).toBe("ready");
  });
});

// ---------------------------------------------------------------------------
// Wiring
// ---------------------------------------------------------------------------

describe("route registration", () => {
  test("is a GET on /asr/status", async () => {
    const routes = buildAsrStatusRoutes({
      backend: () => "local",
      localStatus: async () => localStatus(),
    });

    expect(routes.map((route) => `${route.method} ${route.path}`)).toEqual([
      "GET /asr/status",
    ]);
  });

  test("does not answer other methods on the same path", async () => {
    const app = makeApp();

    const response = await app(
      new Request("http://localhost/asr/status", { method: "POST" })
    );

    expect(response.status).toBe(404);
  });
});
