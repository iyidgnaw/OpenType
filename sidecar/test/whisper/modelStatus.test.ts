/**
 * STAGE-1 (red) harness for the python side of §E-1
 * (`docs/superpowers/specs/2026-08-15-product-batch-plan.md`):
 * 「serve.py 先起服务，后加载模型」.
 *
 * ---------------------------------------------------------------------------
 * What this file is
 * ---------------------------------------------------------------------------
 *
 * Two things that cannot be one thing:
 *
 *  1. **A runner.** `sidecar/test/whisper/test_model_status.py` holds real unit
 *     tests for the state machine, written in python because that is what they
 *     test. This file executes them under `bun test` so they are part of the
 *     one suite everybody runs, and fails with their output attached. No
 *     pytest, no unittest discovery, no new dependency — the python file is a
 *     plain module with a `__main__` runner, which is the smallest thing that
 *     works in a repo that has never had a python harness.
 *
 *  2. **Source-level guards on `serve.py`.** The ordering property this section
 *     is about — *serve first, load second* — lives in `main()`, which is not
 *     importable without `numpy`/`mlx_whisper` and is therefore not unit
 *     testable at all. So it is guarded the same way
 *     `mcpBootResilience.test.ts` guards `server.ts`'s boot ordering: by
 *     reading the file. These guards are deliberately few and deliberately
 *     loose — they catch a regression to today's shape, they do not prove the
 *     new shape works. **Stage 4 must verify the behavior by hand**; see this
 *     file's closing note for exactly what.
 *
 * ---------------------------------------------------------------------------
 * The one that is easy to miss
 * ---------------------------------------------------------------------------
 *
 * `socketserver.UnixStreamServer` handles **one request at a time**. Today that
 * is invisible: nothing calls `serve.py` concurrently. The moment `/transcribe`
 * starts blocking on `wait_until_ready()`, a single-threaded server can no
 * longer answer `/status` — so a user who presses the hotkey during the
 * download wedges the very endpoint that was supposed to explain the wait, and
 * §E ships as a feature that works only when nobody uses it. `ThreadingMixIn`
 * is not a nicety here; it is the difference between the section working and
 * not. It is asserted below and it is the first thing stage 4 should exercise.
 */
import { describe, expect, test } from "bun:test";
import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";

const SIDECAR_ROOT = join(import.meta.dir, "..", "..");
const WHISPER_DIR = join(SIDECAR_ROOT, "whisper");
const SERVE_PY = join(WHISPER_DIR, "serve.py");
const MODEL_STATUS_PY = join(WHISPER_DIR, "model_status.py");
const PYTHON_TESTS = join(import.meta.dir, "test_model_status.py");

/**
 * The venv python (3.12, the one that actually runs `serve.py`) when the
 * developer has set it up, otherwise macOS's own `/usr/bin/python3`. Falling
 * back rather than requiring the venv keeps a fresh checkout able to run the
 * suite; `model_status.py` is stdlib-only precisely so both work.
 */
function resolvePython(): string {
  const venv = join(SIDECAR_ROOT, "whisper-env", "bin", "python3");
  if (existsSync(venv)) return venv;
  if (existsSync("/usr/bin/python3")) return "/usr/bin/python3";
  throw new Error(
    "No python3 found (looked for sidecar/whisper-env/bin/python3 and /usr/bin/python3)."
  );
}

function readSource(path: string): string {
  expect(existsSync(path)).toBe(true);
  return readFileSync(path, "utf8");
}

// ---------------------------------------------------------------------------
// 1. The state machine's own unit tests
// ---------------------------------------------------------------------------

