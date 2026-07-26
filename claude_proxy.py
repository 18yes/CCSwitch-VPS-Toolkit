#!/usr/bin/env python3
"""
Claude-to-OpenAI Protocol Translation Proxy for Linux VPS
Lightweight replacement for CC Switch's built-in proxy.
Uses only Python standard library — no pip dependencies.

Usage:
    python3 claude_proxy.py              # foreground
    python3 claude_proxy.py --daemon     # background daemon

Config: ~/proxy_config.json
Logs:   ~/claude_proxy.log
PID:    ~/claude_proxy.pid
"""

import http.server
import http.client
import json
import ssl
import sys
import os
import uuid
import time
import signal
from urllib.parse import urlparse
from socketserver import ThreadingMixIn

# ===================== Paths =====================

CONFIG_PATH = os.path.expanduser("~/proxy_config.json")
PID_FILE = os.path.expanduser("~/claude_proxy.pid")
LOG_FILE = os.path.expanduser("~/claude_proxy.log")

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


# ===================== Request: Anthropic -> OpenAI =====================

def translate_request(body, config):
    """Translate Anthropic Messages request to OpenAI Chat Completions."""

    result = {
        # Claude Code sends Claude aliases. The selected package model is the
        # authoritative upstream model for OpenAI-compatible endpoints.
        "model": config["model"],
        "stream": body.get("stream", False),
    }

    if "max_tokens" in body:
        result["max_tokens"] = body["max_tokens"]
    if "temperature" in body:
        result["temperature"] = body["temperature"]
    if "top_p" in body:
        result["top_p"] = body["top_p"]

    messages = []

    # ---- System prompt ----
    system = body.get("system")
    if system:
        if isinstance(system, str):
            messages.append({"role": "system", "content": system})
        elif isinstance(system, list):
            parts = [b["text"] for b in system
                     if isinstance(b, dict) and b.get("type") == "text"]
            if parts:
                messages.append({"role": "system", "content": "\n".join(parts)})

    # ---- Messages ----
    for msg in body.get("messages", []):
        role = msg["role"]
        content = msg.get("content")

        if role == "user":
            if isinstance(content, str):
                messages.append({"role": "user", "content": content})
            elif isinstance(content, list):
                text_parts = []
                for block in content:
                    if not isinstance(block, dict):
                        continue
                    btype = block.get("type", "")
                    if btype == "text":
                        text_parts.append(block["text"])
                    elif btype == "tool_result":
                        tr_content = block.get("content", "")
                        if isinstance(tr_content, list):
                            tr_text = "\n".join(
                                b.get("text", "") for b in tr_content
                                if isinstance(b, dict) and b.get("type") == "text"
                            )
                        else:
                            tr_text = str(tr_content)
                        messages.append({
                            "role": "tool",
                            "tool_call_id": block.get("tool_use_id", ""),
                            "content": tr_text or ""
                        })
                    elif btype == "image":
                        text_parts.append("[image]")
                if text_parts:
                    messages.append({"role": "user", "content": "\n".join(text_parts)})

        elif role == "assistant":
            if isinstance(content, str):
                messages.append({"role": "assistant", "content": content})
            elif isinstance(content, list):
                text_parts = []
                tool_calls = []
                for block in content:
                    if not isinstance(block, dict):
                        continue
                    btype = block.get("type", "")
                    if btype == "text":
                        text_parts.append(block["text"])
                    elif btype == "thinking":
                        thinking = block.get("thinking", "")
                        if thinking:
                            text_parts.append(f"<thinking>{thinking}</thinking>")
                    elif btype == "tool_use":
                        tc_input = block.get("input", {})
                        tool_calls.append({
                            "id": block.get("id", f"call_{uuid.uuid4().hex[:24]}"),
                            "type": "function",
                            "function": {
                                "name": block["name"],
                                "arguments": json.dumps(tc_input)
                                if isinstance(tc_input, dict) else str(tc_input)
                            }
                        })
                assistant_msg = {"role": "assistant"}
                assistant_msg["content"] = "\n".join(text_parts) if text_parts else None
                if tool_calls:
                    assistant_msg["tool_calls"] = tool_calls
                messages.append(assistant_msg)

    result["messages"] = messages

    # ---- Tools ----
    if body.get("tools"):
        openai_tools = []
        for tool in body["tools"]:
            func = {"name": tool["name"]}
            if "description" in tool:
                func["description"] = tool["description"]
            if "input_schema" in tool:
                func["parameters"] = tool["input_schema"]
            openai_tools.append({"type": "function", "function": func})
        result["tools"] = openai_tools

    # ---- Tool choice ----
    tc = body.get("tool_choice")
    if tc:
        if isinstance(tc, dict):
            tc_type = tc.get("type", "auto")
            if tc_type == "auto":
                result["tool_choice"] = "auto"
            elif tc_type == "any":
                result["tool_choice"] = "required"
            elif tc_type == "tool":
                result["tool_choice"] = {
                    "type": "function",
                    "function": {"name": tc["name"]}
                }
        elif isinstance(tc, str):
            mapping = {"auto": "auto", "any": "required", "none": "none"}
            result["tool_choice"] = mapping.get(tc, "auto")

    # If stream_options needed for usage in streaming
    if result.get("stream"):
        result["stream_options"] = {"include_usage": True}

    return result


