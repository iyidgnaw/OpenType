/**
 * P1-7 (补): `/asr/transcribe` must contribute episodic events too.
 *
 * ## Why this file exists
 *
 * Before P1-7 the *only* writer of `episodic_events` was `/agent/run`
 * (`agent/routes.ts`), so consolidation's raw material was agent tasks and
 * nothing else — the entity dictionary could never learn a term from plain
 * dictation, which is the product's most-used mode. Dictation is also where
 * ASR mis-hearings actually show up, and mis-hearings are precisely what the
 * consolidation prompt asks the model to mine (`buildConsolidationPrompt`
 * sends `mode`, `rawTranscript`, `correctedTranscript` and nothing else).
 *
 * ## The contract stage 3 must implement
 *
 * `AsrRouteDeps` gains a second, OPTIONAL member so that every pre-existing
 * `buildAsrRoutes(transcribe)` / `buildAsrRoutes(transcribe, { listTerms })`
 * call site keeps compiling unchanged (the same least-invasive shape the file
 * already uses for `deps` itself):
 *
 *   export interface AsrRouteDeps {
 *     listTerms(): EntityTerm[];
 *     recordEpisodicEvent?(input: RecordEpisodicEventInput): void;
 *   }
 *
 * Server wiring (`buildApp` passing the real store's method through) is pinned
 * separately in `test/memory/episodicWiring.test.ts` — an optional seam that
 * nobody wires is exactly the inert-memory-layer failure P1-7 is cleaning up.
 *
 * ### Field mapping, pinned here
 *
 * - `mode: "transcribe"` — matches Swift's `InputMode.transcribe` rawValue,
 *   the same way the agent route's `"agent"` matches `InputMode.agent`.
 * - `rawTranscript` = what the ASR backend returned, BEFORE
 *   `applyAliasCorrections`. This is the one route in the product where a real
 *   raw/corrected pair exists for free, and it is the pair consolidation mines.
 * - `correctedTranscript` = the alias-corrected text, i.e. exactly what the
 *   response body carries and the user receives.
 * - `effectiveInput: null`, `result: null` — transcribe has no LLM stage, so
 *   there is no "input as fed to a model" and no "model output" for this row.
 *   NULL means "this mode has no such stage", which a reader can tell apart
 *   from a real value; copying the transcript into all four columns would
 *   store the same string four times and make the record lie about having had
 *   an LLM step. `consolidator.test.ts`'s own `seedEvents` helper already
 *   writes transcribe-mode rows exactly this way (`effectiveInput: null`,
 *   `result: null`), so this keeps synthetic and real rows the same shape.
 * - `selectedContext: null` — the transcribe request body is `{ audioBase64 }`;
 *   there is no selection on the wire.
 * - `applicationName: "OpenType Transcribe"` — a placeholder, because the
 *   sidecar genuinely cannot know the frontmost app: nothing in the request
 *   body carries it. This follows the precedent the agent route already set
 *   with the equally synthetic `"OpenType Agent"`. Sending the real app name
 *   would be a wire-format change on the hottest endpoint in the product, and
 *   there is currently no reader that would benefit — `applicationName` is not
 *   in the consolidation prompt at all, and the one component that ever scored
 *   on it (Swift's `LocalMemoryRetriever`) is deleted by P1-7's part (删).
 *   Flagged to the lead rather than assumed.
 * - `origin` left at its `"owner"` default — a dictation transcript is the
 *   owner's own words end to end, with no model in the loop to attribute
 *   anything to.
 *
 * ### Two suppression rules, both deliberate
 *
 * - Nothing is recorded unless the transcription actually succeeded (no row on
 *   400 or 502).
 * - Nothing is recorded for an empty/whitespace-only transcript. Silence is a
 *   normal outcome of an accidental hotkey press, and five accidental presses
 *   would otherwise satisfy `shouldConsolidate`'s `>= 5 unconsolidated events`
 *   gate with zero learnable material, burning a real LLM consolidation call.
 *
 * ### Best-effort, and this is the part that matters most
 *
 * `/asr/transcribe` is the hottest path in the product. A memory write that
 * throws (locked sqlite, corrupt DB, disk full) must degrade to "no episodic
 * event", never to "the user lost their dictation" — the same stance
 * `readTerms` already takes for the dictionary read directly above it.
 */
import { describe, expect, test } from "bun:test";
import { buildAsrRoutes, type AsrRouteDeps } from "../../src/asr/routes";
import type { EntityTerm, RecordEpisodicEventInput } from "../../src/memory/MemoryStore";
import { createRouter } from "../../src/router";

function post(body: unknown): Request {
  return new Request("http://sidecar/asr/transcribe", {
    method: "POST",
    body: JSON.stringify(body),
  });
}

let nextTermId = 1;

function makeTerm(canonicalTerm: string, aliases: string[] = []): EntityTerm {
  return {
    id: nextTermId++,
    canonicalTerm,
    aliases,
    category: "term",
    confidence: 0.9,
    origin: "owner",
    sourceEventIds: [],
    createdAt: 0,
    updatedAt: 0,
    supersedes: null,
  };
}