describe("whisper/model_status.py", () => {
  test("its python unit tests all pass", () => {
    const result = Bun.spawnSync([resolvePython(), PYTHON_TESTS], {
      cwd: SIDECAR_ROOT,
      stdout: "pipe",
      stderr: "pipe",
    });
    const output = `${result.stdout.toString()}\n${result.stderr.toString()}`.trim();

    // The python runner's own output is the failure message: without it, a red
    // here says only "exit code 1" and the reader has to re-run it by hand.
    if (result.exitCode !== 0) {
      throw new Error(
        `test_model_status.py failed (exit ${result.exitCode}):\n\n${output}\n`
      );
    }
    expect(result.exitCode).toBe(0);

    // Exit 0 is also what a runner that collected *nothing* returns, and 22
    // python assertions hiding behind one `bun test` line is exactly the place
    // a silent zero would never be noticed. Parse the summary and require that
    // tests actually ran.
    const summary = /(\d+) passed, (\d+) failed, (\d+) total/.exec(output);
    if (!summary) {
      throw new Error(
        `test_model_status.py exited 0 but printed no summary line:\n\n${output}\n`
      );
    }
    expect(Number(summary[3])).toBeGreaterThan(0);
  });

  test("is importable with the standard library alone", () => {
    // It is a separate module from `serve.py` for exactly one reason: `serve.py`
    // imports `numpy` and `mlx_whisper` at module scope, so importing it to test
    // the state machine would require the whole MLX venv. A third-party import
    // creeping in here would quietly undo that and take the unit tests with it.
    //
    // Checked by importing it, not by reading it: `python3 -S` starts without
    // `site`, so `sidecar/whisper-env`'s site-packages is off the path and ANY
    // third-party import fails — including one nobody here thought to name. A
    // source scan alone would have to spell out an allowlist, which then fails
    // the day the module legitimately wants `copy` or `dataclasses`.
    const probe = Bun.spawnSync(
      [
        resolvePython(),
        "-S",
        "-c",
        "import sys; sys.path.insert(0, 'whisper'); import model_status",
      ],
      { cwd: SIDECAR_ROOT, stdout: "pipe", stderr: "pipe" }
    );
    if (probe.exitCode !== 0) {
      throw new Error(
        "model_status.py must import with no site-packages on the path " +
          `(ran python3 -S):\n\n${probe.stderr.toString()}\n`
      );
    }

    // The one thing `-S` cannot see: a third-party import deferred inside a
    // function body, which would still drag the venv in at load time.
    const source = readSource(MODEL_STATUS_PY);
    const thirdParty = new Set([
      "numpy",
      "mlx",
      "mlx_whisper",
      "huggingface_hub",
      "torch",
      "tqdm",
      "requests",
    ]);
    const imported = [...source.matchAll(/^\s*(?:from|import)\s+([A-Za-z_][\w.]*)/gm)].map(
      (match) => match[1]!.split(".")[0]!
    );

    expect(imported.length).toBeGreaterThan(0);
    expect(imported.filter((module) => thirdParty.has(module))).toEqual([]);
  });

  test("opts into postponed annotation evaluation", () => {
    // `sidecar/whisper-env` is python 3.12 but the fallback interpreter above is
    // macOS's 3.9, where a bare `int | None` in a signature raises at import
    // time. One `__future__` line makes the module read the same on both and
    // keeps this file's red meaning "the behavior is wrong" rather than "the
    // interpreter is older".
    expect(readSource(MODEL_STATUS_PY)).toMatch(/^from __future__ import annotations$/m);
  });
});

// ---------------------------------------------------------------------------
// 2. serve.py: serve first, load second
// ---------------------------------------------------------------------------