# ===================== Response: OpenAI -> Anthropic (non-streaming) =====================

def translate_response(openai_resp, model):
    """Translate OpenAI Chat Completions response to Anthropic Messages."""

    choices = openai_resp.get("choices", [])
    if not choices:
        return _empty_anthropic_response(model)

    choice = choices[0]
    message = choice.get("message", {})
    finish = choice.get("finish_reason", "stop")

    content = []

    if message.get("content"):
        content.append({"type": "text", "text": message["content"]})

    for tc in message.get("tool_calls", []):
        try:
            input_data = json.loads(tc["function"]["arguments"])
        except (json.JSONDecodeError, KeyError, TypeError):
            input_data = {}
        content.append({
            "type": "tool_use",
            "id": tc.get("id", f"toolu_{uuid.uuid4().hex[:24]}"),
            "name": tc["function"]["name"],
            "input": input_data
        })

    if not content:
        content.append({"type": "text", "text": ""})

    stop_map = {"stop": "end_turn", "tool_calls": "tool_use",
                "function_call": "tool_use", "length": "max_tokens"}
    usage = openai_resp.get("usage", {})

    return {
        "id": f"msg_{uuid.uuid4().hex[:24]}",
        "type": "message",
        "role": "assistant",
        "model": model,
        "content": content,
        "stop_reason": stop_map.get(finish, "end_turn"),
        "stop_sequence": None,
        "usage": {
            "input_tokens": usage.get("prompt_tokens", 0),
            "output_tokens": usage.get("completion_tokens", 0),
            "cache_creation_input_tokens": 0,
            "cache_read_input_tokens": 0
        }
    }


def _empty_anthropic_response(model):
    return {
        "id": f"msg_{uuid.uuid4().hex[:24]}",
        "type": "message", "role": "assistant", "model": model,
        "content": [{"type": "text", "text": ""}],
        "stop_reason": "end_turn", "stop_sequence": None,
        "usage": {"input_tokens": 0, "output_tokens": 0}
    }


# ===================== Response: OpenAI -> Anthropic (SSE streaming) =====================

def _send_sse(wfile, event, data):
    try:
        wfile.write(f"event: {event}\ndata: {json.dumps(data)}\n\n".encode())
        wfile.flush()
    except (BrokenPipeError, ConnectionResetError):
        raise


