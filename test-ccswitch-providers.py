#!/usr/bin/env python3
"""
测试 cc-switch 所有 claude 套餐是否可用，并验证 /model 模型映射。
用法:
    python3 test-ccswitch-providers.py          # 只测 Claude 套餐（原行为）
    python3 test-ccswitch-providers.py --codex  # 只测 Codex 套餐
    python3 test-ccswitch-providers.py --all    # Claude + Codex 均测
"""
import sqlite3, json, os, sys, urllib.request, urllib.error, time

DB = os.path.expanduser("~/.cc-switch/cc-switch.db")
TIMEOUT = 15  # 秒

MODE_CLAUDE = "--codex" not in sys.argv
MODE_CODEX  = "--codex" in sys.argv or "--all" in sys.argv

if not os.path.exists(DB):
    sys.exit(f"数据库不存在: {DB}")

conn = sqlite3.connect(DB)

# 读取 universal_providers 备注
row = conn.execute("SELECT value FROM settings WHERE key='universal_providers'").fetchone()
universal = json.loads(row[0]) if row else {}

# 读取所有 claude 套餐
rows = conn.execute(
    "SELECT id, name, settings_config FROM providers WHERE app_type='claude' ORDER BY rowid"
).fetchall()

# 读取所有 codex 套餐
codex_rows = conn.execute(
    "SELECT id, name, settings_config FROM providers WHERE app_type='codex' ORDER BY rowid"
).fetchall()

GREEN  = "\033[32m"
RED    = "\033[31m"
YELLOW = "\033[33m"
CYAN   = "\033[36m"
RESET  = "\033[0m"

def get_label(pid, name):
    short = pid.replace("universal-claude-", "")
    u = universal.get(short, {})
    return u.get("notes") or name

def is_openai_format(env):
    """Grok/GPT系模型需走 OpenAI Chat 格式"""
    model = env.get("ANTHROPIC_MODEL", "").split("[")[0]
    return bool(model) and not (
        model.startswith("claude-") or model.startswith("deepseek-") or
        model.startswith("gemini-") or model.startswith("gpt-image")
    )

def test_provider(pid, name, cfg_raw):
    label = get_label(pid, name)
    cfg = json.loads(cfg_raw) if cfg_raw else {}
    env = cfg.get("env", {})

    base_url = env.get("ANTHROPIC_BASE_URL", "").rstrip("/")
    api_key  = env.get("ANTHROPIC_AUTH_TOKEN") or env.get("ANTHROPIC_API_KEY", "")
    model    = env.get("ANTHROPIC_MODEL") or env.get("ANTHROPIC_DEFAULT_SONNET_MODEL", "claude-sonnet-5")
    model_clean = model.split("[")[0]

    if not base_url or not api_key:
        return False, "配置缺少 base_url 或 api_key", None, None

    if is_openai_format(env):
        # OpenAI Chat 格式（Grok、GptPlus 等）
        url = f"{base_url}/v1/chat/completions"
        payload = json.dumps({
            "model": model_clean,
            "max_tokens": 10,
            "messages": [{"role": "user", "content": "hi"}]
        }).encode()
        req = urllib.request.Request(url, data=payload, method="POST")
        req.add_header("Content-Type", "application/json")
        req.add_header("Authorization", f"Bearer {api_key}")
        req.add_header("User-Agent", "claude-cli/1.0")
        try:
            with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
                body = json.loads(resp.read())
                actual_model = (body.get("model") or
                                body.get("choices",[{}])[0].get("message",{}).get("model", "?"))
                return True, "OK (OpenAI格式)", model_clean, actual_model
        except urllib.error.HTTPError as e:
            try:
                err_body = json.loads(e.read())
                msg = err_body.get("error", {}).get("message", str(e))
            except Exception:
                msg = str(e)
            return False, f"HTTP {e.code}: {msg[:80]}", model_clean, None
        except Exception as e:
            return False, str(e)[:80], model_clean, None
    else:
        # Anthropic Messages 格式
        url = f"{base_url}/v1/messages"
        payload = json.dumps({
            "model": model_clean,
            "max_tokens": 10,
            "messages": [{"role": "user", "content": "hi"}]
        }).encode()
        req = urllib.request.Request(url, data=payload, method="POST")
        req.add_header("Content-Type", "application/json")
        req.add_header("anthropic-version", "2023-06-01")
        req.add_header("User-Agent", "claude-cli/1.0")
        if "ANTHROPIC_AUTH_TOKEN" in env:
            req.add_header("Authorization", f"Bearer {api_key}")
        else:
            req.add_header("x-api-key", api_key)
        try:
            with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
                body = json.loads(resp.read())
                actual_model = body.get("model", "?")
                return True, "OK", model_clean, actual_model
        except urllib.error.HTTPError as e:
            try:
                err_body = json.loads(e.read())
                msg = err_body.get("error", {}).get("message", str(e))
            except Exception:
                msg = str(e)
            return False, f"HTTP {e.code}: {msg[:80]}", model_clean, None
        except Exception as e:
            return False, str(e)[:80], model_clean, None

