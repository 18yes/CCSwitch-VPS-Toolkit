#!/usr/bin/env python3
"""
Codex Responses API Proxy for Linux VPS
Strips tool fields (namespace, strict, etc.) incompatible with upstream,
then forwards to the real Responses endpoint.
Uses only Python standard library — no pip dependencies.

Usage:
    python3 codex_proxy.py              # foreground
    python3 codex_proxy.py --daemon     # background daemon

Config: ~/codex_proxy_config.json
Logs:   ~/codex_proxy.log
PID:    ~/codex_proxy.pid
"""

import http.server
import http.client
import json
import ssl
import sys
import os
import time
import signal
from urllib.parse import urlparse
from socketserver import ThreadingMixIn

# ===================== Paths =====================

CONFIG_PATH = os.path.expanduser("~/codex_proxy_config.json")
PID_FILE    = os.path.expanduser("~/codex_proxy.pid")
LOG_FILE    = os.path.expanduser("~/codex_proxy.log")

_config = {}


def load_config():
    global _config
    with open(CONFIG_PATH) as f:
        _config = json.load(f)
    return _config


def get_config():
    return _config


# ===================== Logging =====================

def log(msg):
    ts = time.strftime("%Y-%m-%d %H:%M:%S")
    line = f"[{ts}] {msg}"
    print(line, flush=True)
    try:
        with open(LOG_FILE, "a") as f:
            f.write(line + "\n")
    except Exception:
        pass


# ===================== Tool Sanitization =====================

# Fields the Codex client adds that some upstreams reject.
_TOOL_DROP_FIELDS = {"namespace", "strict"}

# Fields inside a tool's function sub-object to drop.
_FUNC_DROP_FIELDS = {"namespace", "strict"}

# Tool types to drop entirely (Codex namespace declarations).
_TOOL_DROP_TYPES = {"namespace"}


def _sanitize_tool(tool):
    """Return sanitized tool dict, or None if the tool type should be dropped."""
    if not isinstance(tool, dict):
        return tool
    if tool.get("type") in _TOOL_DROP_TYPES:
        return None
    t = {k: v for k, v in tool.items() if k not in _TOOL_DROP_FIELDS}
    if "function" in t and isinstance(t["function"], dict):
        t["function"] = {k: v for k, v in t["function"].items()
                         if k not in _FUNC_DROP_FIELDS}
    return t


def sanitize_request(body):
    """Return a copy of the Responses request with tool fields sanitized."""
    if not isinstance(body, dict):
        return body
    result = dict(body)
    if "tools" in result and isinstance(result["tools"], list):
        sanitized = [_sanitize_tool(t) for t in result["tools"]]
        result["tools"] = [t for t in sanitized if t is not None]
    return result


# ===================== Upstream Connection =====================

def upstream_request(config, body, is_stream):
    """Forward a Responses API request to the real upstream."""
    url = urlparse(config["upstream_base_url"])
    if url.scheme == "https":
        ctx = ssl.create_default_context()
        conn = http.client.HTTPSConnection(
            url.hostname, url.port or 443, context=ctx, timeout=300)
    else:
        conn = http.client.HTTPConnection(
            url.hostname, url.port or 80, timeout=300)

    path_prefix = url.path.rstrip("/")
    # base_url 可能已包含 /v1（Codex 惯例），避免拼出 /v1/v1/responses
    if path_prefix.endswith("/v1"):
        path = f"{path_prefix}/responses"
    else:
        path = f"{path_prefix}/v1/responses"

    api_key = config.get("api_key", "")
    headers = {
        "Content-Type": "application/json",
        "Authorization": f"Bearer {api_key}",
        "User-Agent":    "Mozilla/5.0",
    }

    conn.request("POST", path, json.dumps(body).encode(), headers)
    resp = conn.getresponse()
    return conn, resp


# ===================== Streaming Passthrough =====================

def passthrough_streaming(upstream_resp, wfile):
    """Stream SSE response bytes back to the Codex client unchanged."""
    try:
        while True:
            line = upstream_resp.readline()
            if not line:
                break
            wfile.write(line)
            wfile.flush()
    except (BrokenPipeError, ConnectionResetError):
        pass