def translate_streaming(upstream_resp, model, wfile):
    """Read OpenAI SSE, translate to Anthropic SSE, write to client."""

    msg_id = f"msg_{uuid.uuid4().hex[:24]}"

    # message_start
    _send_sse(wfile, "message_start", {
        "type": "message_start",
        "message": {
            "id": msg_id, "type": "message", "role": "assistant",
            "model": model, "content": [],
            "stop_reason": None, "stop_sequence": None,
            "usage": {"input_tokens": 0, "output_tokens": 0,
                      "cache_creation_input_tokens": 0,
                      "cache_read_input_tokens": 0}
        }
    })

    # State
    next_idx = 0
    text_open = False
    text_idx = -1
    tool_calls = {}          # openai_tc_index -> dict
    output_tokens = 0
    stop_reason = "end_turn"

    try:
        while True:
            line = upstream_resp.readline()
            if not line:
                break
            line = line.decode("utf-8", errors="replace").strip()
            if not line or not line.startswith("data: "):
                continue

            data_str = line[6:]
            if data_str.strip() == "[DONE]":
                break

            try:
                data = json.loads(data_str)
            except json.JSONDecodeError:
                continue

            if "usage" in data:
                output_tokens = data["usage"].get("completion_tokens", output_tokens)

            choices = data.get("choices", [])
            if not choices:
                continue

            choice = choices[0]
            delta = choice.get("delta", {})
            finish_reason = choice.get("finish_reason")

            # ---- Text delta ----
            text_content = delta.get("content")
            if text_content:
                if not text_open:
                    text_idx = next_idx
                    next_idx += 1
                    _send_sse(wfile, "content_block_start", {
                        "type": "content_block_start", "index": text_idx,
                        "content_block": {"type": "text", "text": ""}
                    })
                    text_open = True

                _send_sse(wfile, "content_block_delta", {
                    "type": "content_block_delta", "index": text_idx,
                    "delta": {"type": "text_delta", "text": text_content}
                })

            # ---- Tool call delta ----
            if "tool_calls" in delta:
                # Close text block before first tool
                if text_open and not tool_calls:
                    _send_sse(wfile, "content_block_stop", {
                        "type": "content_block_stop", "index": text_idx
                    })
                    text_open = False

                for tc_d in delta["tool_calls"]:
                    tc_i = tc_d.get("index", 0)

                    if tc_i not in tool_calls:
                        a_idx = next_idx
                        next_idx += 1
                        tool_calls[tc_i] = {
                            "a_idx": a_idx,
                            "id": tc_d.get("id", f"toolu_{uuid.uuid4().hex[:24]}"),
                            "name": "", "started": False
                        }

                    info = tool_calls[tc_i]
                    if tc_d.get("id"):
                        info["id"] = tc_d["id"]

                    func = tc_d.get("function", {})
                    if func.get("name"):
                        info["name"] = func["name"]

                    # Start block once we have a name
                    if info["name"] and not info["started"]:
                        _send_sse(wfile, "content_block_start", {
                            "type": "content_block_start",
                            "index": info["a_idx"],
                            "content_block": {
                                "type": "tool_use",
                                "id": info["id"],
                                "name": info["name"],
                                "input": {}
                            }
                        })
                        info["started"] = True

                    # Stream arguments
                    args_chunk = func.get("arguments", "")
                    if info["started"] and args_chunk:
                        _send_sse(wfile, "content_block_delta", {
                            "type": "content_block_delta",
                            "index": info["a_idx"],
                            "delta": {
                                "type": "input_json_delta",
                                "partial_json": args_chunk
                            }
                        })

            # ---- Finish reason ----
            if finish_reason:
                stop_map = {"stop": "end_turn", "tool_calls": "tool_use",
                            "function_call": "tool_use", "length": "max_tokens"}
                stop_reason = stop_map.get(finish_reason, "end_turn")

    except (BrokenPipeError, ConnectionResetError):
        return

    # ---- Close open blocks ----
    if next_idx == 0:
        # Nothing was emitted; emit an empty text block
        _send_sse(wfile, "content_block_start", {
            "type": "content_block_start", "index": 0,
            "content_block": {"type": "text", "text": ""}
        })
        _send_sse(wfile, "content_block_stop", {
            "type": "content_block_stop", "index": 0
        })
    else:
        if text_open:
            _send_sse(wfile, "content_block_stop", {
                "type": "content_block_stop", "index": text_idx
            })
        for info in tool_calls.values():
            if info["started"]:
                _send_sse(wfile, "content_block_stop", {
                    "type": "content_block_stop", "index": info["a_idx"]
                })

    _send_sse(wfile, "message_delta", {
        "type": "message_delta",
        "delta": {"stop_reason": stop_reason},
        "usage": {"output_tokens": output_tokens}
    })
    _send_sse(wfile, "message_stop", {"type": "message_stop"})


