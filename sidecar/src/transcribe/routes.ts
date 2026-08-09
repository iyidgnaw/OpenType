import type { Route } from "../router";
import type { OneShotChatFn } from "../oneshot/client";
import { CORRECTION_SYSTEM_PROMPT } from "./prompts";

interface CorrectRequestBody {
  fullText?: string;
  selectionStart?: number;
  selectionEnd?: number;
  instruction?: string;
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
  chat: OneShotChatFn
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
  return Response.json({ replacement });
}

/**
 * Review-mode's voice-driven correction endpoint. Takes the full current
 * (possibly already-edited) text plus a UTF-16-code-unit selection range
 * (matching JS string indexing exactly, which in turn matches
 * `NSString`/`NSRange` on the Swift side -- see `ReviewPanelController.swift`)
 * and a spoken correction instruction, and returns just the replacement text
 * for that span. Deliberately takes a bare `chat` function rather than a
 * `MemoryStore`/concrete client, same DI shape as `buildOneShotRoutes`, so
 * this stays pure, dependency-light, unit-testable logic.
 */
export function buildTranscribeRoutes(chat: OneShotChatFn): Route[] {
  return [
    {
      method: "POST",
      path: "/transcribe/correct",
      handler: (req) => handleCorrect(req, chat),
    },
  ];
}
