"""The whisper server's model-load state, as a unit that can be tested.

`serve.py` imports `numpy` and `mlx_whisper` at module scope, so nothing in it
can be imported without the whole `sidecar/whisper-env` venv. That is why this
module exists separately and why it is **standard library only**: it holds the
state machine `GET /status` reports, and `sidecar/test/whisper/test_model_status.py`
drives it directly, under `python3 -S` if need be. A third-party import creeping
in here would quietly take those unit tests with it.

The state it holds is what turns the first launch from a blank screen into
something the user can read. Before §E, `serve.py` warmed the model *before*
constructing its socket server, so during the first ~460 MB download there was
nobody listening to answer 「你在干嘛」 — the app had no way to know, and so
neither did the user.

Four decisions worth keeping, each pinned by a test:

- **The initial state is `downloading`, not a fifth `"idle"`.** `"starting"`
  belongs to the sidecar's `GET /asr/status`, where it means 「python 子进程还没
  起来」 — something only the parent process can observe. Once this module is
  answering at all, it is past starting. An already-cached model spends
  milliseconds here and moves on.
- **`totalBytes` stays `None` until something says otherwise, and `None` is a
  legitimate resting value.** `huggingface_hub`'s progress hook does not always
  know a total. `0` would render as a bar frozen at 0% forever, which is worse
  than no bar; the states matter far more than the bytes.
- **`wait_until_ready` returns `False` on failure rather than blocking.** This
  is what makes 「录音不能丢」 true — a recording that lands mid-download is held
  and transcribed when the model comes up — without turning a model that cannot
  load into a wedge. The caller answers with the real error instead.
- **Progress never moves the state.** Only the `mark_*` calls do. If a late
  chunk of download progress could knock a loaded model back to `downloading`,
  the banner would restart on a model that is already up.
"""

from __future__ import annotations

import threading

DOWNLOADING = "downloading"
LOADING = "loading"
READY = "ready"
FAILED = "failed"


class ModelStatus:
    """Thread-safe holder for where the model load has got to.

    Written to by the loader thread, read by every HTTP handler thread, and
    waited on by `POST /transcribe`. All three touch it at once, so every
    accessor takes the lock — `snapshot()` included, since a dict built from
    fields read one at a time can describe a state that never existed.
    """

    def __init__(self, model: str) -> None:
        self._model = model
        self._state = DOWNLOADING
        self._downloaded_bytes = 0
        self._total_bytes: int | None = None
        self._error: str | None = None
        # A Condition rather than an Event: `wait_until_ready` has to wake for
        # *either* terminal state, and every waiter has to wake, not just one.
        self._condition = threading.Condition()

    # -- Observation --------------------------------------------------------

    def snapshot(self) -> dict:
        """Exactly the body of `GET /status`.

        camelCase because this dict is `json.dumps`'d straight onto the wire and
        decoded by TypeScript and Swift; snake_case here would be a decode
        failure there, not a style question. A fresh dict every call, so a
        handler that mutates what it was handed cannot rewrite the state machine
        from the HTTP layer.
        """
        with self._condition:
            return {
                "state": self._state,
                "model": self._model,
                "downloadedBytes": self._downloaded_bytes,
                "totalBytes": self._total_bytes,
                "error": self._error,
            }

    # -- Progress -----------------------------------------------------------

    def add_downloaded_bytes(self, count: int) -> None:
        """Add an increment, as the tqdm callback reports them (not a total)."""
        with self._condition:
            self._downloaded_bytes += count

    def set_total_bytes(self, total: int | None) -> None:
        """Record the expected size, or `None` when it is not known.

        Settable back to `None` on purpose: a progress hook that stops knowing
        the total must degrade the bar rather than have its `None` coerced to a
        `0` that reads as a download which finished instantly.
        """
        with self._condition:
            self._total_bytes = total

    # -- Transitions --------------------------------------------------------

    def mark_loading(self) -> None:
        """Bytes are on disk; MLX is now building the model."""
        with self._condition:
            self._state = LOADING
            self._condition.notify_all()

    def mark_ready(self) -> None:
        with self._condition:
            self._state = READY
            self._error = None
            self._condition.notify_all()

    def mark_failed(self, error: str) -> None:
        """Record the real message.

        The text is the whole diagnostic value: 「No space left on device」 tells
        the user what to fix, 「模型加载失败」 does not. Progress is deliberately
        left alone — 「下到 300 MB 断了」 and 「一个字节都没下到」 are different
        problems, and this snapshot is the only place that difference survives.
        """
        with self._condition:
            self._state = FAILED
            self._error = error
            self._condition.notify_all()

    # -- What POST /transcribe waits on -------------------------------------

    def wait_until_ready(self, timeout: float | None = None) -> bool:
        """Block until the model is usable; `True` if it is.

        Returns `False` for a failed load and for a timeout, so the caller can
        answer with the error instead of hanging. The default is to wait
        indefinitely: the outer bound belongs to the caller, and this caller is
        the Swift app, which already has one. A default deadline here would be a
        second, invisible timeout nobody could see or change.
        """
        with self._condition:
            if timeout is None:
                self._condition.wait_for(lambda: self._state in (READY, FAILED))
            elif not self._condition.wait_for(
                lambda: self._state in (READY, FAILED), timeout=timeout
            ):
                return False
            return self._state == READY