# ===================== Upstream Connection =====================


# ===================== Anthropic Passthrough =====================

def upstream_request_anthropic(config, body, is_stream):
    """Forward Anthropic Messages request directly to an Anthropic-compatible endpoint."""
    from urllib.parse import urlparse
    url_parsed = urlparse(config["upstream_base_url"])
    if url_parsed.scheme == "https":
        ctx = ssl.create_default_context()
        conn = http.client.HTTPSConnection(
            url_parsed.hostname, url_parsed.port or 443, context=ctx, timeout=300)
    else:
        conn = http.client.HTTPConnection(
            url_parsed.hostname, url_parsed.port or 80, timeout=300)

    path_prefix = url_parsed.path.rstrip("/")
    path = f"{path_prefix}/v1/messages"

    headers = {
        "Content-Type": "application/json",
        "x-api-key": config["api_key"],
        "anthropic-version": "2023-06-01",
        "User-Agent": "Mozilla/5.0",
    }

    # Apply disable_thinking if configured
    if config.get("disable_thinking"):
        body = dict(body)
        body["thinking"] = {"type": "disabled"}

    conn.request("POST", path, json.dumps(body).encode(), headers)
    resp = conn.getresponse()
    return conn, resp


def passthrough_streaming(upstream_resp, wfile):
    """Stream Anthropic SSE response back to client unchanged."""
    try:
        while True:
            line = upstream_resp.readline()
            if not line:
                break
            wfile.write(line)
            wfile.flush()
    except (BrokenPipeError, ConnectionResetError):
        pass

def upstream_request(config, openai_body, is_stream):
    """Send request to the upstream OpenAI-compatible API."""

    url = urlparse(config["upstream_base_url"])
    if url.scheme == "https":
        ctx = ssl.create_default_context()
        conn = http.client.HTTPSConnection(
            url.hostname, url.port or 443, context=ctx, timeout=300)
    else:
        conn = http.client.HTTPConnection(
            url.hostname, url.port or 80, timeout=300)

    path_prefix = url.path.rstrip("/")
    path = f"{path_prefix}/v1/chat/completions"

    headers = {
        "Content-Type": "application/json",
        "Authorization": f"Bearer {config['api_key']}",
        "User-Agent": "Mozilla/5.0",
    }

    conn.request("POST", path, json.dumps(openai_body).encode(), headers)
    resp = conn.getresponse()
    return conn, resp


# ===================== HTTP Handler =====================

