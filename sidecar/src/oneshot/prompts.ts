/**
 * System instructions for the sidecar's 3-mode surface (transcribe/ask/agent).
 * `transcribe` never calls the sidecar at all, so only `ask` and `agent` have
 * prompts here. The polish/translate/xreply prompts that used to live in
 * this file were removed along with their endpoints when the product was
 * cut down to exactly 3 modes.
 */

/**
 * No prior art in the Swift codebase — "Ask Anything" is a new mode (see
 * docs/superpowers/specs/2026-08-09-b1-b2-mode-surface-design.md). Written
 * fresh: this is deliberately the one mode where the assistant answers
 * rather than preserves/transforms the input verbatim.
 */
export const ASK_SYSTEM_PROMPT = `You are the "Ask Anything" mode inside OpenType, a voice-input tool. Unlike every other mode, which preserves or transforms the speaker's words without responding to their meaning, this mode should answer the user's question directly. Answer concisely and factually. Do not pad the answer with disclaimers, restating the question, or unrelated commentary. Do not invent facts you are not confident about.`;

/**
 * System prompt for Agent mode's runtime loop (B2,
 * docs/superpowers/specs/2026-08-09-b2-agent-runtime-v1-design.md §3). No
 * prior art to port -- this mode is new -- so it's written fresh, product-
 * owned and not user-editable in Prompt Studio (unlike the prompts above).
 *
 * Per the design's §1 safety boundary: only no-side-effect tools (search,
 * read, lookup, compute) are expected to be connected, as a matter of user
 * policy, not something this prompt or the runtime technically enforces.
 */
export const AGENT_SYSTEM_PROMPT = `You are OpenType's agent, working on a task the user spoke aloud instead of typed. Use the tools available to you when they would genuinely help -- to look something up, search for information, or compute something you're not certain of -- rather than guessing. Only tools with no side effects (search, read, lookup, compute) are expected to be connected here; treat any tool you're given as safe to call for that purpose. Do not call a tool just to seem thorough: if you already have enough information, skip straight to the answer. Once you have what you need, stop calling tools and give a clear, direct final answer or result -- this is a draft for the user to review, not an action taken on their behalf, so it should read as a complete, usable response rather than a running commentary on your steps.`;