# ===================== HTTP Handler =====================

class CodexProxyHandler(http.server.BaseHTTPRequestHandler):

    def log_message(self, fmt, *args):
        log(f"{self.client_address[0]} {fmt % args}")

    def do_GET(self):
        config = get_config()
        p = self.path.split("?", 1)[0]
        if p == "/health":
            self._json(200, {"status": "ok", "model": config.get("model", "")})
        else:
            self._json(404, {"error": "not found"})

    def do_HEAD(self):
        self.send_response(200)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_POST(self):
        config  = get_config()
        p       = self.path.split("?", 1)[0]

        if p not in ("/v1/responses", "/responses"):
            self._json(404, {"error": f"{self.path} not supported"})
            return

        length = int(self.headers.get("Content-Length", 0))
        raw    = self.rfile.read(length)

        try:
            body = json.loads(raw)
        except json.JSONDecodeError:
            self._json(400, {"error": "invalid JSON"})
            return

        is_stream = body.get("stream", False)
        clean     = sanitize_request(body)

        n_tools_orig  = len(body.get("tools", []))
        n_tools_clean = len(clean.get("tools", []))
        log(f"-> model={clean.get('model','?')} stream={is_stream} "
            f"tools={n_tools_orig} (sanitized={n_tools_clean})")

        conn = None
        try:
            conn, resp = upstream_request(config, clean, is_stream)

            if resp.status != 200:
                err = resp.read().decode("utf-8", errors="replace")
                log(f"<- upstream {resp.status}: {err[:300]}")
                try:
                    err_json = json.loads(err)
                    self._json(resp.status, err_json)
                except Exception:
                    self._json(resp.status, {
                        "error": {"message": f"Upstream {resp.status}: {err[:500]}",
                                  "type": "api_error"}
                    })
                return

            if is_stream:
                self.send_response(200)
                self.send_header("Content-Type", "text/event-stream")
                self.send_header("Cache-Control", "no-cache")
                self.send_header("Connection", "close")
                self.end_headers()
                passthrough_streaming(resp, self.wfile)
                self.close_connection = True
            else:
                data = resp.read()
                self.send_response(200)
                ct = resp.getheader("Content-Type", "application/json")
                self.send_header("Content-Type", ct)
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

            log("<- 200 OK")

        except (BrokenPipeError, ConnectionResetError):
            log("<- client disconnected")
        except Exception as e:
            log(f"Error: {e}")
            import traceback; traceback.print_exc()
            try:
                self._json(502, {"error": str(e)})
            except Exception:
                pass
        finally:
            if conn:
                conn.close()

    def _json(self, status, data):
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        b = json.dumps(data).encode()
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)


# ===================== Threaded Server =====================

class ThreadedServer(ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


# ===================== Main =====================

def cleanup(signum=None, frame=None):
    try:
        os.remove(PID_FILE)
    except Exception:
        pass
    log("Codex proxy stopped.")
    sys.exit(0)


def daemonize():
    if os.fork() > 0:
        sys.exit(0)
    os.setsid()
    if os.fork() > 0:
        sys.exit(0)
    sys.stdin  = open(os.devnull)
    sys.stdout = open(LOG_FILE, "a")
    sys.stderr = sys.stdout


def main():
    config = load_config()
    host   = config.get("listen_host", "127.0.0.1")
    port   = config.get("listen_port", 18722)

    if "--daemon" in sys.argv:
        daemonize()

    signal.signal(signal.SIGTERM, cleanup)
    signal.signal(signal.SIGINT,  cleanup)

    with open(PID_FILE, "w") as f:
        f.write(str(os.getpid()))

    log("=" * 50)
    log("Codex Responses Proxy")
    log(f"Listen:   {host}:{port}")
    log(f"Upstream: {config.get('upstream_base_url','')}")
    log(f"Model:    {config.get('model','')}")
    log("=" * 50)

    server = ThreadedServer((host, port), CodexProxyHandler)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        cleanup()


if __name__ == "__main__":
    main()