class ProxyHandler(http.server.BaseHTTPRequestHandler):

    def log_message(self, fmt, *args):
        log(f"{self.client_address[0]} {fmt % args}")

    # ---- GET ----
    def do_GET(self):
        config = get_config()
        request_path = self.path.split("?", 1)[0]
        if request_path == "/health":
            self._json(200, {"status": "ok", "model": config["model"]})
        elif request_path in ("/v1/models", "/models"):
            self._json(200, {
                "object": "list",
                "data": [{"id": config["model"], "object": "model",
                          "owned_by": "proxy"}]
            })
        else:
            self._json(404, {"error": "not found"})

    def do_HEAD(self):
        self.send_response(200)
        self.send_header("Content-Length", "0")
        self.end_headers()

    # ---- POST ----
    def do_POST(self):
        config = get_config()
        request_path = self.path.split("?", 1)[0]

        if request_path not in ("/v1/messages", "/messages"):
            self._json(404, {"error": f"{self.path} not supported"})
            return

        length = int(self.headers.get("Content-Length", 0))
        raw = self.rfile.read(length)

        try:
            body = json.loads(raw)
        except json.JSONDecodeError:
            self._json(400, {"error": "invalid JSON"})
            return

        is_stream = body.get("stream", False)
        protocol = config.get("protocol", "openai-chat")

        conn = None
        try:
            log(f"-> protocol={protocol} model={config['model']} stream={is_stream}")

            if protocol == "anthropic-passthrough":
                # Forward directly to Anthropic endpoint
                conn, resp = upstream_request_anthropic(config, body, is_stream)
                if resp.status != 200:
                    err = resp.read().decode("utf-8", errors="replace")
                    log(f"<- upstream {resp.status}: {err[:300]}")
                    try:
                        err_json = json.loads(err)
                        self._json(resp.status, err_json)
                    except:
                        self._json(resp.status, {"type":"error","error":{"type":"api_error","message":err[:500]}})
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
                    data = resp.read().decode("utf-8", errors="replace")
                    self.send_response(200)
                    self.send_header("Content-Type", "application/json")
                    self.send_header("Content-Length", str(len(data.encode())))
                    self.end_headers()
                    self.wfile.write(data.encode())
                log("<- 200 OK")

            else:
                # openai-chat: translate then forward
                try:
                    openai_body = translate_request(body, config)
                except Exception as e:
                    log(f"Translation error: {e}")
                    self._json(500, {"error": str(e)})
                    return

                conn, resp = upstream_request(config, openai_body, is_stream)

                if resp.status != 200:
                    err = resp.read().decode("utf-8", errors="replace")
                    log(f"<- upstream {resp.status}: {err[:300]}")
                    self._json(resp.status, {
                        "type": "error",
                        "error": {"type": "api_error",
                                  "message": f"Upstream {resp.status}: {err[:500]}"}
                    })
                    return

                if is_stream:
                    self.send_response(200)
                    self.send_header("Content-Type", "text/event-stream")
                    self.send_header("Cache-Control", "no-cache")
                    self.send_header("Connection", "close")
                    self.end_headers()
                    translate_streaming(resp, config["model"], self.wfile)
                    self.close_connection = True
                else:
                    data = json.loads(resp.read().decode("utf-8", errors="replace"))
                    self._json(200, translate_response(data, config["model"]))

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
    log("Proxy stopped.")
    sys.exit(0)


def daemonize():
    """Simple double-fork daemon."""
    if os.fork() > 0:
        sys.exit(0)
    os.setsid()
    if os.fork() > 0:
        sys.exit(0)
    sys.stdin = open(os.devnull)
    sys.stdout = open(LOG_FILE, "a")
    sys.stderr = sys.stdout


def main():
    config = load_config()
    host = config.get("listen_host", "127.0.0.1")
    port = config.get("listen_port", 18721)

    if "--daemon" in sys.argv:
        daemonize()

    signal.signal(signal.SIGTERM, cleanup)
    signal.signal(signal.SIGINT, cleanup)

    with open(PID_FILE, "w") as f:
        f.write(str(os.getpid()))

    log("=" * 50)
    log("Claude-to-OpenAI Translation Proxy")
    log(f"Listen:   {host}:{port}")
    log(f"Upstream: {config['upstream_base_url']}")
    log(f"Model:    {config['model']}")
    log("=" * 50)

    server = ThreadedServer((host, port), ProxyHandler)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        cleanup()


if __name__ == "__main__":
    main()