# ── 读取 cc-switch 中各模型对应关系 ──
MODEL_FIELDS = {
    "haiku":  "ANTHROPIC_DEFAULT_HAIKU_MODEL",
    "sonnet": "ANTHROPIC_DEFAULT_SONNET_MODEL",
    "opus":   "ANTHROPIC_DEFAULT_OPUS_MODEL",
    "fable":  "ANTHROPIC_DEFAULT_FABLE_MODEL",
}

print(f"\n{'='*70}")
print(f"  cc-switch Claude 套餐测试  ({len(rows)} 个)")
print(f"{'='*70}\n")

if MODE_CLAUDE:
    results = []
    for pid, name, cfg_raw in rows:
        label = get_label(pid, name)
        cfg = json.loads(cfg_raw) if cfg_raw else {}
        env = cfg.get("env", {})

        print(f"{CYAN}▶ {label}{RESET}")

        # 模型映射
        model_map = {}
        for tier, field in MODEL_FIELDS.items():
            if field in env:
                model_map[tier] = env[field].split("[")[0]
        if model_map:
            for tier, m in model_map.items():
                print(f"   /model {tier:<8} → {m}")
        else:
            default = env.get("ANTHROPIC_MODEL", "(未设置)").split("[")[0]
            print(f"   默认模型: {default}")

        # 连通性测试
        ok, msg, sent_model, actual_model = test_provider(pid, name, cfg_raw)
        if ok:
            model_match = ""
            if actual_model and sent_model:
                if actual_model.startswith(sent_model) or sent_model in actual_model:
                    model_match = f" (返回 {actual_model})"
                else:
                    model_match = f" {YELLOW}⚠ 请求 {sent_model} 但返回 {actual_model}{RESET}"
            print(f"   {GREEN}✓ 连通{RESET}{model_match}")
            results.append((label, True, None))
        else:
            print(f"   {RED}✗ 失败: {msg}{RESET}")
            results.append((label, False, msg))
        print()

    # 汇总
    passed = sum(1 for _, ok, _ in results if ok)
    print(f"{'─'*70}")
    print(f"结果: {GREEN}{passed}/{len(results)} 套餐可用{RESET}")
    if passed < len(results):
        print(f"\n失败套餐:")
        for label, ok, msg in results:
            if not ok:
                print(f"  {RED}✗ {label}: {msg}{RESET}")
    print()

# ── Codex 套餐测试 ──

def toml_get(key, text):
    import re
    m = re.search(r'^' + re.escape(key) + r'\s*=\s*"([^"]*)"', text, re.MULTILINE)
    return m.group(1) if m else ''

