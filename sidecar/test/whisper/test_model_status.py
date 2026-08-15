"""STAGE-1 (red) unit tests for the whisper server's model-status state holder.

Part of §E of `docs/superpowers/specs/2026-08-15-product-batch-plan.md` — 消灭
「装完、按热键、说完、松开、什么都没有」这一分钟.

---------------------------------------------------------------------------
Why this file exists at all
---------------------------------------------------------------------------

`sidecar/whisper/serve.py` today calls `_warm_up_model()` *before* it constructs
its `UnixHTTPServer`, so during the first-launch ~460 MB model download there is
literally nobody listening to answer 「你在干嘛」. §E-1 turns that around: serve
first, load on a background thread, and expose the load's state over
`GET /status`.

That state is the thing worth unit-testing, and it cannot be tested inside
`serve.py`: importing that module pulls in `numpy` and `mlx_whisper`, which only
exist inside `sidecar/whisper-env/`. So stage 1 pins a **separate,
stdlib-only** module — `sidecar/whisper/model_status.py` — holding the state
machine and nothing else, which this file drives directly. `serve.py` imports it
and owns only the HTTP plumbing and the actual model load. Splitting it is not
decoration: it is what makes the state machine a pure unit in a repo that has no
pytest and is not getting one.

This repo has no Python test harness and this file does not invent one: no
pytest, no unittest discovery, no new dependency. It is a plain module with a
`__main__` runner that returns a non-zero exit code on failure, invoked from
`sidecar/test/whisper/modelStatus.test.ts` so it runs as part of `bun test`
alongside everything else.

---------------------------------------------------------------------------
The contract stage 3 must implement, in `sidecar/whisper/model_status.py`
---------------------------------------------------------------------------

    from __future__ import annotations   # required; see modelStatus.test.ts

    DOWNLOADING = "downloading"
    LOADING     = "loading"
    READY       = "ready"
    FAILED      = "failed"

    class ModelStatus:
        def __init__(self, model: str) -> None: ...

        # Observation — the exact body of GET /status.
        def snapshot(self) -> dict: ...

        # Progress, from the download's tqdm callback.
        def add_downloaded_bytes(self, count: int) -> None: ...
        def set_total_bytes(self, total) -> None: ...   # None means "unknown"

        # Transitions.
        def mark_loading(self) -> None: ...
        def mark_ready(self) -> None: ...
        def mark_failed(self, error: str) -> None: ...

        # What POST /transcribe waits on.
        def wait_until_ready(self, timeout=None) -> bool: ...

Four decisions this file makes on stage 3's behalf, deliberately:

1.  **The initial state is `downloading`, not a fifth `"idle"`/`"starting"`.**
    `"starting"` belongs to the *sidecar* (`GET /asr/status`), where it means
    「python 子进程还没起来」 — a thing only the parent can observe. Once
    `serve.py` is answering HTTP at all, it is past starting. A model that turns
    out to be already cached spends milliseconds in `downloading` and moves on;
    a fifth state would exist only to describe those milliseconds.

2.  **`totalBytes` is `None` until something tells us otherwise, and `None` is a
    legitimate resting value.** The spec is explicit —「拿不到就退化成
    `totalBytes: null`——状态机（downloading/loading/ready）比字节数重要得多」.
    `0` would render as a progress bar stuck at 0% forever, which is worse than
    no bar at all, so the tests below pin `None` rather than a falsy default.

3.  **`wait_until_ready` returns `False` on failure instead of blocking.** This
    is the seam that makes 「录音不能丢」 true: a recording that lands mid-download
    waits for the model and is then transcribed normally, rather than being
    dropped. But a *failed* load must not turn that guarantee into a hang — the
    caller needs to answer HTTP 500 with the real error so the user reaches
    §E-3's 重试 / 改用远程识别 exit.

4.  **Progress updates never change the state.** Only `mark_*` moves the
    machine. `huggingface_hub`'s tqdm can emit a final chunk after the download
    finishes, and a stray byte count knocking `ready` back to `downloading`
    would restart the banner on a model that is already loaded.
"""

import json
import os
import sys
import threading
import time

sys.path.insert(
    0,
    os.path.abspath(
        os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "whisper")
    ),
)

from model_status import (  # noqa: E402
    DOWNLOADING,
    FAILED,
    LOADING,
    READY,
    ModelStatus,
)

MODEL = "mlx-community/whisper-small-mlx"


# ---------------------------------------------------------------------------
# The wire contract
# ---------------------------------------------------------------------------


def test_state_constants_are_the_wire_strings():
    # These land verbatim in `GET /status`, are re-emitted by the sidecar's
    # `GET /asr/status`, and are matched against a Swift enum's raw values. A
    # rename here is a silent UI outage three layers away.
    assert DOWNLOADING == "downloading"
    assert LOADING == "loading"
    assert READY == "ready"
    assert FAILED == "failed"


def test_initial_snapshot_is_downloading_with_no_progress_known():
    status = ModelStatus(MODEL)

    assert status.snapshot() == {
        "state": "downloading",
        "model": MODEL,
        "downloadedBytes": 0,
        "totalBytes": None,
        "error": None,
    }


