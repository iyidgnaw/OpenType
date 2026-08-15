/**
 * `GET /asr/status` — how far the local speech model has got to loading.
 *
 * Swift polls this so the first launch stops being a blank screen. Two things
 * it reports that `serve.py` cannot report about itself:
 *
 *  - **The python child may not exist yet.** `main()` spawns whisper without
 *    awaiting readiness, so a connection refused on its socket is not an error;
 *    it is `"starting"`, the one state only the parent can observe because the
 *    child is not there to describe it.
 *  - **The user may have configured remote Whisper**, in which case there is no
 *    local model, no download, and nothing to wait for. A remote user must
 *    never be shown a 460 MB progress bar for a file they will never fetch.
 *
 * A separate module from `asr/routes.ts` for the ordinary reason: that one is
 * the transcription request path, this is a polled status read with entirely
 * different dependencies — the same split as `provider/routes.ts` against
 * `agent/mcpConfigRoutes.ts`.
 */
import type { Route } from "../router";

export type WhisperBackend = "local" | "remote";

export type WhisperModelState =
  | "starting"
  | "downloading"
  | "loading"
  | "ready"
  | "failed";

/** Exactly the body of `serve.py`'s `GET /status`. */
export interface LocalWhisperStatus {
  state: "downloading" | "loading" | "ready" | "failed";
  model: string;
  downloadedBytes: number;
  totalBytes: number | null;
  error: string | null;
}

export interface AsrStatusDeps {
  /**
   * `"remote"` exactly when `shouldStartLocalWhisper` (`src/lifecycle.ts`) says
   * no python child was spawned — i.e. the user explicitly saved
   * `mode: "remote"`.
   *
   * Deliberately that predicate and not `resolveTranscribe`'s, which
   * additionally demands a baseUrl and apiKey: a saved remote config with a
   * missing key would key off that one as "local" and poll for a download,
   * while there is no local child in existence to ask.
   *
   * A getter, because the routes are built once at boot and the user can switch
   * backends from Settings at any point afterwards.
   */
  backend(): WhisperBackend;
  /**
   * `serve.py`'s `GET /status` over the whisper socket. Rejects when the child
   * is not up, or is up but answering something else.
   */
  localStatus(): Promise<LocalWhisperStatus>;
}

/**
 * Every branch answers 200. Child down, load failed, body unparseable — all of
 * those are *states*, not HTTP failures. The Swift poller backs off on
 * transport failure, so a 5xx here would make 「python 还没起来」 look like
 * 「sidecar 挂了」 and push the poller into backoff during the exact seconds it
 * should be counting bytes.
 */
export function buildAsrStatusRoutes(deps: AsrStatusDeps): Route[] {
  return [
    {
      method: "GET",
      path: "/asr/status",
      handler: async () => {
        // Short-circuits before `localStatus()` is reached, not merely to the
        // right body: with no python child there, asking would buy a
        // guaranteed connection-refused round trip on every poll.
        if (deps.backend() === "remote") {
          return Response.json({ state: "ready", backend: "remote" });
        }

        let status: LocalWhisperStatus;
        try {
          status = await deps.localStatus();
        } catch {
          return Response.json({ state: "starting", backend: "local" });
        }

        return Response.json({
          state: status.state,
          backend: "local",
          model: status.model,
          downloadedBytes: status.downloadedBytes,
          // `null` survives as `null`. A `0` would render as a bar frozen at
          // 0%, which is this section's blank screen wearing a progress
          // indicator; an unknown total degrades the bar, not the state.
          totalBytes: status.totalBytes,
          // Present only when there is one, so a working model never carries an
          // empty error the UI could render as a warning line.
          ...(status.error ? { error: status.error } : {}),
        });
      },
    },
  ];
}
