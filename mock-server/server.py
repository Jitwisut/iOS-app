#!/usr/bin/env python3
"""Tiny mock light server that speaks the AppleHome API (see ../API.md).

    python3 mock-server/server.py            # http://localhost:8787
    PORT=9000 TOKEN=secret python3 mock-server/server.py

In the app: Settings > Light server (API) > Server URL = http://<this-mac-ip>:8787
(the iOS Simulator can use http://localhost:8787).
"""
import json
import os
import socket
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

TOKEN = os.environ.get("TOKEN")
PORT = int(os.environ.get("PORT", "8787"))

LIGHTS = {
    "living-1": {"id": "living-1", "name": "Ceiling Light", "room": "Living Room", "on": False, "brightness": 80, "type": "ceiling"},
    "living-2": {"id": "living-2", "name": "Floor Lamp", "room": "Living Room", "on": False, "brightness": 60, "type": "floorLamp"},
    "kitchen-1": {"id": "kitchen-1", "name": "Pendant", "room": "Kitchen", "on": False, "brightness": 100, "type": "ceiling"},
    "bed-1": {"id": "bed-1", "name": "Bedside Lamp", "room": "Bedroom", "on": False, "brightness": 40, "type": "tableLamp"},
    "porch-1": {"id": "porch-1", "name": "Porch Light", "room": "Porch", "on": False, "brightness": 100, "type": "outdoor"},
}


class Handler(BaseHTTPRequestHandler):
    def _send(self, status, body=None):
        data = json.dumps(body).encode() if body is not None else b""
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _authorized(self):
        if not TOKEN:
            return True
        if self.headers.get("Authorization") == f"Bearer {TOKEN}":
            return True
        self._send(401, {"error": "unauthorized"})
        return False

    def do_GET(self):
        if not self._authorized():
            return
        if self.path.rstrip("/") == "/lights":
            return self._send(200, list(LIGHTS.values()))
        self._send(404, {"error": "not found"})

    def do_PATCH(self):
        if not self._authorized():
            return
        parts = self.path.strip("/").split("/")
        if len(parts) != 2 or parts[0] != "lights" or parts[1] not in LIGHTS:
            return self._send(404, {"error": "not found"})
        length = int(self.headers.get("Content-Length", 0))
        try:
            patch = json.loads(self.rfile.read(length) or b"{}")
        except json.JSONDecodeError:
            return self._send(400, {"error": "invalid json"})
        light = LIGHTS[parts[1]]
        if "on" in patch:
            light["on"] = bool(patch["on"])
        if "brightness" in patch:
            light["brightness"] = max(0, min(100, int(patch["brightness"])))
        print(f"  -> {light['name']}: {'ON' if light['on'] else 'off'} {light['brightness']}%", flush=True)
        self._send(200, light)


class DualStackServer(ThreadingHTTPServer):
    """Listens on IPv6 and IPv4, so `localhost` works whichever one it resolves to."""
    address_family = socket.AF_INET6

    def server_bind(self):
        self.socket.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
        super().server_bind()


if __name__ == "__main__":
    print(f"AppleHome mock light server on http://localhost:{PORT}" + (" (token required)" if TOKEN else ""), flush=True)
    DualStackServer(("::", PORT), Handler).serve_forever()
