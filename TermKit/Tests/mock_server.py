#!/usr/bin/env python3
"""Minimal OpenAI-compatible mock for the live streaming test.

First chat call streams a tool call (split across chunks), the follow-up streams text.
Usage: python3 mock_server.py 8765, then TERMAI_TEST_BASEURL=http://127.0.0.1:8765/v1 swift test
"""
import json
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def _json(self, status, obj):
        body = json.dumps(obj).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _authorized(self):
        if self.headers.get("Authorization") == "Bearer test-key":
            return True
        self._json(401, {"error": {"message": "bad key"}})
        return False

    def do_GET(self):
        if self._authorized() and self.path == "/v1/models":
            self._json(200, {"data": [{"id": "mock-b"}, {"id": "mock-a"}]})

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))))
        if not self._authorized():
            return
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.end_headers()
        has_result = any(m["role"] == "tool" for m in body["messages"])
        if has_result:
            raw = "".join(
                "data: " + json.dumps({"choices": [{"delta": {"content": t}}]}, ensure_ascii=False) + "\n\n"
                for t in ["héllo ", "✓ done"]
            ).encode()
            raw += b'data: {"choices":[],"usage":{"prompt_tokens":9,"completion_tokens":4}}\n\ndata: [DONE]\n\n'
        else:
            deltas = [
                {"tool_calls": [{"index": 0, "id": "call_1", "function": {"name": "ssh_exec", "arguments": ""}}]},
                {"tool_calls": [{"index": 0, "function": {"arguments": '{"command":'}}]},
                {"tool_calls": [{"index": 0, "function": {"arguments": '"echo hi"}'}}]},
            ]
            raw = "".join("data: " + json.dumps({"choices": [{"delta": d}]}) + "\n\n" for d in deltas).encode()
            raw += b"data: [DONE]\n\n"
        # Deliberately awkward chunking: split mid-line and mid-character.
        for i in range(0, len(raw), 7):
            self.wfile.write(raw[i:i + 7])
            self.wfile.flush()
            time.sleep(0.002)


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()
