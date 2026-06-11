#!/usr/bin/env python3
"""Fake OpenAI-compatible LLM server for Collavre demo recording.

Streams pre-injected scripted responses as OpenAI Chat Completions SSE so the
*real* Collavre agent pipeline animates in the recording (typing indicator +
token-by-token stream). No external dependencies — Python stdlib only.

Endpoints
  POST /inject               body: {"responses": ["...", "..."]}  -> FIFO queue
  POST /reset                clear the queue
  GET  /health               {"ok": true, "queued": N}
  GET  /v1/models            minimal model list (some clients probe this)
  POST /v1/chat/completions  OpenAI-compatible. Pops the next queued response
                             and streams it (or returns it whole when the
                             request does not ask for streaming).

Each call to /v1/chat/completions consumes one queued response (FIFO). When the
queue is empty it falls back to FAKE_LLM_FALLBACK so a recording never hangs.

Env
  FAKE_LLM_PORT          port to bind (default 8730)
  FAKE_LLM_TOKEN_DELAY   seconds between streamed chunks (default 0.025)
  FAKE_LLM_CHUNK         characters per streamed chunk (default 2)
  FAKE_LLM_FALLBACK      response used when the queue is empty
"""

import json
import os
import sys
import threading
import time
from collections import deque
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(os.environ.get("FAKE_LLM_PORT", "8730"))
TOKEN_DELAY = float(os.environ.get("FAKE_LLM_TOKEN_DELAY", "0.025"))
CHUNK_SIZE = max(1, int(os.environ.get("FAKE_LLM_CHUNK", "2")))
FALLBACK = os.environ.get(
    "FAKE_LLM_FALLBACK",
    "분석을 완료했습니다. 추가로 궁금한 점이 있으면 언제든 알려주세요.",
)

_queue = deque()
_lock = threading.Lock()


def _now():
    return int(time.time())


def _next_response():
    with _lock:
        if _queue:
            return _queue.popleft()
    return FALLBACK


def _chunks(text):
    for i in range(0, len(text), CHUNK_SIZE):
        yield text[i : i + CHUNK_SIZE]


class Handler(BaseHTTPRequestHandler):
    # Silence default request logging (keep stdout clean for the orchestrator).
    def log_message(self, fmt, *args):  # noqa: N802
        pass

    # ---- helpers -------------------------------------------------------
    def _read_json(self):
        length = int(self.headers.get("Content-Length", 0) or 0)
        if not length:
            return {}
        raw = self.rfile.read(length)
        try:
            return json.loads(raw or b"{}")
        except (ValueError, TypeError):
            return {}

    def _send_json(self, obj, status=200):
        body = json.dumps(obj).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    # ---- routing -------------------------------------------------------
    def do_GET(self):  # noqa: N802
        if self.path.rstrip("/") == "/health":
            with _lock:
                queued = len(_queue)
            return self._send_json({"ok": True, "queued": queued})
        if self.path.rstrip("/").endswith("/v1/models") or self.path.rstrip("/") == "/models":
            return self._send_json(
                {
                    "object": "list",
                    "data": [{"id": "demo", "object": "model", "owned_by": "demo"}],
                }
            )
        return self._send_json({"error": "not found"}, status=404)

    def do_POST(self):  # noqa: N802
        path = self.path.rstrip("/")
        if path == "/inject":
            data = self._read_json()
            responses = data.get("responses", [])
            if isinstance(responses, str):
                responses = [responses]
            with _lock:
                for r in responses:
                    _queue.append(str(r))
                queued = len(_queue)
            return self._send_json({"ok": True, "queued": queued})

        if path == "/reset":
            with _lock:
                _queue.clear()
            return self._send_json({"ok": True, "queued": 0})

        if path.endswith("/chat/completions"):
            return self._chat_completions()

        return self._send_json({"error": "not found"}, status=404)

    # ---- the OpenAI-compatible endpoint --------------------------------
    def _chat_completions(self):
        req = self._read_json()
        model = req.get("model", "demo")
        stream = bool(req.get("stream", False))
        content = _next_response()

        if not stream:
            return self._send_json(
                {
                    "id": "chatcmpl-demo",
                    "object": "chat.completion",
                    "created": _now(),
                    "model": model,
                    "choices": [
                        {
                            "index": 0,
                            "message": {"role": "assistant", "content": content},
                            "finish_reason": "stop",
                        }
                    ],
                    "usage": {
                        "prompt_tokens": 0,
                        "completion_tokens": len(content),
                        "total_tokens": len(content),
                    },
                }
            )

        # Streaming (SSE) response.
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream; charset=utf-8")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "keep-alive")
        self.end_headers()

        created = _now()

        def emit(delta, finish=None):
            payload = {
                "id": "chatcmpl-demo",
                "object": "chat.completion.chunk",
                "created": created,
                "model": model,
                "choices": [
                    {"index": 0, "delta": delta, "finish_reason": finish}
                ],
            }
            self.wfile.write(b"data: " + json.dumps(payload).encode("utf-8") + b"\n\n")
            self.wfile.flush()

        try:
            emit({"role": "assistant", "content": ""})
            for piece in _chunks(content):
                emit({"content": piece})
                time.sleep(TOKEN_DELAY)
            emit({}, finish="stop")
            self.wfile.write(b"data: [DONE]\n\n")
            self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            # Client (Collavre) closed the stream early — nothing to do.
            pass


class QuietServer(ThreadingHTTPServer):
    daemon_threads = True

    def handle_error(self, request, client_address):
        # Streaming clients (Collavre / curl) routinely close mid-stream;
        # don't spew a traceback for benign connection resets.
        exc = sys.exc_info()[1]
        if isinstance(exc, (BrokenPipeError, ConnectionResetError)):
            return
        super().handle_error(request, client_address)


def main():
    server = QuietServer(("127.0.0.1", PORT), Handler)
    print(f"[fake_llm] listening on http://127.0.0.1:{PORT}  "
          f"(delay={TOKEN_DELAY}s chunk={CHUNK_SIZE})", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.shutdown()


if __name__ == "__main__":
    sys.exit(main())
