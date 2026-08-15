import {
  applyAliasCorrections,
  buildInitialPrompt,
  termIdForReplacement,
} from "./dictionaryBias";
import type { AliasReplacement } from "./dictionaryBias";
import type { EntityTerm, RecordEpisodicEventInput } from "../memory/MemoryStore";
import type { Route } from "../router";

interface TranscribeRequestBody {
  audioBase64?: string;
  language?: string;
}

export interface TranscribeOptions {
  /** Decoding bias built from the entity dictionary; omitted when there is none. */
  initialPrompt?: string;
  /**
   * The user's transcription-language setting as an ISO-639-1 code, forwarded
   * to whichever backend serves the request. Omitted means auto-detect. The two
   * options are independent: a language must not displace the dictionary bias.
   */
  language?: string;
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

/**
 * One rewrite, as the client reads it (D-1).
 *
 * Named `from`/`to` rather than `alias`/`canonicalTerm` because this is the
 * user's view of what happened — 「呸泡 → PayPal」 — not the dictionary's view of
 * its own columns, and the row is rendered before anyone has to know what an
 * alias is. `termId` is what makes it undoable.
 */
interface ReplacementRow {
  from: string;
  to: string;
  termId: number;
}

/**
 * Turns the scan's replacements into the wire's rows, in text order, dropping
 * any whose term cannot be named.
 *
 * A row without a `termId` would render as an undo control that has nothing to
 * delete, which is worse than not offering the row: the user clicks, the alias
 * survives, and the next transcription rewrites their words again.
 */
function describeReplacements(
  replacements: AliasReplacement[],
  terms: EntityTerm[]
): ReplacementRow[] {
  const rows: ReplacementRow[] = [];
  for (const replacement of replacements) {
    const termId = termIdForReplacement(replacement, terms);
    if (termId === null) continue;
    rows.push({
      from: replacement.alias,
      to: replacement.canonicalTerm,
      termId,
    });
  }
  return rows;
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
  // Keys are omitted, never set to "", so an empty dictionary never reaches the
  // decoder as an empty prompt and an unset language never reaches it as a
  // language named "". `automatic` is the absence of a language, not a value.
  const language = body.language?.trim();
  const options: TranscribeOptions = {};
  if (initialPrompt) {
    options.initialPrompt = initialPrompt;
  }
  if (language) {
    options.language = language;
  }

  try {
    const text = await transcribe(audio, options);
    // The deterministic half of the dictionary feedback: it also covers remote
    // whisper providers, which never see `initialPrompt`.
    const corrected = applyAliasCorrections(text, terms);
    recordDictation(deps, text, corrected.text);
    // D-1: what the dictionary rewrote, reported rather than discarded. Until
    // this, the one guaranteed half of the learning loop left no trace the user
    // could see — they said 「呸泡」, 「PayPal」 came out, and nothing on screen
    // said which of the two had happened.
    const replacements = describeReplacements(corrected.replacements, terms);
    // The key is omitted, never sent as `[]`. Every response written before
    // D-1 looked exactly like the line below, `routes.test.ts` pins it with a
    // strict `toEqual({ text })`, and an empty list downstream would let the UI
    // announce 「自动修正 0 处」 on the hottest path in the product.
    if (replacements.length === 0) {
      return Response.json({ text: corrected.text });
    }
    return Response.json({ text: corrected.text, replacements });
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
