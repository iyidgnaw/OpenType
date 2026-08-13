/**
 * A wall-clock anchor for the model, injected into every ask/agent request
 * (T4 of docs/superpowers/specs/2026-08-13-dsh-borrowings-plan.md §6).
 *
 * OpenType's input is speech, and speech is full of relative time -- "明天",
 * "刚才", "这周", "下周三", "remind me tomorrow". Without an anchor the model
 * has to guess, and it guesses from its training cutoff. The weekday is not
 * decoration: "下周三" is unresolvable from a date alone.
 *
 * MODEL EXPERIENCE: the returned string reaches the model verbatim, in the
 * USER message (never the system prompt -- a per-request timestamp there
 * would invalidate the reusable prefix on every call). Catalogued in
 * `docs/model-context-inventory.md` -- update it in the SAME change that
 * alters this rendering.
 */

/**
 * Told to the model instead of a guessed zone when we cannot resolve one.
 * Borrowed from dsh's time-context, whose rule for mixed/unknown provenance
 * is to ask rather than assume: a wrong zone silently shifts every relative
 * date by a day, while an admission of ignorance costs one clarifying
 * question.
 */
const UNRESOLVED_ZONE_NOTICE =
  "Time zone could not be determined; ask the user to confirm before acting on a relative date.";

/** Rendering fallback when the resolved zone is unusable. */
const FALLBACK_TIME_ZONE = "UTC";

/**
 * Whether `Intl` accepts this as an IANA zone. `DateTimeFormat` throws
 * `RangeError` on an unknown zone, which is the only reliable cross-runtime
 * validity check -- there is no exposed zone registry to consult.
 */
function isUsableTimeZone(timeZone: string): boolean {
  try {
    new Intl.DateTimeFormat("en-US", { timeZone });
    return true;
  } catch {
    return false;
  }
}

/**
 * The zone to render in. Returns `undefined` when none resolves, which is
 * what makes the notice conditional rather than a guess.
 *
 * An explicit zone is authoritative AND terminal: a caller passing one is
 * asserting "this is the user's zone", so an unusable value degrades loudly
 * instead of falling through to the environment. Falling through would
 * substitute the SIDECAR HOST's zone for the user's and silently shift every
 * relative date -- precisely the failure the notice exists to prevent, and
 * the harder one to notice because the output still looks well-formed.
 *
 * Without an explicit zone we walk `TZ` (which Node honors, and a
 * launchd-spawned sidecar may inherit) and then the runtime's resolved zone.
 */
function resolveTimeZone(explicit?: string): string | undefined {
  if (explicit !== undefined) {
    return isUsableTimeZone(explicit) ? explicit : undefined;
  }
  for (const candidate of [process.env.TZ, Intl.DateTimeFormat().resolvedOptions().timeZone]) {
    if (typeof candidate === "string" && candidate.length > 0 && isUsableTimeZone(candidate)) {
      return candidate;
    }
  }
  return undefined;
}

/**
 * Numeric UTC offset for one instant in one zone, as `+08:00`.
 *
 * `timeZoneName: 'longOffset'` renders `GMT+08:00`, and plain `GMT` at zero
 * offset -- hence the explicit zero case rather than a regex that would
 * silently produce an empty offset for UTC.
 */
function offsetOf(now: Date, timeZone: string): string {
  const parts = new Intl.DateTimeFormat("en-US", {
    timeZone,
    timeZoneName: "longOffset",
  }).formatToParts(now);
  const rendered = parts.find((part) => part.type === "timeZoneName")?.value ?? "";
  const match = /GMT([+-]\d{2}:\d{2})/.exec(rendered);
  return match?.[1] ?? "+00:00";
}

/**
 * Build the model-facing time line.
 *
 * @param now - the instant to render; injectable so callers and tests pin it.
 * @param timeZone - explicit IANA zone; omitted resolves from the environment.
 * @returns one line, plus the clarification sentence when no zone resolved.
 */
export function buildTimeContext(now: Date = new Date(), timeZone?: string): string {
  const resolved = resolveTimeZone(timeZone);
  const rendering = resolved ?? FALLBACK_TIME_ZONE;

  const parts = new Intl.DateTimeFormat("en-US", {
    timeZone: rendering,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
    weekday: "long",
    hourCycle: "h23",
  }).formatToParts(now);

  const valueOf = (type: Intl.DateTimeFormatPartTypes): string =>
    parts.find((part) => part.type === type)?.value ?? "";

  const date = `${valueOf("year")}-${valueOf("month")}-${valueOf("day")}`;
  const clock = `${valueOf("hour")}:${valueOf("minute")}:${valueOf("second")}`;
  const offset = offsetOf(now, rendering);
  const line = `Current time: ${date} ${clock} ${offset} (${rendering}, ${valueOf("weekday")})`;

  // A degraded reading is still worth sending: the model can order events and
  // read the absolute timestamp, it just must not assume the user's local
  // calendar day. Sending nothing would lose both.
  return resolved === undefined ? `${line}\n${UNRESOLVED_ZONE_NOTICE}` : line;
}