/** Collects every episodic write the route attempts, and lets one throw. */
function recorder(options: { throwOnRecord?: boolean } = {}): {
  deps: AsrRouteDeps;
  recorded: RecordEpisodicEventInput[];
  terms: EntityTerm[];
} {
  const recorded: RecordEpisodicEventInput[] = [];
  const terms: EntityTerm[] = [];
  const deps: AsrRouteDeps = {
    listTerms: () => terms,
    recordEpisodicEvent: (input) => {
      recorded.push(input);
      if (options.throwOnRecord) {
        throw new Error("database is locked");
      }
      return 1;
    },
  };
  return { deps, recorded, terms };
}

describe("POST /asr/transcribe records an episodic event", () => {
  test("records one event, in transcribe mode, on a successful transcription", async () => {
    const { deps, recorded } = recorder();
    const router = createRouter(buildAsrRoutes(async () => "hello world", deps));

    const response = await router(post({ audioBase64: "aGk=" }));

    expect(response.status).toBe(200);
    expect(recorded).toHaveLength(1);
    expect(recorded[0]!.mode).toBe("transcribe");
  });

  test("rawTranscript is the pre-correction ASR text, correctedTranscript the delivered text", async () => {
    const { deps, recorded, terms } = recorder();
    const term = makeTerm("PayPal", ["呸泡"]);
    terms.push(term);
    const router = createRouter(buildAsrRoutes(async () => "我用呸泡付款", deps));

    const response = await router(post({ audioBase64: "aGk=" }));

    // What the user got back, whole. The rewrite is now reported alongside the
    // text it changed (D-1), so this grew a key rather than losing its strict
    // shape — the body is still pinned exactly, which is what lets this test
    // notice a third key appearing.
    expect(await response.json()).toEqual({
      text: "我用PayPal付款",
      replacements: [{ from: "呸泡", to: "PayPal", termId: term.id }],
    });
    // What consolidation gets to mine: the mis-hearing AND its correction.
    expect(recorded).toHaveLength(1);
    expect(recorded[0]!.rawTranscript).toBe("我用呸泡付款");
    expect(recorded[0]!.correctedTranscript).toBe("我用PayPal付款");
  });

  test("with an empty dictionary, raw and corrected are both the ASR text", async () => {
    const { deps, recorded } = recorder();
    const router = createRouter(buildAsrRoutes(async () => "纯听写没有词典", deps));

    await router(post({ audioBase64: "aGk=" }));

    expect(recorded[0]!.rawTranscript).toBe("纯听写没有词典");
    expect(recorded[0]!.correctedTranscript).toBe("纯听写没有词典");
  });

  test("the LLM-stage columns are null, and applicationName is the sidecar-side placeholder", async () => {
    const { deps, recorded } = recorder();
    const router = createRouter(buildAsrRoutes(async () => "hello world", deps));

    await router(post({ audioBase64: "aGk=" }));

    const event = recorded[0]!;
    expect(event.effectiveInput).toBeNull();
    expect(event.result).toBeNull();
    expect(event.selectedContext).toBeNull();
    expect(event.applicationName).toBe("OpenType Transcribe");
    // Left at the store's "owner" default: no model produced any of this row.
    expect(event.origin ?? "owner").toBe("owner");
  });

  test("records nothing when transcription fails", async () => {
    const { deps, recorded } = recorder();
    const router = createRouter(
      buildAsrRoutes(async () => {
        throw new Error("whisper server unavailable");
      }, deps)
    );

    const response = await router(post({ audioBase64: "aGk=" }));

    expect(response.status).toBe(502);
    expect(recorded).toEqual([]);
  });

  test("records nothing when the request never reached the ASR backend", async () => {
    const { deps, recorded } = recorder();
    const router = createRouter(buildAsrRoutes(async () => "unused", deps));

    expect((await router(post({}))).status).toBe(400);
    expect((await router(post({ audioBase64: "not valid base64!!" }))).status).toBe(400);
    expect(recorded).toEqual([]);
  });

  test("records nothing for a silent recording (empty or whitespace-only transcript)", async () => {
    const empty = recorder();
    const emptyRouter = createRouter(buildAsrRoutes(async () => "", empty.deps));
    expect((await emptyRouter(post({ audioBase64: "aGk=" }))).status).toBe(200);
    expect(empty.recorded).toEqual([]);

    const blank = recorder();
    const blankRouter = createRouter(buildAsrRoutes(async () => "  \n \t ", blank.deps));
    expect((await blankRouter(post({ audioBase64: "aGk=" }))).status).toBe(200);
    expect(blank.recorded).toEqual([]);
  });

  test("a failing episodic write never fails the transcription", async () => {
    const { deps, recorded } = recorder({ throwOnRecord: true });
    const router = createRouter(buildAsrRoutes(async () => "hello world", deps));

    const response = await router(post({ audioBase64: "aGk=" }));

    // The write was attempted and blew up...
    expect(recorded).toHaveLength(1);
    // ...and the user still got their dictation, with a normal 200.
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ text: "hello world" });
  });

  test("a failing episodic write does not break the NEXT request either", async () => {
    const { deps } = recorder({ throwOnRecord: true });
    const router = createRouter(buildAsrRoutes(async () => "hello world", deps));

    await router(post({ audioBase64: "aGk=" }));
    const second = await router(post({ audioBase64: "aGk=" }));

    expect(second.status).toBe(200);
    expect(await second.json()).toEqual({ text: "hello world" });
  });

  test("still transcribes when no recorder is wired at all (legacy call sites)", async () => {
    const router = createRouter(buildAsrRoutes(async () => "hello world", { listTerms: () => [] }));

    const response = await router(post({ audioBase64: "aGk=" }));

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ text: "hello world" });
  });
});