def test_codex_responses(base_url, api_key, model, stream=False):
    """向 /v1/responses 发送最小 Responses 请求，返回 (ok, msg, model_returned)"""
    base = base_url.rstrip('/')
    # base_url 可能已包含 /v1（Codex 惯例），避免拼出 /v1/v1/responses
    url = base + ('/responses' if base.endswith('/v1') else '/v1/responses')
    payload = json.dumps({
        "model": model,
        "max_output_tokens": 16,
        "stream": stream,
        "input": [{"role": "user", "content": "hi"}]
    }).encode()
    req = urllib.request.Request(url, data=payload, method='POST')
    req.add_header('Content-Type', 'application/json')
    req.add_header('Authorization', f'Bearer {api_key}')
    req.add_header('User-Agent', 'codex-cli/1.0')
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
            if stream:
                # 读第一行 SSE 验证格式
                first = resp.readline().decode('utf-8', errors='replace').strip()
                return True, f"SSE首行: {first[:80]}", model
            body = json.loads(resp.read())
            # Responses 格式：body.model 或 body.output[*].type
            returned_model = body.get('model', '?')
            output = body.get('output', [])
            has_output = bool(output)
            return True, f"OK (output_items={len(output)})", returned_model
    except urllib.error.HTTPError as e:
        try:
            err_body = json.loads(e.read())
            msg = (err_body.get('error', {}).get('message') or
                   json.dumps(err_body)[:100])
        except Exception:
            msg = str(e)
        return False, f"HTTP {e.code}: {msg[:100]}", None
    except Exception as e:
        return False, str(e)[:100], None

if MODE_CODEX:
    print(f"\n{'='*70}")
    print(f"  cc-switch Codex 套餐测试  ({len(codex_rows)} 个)")
    print(f"{'='*70}\n")
    print("  注意：每个套餐产生真实 Responses API 请求，可能计费。\n")

    codex_results = []
    for pid, name, cfg_raw in codex_rows:
        short = pid.replace('universal-codex-', '')
        u = universal.get(short, {})
        label = u.get('notes') or name
        cfg = json.loads(cfg_raw) if cfg_raw else {}
        config_str = cfg.get('config', '')
        auth = cfg.get('auth', {})

        base_url = toml_get('base_url', config_str)
        model    = toml_get('model', config_str)
        wire_api = toml_get('wire_api', config_str)
        api_key  = (auth.get('OPENAI_API_KEY') or
                    auth.get('ANTHROPIC_AUTH_TOKEN') or
                    auth.get('ANTHROPIC_API_KEY') or '')

        print(f"{CYAN}▶ {label}{RESET}")
        print(f"   base_url : {base_url}")
        print(f"   model    : {model}")
        print(f"   wire_api : {wire_api}")

        if not base_url or not api_key or not model:
            msg = "配置缺少 base_url / api_key / model"
            print(f"   {RED}✗ 跳过: {msg}{RESET}\n")
            codex_results.append((label, False, msg))
            continue

        if wire_api != 'responses':
            msg = f"wire_api={wire_api!r}，非 Responses 格式，跳过"
            print(f"   {YELLOW}⚠ {msg}{RESET}\n")
            codex_results.append((label, None, msg))
            continue

        # 非流式测试
        ok, msg, returned = test_codex_responses(base_url, api_key, model, stream=False)
        if ok:
            match_info = ''
            if returned and returned != '?' and returned != model:
                match_info = f' {YELLOW}(请求 {model}，返回 {returned}){RESET}'
            print(f"   {GREEN}✓ 非流式{RESET}: {msg}{match_info}")
        else:
            print(f"   {RED}✗ 非流式失败: {msg}{RESET}")

        # 流式测试（仅非流式成功时才测，避免重复计费）
        if ok:
            sok, smsg, _ = test_codex_responses(base_url, api_key, model, stream=True)
            if sok:
                print(f"   {GREEN}✓ 流式{RESET}: {smsg}")
            else:
                print(f"   {RED}✗ 流式失败: {smsg}{RESET}")

        codex_results.append((label, ok, None if ok else msg))
        print()

    passed_c = sum(1 for _, ok, _ in codex_results if ok)
    skipped_c = sum(1 for _, ok, _ in codex_results if ok is None)
    failed_c  = sum(1 for _, ok, _ in codex_results if ok is False)
    print(f"{'─'*70}")
    print(f"Codex 结果: {GREEN}{passed_c} 通过{RESET}  {YELLOW}{skipped_c} 跳过{RESET}  {RED}{failed_c} 失败{RESET}  共 {len(codex_results)} 个")
    if failed_c:
        print(f"\n失败套餐:")
        for label, ok, msg in codex_results:
            if ok is False:
                print(f"  {RED}✗ {label}: {msg}{RESET}")
    print()
