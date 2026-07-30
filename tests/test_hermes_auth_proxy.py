#!/usr/bin/env python3
"""Dependency-free local test for the Hermes Bearer authentication bridge."""

import http.server
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import time
import urllib.request

REPO = Path(__file__).resolve().parent.parent
received = {}


class UpstreamHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        return

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(length)
        received.update(
            path=self.path,
            authorization=self.headers.get("Authorization"),
            x_api_key=self.headers.get("x-api-key"),
            user_agent=self.headers.get("User-Agent"),
            x_app=self.headers.get("x-app"),
            body=body,
        )
        payload = json.dumps({"type": "message", "content": [{"type": "text", "text": "OK"}]}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)


upstream = http.server.ThreadingHTTPServer(("127.0.0.1", 0), UpstreamHandler)
thread = threading.Thread(target=upstream.serve_forever, daemon=True)
thread.start()

with tempfile.TemporaryDirectory() as tmp:
    home = Path(tmp)
    hermes_dir = home / ".hermes"
    hermes_dir.mkdir()
    # Reserve a free port for the bridge.
    probe = http.server.ThreadingHTTPServer(("127.0.0.1", 0), http.server.BaseHTTPRequestHandler)
    proxy_port = probe.server_port
    probe.server_close()
    config = {
        "upstream_base_url": f"http://127.0.0.1:{upstream.server_port}/v1",
        "api_key": "real-bearer-test-key",
        "auth_mode": "bearer",
        "listen_host": "127.0.0.1",
        "listen_port": proxy_port,
    }
    (hermes_dir / "ccswitch-auth-proxy.json").write_text(json.dumps(config))
    env = dict(os.environ, HOME=str(home))
    process = subprocess.Popen(
        [sys.executable, str(REPO / "hermes_auth_proxy.py")],
        env=env,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    try:
        health = f"http://127.0.0.1:{proxy_port}/health"
        for _ in range(50):
            try:
                with urllib.request.urlopen(health, timeout=0.2) as response:
                    if response.status == 200:
                        break
            except Exception:
                time.sleep(0.05)
        else:
            raise AssertionError("proxy health check did not become ready")

        body = json.dumps({
            "model": "claude-sonnet-5",
            "stream": False,
            "messages": [{"role": "user", "content": "test"}],
        }).encode()
        request = urllib.request.Request(
            f"http://127.0.0.1:{proxy_port}/v1/messages",
            data=body,
            headers={
                "Content-Type": "application/json",
                "x-api-key": "hermes-placeholder",
                "anthropic-version": "2023-06-01",
                "User-Agent": "Anthropic/Python test-version",
            },
            method="POST",
        )
        with urllib.request.urlopen(request, timeout=3) as response:
            assert response.status == 200
            assert json.loads(response.read())["content"][0]["text"] == "OK"

        assert received["path"] == "/v1/messages", received
        assert received["authorization"] == "Bearer real-bearer-test-key", received
        assert received["x_api_key"] is None, received
        assert received["user_agent"] == "claude-code/2.1.0 (external, cli)", received
        assert received["x_app"] == "cli", received
        assert received["body"] == body, received
    finally:
        process.terminate()
        try:
            process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=3)

upstream.shutdown()
upstream.server_close()
print("PASS: Hermes auth proxy sets Bearer/Claude Code identity and preserves Messages body")