def test_snapshot_keys_are_exactly_the_five_the_spec_names():
    # camelCase, because this dict is `json.dumps`'d straight onto the wire and
    # read by TypeScript and Swift. snake_case here would be a decode failure
    # there, not a style question.
    assert set(ModelStatus(MODEL).snapshot()) == {
        "state",
        "model",
        "downloadedBytes",
        "totalBytes",
        "error",
    }


def test_snapshot_is_json_serialisable_in_every_state():
    for arrange in (
        lambda s: None,
        lambda s: s.set_total_bytes(460_000_000),
        lambda s: s.mark_loading(),
        lambda s: s.mark_ready(),
        lambda s: s.mark_failed("no space left on device"),
    ):
        status = ModelStatus(MODEL)
        arrange(status)
        json.dumps(status.snapshot())


def test_snapshot_is_a_copy_the_caller_cannot_corrupt():
    # The handler serialises whatever it is handed; if that were the live dict,
    # one careless `snapshot()["state"] = ...` would rewrite the state machine
    # from the HTTP layer.
    status = ModelStatus(MODEL)
    taken = status.snapshot()
    taken["state"] = "ready"
    taken["downloadedBytes"] = 999

    assert status.snapshot()["state"] == "downloading"
    assert status.snapshot()["downloadedBytes"] == 0


# ---------------------------------------------------------------------------
# Progress
# ---------------------------------------------------------------------------


def test_downloaded_bytes_accumulate_across_calls():
    # The tqdm callback reports increments, not a running total.
    status = ModelStatus(MODEL)

    status.add_downloaded_bytes(1_000)
    status.add_downloaded_bytes(2_500)

    assert status.snapshot()["downloadedBytes"] == 3_500


def test_total_bytes_can_be_learned_late():
    status = ModelStatus(MODEL)
    assert status.snapshot()["totalBytes"] is None

    status.set_total_bytes(460_000_000)

    assert status.snapshot()["totalBytes"] == 460_000_000


def test_total_bytes_can_be_set_back_to_unknown():
    # `snapshot_download`'s tqdm does not always know a total; a `None` from the
    # progress hook must degrade the bar, not be coerced to 0 (which reads as a
    # finished-instantly download).
    status = ModelStatus(MODEL)
    status.set_total_bytes(460_000_000)

    status.set_total_bytes(None)

    assert status.snapshot()["totalBytes"] is None


def test_progress_still_works_when_the_total_is_never_known():
    status = ModelStatus(MODEL)

    status.add_downloaded_bytes(12_345)
    status.mark_loading()
    status.mark_ready()

    assert status.snapshot()["downloadedBytes"] == 12_345
    assert status.snapshot()["totalBytes"] is None
    assert status.snapshot()["state"] == "ready"


def test_progress_updates_never_move_the_state():
    # A late tqdm chunk must not knock a loaded model back to "downloading" and
    # restart the 「正在准备语音模型」 banner.
    status = ModelStatus(MODEL)
    status.mark_ready()

    status.add_downloaded_bytes(4_096)
    status.set_total_bytes(460_000_000)

    assert status.snapshot()["state"] == "ready"


def test_concurrent_progress_updates_do_not_lose_counts():
    # The download runs on a background thread while the HTTP thread reads
    # `snapshot()`; `huggingface_hub` may also parallelise file downloads. An
    # unguarded `self._downloaded += n` loses updates under exactly that.
    status = ModelStatus(MODEL)
    threads = [
        threading.Thread(target=lambda: [status.add_downloaded_bytes(1) for _ in range(500)])
        for _ in range(8)
    ]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join()

    assert status.snapshot()["downloadedBytes"] == 4_000


# ---------------------------------------------------------------------------
# Transitions
# ---------------------------------------------------------------------------


def test_mark_loading_moves_to_loading_and_keeps_the_model_and_progress():
    status = ModelStatus(MODEL)
    status.add_downloaded_bytes(460_000_000)
    status.set_total_bytes(460_000_000)

    status.mark_loading()

    snapshot = status.snapshot()
    assert snapshot["state"] == "loading"
    assert snapshot["model"] == MODEL
    assert snapshot["downloadedBytes"] == 460_000_000
    assert snapshot["error"] is None


def test_mark_ready_moves_to_ready_with_no_error():
    status = ModelStatus(MODEL)
    status.mark_loading()

    status.mark_ready()

    assert status.snapshot()["state"] == "ready"
    assert status.snapshot()["error"] is None


def test_mark_failed_records_the_real_error_text():
    # The message is the whole diagnostic value: 「No space left on device」 tells
    # the user what to fix, 「模型加载失败」 does not. Same stance
    # `mcpBootResilience.test.ts` takes for a failed MCP server.
    status = ModelStatus(MODEL)

    status.mark_failed("HTTPError: 401 Client Error for url: https://huggingface.co/...")

    snapshot = status.snapshot()
    assert snapshot["state"] == "failed"
    assert "401" in snapshot["error"]