describe("whisper/serve.py structure", () => {
  test("uses the shared state machine rather than a second copy of it", () => {
    // If `serve.py` grows its own inline flags, everything above tests a module
    // nobody runs.
    expect(readSource(SERVE_PY)).toMatch(/(?:from|import)\s+model_status/);
  });

  test("routes GET /status", () => {
    const source = readSource(SERVE_PY);
    expect(source).toMatch(/["']\/status["']/);
    // Answered from the state machine, not recomputed.
    expect(source).toMatch(/snapshot\(\)/);
  });

  test("does not load the model before the socket server exists", () => {
    // Today: `main()` calls `_warm_up_model()` at line 175 and constructs
    // `UnixHTTPServer` at line 178, which is the entire bug — during a ~460 MB
    // first-launch download there is nobody listening to answer 「你在干嘛」.
    const source = readSource(SERVE_PY);
    const mainStart = source.indexOf("def main(");
    const construction = source.lastIndexOf("UnixHTTPServer(");
    expect(mainStart).toBeGreaterThan(-1);
    // The construction has to be inside `main()`. If it moves into a helper
    // defined above `main()`, the window below is empty and this whole
    // assertion goes vacuous rather than red.
    expect(construction).toBeGreaterThan(mainStart);

    // The window is `main()`'s own body up to the server construction, NOT the
    // whole file. The *correct* implementation puts a `_warm_up_model()` call
    // inside a loader helper, and helpers are defined above `main()` — scanning
    // from byte 0 would fail the fixed shape as loudly as the broken one.
    const beforeServing = source.slice(mainStart, construction);

    // Any body-level call to something named like a model load, before the
    // server is constructed. Loose on the name on purpose: the point is that no
    // blocking load happens first, not what stage 3 calls its function. Loose
    // on the arguments too — `_load_model(status)` blocks exactly as hard as
    // `_load_model()`.
    expect(beforeServing).not.toMatch(/^[ \t]+_?\w*(?:warm_up|load_model|load_the_model)\w*\(/m);
  });

  test("loads the model on a background thread", () => {
    expect(readSource(SERVE_PY)).toMatch(/threading\.Thread\(/);
  });

  test("serves requests concurrently, or /status cannot be answered during a transcription", () => {
    // See this file's header. `socketserver.UnixStreamServer` is one-request-at-
    // a-time; once `/transcribe` blocks on `wait_until_ready()`, a
    // single-threaded server makes `/status` unanswerable exactly when it
    // matters, and §E ships doing nothing.
    const source = readSource(SERVE_PY);
    expect(source).toMatch(/class\s+UnixHTTPServer\([^)]*ThreadingMixIn/);
  });

  test("POST /transcribe waits for readiness instead of erroring", () => {
    // 「POST /transcribe 在模型未就绪时**阻塞等待**（保持今天的语义，Swift 侧已有
    // 超时），不要改成报错」. This is 「录音不能丢」 at the HTTP layer: the audio is
    // already recorded by the time it gets here, and a 503 throws it away.
    const source = readSource(SERVE_PY);
    expect(source).toMatch(/wait_until_ready\(/);
    // No "model not ready" rejection status anywhere in the file.
    expect(source).not.toMatch(/_send_json\(\s*503/);
  });

  test("keeps OPENTYPE_WHISPER_MODEL working as an override", () => {
    // §E-4: the env var stays; the *saved* config simply wins over it, which the
    // sidecar arranges by passing the resolved model down as this same variable
    // (`test/asr/whisperModel.test.ts`). Deleting it here would break every dev
    // who sets it today and every packaged launch at the same time.
    expect(readSource(SERVE_PY)).toMatch(/OPENTYPE_WHISPER_MODEL/);
  });
});

/**
 * ---------------------------------------------------------------------------
 * What stage 4 must verify by hand in `serve.py`
 * ---------------------------------------------------------------------------
 *
 * The guards above are structural. None of them proves the server behaves, and
 * the four checks below cannot be automated without a real MLX venv and a real
 * model download. Run them against a live `serve.py`:
 *
 *  1. **`/status` answers before the model is loaded.** Delete
 *     `~/.cache/huggingface/hub/models--mlx-community--whisper-small-mlx` (or
 *     point `OPENTYPE_WHISPER_MODEL` at a model you have not downloaded), start
 *     `serve.py`, and `curl --unix-socket … http://localhost/status` **during**
 *     the download. Expect `{"state":"downloading", …}` within a second, not a
 *     connection refused and not a hang.
 *
 *  2. **`/status` still answers while `/transcribe` is blocked.** With the model
 *     still downloading, POST a WAV to `/transcribe` (it must block), then hit
 *     `/status` from a second shell. If that second request hangs, the
 *     `ThreadingMixIn` above is present but something else serialises requests —
 *     this is the failure mode most likely to survive every test in this file.
 *
 *  3. **The blocked transcription completes.** The POST from (2) must return the
 *     transcript once the model finishes loading — not a timeout, not an error.
 *     This is 「录音不能丢」 end to end.
 *
 *  4. **Bytes actually move.** `downloadedBytes` must increase across successive
 *     `/status` calls during a real download. `totalBytes` may legitimately stay
 *     `null` — that degradation is by design — but a `downloadedBytes` frozen at
 *     0 means the tqdm hook is not wired, and the progress bar will sit at 0%
 *     for the entire minute this section exists to fix.
 */
