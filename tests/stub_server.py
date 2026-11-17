#!/usr/bin/env python3
"""Offline stub endpoint for qlaude's test suite (CI/dev only — never a user
path, spec C2). Speaks ONLY the wire shapes verified in spec §5.8 and
enforces auth: both routes require the configured dummy token in the style
QLAUDE_AUTH dictates plus the anthropic-version header; missing/wrong -> 401.
T1: minimal contract; T7 polishes (anthropic-version on both routes,
negative-path asserts)."""
import json
import os
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

TOKEN = os.environ.get("QLAUDE_CI_TOKEN", "qlaude-ci-dummy-token-8f31")
AUTH_STYLE = os.environ.get("QLAUDE_AUTH", "bearer")
PORTFILE = os.environ.get("QLAUDE_STUB_PORTFILE", "")


class Stub(BaseHTTPRequestHandler):
    def _authorized(self):
        if self.headers.get("anthropic-version") is None:
            return False
        if AUTH_STYLE == "api-key":
            return self.headers.get("x-api-key") == TOKEN
        return self.headers.get("Authorization") == "Bearer " + TOKEN

    def _send(self, code, payload):
        body = json.dumps(payload, separators=(",", ":")).encode()
        self.send_response(code)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(body)))
        # claude's SDK classifies a reply without request-id as "server
        # other" (T7 live-CLI ground truth).
        self.send_header("request-id", "stub_req_1")
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        # claude 2.x requests /v1/messages?beta=true — route on the path,
        # query string stripped (T7 live-CLI ground truth).
        if self.path.split("?", 1)[0] != "/v1/messages":
            self._send(404, {"error": {"type": "not_found_error"}})
            return
        if not self._authorized():
            self._send(401, {"error": {"type": "authentication_error"}})
            return
        length = int(self.headers.get("content-length", "0"))
        try:
            req = json.loads(self.rfile.read(length) or b"{}")
        except ValueError:
            self._send(400, {"error": {"type": "invalid_request_error"}})
            return
        model = req.get("model", "unknown")
        text = ""
        for msg in reversed(req.get("messages", [])):
            if msg.get("role") == "user":
                c = msg.get("content", "")
                text = c if isinstance(c, str) else str(c)
                break
        self._send(200, {
            "id": "stub-msg-1",
            "type": "message",
            "role": "assistant",
            "content": [{"type": "text", "text": text}],
            "stop_reason": "end_turn",
            "stop_sequence": None,
            "usage": {"input_tokens": 1, "output_tokens": 2,
                      "cache_read_input_tokens": 0,
                      "cache_creation_input_tokens": 0},
            "model": model,
        })

    def do_GET(self):
        if self.path.split("?", 1)[0] != "/v1/models":
            self._send(404, {"error": {"type": "not_found_error"}})
            return
        if not self._authorized():
            self._send(401, {"error": {"type": "authentication_error"}})
            return
        self._send(200, {"data": [{"id": "stub-model", "object": "model"}]})

    def log_message(self, fmt, *args):  # silence access logging
        pass


def main():
    server = HTTPServer(("127.0.0.1", 0), Stub)
    if PORTFILE:
        with open(PORTFILE, "w") as fh:
            fh.write(str(server.server_address[1]))
    server.serve_forever()


if __name__ == "__main__":
    sys.exit(main())
