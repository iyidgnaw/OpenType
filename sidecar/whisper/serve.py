#!/usr/bin/env python3
"""Persistent local MLX-Whisper transcription server.

Serves transcription requests over a Unix domain socket, spawned once by the
TypeScript sidecar (see `sidecar/src/asr/whisperClient.ts`) and reused for the
lifetime of the app. The model is loaded once, in the background, because
loading has real latency and paying it per request would make every
transcription noticeably slower.

**The socket opens before the model loads, and that ordering is the point.**
Until §E this file warmed the model first, so during the first launch's ~460 MB
download there was nobody listening: the app could not ask what was happening,
and so neither could the user — install, grant, hold the hotkey, speak, release,
and nothing, for minutes. Now the server is up immediately, the load runs on a
background thread, and `GET /status` reports where it has got to.

Endpoints:
  GET  /health      -> {"status": "ok"}
  GET  /status      -> the model load's state; see `model_status.ModelStatus`
  POST /transcribe   -> body is the raw bytes of a WAV file; returns {"text": "..."}
                        optional query parameter `initial_prompt` (URL-encoded)
                        biases decoding toward known proper nouns; optional
                        query parameter `language` (an ISO-639-1 code) pins the
                        spoken language instead of letting Whisper detect it.
                        **Waits** when the model is not ready yet rather than
                        rejecting: the audio is already recorded by the time it
                        arrives here, and refusing it throws away words the user
                        has already spoken.

Deliberately dependency-light: the standard library plus `mlx_whisper` (and
`huggingface_hub`, which comes with it, for download progress). `http.server` +
`socketserver.UnixStreamServer` mirror the Unix-socket-over-HTTP pattern
`sidecar/src/server.ts` uses via `Bun.serve({unix: ...})`.
"""

import json
import os
import socketserver
import sys
import tempfile
import threading
from http.server import BaseHTTPRequestHandler
from urllib.parse import parse_qs, urlparse

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import numpy as np
import mlx_whisper

from model_status import ModelStatus

# "small" is the chosen balance for interactive dictation: multilingual (not
# a .en-only variant, since this app also transcribes Chinese), noticeably
# more accurate than "tiny"/"base" on real speech, while still transcribing
# a short dictation clip in well under a second once warm on Apple Silicon
# GPU/ANE via MLX -- "medium"/"large" trade that responsiveness away for
# marginal accuracy gains that don't matter much for short voice-input clips.
DEFAULT_MODEL = "mlx-community/whisper-small-mlx"
MODEL = os.environ.get("OPENTYPE_WHISPER_MODEL", DEFAULT_MODEL)

# mlx_whisper.transcribe() caches the loaded model in a process-global
# (ModelHolder, keyed by path_or_hf_repo) so repeated calls with the same
# model path reuse it -- this lock just serializes concurrent requests
# against that shared, non-thread-safe model state.
_transcribe_lock = threading.Lock()

# Where the model load has got to, reported by GET /status and waited on by
# POST /transcribe. Lives in its own stdlib-only module so it can be unit
# tested without the MLX venv -- see `model_status.py`.
STATUS = ModelStatus(MODEL)


def _byte_counting_tqdm(status: ModelStatus):
    """A tqdm subclass that reports download progress into `status`.

    `huggingface_hub` drives one bar per file for the bytes plus an outer bar
    counting files, so only the byte bars (`unit == "B"`) are counted -- adding
    the outer one would inflate the figure with a file count.

    Returns `None` if tqdm is not importable, which is not a failure worth
    stopping for: the states matter far more than the bytes, and `totalBytes`
    degrading to null is the documented fallback.
    """
    try:
        from tqdm.auto import tqdm as _tqdm
    except Exception:  # noqa: BLE001 - progress is optional, the download is not
        return None

    class _ByteCountingTqdm(_tqdm):  # type: ignore[misc, valid-type]
        def __init__(self, *args, **kwargs):
            super().__init__(*args, **kwargs)
            if getattr(self, "unit", None) == "B" and self.total:
                status.set_total_bytes((status.snapshot()["totalBytes"] or 0) + self.total)

        def update(self, n=1):
            if n and getattr(self, "unit", None) == "B":
                status.add_downloaded_bytes(int(n))
            return super().update(n)

    return _ByteCountingTqdm