def test_a_failure_after_a_partial_download_keeps_the_partial_progress():
    # 「下到 300 MB 断了」 and 「一个字节都没下到」 are different problems with
    # different fixes, and the snapshot is the only place that difference exists.
    status = ModelStatus(MODEL)
    status.set_total_bytes(460_000_000)
    status.add_downloaded_bytes(300_000_000)

    status.mark_failed("Connection reset by peer")

    snapshot = status.snapshot()
    assert snapshot["state"] == "failed"
    assert snapshot["downloadedBytes"] == 300_000_000
    assert snapshot["totalBytes"] == 460_000_000


# ---------------------------------------------------------------------------
# wait_until_ready — this is 「录音不能丢」
# ---------------------------------------------------------------------------


def test_wait_until_ready_returns_immediately_when_already_ready():
    status = ModelStatus(MODEL)
    status.mark_ready()

    started = time.monotonic()
    assert status.wait_until_ready(timeout=5) is True
    assert time.monotonic() - started < 0.5


def test_wait_until_ready_blocks_until_the_model_becomes_ready():
    # THE test for 「录音不能丢」: a recording that lands mid-download is held,
    # not rejected, and is transcribed the moment the model is up. `serve.py`
    # keeps today's semantics — POST /transcribe blocks, it does not start
    # erroring — and Swift already carries a timeout for the outer bound.
    status = ModelStatus(MODEL)
    observed = []

    def become_ready():
        time.sleep(0.05)
        status.mark_loading()
        time.sleep(0.05)
        status.mark_ready()

    loader = threading.Thread(target=become_ready)
    loader.start()
    observed.append(status.wait_until_ready(timeout=5))
    loader.join()

    assert observed == [True]
    assert status.snapshot()["state"] == "ready"


def test_wait_until_ready_returns_false_on_failure_rather_than_hanging():
    # Without this, a model that cannot load turns 「等一下就好」 into a wedge: the
    # request never answers, Swift's timeout eventually fires, and the user is
    # back at the blank screen this whole section exists to remove. Returning
    # False lets the handler answer 500 with the real error.
    status = ModelStatus(MODEL)

    def fail_soon():
        time.sleep(0.05)
        status.mark_failed("No space left on device")

    failer = threading.Thread(target=fail_soon)
    failer.start()
    result = status.wait_until_ready(timeout=5)
    failer.join()

    assert result is False


def test_wait_until_ready_returns_false_immediately_when_already_failed():
    status = ModelStatus(MODEL)
    status.mark_failed("boom")

    started = time.monotonic()
    assert status.wait_until_ready(timeout=5) is False
    assert time.monotonic() - started < 0.5


def test_wait_until_ready_times_out_returning_false():
    status = ModelStatus(MODEL)

    started = time.monotonic()
    result = status.wait_until_ready(timeout=0.05)
    elapsed = time.monotonic() - started

    assert result is False
    assert elapsed >= 0.05
    # Still downloading — a timed-out wait must not have declared it failed.
    assert status.snapshot()["state"] == "downloading"


def test_several_waiters_are_all_released_by_one_mark_ready():
    # Two dictations queued behind the same first-launch download is an ordinary
    # case, not a corner: the user presses the hotkey, sees nothing, and presses
    # it again. A one-shot event would strand the second one forever.
    status = ModelStatus(MODEL)
    results = []
    lock = threading.Lock()

    def wait():
        outcome = status.wait_until_ready(timeout=5)
        with lock:
            results.append(outcome)

    waiters = [threading.Thread(target=wait) for _ in range(3)]
    for waiter in waiters:
        waiter.start()
    time.sleep(0.05)
    status.mark_ready()
    for waiter in waiters:
        waiter.join()

    assert results == [True, True, True]


def test_wait_until_ready_with_no_timeout_waits_indefinitely():
    # The default is 「一直等」 because the outer bound belongs to the caller, and
    # `serve.py`'s caller is Swift, which has one. A default timeout here would
    # be a second, invisible deadline nobody could see or change.
    status = ModelStatus(MODEL)
    result = []

    def wait():
        result.append(status.wait_until_ready())

    waiter = threading.Thread(target=wait)
    waiter.start()
    time.sleep(0.1)
    assert result == []  # still waiting, no default deadline fired

    status.mark_ready()
    waiter.join(timeout=5)
    assert result == [True]


# ---------------------------------------------------------------------------
# Runner: no pytest, no unittest discovery, no new dependency.
# ---------------------------------------------------------------------------


def _main() -> int:
    tests = [
        value
        for name, value in globals().items()
        if name.startswith("test_") and callable(value)
    ]
    tests.sort(key=lambda fn: fn.__code__.co_firstlineno)

    failures = []
    for test in tests:
        try:
            test()
        except Exception as exc:  # noqa: BLE001 - a test runner reports everything
            import traceback

            failures.append((test.__name__, traceback.format_exc()))
            print("FAIL {}: {}".format(test.__name__, exc))
        else:
            print("ok   {}".format(test.__name__))

    print("\n{} passed, {} failed, {} total".format(
        len(tests) - len(failures), len(failures), len(tests)
    ))
    for name, trace in failures:
        print("\n--- {} ---\n{}".format(name, trace))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(_main())
