import type { Route } from "../router";
import type { OneShotChatFn } from "../oneshot/client";
import { upsertEntityTerm } from "../memory/consolidator";
import type { MemoryStore } from "../memory/MemoryStore";
import { CORRECTION_SYSTEM_PROMPT } from "./prompts";
import { shouldLearnCorrection } from "./learnCorrection";

interface CorrectRequestBody {
  fullText?: string;
  selectionStart?: number;
  selectionEnd?: number;
  instruction?: string;
}

export interface TranscribeRoutesDeps {
  /**
   * When present, gate-passing corrections are learned into the entity
   * dictionary (P0-2). Optional: without it the endpoint behaves exactly as
   * it did before learning existed.
   */
  store?: MemoryStore;
}

/** What a correction taught the dictionary, echoed back for UI ("已记住"). */
interface LearnedTerm {
  canonicalTerm: string;
  alias: string;
}

/**
 * Confidence for a correction the owner made by hand. Deliberately below the
 * 1.0 that an explicit "记住 X" (`remember_fact`) writes -- fixing one word in
 * one transcript is weaker evidence than asking for it to be remembered --
 * and above what the dreaming pass typically infers on its own.
 */
const CORRECTION_CONFIDENCE = 0.8;

/**
 * Writes `alias -> canonicalTerm` into `entity_terms`, reusing
 * `upsertEntityTerm` -- the same merge-by-canonical-or-alias path
 * `remember_fact` and the dreaming pass use, so a correction folds into an
 * existing term instead of starting a rival row.
 *
 * Best-effort by contract: the correction itself already succeeded by the
 * time this runs, so a broken/unwritable memory DB must degrade to "learned
 * nothing", never to a failed request. Returns `null` when nothing was
 * learned, for any reason.
 */
function learnCorrection(
  store: MemoryStore,
  selectedText: string,
  replacement: string
): LearnedTerm | null {
  if (!shouldLearnCorrection(selectedText, replacement)) {
    return null;
  }

  const alias = selectedText.trim();
  try {
    const { term } = upsertEntityTerm(store, store.allTerms(), {
      canonicalTerm: replacement.trim(),
      aliases: [alias],
      category: "term",
      confidence: CORRECTION_CONFIDENCE,
      sourceEventIds: [],
      // The owner corrected this by hand in their own text, so it is
      // owner-confirmed (P1-12) -- unlike `remember_fact`, which runs inside
      // the agent loop where content can originate from untrusted context.
      origin: "owner",
    });
    // Report the row that now exists rather than the raw replacement: when
    // the replacement matched an existing term only by alias, the dictionary
    // says `alias -> that term's canonical`, and that is what was learned.
    return { canonicalTerm: term.canonicalTerm, alias };
  } catch (err) {
    console.error(
      "[transcribe/correct] failed to learn the correction into the entity dictionary; returning the correction anyway.",
      err
    );
    return null;
  }
}

/**
 * How much of the text immediately surrounding the selection to include
 * verbatim in the prompt, on top of the full text itself -- keeps the
 * "selected span" highlighted unambiguously for the model even when
 * `fullText` is long, without truncating `fullText` itself (Review-mode
 * transcripts are short dictation results, not documents, so sending the
 * whole thing is cheap).
 */
const SURROUNDING_CONTEXT_CHARS = 200;

function isValidSelection(
  fullText: string,
  selectionStart: unknown,
  selectionEnd: unknown
): selectionStart is number {
  return (
    typeof selectionStart === "number" &&
    typeof selectionEnd === "number" &&
    Number.isInteger(selectionStart) &&
    Number.isInteger(selectionEnd) &&
    selectionStart >= 0 &&
    selectionEnd <= fullText.length &&
    selectionStart < selectionEnd
  );
}

function buildUserContent(
  fullText: string,
  selectionStart: number,
  selectionEnd: number,
  instruction: string
): string {
  const selectedSpan = fullText.slice(selectionStart, selectionEnd);
  const before = fullText.slice(
    Math.max(0, selectionStart - SURROUNDING_CONTEXT_CHARS),
    selectionStart
  );
  const after = fullText.slice(
    selectionEnd,
    selectionEnd + SURROUNDING_CONTEXT_CHARS
  );

  return [
    `Full text:\n${fullText}`,
    `Selected span (this is what you must replace): "${selectedSpan}"`,
    `Text immediately before the selection: "${before}"`,
    `Text immediately after the selection: "${after}"`,
    `Spoken correction instruction: "${instruction}"`,
  ].join("\n\n");
}

async function handleCorrect(
  req: Request,
  chat: OneShotChatFn,
  deps: TranscribeRoutesDeps
): Promise<Response> {
  const body = (await req.json()) as CorrectRequestBody;
  const fullText = body.fullText ?? "";
  const instruction = (body.instruction ?? "").trim();

  if (!isValidSelection(fullText, body.selectionStart, body.selectionEnd)) {
    return Response.json({ error: "invalid selection range" }, { status: 400 });
  }
  if (!instruction) {
    return Response.json({ error: "instruction is required" }, { status: 400 });
  }

  // `isValidSelection` is a type guard on `selectionStart` only; `selectionEnd`
  // was checked by the same call but TypeScript can't narrow it through the
  // guard's return type, so re-read it directly -- it's already been
  // validated to be an in-range integer > selectionStart.
  const selectionStart = body.selectionStart as number;
  const selectionEnd = body.selectionEnd as number;

  const userContent = buildUserContent(
    fullText,
    selectionStart,
    selectionEnd,
    instruction
  );

  const result = await chat([
    { role: "system", content: CORRECTION_SYSTEM_PROMPT },
    { role: "user", content: userContent },
  ]);

  const replacement = (result.content ?? "").trim();

  const learned = deps.store
    ? learnCorrection(
        deps.store,
        fullText.slice(selectionStart, selectionEnd),
        replacement
      )
    : null;

  // `learned` is omitted entirely rather than sent as null, so a caller can
  // test for the key's presence.
  return Response.json(learned ? { replacement, learned } : { replacement });
}

/**
 * Review-mode's voice-driven correction endpoint. Takes the full current
 * (possibly already-edited) text plus a UTF-16-code-unit selection range
 * (matching JS string indexing exactly, which in turn matches
 * `NSString`/`NSRange` on the Swift side -- see `ReviewPanelController.swift`)
 * and a spoken correction instruction, and returns just the replacement text
 * for that span.
 *
 * `chat` is a bare function rather than a concrete client, same DI shape as
 * `buildOneShotRoutes`. `deps.store` is *optional*: with it, a correction
 * that looks like a term fix is also learned into the entity dictionary
 * (P0-2, `learnCorrection.ts` decides which ones qualify) so the next
 * transcription gets that term right; without it the endpoint is the same
 * pure, dependency-light correction logic it has always been, which is also
 * how most of its own tests exercise it. Learning is strictly best-effort --
 * it happens after the correction has already succeeded and can only add a
 * `learned` field to the response, never fail the request.
 */
export function buildTranscribeRoutes(
  chat: OneShotChatFn,
  deps: TranscribeRoutesDeps = {}
): Route[] {
  return [
    {
      method: "POST",
      path: "/transcribe/correct",
      handler: (req) => handleCorrect(req, chat, deps),
    },
  ];
}
