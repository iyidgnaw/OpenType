import { applyAliasCorrections, buildInitialPrompt } from "./dictionaryBias";
import type { EntityTerm, RecordEpisodicEventInput } from "../memory/MemoryStore";
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
  /**
   * Appends one episodic event per successful dictation (P1-7). Optional so
   * pre-existing `buildAsrRoutes(transcribe)` / `buildAsrRoutes(transcribe, {
   * listTerms })` call sites keep compiling; `buildApp` passes the real store's
   * method, and `test/memory/episodicWiring.test.ts` pins that it does.
   */
  recordEpisodicEvent?(input: RecordEpisodicEventInput): void;
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

/**
 * P1-7: dictation feeds consolidation too. Before this, `/agent/run` was the
 * only writer of `episodic_events`, so the entity dictionary could never learn
 * a term from the mode people actually use most — and dictation is where ASR
 * mis-hearings show up, which is exactly the raw/corrected pair
 * `buildConsolidationPrompt` asks the model to mine.
 *
 * Two things this deliberately does not record. A silent recording (an
 * accidental hotkey press) carries nothing learnable, and five of them would
 * otherwise open `shouldConsolidate`'s gate and burn a real LLM call on
 * nothing. And a write that throws is swallowed: `/asr/transcribe` is the
 * hottest path in the product, so a locked or corrupt memory DB must cost the
 * user an episodic row, never their dictation — the same stance `readTerms`
 * takes above.
 */
function recordDictation(
  deps: AsrRouteDeps | undefined,
  rawTranscript: string,
  correctedTranscript: string
): void {
  if (!deps?.recordEpisodicEvent) return;
  if (rawTranscript.trim() === "") return;
  try {
    deps.recordEpisodicEvent({
      mode: "transcribe",
      rawTranscript,
      correctedTranscript,
      // Transcribe has no LLM stage, so there is no "input as fed to a model"
      // and no model output. NULL says "this mode has no such stage", which a
      // reader can tell apart from the transcript repeated four times.
      effectiveInput: null,
      selectedContext: null,
      result: null,
      // The sidecar cannot know the frontmost app — nothing in the request body
      // carries it — so this is a placeholder, following the precedent
      // `/agent/run` set with the equally synthetic "OpenType Agent".
      // `applicationName` never reaches the consolidation prompt anyway.
      applicationName: "OpenType Transcribe",
      // `origin` left at the store's "owner" default: a dictation transcript is
      // the owner's own words end to end, with no model in the loop.
    });
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    console.warn(`asr: could not record episodic event, continuing: ${message}`);
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
    const corrected = applyAliasCorrections(text, terms).text;
    recordDictation(deps, text, corrected);
    return Response.json({ text: corrected });
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