def _download_model(status: ModelStatus) -> None:
    """Fetch the weights, reporting bytes as they arrive.

    Best-effort by design. `MODEL` may be a local directory rather than a Hub
    repo id, `huggingface_hub` may be absent, and the download may already be
    cached -- none of which is a problem, because `mlx_whisper` fetches whatever
    is missing anyway when the model is loaded. All this adds is a byte count
    for the wait, so every failure here is swallowed rather than surfaced.
    """
    if os.path.isdir(MODEL):
        return
    try:
        from huggingface_hub import snapshot_download
    except Exception:  # noqa: BLE001 - see docstring
        return

    tqdm_class = _byte_counting_tqdm(status)
    try:
        if tqdm_class is None:
            snapshot_download(MODEL)
        else:
            snapshot_download(MODEL, tqdm_class=tqdm_class)
    except Exception:  # noqa: BLE001 - see docstring
        return


def _warm_up_model() -> None:
    """Forces the model to load now rather than on the first transcription."""
    silence = np.zeros(16_000, dtype=np.float32)  # 1s of silence at 16kHz
    mlx_whisper.transcribe(silence, path_or_hf_repo=MODEL)


def _prepare_model(status: ModelStatus) -> None:
    """The background thread's whole job: download, load, and say so.

    A failure is recorded rather than raised. The thread has nobody to raise to,
    and the message is what the user needs -- 「No space left on device」 tells
    them what to fix, and it reaches them through `/status` and the app's retry
    and switch-to-remote exits.
    """
    try:
        _download_model(status)
        status.mark_loading()
        print(f"Loading MLX-Whisper model '{MODEL}'...", file=sys.stderr, flush=True)
        _warm_up_model()
    except Exception as exc:  # noqa: BLE001 - see docstring
        status.mark_failed(str(exc))
        print(f"Model preparation failed: {exc}", file=sys.stderr, flush=True)
        return
    status.mark_ready()
    print("Model loaded.", file=sys.stderr, flush=True)


class UnixHTTPServer(socketserver.ThreadingMixIn, socketserver.UnixStreamServer):
    """One thread per request.

    `UnixStreamServer` alone handles one request at a time, which was invisible
    while nothing called this server concurrently. It stops being invisible the
    moment `/transcribe` blocks waiting for the model: a single-threaded server
    could not answer `/status` while a recording was queued behind the download,
    so the endpoint that exists to explain the wait would be unreachable exactly
    when the user is waiting. Threading is what makes the rest of §E true.
    """

    allow_reuse_address = True
    daemon_threads = True


class WhisperRequestHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, format: str, *args) -> None:  # noqa: A002 - stdlib signature
        sys.stderr.write("%s - %s\n" % (self.address_string(), format % args))

    def _send_json(self, status: int, payload: dict) -> None:
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def address_string(self) -> str:
        # BaseHTTPRequestHandler.address_string() assumes a (host, port)
        # tuple, which Unix-domain client addresses aren't.
        return "unix-socket-client"

    def _path_only(self) -> str:
        # Bun's `fetch(url, {unix: socketPath})` sends an absolute-form
        # request target (e.g. "http://localhost:80/health") rather than the
        # origin-form ("/health") most HTTP/1.1 clients use, so comparing
        # `self.path` directly against "/health"/"/transcribe" silently
        # 404s every request. Parse out just the path component so both
        # forms match the same way.
        return urlparse(self.path).path

    def _query_param(self, name: str) -> str:
        # Decode options are sent as query parameters rather than headers
        # because a header value must be latin-1 safe and `initial_prompt`'s
        # terms are routinely CJK. Absent or empty means "unset": mlx_whisper
        # must receive its own default (None) rather than initial_prompt="" or
        # language="" -- a language named "" is not the same request as "detect
        # the language yourself".
        values = parse_qs(urlparse(self.path).query).get(name, [])
        return values[0].strip() if values else ""

    def do_GET(self) -> None:  # noqa: N802 - stdlib method name
        path = self._path_only()
        if path == "/health":
            # Deliberately not gated on the model: health means "this process is
            # answering", and the sidecar polls it to decide the server is up.
            # Whether the model is ready is what /status is for.
            self._send_json(200, {"status": "ok"})
        elif path == "/status":
            self._send_json(200, STATUS.snapshot())
        else:
            self._send_json(404, {"error": "not_found"})

    def do_POST(self) -> None:  # noqa: N802 - stdlib method name
        if self._path_only() != "/transcribe":
            self._send_json(404, {"error": "not_found"})
            return

        try:
            length = int(self.headers.get("Content-Length", 0))
        except ValueError:
            self._send_json(400, {"error": "missing or invalid Content-Length"})
            return

        audio_bytes = self.rfile.read(length) if length > 0 else b""
        if not audio_bytes:
            self._send_json(400, {"error": "empty request body"})
            return

        initial_prompt = self._query_param("initial_prompt")
        language = self._query_param("language")

        # Wait rather than reject. The words are already spoken and recorded by
        # the time this arrives, so refusing would throw them away; the caller
        # (Swift) carries the outer deadline. A load that has *failed* returns
        # False instead of waiting forever, so the user gets the real reason and
        # can reach the retry / switch-to-remote exits.
        if not STATUS.wait_until_ready():
            snapshot = STATUS.snapshot()
            self._send_json(
                500,
                {"error": snapshot["error"] or "the speech model failed to load"},
            )
            return

        tmp_path = None
        try:
            with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as tmp_file:
                tmp_file.write(audio_bytes)
                tmp_path = tmp_file.name

            options = {"path_or_hf_repo": MODEL}
            if initial_prompt:
                options["initial_prompt"] = initial_prompt
            if language:
                # Unlike `initial_prompt`, `language` is not one of
                # `mlx_whisper.transcribe`'s named parameters -- it reaches the
                # decoder through that function's trailing `**decode_options`,
                # which is precisely what splatting this dict does. Keep it in
                # the dict; there is no top-level argument to bind it to.
                options["language"] = language

            with _transcribe_lock:
                result = mlx_whisper.transcribe(tmp_path, **options)
            text = (result.get("text") or "").strip()
            self._send_json(200, {"text": text})
        except Exception as exc:  # noqa: BLE001 - report any failure to the caller
            self._send_json(500, {"error": str(exc)})
        finally:
            if tmp_path is not None:
                try:
                    os.unlink(tmp_path)
                except OSError:
                    pass


def main() -> None:
    socket_path = os.environ.get("OPENTYPE_WHISPER_SOCKET")
    if not socket_path and len(sys.argv) > 1:
        socket_path = sys.argv[1]
    if not socket_path:
        print(
            "OPENTYPE_WHISPER_SOCKET is not set and no socket path argument was given.",
            file=sys.stderr,
        )
        sys.exit(1)

    # Remove a stale socket file from a previous run so binding doesn't fail.
    if os.path.exists(socket_path):
        os.unlink(socket_path)
    socket_dir = os.path.dirname(socket_path)
    if socket_dir:
        os.makedirs(socket_dir, exist_ok=True)

    server = UnixHTTPServer(socket_path, WhisperRequestHandler)
    print(f"opentype-whisper-server listening on unix:{socket_path}", file=sys.stderr, flush=True)

    # After the socket exists, never before: this thread is what the first
    # launch spends its minutes in, and until it finishes the only thing that
    # can tell anyone so is the server constructed above.
    threading.Thread(
        target=_prepare_model, args=(STATUS,), name="model-loader", daemon=True
    ).start()

    try:
        server.serve_forever()
    finally:
        server.server_close()
        if os.path.exists(socket_path):
            os.unlink(socket_path)


if __name__ == "__main__":
    main()
