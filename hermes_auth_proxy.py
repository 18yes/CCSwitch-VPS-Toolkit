#!/usr/bin/env python3
"""Local auth bridge for Hermes Anthropic-compatible providers.

Hermes' Anthropic SDK uses ``x-api-key`` for generic third-party endpoints.
Some Claude Code gateways instead require ``Authorization: Bearer`` while
still speaking the Anthropic Messages protocol. This loopback-only proxy keeps
the request/response body unchanged and replaces only the authentication
header.

Config: ~/.hermes/ccswitch-auth-proxy.json
PID:    ~/.hermes/ccswitch-auth-proxy.pid
Log:    ~/.hermes/ccswitch-auth-proxy.log
"""

import http.client
import http.server
import json
import os
import signal
import ssl
import sys
import time
from socketserver import ThreadingMixIn
from urllib.parse import urlparse

HERMES_DIR = os.path.expanduser("~/.hermes")
CONFIG_PATH = os.path.join(HERMES_DIR, "ccswitch-auth-proxy.json")
PID_FILE = os.path.join(HERMES_DIR, "ccswitch-auth-proxy.pid")
LOG_FILE = os.path.join(HERMES_DIR, "ccswitch-auth-proxy.log")
_config = {}


def load_config():
    global _config
    with open(CONFIG_PATH, encoding="utf-8") as fh:
        _config = json.load(fh)
    return _config


def log(message):
    line = f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] {message}"
    print(line, flush=True)


def _upstream_path(base_path, incoming_path):
    base_path = (base_path or "").rstrip("/")
    incoming = incoming_path.split("?", 1)[0].rstrip("/")
    query = "?" + incoming_path.split("?", 1)[1] if "?" in incoming_path else ""
    endpoint = "/messages" if incoming.endswith("/messages") else incoming
    if base_path.endswith("/v1"):
        path = base_path + endpoint
    else:
        path = base_path + "/v1" + endpoint
    return path + query


def upstream_request(config, incoming_path, raw_body, incoming_headers):
    url = urlparse(config["upstream_base_url"])
    if url.scheme == "https":
        conn = http.client.HTTPSConnection(
            url.hostname, url.port or 443, context=ssl.create_default_context(), timeout=900
        )
    elif url.scheme == "http":
        conn = http.client.HTTPConnection(url.hostname, url.port or 80, timeout=900)
    else:
        raise ValueError("upstream_base_url must use http or https")

    blocked = {
        "authorization", "x-api-key", "host", "content-length", "connection",
        "proxy-connection", "transfer-encoding", "accept-encoding",
    }
    headers = {
        key: value for key, value in incoming_headers.items()
        if key.lower() not in blocked
    }
    headers["Authorization"] = "Bearer " + config["api_key"]
    headers["Content-Length"] = str(len(raw_body))
    headers.setdefault("Content-Type", "application/json")
    # Claude Code billing gateways can route or authorize requests by client
    # identity as well as by Bearer token. Do not preserve the Anthropic SDK's
    # User-Agent here: these packages are explicitly Claude Code-style routes.
    headers["User-Agent"] = config.get(
        "user_agent", "claude-code/2.1.0 (external, cli)"
    )
    headers["x-app"] = config.get("x_app", "cli")

    conn.request("POST", _upstream_path(url.path, incoming_path), raw_body, headers)
    return conn, conn.getresponse()


class HermesAuthProxyHandler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        return

    def do_GET(self):
        if self.path.split("?", 1)[0] == "/health":
            self._json(200, {"status": "ok"})
        else:
            self._json(404, {"error": "not found"})

    def do_HEAD(self):
        self.send_response(200)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_POST(self):
        if self.path.split("?", 1)[0] not in ("/messages", "/v1/messages"):
            self._json(404, {"error": f"{self.path} not supported"})
            return

        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            self._json(400, {"error": "invalid Content-Length"})
            return
        raw_body = self.rfile.read(length)
        try:
            request_info = json.loads(raw_body)
        except Exception:
            self._json(400, {"error": "invalid JSON"})
            return

        log(
            f"-> model={request_info.get('model', '?')} "
            f"stream={bool(request_info.get('stream'))} bytes={len(raw_body)}"
        )
        conn = None
        try:
            conn, response = upstream_request(_config, self.path, raw_body, self.headers)
            self.send_response(response.status)
            excluded = {"content-length", "transfer-encoding", "connection", "content-encoding"}
            for key, value in response.getheaders():
                if key.lower() not in excluded:
                    self.send_header(key, value)
            self.send_header("Connection", "close")
            self.end_headers()
            while True:
                chunk = response.read(8192)
                if not chunk:
                    break
                self.wfile.write(chunk)
                self.wfile.flush()
            self.close_connection = True
            log(f"<- upstream {response.status}")
        except (BrokenPipeError, ConnectionResetError):
            log("<- client disconnected")
        except Exception as exc:
            log(f"proxy error: {type(exc).__name__}: {exc}")
            try:
                self._json(502, {"error": {"type": "proxy_error", "message": str(exc)}})
            except Exception:
                pass
        finally:
            if conn is not None:
                conn.close()

    def _json(self, status, payload):
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


class ThreadedServer(ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


def cleanup(signum=None, frame=None):
    try:
        os.remove(PID_FILE)
    except FileNotFoundError:
        pass
    log("Hermes auth proxy stopped")
    raise SystemExit(0)


def daemonize():
    if os.fork() > 0:
        raise SystemExit(0)
    os.setsid()
    if os.fork() > 0:
        raise SystemExit(0)
    sys.stdin = open(os.devnull)
    sys.stdout = open(LOG_FILE, "a")
    sys.stderr = sys.stdout


def main():
    os.makedirs(HERMES_DIR, exist_ok=True)
    config = load_config()
    host = config.get("listen_host", "127.0.0.1")
    port = int(config.get("listen_port", 18723))
    if host not in ("127.0.0.1", "::1", "localhost"):
        raise ValueError("Hermes auth proxy must listen on loopback")
    if config.get("auth_mode") != "bearer":
        raise ValueError("Only auth_mode=bearer is supported")
    if not config.get("api_key") or not config.get("upstream_base_url"):
        raise ValueError("api_key and upstream_base_url are required")

    if "--daemon" in sys.argv:
        daemonize()
    signal.signal(signal.SIGTERM, cleanup)
    signal.signal(signal.SIGINT, cleanup)
    with open(PID_FILE, "w", encoding="utf-8") as fh:
        fh.write(str(os.getpid()))
    os.chmod(PID_FILE, 0o600)

    log(f"Hermes auth proxy listening on {host}:{port}")
    log(f"Upstream: {config['upstream_base_url']} (Bearer auth)")
    server = ThreadedServer((host, port), HermesAuthProxyHandler)
    try:
        server.serve_forever()
    finally:
        server.server_close()
        cleanup()


if __name__ == "__main__":
    main()
