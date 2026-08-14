#!/usr/bin/env python3
"""Persistent local MLX-Whisper transcription server.

Loads the MLX-Whisper model once at startup (model loading has real latency;
paying that cost per request would make every transcription noticeably
slower) and then serves transcription requests over a Unix domain socket, so
it can be spawned once by the TypeScript sidecar (see
`sidecar/src/asr/whisperClient.ts`) and reused for the lifetime of the app.

Endpoints:
  GET  /health      -> {"status": "ok"}
  POST /transcribe   -> body is the raw bytes of a WAV file; returns {"text": "..."}
                        optional query parameter `initial_prompt` (URL-encoded)
                        biases decoding toward known proper nouns.

Deliberately dependency-light: only the standard library plus `mlx_whisper`
itself (`http.server` + `socketserver.UnixStreamServer` for the Unix-socket
HTTP server, mirroring the Unix-socket-over-HTTP pattern
`sidecar/src/server.ts` uses via `Bun.serve({unix: ...})`).
"""

import json
import os
import socketserver
import sys
import tempfile
import threading
from http.server import BaseHTTPRequestHandler
from urllib.parse import parse_qs, urlparse

import numpy as np
import mlx_whisper

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


def _warm_up_model() -> None:
    """Forces the model to load now (at startup) rather than on first request."""
    silence = np.zeros(16_000, dtype=np.float32)  # 1s of silence at 16kHz
    mlx_whisper.transcribe(silence, path_or_hf_repo=MODEL)


class UnixHTTPServer(socketserver.UnixStreamServer):
    allow_reuse_address = True


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

    def _initial_prompt(self) -> str:
        # Sent as a query parameter rather than a header because a header value
        # must be latin-1 safe and these terms are routinely CJK. Absent or
        # empty means "no bias": mlx_whisper must receive the default (None),
        # never initial_prompt="".
        values = parse_qs(urlparse(self.path).query).get("initial_prompt", [])
        return values[0].strip() if values else ""

    def do_GET(self) -> None:  # noqa: N802 - stdlib method name
        if self._path_only() == "/health":
            self._send_json(200, {"status": "ok"})
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

        initial_prompt = self._initial_prompt()

        tmp_path = None
        try:
            with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as tmp_file:
                tmp_file.write(audio_bytes)
                tmp_path = tmp_file.name

            options = {"path_or_hf_repo": MODEL}
            if initial_prompt:
                options["initial_prompt"] = initial_prompt

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

    print(f"Loading MLX-Whisper model '{MODEL}'...", file=sys.stderr, flush=True)
    _warm_up_model()
    print("Model loaded.", file=sys.stderr, flush=True)

    server = UnixHTTPServer(socket_path, WhisperRequestHandler)
    print(f"opentype-whisper-server listening on unix:{socket_path}", file=sys.stderr, flush=True)
    try:
        server.serve_forever()
    finally:
        server.server_close()
        if os.path.exists(socket_path):
            os.unlink(socket_path)


if __name__ == "__main__":
    main()
