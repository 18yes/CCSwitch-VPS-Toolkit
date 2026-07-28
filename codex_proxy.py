#!/usr/bin/env python3
"""
Codex Responses API Proxy for Linux VPS
- Strips tool fields (namespace, strict) incompatible with upstream
- Caches function_call name by call_id from each response
- Backfills missing `name` in subsequent request input items
- Logs full request/response body on errors for diagnosis

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
import re
import time
import signal
import threading
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


# ===================== Name Cache =====================
# Stores call_id -> tool name extracted from upstream responses.
# Used to backfill missing `name` fields in subsequent requests.

_name_cache: dict = {}
_name_cache_lock = threading.Lock()
MAX_CACHE = 2000  # avoid unbounded growth


def cache_put(call_id: str, name: str):
    if not call_id or not name:
        return
    with _name_cache_lock:
        _name_cache[call_id] = name
        if len(_name_cache) > MAX_CACHE:
            # drop oldest half
            keys = list(_name_cache.keys())
            for k in keys[:MAX_CACHE // 2]:
                del _name_cache[k]


def cache_get(call_id: str):
    with _name_cache_lock:
        return _name_cache.get(call_id)


def extract_names_from_sse(sse_bytes: bytes):
    """
    Parse SSE stream bytes and extract function_call name+call_id pairs.
    Works on buffered complete responses (non-streaming passthrough).
    For streaming this is called after the fact from accumulated chunks.
    """
    try:
        text = sse_bytes.decode("utf-8", errors="replace")
        for line in text.splitlines():
            if not line.startswith("data:"):
                continue
            payload = line[5:].strip()
            if payload in ("", "[DONE]"):
                continue
            try:
                ev = json.loads(payload)
            except Exception:
                continue
            _walk_extract_names(ev)
    except Exception:
        pass


def _walk_extract_names(obj):
    """Recursively find function_call / tool_use items and cache name."""
    if isinstance(obj, dict):
        t = obj.get("type", "")
        # Responses API output item
        if t == "function_call":
            name = obj.get("name") or obj.get("function", {}).get("name") if isinstance(obj.get("function"), dict) else obj.get("name")
            call_id = obj.get("call_id") or obj.get("id")
            if name and call_id:
                cache_put(call_id, name)
                cache_put(obj.get("id", call_id), name)
        # Anthropic tool_use
        elif t == "tool_use":
            name = obj.get("name")
            id_ = obj.get("id")
            if name and id_:
                cache_put(id_, name)
        # delta style from streaming
        if "name" in obj and obj.get("type") in ("function_call", "tool_use"):
            pass  # handled above
        for v in obj.values():
            if isinstance(v, (dict, list)):
                _walk_extract_names(v)
    elif isinstance(obj, list):
        for item in obj:
            _walk_extract_names(item)


def extract_names_from_response_body(body: dict):
    """Extract from a parsed JSON response body."""
    _walk_extract_names(body)


# ===================== Tool Sanitization =====================

_TOOL_DROP_FIELDS = {"namespace", "strict"}
_FUNC_DROP_FIELDS = {"namespace", "strict"}
_TOOL_DROP_TYPES  = {"namespace"}
# Upstream rejects native web_search tools from non-Claude-Code clients with
# "native web search is supported only for Claude Code WebSearch requests".
# Codex can never satisfy that check, so drop these before forwarding.
_TOOL_DROP_TYPE_PREFIXES = ("web_search",)


def _sanitize_tool(tool):
    if not isinstance(tool, dict):
        return tool
    t_type = tool.get("type", "")
    if t_type in _TOOL_DROP_TYPES:
        return None
    if any(t_type.startswith(p) for p in _TOOL_DROP_TYPE_PREFIXES):
        return None
    t = {k: v for k, v in tool.items() if k not in _TOOL_DROP_FIELDS}
    if "function" in t and isinstance(t["function"], dict):
        t["function"] = {k: v for k, v in t["function"].items()
                         if k not in _FUNC_DROP_FIELDS}
    return t


# ===================== Name Backfill =====================

def _backfill_item(item: dict) -> dict:
    """
    If a request input item is a function_call / tool_use missing `name`,
    try to recover from cache.
    """
    if not isinstance(item, dict):
        return item

    t = item.get("type", "")

    if t == "function_call" and not item.get("name"):
        call_id = item.get("call_id") or item.get("id")
        name = cache_get(call_id) if call_id else None
        if name:
            log(f"[backfill] function_call call_id={call_id} -> name={name}")
            item = dict(item)
            item["name"] = name

    elif t == "tool_use" and not item.get("name"):
        id_ = item.get("id")
        name = cache_get(id_) if id_ else None
        if name:
            log(f"[backfill] tool_use id={id_} -> name={name}")
            item = dict(item)
            item["name"] = name

    # Also recurse into content arrays (assistant message style)
    if "content" in item and isinstance(item["content"], list):
        new_content = []
        changed = False
        for block in item["content"]:
            new_block = _backfill_item(block)
            if new_block is not block:
                changed = True
            new_content.append(new_block)
        if changed:
            item = dict(item)
            item["content"] = new_content

    return item


def _drop_unrecoverable_calls(items: list) -> list:
    """
    Drop function_call items whose `name` is still empty after backfill
    (i.e. upstream never gave us a name for this call_id, so there's
    nothing to recover), along with their matching function_call_output.
    Forwarding these guarantees a permanent 400 loop since the client
    replays history on every request.
    """
    dropped_call_ids = set()
    result = []
    for item in items:
        if not isinstance(item, dict):
            result.append(item)
            continue

        t = item.get("type", "")

        if t == "function_call" and not item.get("name"):
            call_id = item.get("call_id") or item.get("id") or ""
            log(f"[drop] unrecoverable function_call (empty name) call_id={call_id!r}")
            dropped_call_ids.add(call_id)
            continue

        if t == "function_call_output":
            call_id = item.get("call_id") or ""
            if call_id in dropped_call_ids:
                log(f"[drop] orphan function_call_output call_id={call_id!r}")
                continue

        result.append(item)
    return result


def sanitize_request(body: dict) -> dict:
    """Sanitize tools list and backfill missing names in input."""
    if not isinstance(body, dict):
        return body
    result = dict(body)

    # 1. Sanitize tools
    if "tools" in result and isinstance(result["tools"], list):
        sanitized = [_sanitize_tool(t) for t in result["tools"]]
        result["tools"] = [t for t in sanitized if t is not None]

    # 2. Backfill missing names in input items, then drop anything
    #    that's still broken (unrecoverable) to avoid a permanent 400 loop.
    if "input" in result and isinstance(result["input"], list):
        new_input = [_backfill_item(item) for item in result["input"]]
        result["input"] = _drop_unrecoverable_calls(new_input)

    # 3. Also backfill in messages (Chat Completions compat)
    if "messages" in result and isinstance(result["messages"], list):
        result["messages"] = [_backfill_item(m) for m in result["messages"]]

    return result


# ===================== Upstream Connection =====================

def upstream_request(config, body, is_stream):
    url = urlparse(config["upstream_base_url"])
    if url.scheme == "https":
        ctx = ssl.create_default_context()
        conn = http.client.HTTPSConnection(
            url.hostname, url.port or 443, context=ctx, timeout=300)
    else:
        conn = http.client.HTTPConnection(
            url.hostname, url.port or 80, timeout=300)

    path_prefix = url.path.rstrip("/")
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
    """Stream SSE bytes back to client; accumulate for name extraction."""
    accumulated = bytearray()
    try:
        while True:
            line = upstream_resp.readline()
            if not line:
                break
            accumulated.extend(line)
            wfile.write(line)
            wfile.flush()
    except (BrokenPipeError, ConnectionResetError):
        pass
    # extract names from the full stream after it's done
    if accumulated:
        extract_names_from_sse(bytes(accumulated))


# ===================== HTTP Handler =====================

class CodexProxyHandler(http.server.BaseHTTPRequestHandler):

    def log_message(self, fmt, *args):
        log(f"{self.client_address[0]} {fmt % args}")

    def do_GET(self):
        config = get_config()
        p = self.path.split("?", 1)[0]
        if p == "/health":
            self._json(200, {"status": "ok", "model": config.get("model", ""),
                             "cache_size": len(_name_cache)})
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
        n_input       = len(clean.get("input", []))
        log(f"-> model={clean.get('model','?')} stream={is_stream} "
            f"tools={n_tools_orig}(sanitized={n_tools_clean}) input_items={n_input} "
            f"name_cache={len(_name_cache)}")

        conn = None
        try:
            conn, resp = upstream_request(config, clean, is_stream)

            if resp.status != 200:
                err = resp.read().decode("utf-8", errors="replace")
                log(f"<- upstream {resp.status}: {err[:500]}")
                # Log abbreviated request body for diagnosis
                try:
                    debug_input = []
                    for item in clean.get("input", [])[-6:]:
                        if isinstance(item, dict):
                            brief = {k: v for k, v in item.items()
                                     if k in ("type","role","id","call_id","name")}
                            if "content" in item and isinstance(item["content"], list):
                                brief["content_types"] = [
                                    b.get("type") if isinstance(b, dict) else type(b).__name__
                                    for b in item["content"]
                                ]
                        else:
                            brief = str(item)[:80]
                        debug_input.append(brief)
                    log(f"[debug] last input items: {json.dumps(debug_input)}")
                except Exception as de:
                    log(f"[debug] failed to summarize input: {de}")

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
                # Extract names from non-streaming response
                try:
                    resp_body = json.loads(data)
                    extract_names_from_response_body(resp_body)
                except Exception:
                    pass
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
    log("Codex Responses Proxy v2 (name-backfill)")
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
