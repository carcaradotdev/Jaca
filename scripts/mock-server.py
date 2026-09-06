#!/usr/bin/env python3
"""Jaca POC mock server.

Serves the canned `product-state` payload for the one endpoint the agent diverts.
The device reaches this via `adb reverse tcp:8099 tcp:8099`, so the app connects to
http://localhost:8099 in cleartext -- which its network_security_config already permits.

Run:  python3 jaca-mock-server.py
"""

import json
from http.server import BaseHTTPRequestHandler, HTTPServer

PORT = 8099

PAYLOAD = {
    "product_states": [
        {
            "product_state": "ACTIVE_APPLICATION",
            "details": {
                "allowed_product_types": ["MCA"],
                "currency": "GBP",
                "offer_amount": 22500.00,
                "application_started_at": "2026-08-25T12:30:53.913008Z",
            },
            "actions": [
                {
                    "type": "WEBVIEW",
                    "url": "https://business.teya.xyz/standalone/unified"
                           "?companyId=2f4bb906-8ecb-43b8-afc2-c510553cdd99&locale=en",
                }
            ],
        }
    ],
    "funding_supported": True,
}


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def _serve(self):
        original = self.headers.get("X-Jaca-Original-URL", "(header absent)")
        body = json.dumps(PAYLOAD).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
        print(f"[mock] {self.command} {self.path}", flush=True)
        print(f"       original: {original}", flush=True)
        print(f"       served {len(body)} bytes of mocked product-state", flush=True)

    do_GET = _serve
    do_POST = _serve

    def log_message(self, *args):
        pass  # quiet the default stderr access log; we print our own


if __name__ == "__main__":
    print(f"[mock] listening on 127.0.0.1:{PORT}", flush=True)
    HTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
