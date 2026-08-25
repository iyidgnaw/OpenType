import type { EpisodicEventRow } from "./MemoryStore";

/**
 * MODEL EXPERIENCE: `buildRecentActivityContext`'s output is injected
 * verbatim into the ask/agent user message. Exact rendered text, token
 * cost, and KV-cache impact are catalogued in
 * `docs/model-context-inventory.md` §3.9 — update it in the SAME change
 * that alters what is injected here.
 *
 * Renders recent episodic events as JSONL (one JSON object per line) rather
 * than a compact bracket form (e.g. `[#43 ask · conv 17]`). The decisive
 * reason is that the key names here are exactly the `opentype__read_history`
 * tool's parameter names: `{"eventId":43}` in context maps straight onto
 * `opentype__read_history({ eventId: 43 })` with no translation step. A
 * compact form would force the model to first parse a bespoke syntax, then
 * infer which token is which id from a header line — the line most easily
 * skimmed past. The cost is roughly 15-20% more tokens than the compact
 * form; the benefit is not misreading which id is which and expanding (or
 * answering from) the wrong history entry.
 *
 * Keys with no value are omitted entirely, never written as `null`. A
 * `null` in context both costs tokens for nothing and invites the model to
 * pass that same `null` back into a tool argument — omitting the key keeps
 * "this field doesn't apply here" from ever looking like a valid value.
 *
 * `RECENT_ACTIVITY_EXCLUDED_MODES` is empty on purpose: all three modes
 * (`transcribe`, `ask`, `agent`) feed this context, with no opt-out. That is
 * a deliberate product decision (spec §3.5/§六), not a privacy control that
 * happens to be turned off right now — don't describe it as one.
 */

export const RECENT_ACTIVITY_LIMIT = 10;
export const RECENT_ACTIVITY_FIELD_MAX = 120;
export const RECENT_ACTIVITY_EXCLUDED_MODES: readonly string[] = [];

const HEADER_WITH_TOOL =
  "Recent activity, oldest first. Expand any entry with opentype__read_history.";
const HEADER_PLAIN = "Recent activity, oldest first.";

/** Collapses whitespace runs to single spaces, then clips to the field cap with a trailing ellipsis. */
function clip(text: string): string {
  const normalized = text.replace(/\s+/gu, " ").trim();
  return normalized.length > RECENT_ACTIVITY_FIELD_MAX
    ? `${normalized.slice(0, RECENT_ACTIVITY_FIELD_MAX)}…`
    : normalized;
}

/**
 * Renders `rows` (caller-supplied order, oldest first) as a header line
 * followed by one JSON object per line. Returns the empty string for an
 * empty input rather than a lone header — a header with nothing under it
 * would just be noise in the prompt.
 *
 * `opts.includeIds` gates both the `eventId`/`conversationId` keys and the
 * header's mention of `opentype__read_history`: the ask surface has no such
 * tool, so it must not be shown identifiers it has no way to use.
 */
export function buildRecentActivityContext(
  rows: EpisodicEventRow[],
  opts: { includeIds: boolean }
): string {
  if (rows.length === 0) {
    return "";
  }

  const lines = rows.map((r) => {
    const entry: Record<string, unknown> = {};
    if (opts.includeIds) entry.eventId = r.id;
    entry.mode = r.mode;
    entry.app = r.applicationName;
    if (opts.includeIds && r.conversationId != null) entry.conversationId = r.conversationId;
    entry.input = clip(r.correctedTranscript);
    if (r.result != null && r.result.trim() !== "") entry.result = clip(r.result);
    return JSON.stringify(entry);
  });

  const header = opts.includeIds ? HEADER_WITH_TOOL : HEADER_PLAIN;
  return [header, ...lines].join("\n");
}
