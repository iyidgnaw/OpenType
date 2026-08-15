/**
 * `GET`/`PUT /config/whisper-model` — the model picker's two endpoints.
 *
 * See `whisperModel.ts` for why this exists and how the precedence works. The
 * routes themselves hold one decision worth stating: a `PUT` **reports** that a
 * restart is needed rather than performing one.
 *
 * Restarting the whisper child mid-flight means killing a python process that
 * may be blocking a queued transcription, and then re-downloading up to 3 GB
 * before anything works again — a bigger and separately reviewable change than
 * this. Saying so, as the MCP panel already says 「下次启动生效」, is the simple
 * reliable half of the choice the spec left open.
 */
import type { Route } from "../router";
import type { ProviderConfigStore } from "../provider/configStore";
import {
  WHISPER_MODEL_PRESETS,
  resolveWhisperModel,
} from "./whisperModel";

export interface WhisperModelRouteOptions {
  /** `OPENTYPE_WHISPER_MODEL`, when set. */
  envValue?: string;
}

export function buildWhisperModelRoutes(
  store: ProviderConfigStore,
  options: WhisperModelRouteOptions = {}
): Route[] {
  // Read per request, never snapshotted: the routes are built once at boot and
  // the user can save a different model at any point afterwards.
  const current = () => ({
    ...resolveWhisperModel(store.getWhisperModel(), options.envValue),
    presets: [...WHISPER_MODEL_PRESETS],
  });

  return [
    {
      method: "GET",
      path: "/config/whisper-model",
      handler: () => Response.json(current()),
    },
    {
      method: "PUT",
      path: "/config/whisper-model",
      handler: async (req) => {
        let body: { model?: unknown };
        try {
          body = (await req.json()) as { model?: unknown };
        } catch {
          return Response.json({ error: "model is required" }, { status: 400 });
        }

        const model = typeof body.model === "string" ? body.model.trim() : "";
        if (!model) {
          return Response.json({ error: "model is required" }, { status: 400 });
        }

        store.setWhisperModel(model);
        return Response.json({ ...current(), restartRequired: true });
      },
    },
  ];
}
