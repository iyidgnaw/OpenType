import { applyAliasCorrections, buildInitialPrompt } from "./dictionaryBias";
import type { EntityTerm } from "../memory/MemoryStore";
import type { Route } from "../router";

interface TranscribeRequestBody {
  audioBase64?: string;
}

export interface TranscribeOptions {
  /** Decoding bias built from the entity dictionary; omitted when there is none. */
  initialPrompt?: string;
}

export type TranscribeFn = (
  audio: Uint8Array,
  options?: TranscribeOptions
) => Promise<string>;

export interface AsrRouteDeps {
  /** The entity dictionary, read fresh per request so a just-taught term applies immediately. */
  listTerms(): EntityTerm[];
}

function decodeBase64(value: string): Uint8Array | null {
  try {
    const binary = atob(value);
    const bytes = new Uint8Array(binary.length);
    for (let i = 0; i < binary.length; i++) {
      bytes[i] = binary.charCodeAt(i);
    }
    return bytes;
  } catch {
    return null;
  }
}

/**
 * Losing term biasing is a degradation; losing transcription is an outage. A
 * broken or locked memory DB therefore degrades to a plain, uncorrected
 * transcription rather than failing the request.
 */
function readTerms(deps: AsrRouteDeps | undefined): EntityTerm[] {
  if (!deps) return [];
  try {
    return deps.listTerms();
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    console.warn(`asr: entity dictionary unavailable, transcribing unbiased: ${message}`);
    return [];
  }
}

async function handleTranscribe(
  req: Request,
  transcribe: TranscribeFn,
  deps: AsrRouteDeps | undefined
): Promise<Response> {
  const body = (await req.json()) as TranscribeRequestBody;
  const audioBase64 = body.audioBase64 ?? "";
  if (!audioBase64) {
    return Response.json({ error: "audioBase64 is required" }, { status: 400 });
  }
  const audio = decodeBase64(audioBase64);
  if (!audio) {
    return Response.json({ error: "audioBase64 is not valid base64" }, { status: 400 });
  }

  const terms = readTerms(deps);
  const initialPrompt = buildInitialPrompt(terms);
  // The key is omitted, not set to "", so an empty dictionary never reaches the
  // decoder as an empty prompt.
  const options: TranscribeOptions = initialPrompt ? { initialPrompt } : {};

  try {
    const text = await transcribe(audio, options);
    // The deterministic half of the dictionary feedback: it also covers remote
    // whisper providers, which never see `initialPrompt`.
    return Response.json({ text: applyAliasCorrections(text, terms).text });
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    return Response.json({ error: message }, { status: 502 });
  }
}

/**
 * Local ASR route, backed by the MLX-Whisper python process managed by
 * `WhisperClient`. Takes a plain `transcribe` function rather than a
 * `WhisperClient` instance so it stays testable the same way
 * `buildOneShotRoutes`/`buildAgentRoutes` take a bare `chat` function instead
 * of a concrete client.
 *
 * `deps` is optional so the route keeps working (unbiased, uncorrected) without
 * a memory store. When present, both dictionary-feedback mechanisms run here,
 * in one testable place, from a single read of the dictionary.
 */
export function buildAsrRoutes(transcribe: TranscribeFn, deps?: AsrRouteDeps): Route[] {
  return [
    {
      method: "POST",
      path: "/asr/transcribe",
      handler: (req) => handleTranscribe(req, transcribe, deps),
    },
  ];
}
