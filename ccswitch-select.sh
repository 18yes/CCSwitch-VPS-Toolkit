#!/usr/bin/env bash
# VPS 端：交互式切换 cc-switch 套餐（支持所有 app 类型）
# 用法: ccswitch-select [app类型]
#   ccswitch-select           # 交互式选择 app 类型
#   ccswitch-select claude    # 直接切换 Claude Code CLI 套餐
#   ccswitch-select codex     # 直接切换 Codex 套餐
#   ccswitch-select gemini    # 直接切换 Gemini 套餐
#   ccswitch-select openclaw  # 直接切换 OpenClaw 套餐
#   ccswitch-select hermes    # 直接切换 Hermes Gateway 套餐
set -euo pipefail

DB="$HOME/.cc-switch/cc-switch.db"
CC_SETTINGS="$HOME/.cc-switch/settings.json"

die() { echo "错误: $*" >&2; exit 1; }
[[ -f "$DB" ]] || die "数据库不存在: $DB\n请先从本机运行 sync-ccswitch-to-vps.sh"
command -v sqlite3 &>/dev/null || die "需要 sqlite3: sudo apt install sqlite3"
command -v python3 &>/dev/null || die "需要 python3"

APP_TYPE="${1:-}"
PROVIDER_NUM="${2:-}"  # 可选：直接传套餐编号，跳过交互

python3 - "$DB" "$CC_SETTINGS" "$APP_TYPE" "$PROVIDER_NUM" <<'PYEOF'
import sys, json, os, re

def _read_choice(prompt):
    """优先用命令行传入的编号，否则从终端读取"""
    if provider_num:
        print(prompt + provider_num)
        return provider_num
    sys.stdout.write(prompt)
    sys.stdout.flush()
    try:
        with open('/dev/tty') as tty:
            return tty.readline().strip()
    except OSError:
        return (sys.stdin.readline()).strip()

db_path      = sys.argv[1]
cc_settings_path = sys.argv[2]
app_arg      = sys.argv[3].strip().lower() if sys.argv[3] else ''
provider_num = sys.argv[4].strip() if len(sys.argv) > 4 and sys.argv[4] else ''

import sqlite3
conn = sqlite3.connect(db_path)

# --- 可支持的 app 类型（跳过 GUI 专用的 claude-desktop）---
SUPPORTED = {
    'claude':   'Claude Code CLI',
    'codex':    'Codex',
    'gemini':   'Gemini CLI',
    'openclaw': 'OpenClaw (龙虾)',
    'hermes':   'Hermes Gateway',
}

# --- 统计各 app 类型的套餐数量 ---
counts = {}
for row in conn.execute("SELECT app_type, COUNT(*) FROM providers WHERE app_type != 'claude-desktop' GROUP BY app_type"):
    counts[row[0]] = row[1]

# --- 选择 app 类型 ---
if app_arg in SUPPORTED:
    app_type = app_arg
else:
    print("\n选择要切换套餐的应用:\n")
    apps = [(k, v) for k, v in SUPPORTED.items() if k in counts]
    for i, (k, v) in enumerate(apps):
        print(f"  [{i+1}] {v:<20} ({counts.get(k,0)} 个套餐)")
    print()
    try:
        choice = _read_choice("输入编号: ")
        idx = int(choice) - 1
        assert 0 <= idx < len(apps)
        app_type = apps[idx][0]
    except (ValueError, AssertionError, EOFError, KeyboardInterrupt):
        print("\n已取消。")
        sys.exit(0)

# --- 读取 universal_providers 补充备注 ---
row = conn.execute("SELECT value FROM settings WHERE key='universal_providers'").fetchone()
universal = {}
if row:
    try:
        universal = json.loads(row[0])
    except Exception:
        pass

# --- 读取当前激活的套餐 ---
cc_settings = {}
try:
    with open(cc_settings_path) as f:
        cc_settings = json.load(f)
except Exception:
    pass

CURRENT_KEY = {
    'claude':   'currentProviderClaude',
    'codex':    'currentProviderCodex',
    'gemini':   'currentProviderGemini',
    'openclaw': 'currentProviderOpenclaw',
    'hermes':   'currentProviderHermes',
}.get(app_type, '')
current_id = cc_settings.get(CURRENT_KEY, '')

# --- 列出该 app 的所有套餐 ---
rows = conn.execute(
    "SELECT id, name, settings_config FROM providers WHERE app_type=? ORDER BY rowid",
    (app_type,)
).fetchall()

if not rows:
    print(f"没有找到 {app_type} 的套餐。")
    sys.exit(1)

print(f"\n{SUPPORTED.get(app_type, app_type)} 套餐列表:\n")
providers = []
for pid, name, cfg_raw in rows:
    pid_short = pid.replace(f'universal-{app_type}-', '')
    u = universal.get(pid_short, {})
    notes = u.get('notes', '')
    label = notes if notes else name
    # 提取 base_url 用于显示
    base_url = ''
    try:
        cfg = json.loads(cfg_raw) if cfg_raw else {}
        env = cfg.get('env', {})
        base_url = (env.get('ANTHROPIC_BASE_URL') or
                    env.get('GOOGLE_GEMINI_BASE_URL') or
                    cfg.get('base_url') or
                    cfg.get('baseUrl') or
                    cfg.get('config','').split('base_url')[1].split('"')[1] if 'base_url' in cfg.get('config','') else '')
    except Exception:
        pass
    url_short = base_url.replace('https://','').replace('http://','').split('/')[0]
    marker = " ← 当前" if pid == current_id else ""
    print(f"  [{len(providers)+1}] {label:<32} {url_short}{marker}")
    providers.append({'id': pid, 'name': name, 'cfg_raw': cfg_raw, 'label': label})

print()
try:
    choice = _read_choice("输入编号切换套餐 (回车取消): ")
except (EOFError, KeyboardInterrupt):
    print("\n已取消。")
    sys.exit(0)

if not choice:
    print("已取消。")
    sys.exit(0)

try:
    sel = providers[int(choice)-1]
except (ValueError, IndexError):
    print("无效编号。")
    sys.exit(1)

cfg = json.loads(sel['cfg_raw']) if sel['cfg_raw'] else {}

# ===================== 各 app 类型的写入逻辑 =====================

def needs_proxy(env):
    """检测是否需要 OpenAI Chat 转换代理（grok-* / gpt-5.* 等模型）"""
    model = env.get('ANTHROPIC_MODEL', '')
    return bool(model) and not (
        model.startswith('claude-') or
        model.startswith('deepseek-') or
        model.startswith('gemini-') or
        model.startswith('gpt-image')
    )

def start_claude_proxy(env, model):
    """写 proxy_config.json 并重启 claude_proxy.py"""
    import subprocess
    proxy_cfg = os.path.expanduser('~/proxy_config.json')
    proxy_py  = os.path.expanduser('~/claude_proxy.py')
    pid_file  = os.path.expanduser('~/claude_proxy.pid')

    # 停掉旧实例
    if os.path.exists(pid_file):
        try:
            pid = int(open(pid_file).read().strip())
            os.kill(pid, 15)
            import time; time.sleep(0.5)
        except Exception:
            pass
        try: os.remove(pid_file)
        except Exception: pass

    if not os.path.exists(proxy_py):
        print("  ⚠ 未找到 ~/claude_proxy.py，Grok/GptPlus 类套餐无法使用")
        return False

    cfg_data = {
        "upstream_base_url": env.get('ANTHROPIC_BASE_URL', '').rstrip('/'),
        "api_key": env.get('ANTHROPIC_AUTH_TOKEN') or env.get('ANTHROPIC_API_KEY', ''),
        "model": model,
        "listen_host": "127.0.0.1",
        "listen_port": 18721
    }
    with open(proxy_cfg, 'w') as f:
        json.dump(cfg_data, f, indent=2)
    os.chmod(proxy_cfg, 0o600)

    subprocess.Popen(
        ['python3', proxy_py, '--daemon'],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
    )
    import time; time.sleep(1.2)

    if os.path.exists(pid_file):
        pid = open(pid_file).read().strip()
        print(f"  代理已启动 (PID {pid}) → 上游 {cfg_data['upstream_base_url']}")
        return True
    else:
        print("  ⚠ 代理启动失败，查看 ~/claude_proxy.log")
        return False

def start_codex_proxy(upstream_url, api_key, model):
    """写 codex_proxy_config.json，重启 codex_proxy.py，等待 /health 就绪"""
    import subprocess, time, urllib.request
    proxy_cfg = os.path.expanduser('~/codex_proxy_config.json')
    proxy_py  = os.path.expanduser('~/codex_proxy.py')
    pid_file  = os.path.expanduser('~/codex_proxy.pid')

    # 停掉旧实例
    if os.path.exists(pid_file):
        try:
            pid = int(open(pid_file).read().strip())
            os.kill(pid, 15)
            time.sleep(0.5)
        except Exception:
            pass
        try: os.remove(pid_file)
        except Exception: pass

    if not os.path.exists(proxy_py):
        print("  ⚠ 未找到 ~/codex_proxy.py，Codex 代理无法启动")
        return False

    cfg_data = {
        "upstream_base_url": upstream_url.rstrip('/'),
        "api_key": api_key,
        "model": model,
        "listen_host": "127.0.0.1",
        "listen_port": 18722
    }
    with open(proxy_cfg, 'w') as f:
        json.dump(cfg_data, f, indent=2)
    os.chmod(proxy_cfg, 0o600)

    subprocess.Popen(
        ['python3', proxy_py, '--daemon'],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
    )

    # 轮询 /health，最多等 5 秒
    for _ in range(10):
        time.sleep(0.5)
        try:
            with urllib.request.urlopen('http://127.0.0.1:18722/health', timeout=2) as r:
                if r.status == 200:
                    pid_str = open(pid_file).read().strip() if os.path.exists(pid_file) else '?'
                    print(f"  Codex 代理已启动 (PID {pid_str}) → {upstream_url}")
                    return True
        except Exception:
            pass
    print("  ⚠ Codex 代理启动失败，查看 ~/codex_proxy.log")
    return False

def stop_codex_proxy():
    """停止 Codex 专用代理"""
    pid_file = os.path.expanduser('~/codex_proxy.pid')
    if os.path.exists(pid_file):
        try:
            pid = int(open(pid_file).read().strip())
            os.kill(pid, 15)
        except Exception:
            pass
        try: os.remove(pid_file)
        except Exception: pass

def apply_claude(cfg):
    """写入 ~/.claude/settings.json；OpenAI 格式套餐自动启动本地代理"""
    path = os.path.expanduser('~/.claude/settings.json')
    env  = cfg.get('env', {})
    model_raw = env.get('ANTHROPIC_MODEL', '') or env.get('ANTHROPIC_DEFAULT_SONNET_MODEL', '')
    model = model_raw.split('[')[0]  # 去掉 [1M] 等后缀

    existing = {}
    try:
        with open(path) as f:
            existing = json.load(f)
    except Exception:
        pass

    if needs_proxy(env):
        # OpenAI Chat 格式套餐 → 通过本地代理
        ok = start_claude_proxy(env, model)
        if ok:
            proxy_env = dict(env)  # 保留模型映射字段
            proxy_env['ANTHROPIC_BASE_URL']  = 'http://127.0.0.1:18721'
            proxy_env['ANTHROPIC_AUTH_TOKEN'] = 'PROXY_MANAGED'
            # 统一把所有模型别名指向同一个 model（代理负责实际路由）
            for k in list(proxy_env.keys()):
                if k.startswith('ANTHROPIC_DEFAULT_') and k.endswith('_MODEL') and not k.endswith('_NAME'):
                    proxy_env[k] = model
            existing['env'] = proxy_env
        else:
            return
    else:
        # 直接 Anthropic Messages 格式
        # 停掉代理（避免占用端口干扰）
        pid_file = os.path.expanduser('~/claude_proxy.pid')
        if os.path.exists(pid_file):
            try:
                pid = int(open(pid_file).read().strip())
                os.kill(pid, 15)
            except Exception:
                pass
            try: os.remove(pid_file)
            except Exception: pass
        existing['env'] = env

    if 'model' in cfg:
        existing['model'] = cfg['model']

    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, 'w') as f:
        json.dump(existing, f, indent=4, ensure_ascii=False)
    print(f"  已写入: {path}")

def apply_codex(cfg):
    """写入 ~/.codex/config.toml 和 ~/.codex/auth.json；需要代理时启动 codex_proxy.py"""
    codex_dir = os.path.expanduser('~/.codex')
    os.makedirs(codex_dir, exist_ok=True)

    config_str = cfg.get('config', '')
    auth = cfg.get('auth', {})

    # 从 TOML 文本提取关键字段（仅用正则，不引入 toml 解析库）
    def toml_get(key, text):
        m = re.search(r'^' + re.escape(key) + r'\s*=\s*"([^"]*)"', text, re.MULTILINE)
        return m.group(1) if m else ''

    model_in_toml = toml_get('model', config_str)
    base_url_in_toml = toml_get('base_url', config_str)
    wire_api = toml_get('wire_api', config_str)  # "responses" 表示上游用 Responses API

    # 判断是否需要 Codex 专用代理（上游为 Responses 格式时，代理负责剥离不兼容工具字段）
    needs_codex_proxy = wire_api == 'responses' and bool(base_url_in_toml)

    # 提取 API key（优先 OPENAI_API_KEY，兼容其他字段名）
    api_key = (auth.get('OPENAI_API_KEY') or
               auth.get('ANTHROPIC_AUTH_TOKEN') or
               auth.get('ANTHROPIC_API_KEY') or '')

    if needs_codex_proxy:
        # 启动代理；失败则不继续写配置
        ok = start_codex_proxy(base_url_in_toml, api_key, model_in_toml)
        if not ok:
            return False   # 返回 False 让上层跳过 currentProvider 更新

        # 将 config.toml 的 base_url 指向本地代理
        proxy_url = 'http://127.0.0.1:18722/v1'
        config_str = re.sub(
            r'^(base_url\s*=\s*)"[^"]*"',
            r'\g<1>"' + proxy_url + '"',
            config_str, count=1, flags=re.MULTILINE
        )
        # auth.json 里的 key 换成占位符（代理自己管理真实 key）
        if auth:
            auth_to_write = {k: ('PROXY_MANAGED' if 'key' in k.lower() or 'token' in k.lower() else v)
                             for k, v in auth.items()}
        else:
            auth_to_write = {}
    else:
        # 直连：停止 Codex 代理
        stop_codex_proxy()
        auth_to_write = auth

    # 写 auth.json
    if auth_to_write:
        auth_path = os.path.join(codex_dir, 'auth.json')
        with open(auth_path, 'w') as f:
            json.dump(auth_to_write, f, indent=4)
        print(f"  已写入: {auth_path}")

    # 读取现有 TOML，保留本地块
    toml_path = os.path.join(codex_dir, 'config.toml')
    existing_toml = ''
    try:
        with open(toml_path) as f:
            existing_toml = f.read()
    except Exception:
        pass

    local_blocks = re.findall(r'(\[(?:projects|tui|trust)[^\]]*\].*?)(?=\n\[|\Z)', existing_toml, re.DOTALL)
    # 过滤掉套餐 config 本身已包含的相同块，避免重复
    new_header = config_str.rstrip()
    existing_keys = set(re.findall(r'(\[(?:projects|tui|trust)[^\]]*\])', new_header))
    filtered_blocks = [b for b in local_blocks
                       if re.match(r'\[(?:projects|tui|trust)[^\]]*\]', b.strip())
                       and b.strip().split('\n')[0] not in existing_keys]
    new_toml = new_header + '\n'
    if filtered_blocks:
        new_toml += '\n' + '\n'.join(b.rstrip() for b in filtered_blocks) + '\n'
    with open(toml_path, 'w') as f:
        f.write(new_toml)
    print(f"  已写入: {toml_path}")
    return True  # 成功

def apply_gemini(cfg):
    """写 ~/.gemini/config/config.json 或环境变量提示"""
    env = cfg.get('env', {})
    if not env:
        print("该套餐没有环境变量配置。")
        return
    # Gemini CLI 通过环境变量控制
    env_file = os.path.expanduser('~/.cc-switch/gemini.env')
    with open(env_file, 'w') as f:
        for k, v in env.items():
            f.write(f'export {k}="{v}"\n')
    print(f"已写入: {env_file}")
    print("在 ~/.bashrc 或 ~/.zshrc 中添加: source ~/.cc-switch/gemini.env")

def apply_openclaw(cfg):
    """写入 ~/.openclaw/config.json 的 models.providers 段"""
    path = os.path.expanduser('~/.openclaw/config.json')
    existing = {}
    try:
        with open(path) as f:
            existing = json.load(f)
    except Exception:
        pass
    existing.setdefault('models', {}).setdefault('providers', {})
    # 用套餐 id 作为 provider key（保持一致）
    provider_key = sel['id']
    existing['models']['providers'] = {provider_key: cfg}
    os.makedirs(os.path.dirname(path) if '/' in path else '.', exist_ok=True)
    with open(path, 'w') as f:
        json.dump(existing, f, indent=2, ensure_ascii=False)
    print(f"已写入: {path}")

def apply_hermes(cfg):
    """将 CC Switch 的 Hermes 套餐写入 Hermes 原生 custom provider 配置。"""
    import subprocess, shutil, time, re as _re

    hermes_dir = os.path.expanduser('~/.hermes')
    config_path = os.path.join(hermes_dir, 'config.yaml')
    os.makedirs(hermes_dir, exist_ok=True)

    base_url = str(cfg.get('base_url', '') or '').rstrip('/')
    api_key = str(cfg.get('api_key', '') or '')
    raw_models = cfg.get('models', [])
    models = [m for m in raw_models if isinstance(m, dict)] if isinstance(raw_models, list) else []
    model_ids = [str(m.get('id', '') or '').strip() for m in models]
    first_model = next((mid for mid in model_ids if mid), '')
    api_mode = str(cfg.get('api_mode', '') or '').strip()

    if not base_url:
        print("  ⚠ 套餐缺少 base_url，无法更新 Hermes 配置")
        return False
    if not api_key:
        print("  ⚠ 套餐缺少 api_key，无法更新 Hermes 配置")
        return False

    # CC Switch 的旧记录可能没有 api_mode。Hermes 原生支持三种传输，
    # 根据模型族补全，避免误走默认 /chat/completions。
    if not api_mode:
        model_l = first_model.lower()
        if model_l.startswith('claude-'):
            api_mode = 'anthropic_messages'
        elif model_l.startswith('gpt-5') or 'codex' in model_l:
            api_mode = 'codex_responses'
        else:
            api_mode = 'chat_completions'

    mode_aliases = {
        'openai_chat': 'chat_completions',
        'openai': 'chat_completions',
        'openai_responses': 'codex_responses',
        'responses': 'codex_responses',
        'anthropic': 'anthropic_messages',
    }
    api_mode = mode_aliases.get(api_mode, api_mode)
    valid_modes = {'anthropic_messages', 'codex_responses', 'chat_completions'}
    if api_mode not in valid_modes:
        print(f"  ⚠ 未知 api_mode={api_mode!r}，按 chat_completions 处理")
        api_mode = 'chat_completions'

    # Hermes 的 Anthropic SDK 对普通第三方域名固定发送 x-api-key；部分
    # Claude Code 网关使用同一 Messages 协议，却要求 Authorization: Bearer。
    # 套餐可显式设置 auth_mode=bearer。为兼容旧记录，若当前 Claude Code
    # 配置的 URL 和 ANTHROPIC_AUTH_TOKEN 与套餐完全匹配，也自动判定为 bearer。
    auth_mode = str(cfg.get('auth_mode') or cfg.get('auth_type') or '').strip().lower()
    auth_aliases = {
        'authorization_bearer': 'bearer',
        'bearer_token': 'bearer',
        'x-api-key': 'x_api_key',
        'x_api_key': 'x_api_key',
        'api_key': 'x_api_key',
    }
    auth_mode = auth_aliases.get(auth_mode, auth_mode)
    if api_mode != 'anthropic_messages':
        auth_mode = 'bearer' if auth_mode == 'bearer' else 'native'
    elif not auth_mode:
        try:
            claude_settings_path = os.path.expanduser('~/.claude/settings.json')
            with open(claude_settings_path) as f:
                claude_env = (json.load(f) or {}).get('env', {})
            claude_url = str(claude_env.get('ANTHROPIC_BASE_URL', '') or '').rstrip('/')
            claude_token = str(claude_env.get('ANTHROPIC_AUTH_TOKEN', '') or '')
            normalize_api_root = lambda value: _re.sub(r'/v1$', '', value.rstrip('/'))
            if (claude_token and claude_token == api_key and claude_url
                    and normalize_api_root(claude_url) == normalize_api_root(base_url)):
                auth_mode = 'bearer'
        except Exception:
            pass
    if api_mode == 'anthropic_messages' and not auth_mode:
        auth_mode = 'x_api_key'
    if api_mode == 'anthropic_messages' and auth_mode not in {'bearer', 'x_api_key'}:
        print(f"  ⚠ 未知 auth_mode={auth_mode!r}，按 x_api_key 处理")
        auth_mode = 'x_api_key'

    hermes_bin = shutil.which('hermes')
    if not hermes_bin:
        print("  ⚠ 找不到 hermes 命令，无法校验或重启 Gateway")
        return False

    proxy_script = os.path.expanduser('~/hermes_auth_proxy.py')
    proxy_port = int(os.environ.get('CCSWITCH_HERMES_PROXY_PORT', '18723'))
    proxy_cfg_path = os.path.join(hermes_dir, 'ccswitch-auth-proxy.json')
    proxy_pid_path = os.path.join(hermes_dir, 'ccswitch-auth-proxy.pid')
    old_proxy_cfg = None
    if os.path.exists(proxy_cfg_path):
        with open(proxy_cfg_path, 'rb') as f:
            old_proxy_cfg = f.read()

    def proxy_pid():
        try:
            pid = int(open(proxy_pid_path).read().strip())
            os.kill(pid, 0)
            return pid
        except Exception:
            return None

    old_proxy_was_running = proxy_pid() is not None

    def stop_auth_proxy():
        pid = proxy_pid()
        if pid:
            try:
                os.kill(pid, 15)
                for _ in range(20):
                    time.sleep(0.1)
                    if not proxy_pid():
                        break
            except Exception:
                pass
        try:
            os.unlink(proxy_pid_path)
        except FileNotFoundError:
            pass

    def launch_auth_proxy():
        subprocess.Popen(
            ['python3', proxy_script, '--daemon'],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        import urllib.request
        for _ in range(30):
            time.sleep(0.1)
            try:
                with urllib.request.urlopen(f'http://127.0.0.1:{proxy_port}/health', timeout=1) as response:
                    if response.status == 200:
                        return True
            except Exception:
                pass
        return False

    proxy_changed = False

    def restore_auth_proxy():
        if not proxy_changed:
            return
        stop_auth_proxy()
        if old_proxy_cfg is None:
            try:
                os.unlink(proxy_cfg_path)
            except FileNotFoundError:
                pass
        else:
            with open(proxy_cfg_path, 'wb') as f:
                f.write(old_proxy_cfg)
            os.chmod(proxy_cfg_path, 0o600)
            if old_proxy_was_running and os.path.exists(proxy_script):
                launch_auth_proxy()

    provider_base_url = base_url
    provider_api_key = api_key
    if api_mode == 'anthropic_messages' and auth_mode == 'bearer':
        if not os.path.exists(proxy_script):
            print(f"  ⚠ Bearer 套餐需要认证桥，但未找到: {proxy_script}")
            return False
        proxy_data = {
            'upstream_base_url': base_url,
            'api_key': api_key,
            'auth_mode': 'bearer',
            'listen_host': '127.0.0.1',
            'listen_port': proxy_port,
        }
        stop_auth_proxy()
        tmp_proxy_cfg = proxy_cfg_path + '.tmp'
        with open(tmp_proxy_cfg, 'w') as f:
            json.dump(proxy_data, f, indent=2)
        os.chmod(tmp_proxy_cfg, 0o600)
        os.replace(tmp_proxy_cfg, proxy_cfg_path)
        proxy_changed = True
        if not launch_auth_proxy():
            restore_auth_proxy()
            print("  ⚠ Hermes Bearer 认证桥启动失败，请查看 ~/.hermes/ccswitch-auth-proxy.log")
            return False
        provider_base_url = f'http://127.0.0.1:{proxy_port}'
        provider_api_key = 'ccswitch-local-auth-proxy'

    def yq(value):
        # JSON 双引号字符串也是合法 YAML，且可安全处理特殊字符。
        return json.dumps(str(value), ensure_ascii=False)

    block = [
        '  - name: ccswitch-selected\n',
        f'    base_url: {yq(provider_base_url)}\n',
        f'    api_key: {yq(provider_api_key)}\n',
        f'    api_mode: {yq(api_mode)}\n',
    ]
    if models:
        block.append('    models:\n')
        for model in models:
            mid = str(model.get('id', '') or '').strip()
            if not mid:
                continue
            mname = str(model.get('name', mid) or mid)
            block.append(f'      - id: {yq(mid)}\n')
            block.append(f'        name: {yq(mname)}\n')
            context_length = model.get('context_length')
            if isinstance(context_length, int) and context_length > 0:
                block.append(f'        context_length: {context_length}\n')
    if first_model:
        block.append(f'    default_model: {yq(first_model)}\n')
    provider_block = ''.join(block)

    existing = ''
    had_existing = os.path.exists(config_path)
    if had_existing:
        with open(config_path) as f:
            existing = f.read()
        shutil.copy2(config_path, config_path + '.bak')

    lines = existing.splitlines(keepends=True)
    cp_idx = next((i for i, line in enumerate(lines)
                   if _re.match(r'^custom_providers:\s*(?:#.*)?$', line.rstrip('\n'))), None)
    if cp_idx is None:
        if existing and not existing.endswith('\n'):
            existing += '\n'
        new_yaml = existing + 'custom_providers:\n' + provider_block
    else:
        section_end = len(lines)
        for i in range(cp_idx + 1, len(lines)):
            if _re.match(r'^[A-Za-z_][A-Za-z0-9_-]*:\s*', lines[i]):
                section_end = i
                break

        entry_start = entry_end = None
        # 正确的 list 形式。
        for i in range(cp_idx + 1, section_end):
            if _re.match(r'^  -\s+name:\s*["\']?ccswitch-selected["\']?\s*$', lines[i].rstrip('\n')):
                entry_start = i
                entry_end = section_end
                for j in range(i + 1, section_end):
                    if _re.match(r'^  -\s+', lines[j]):
                        entry_end = j
                        break
                break
        # 兼容并清理旧脚本写出的错误 dict 形式。
        if entry_start is None:
            for i in range(cp_idx + 1, section_end):
                match = _re.match(r'^(\s+)ccswitch-selected:\s*$', lines[i].rstrip('\n'))
                if match:
                    indent = len(match.group(1))
                    entry_start = i
                    entry_end = section_end
                    for j in range(i + 1, section_end):
                        sibling = _re.match(r'^(\s+)[A-Za-z0-9_-]+:\s*', lines[j])
                        if sibling and len(sibling.group(1)) == indent:
                            entry_end = j
                            break
                    break

        if entry_start is None:
            lines[cp_idx + 1:cp_idx + 1] = [provider_block]
        else:
            lines[entry_start:entry_end] = [provider_block]
        new_yaml = ''.join(lines)

    # 套餐切换时同步更新全局默认模型，CLI/新会话无需再次手工 /model。
    if first_model:
        model_block = (
            'model:\n'
            f'  default: {yq(first_model)}\n'
            '  provider: custom:ccswitch-selected\n'
        )
        model_pattern = _re.compile(r'^model:\s*\n(?:^[ \t]+.*\n)*', _re.MULTILINE)
        if model_pattern.search(new_yaml):
            new_yaml = model_pattern.sub(model_block, new_yaml, count=1)
        else:
            new_yaml = model_block + new_yaml

    # 若系统 Python 已安装 PyYAML，写前做严格语法检查；未安装时由
    # Hermes 自己的 `config check` 在写后验证，避免增加 Toolkit 依赖。
    try:
        import yaml
    except ImportError:
        yaml = None
    if yaml is not None:
        try:
            parsed = yaml.safe_load(new_yaml)
            if not isinstance(parsed, dict) or not isinstance(parsed.get('custom_providers'), list):
                raise ValueError('custom_providers 必须是 YAML list')
        except Exception as exc:
            restore_auth_proxy()
            print(f"  ⚠ 生成的 Hermes YAML 无效，已取消写入: {exc}")
            return False

    tmp_path = config_path + '.tmp.ccswitch'
    with open(tmp_path, 'w') as f:
        f.write(new_yaml)
    os.replace(tmp_path, config_path)

    def restore_config():
        if had_existing:
            shutil.copy2(config_path + '.bak', config_path)
        else:
            try:
                os.unlink(config_path)
            except FileNotFoundError:
                pass

    # 使用 Hermes 自带解析器做轻量检查；失败时自动回滚。
    try:
        check = subprocess.run([hermes_bin, 'config', 'check'], capture_output=True,
                               text=True, timeout=20)
        check_text = (check.stdout or '') + (check.stderr or '')
    except Exception as exc:
        restore_config()
        restore_auth_proxy()
        print(f"  ⚠ 无法校验 Hermes 配置，已恢复备份: {exc}")
        return False
    invalid_markers = (
        'failed to parse',
        'custom_providers is a dict',
        'must be a yaml list',
        'yaml syntax',
    )
    if check.returncode != 0 or any(marker in check_text.lower() for marker in invalid_markers):
        restore_config()
        restore_auth_proxy()
        detail = next((line.strip() for line in check_text.splitlines() if line.strip()),
                      f'exit {check.returncode}')
        print(f"  ⚠ Hermes 配置校验失败，已恢复备份: {detail}")
        return False

    if not (api_mode == 'anthropic_messages' and auth_mode == 'bearer'):
        stop_auth_proxy()

    print(f"  已写入: {config_path}")
    print(f"  协议: {api_mode}  模型: {first_model or '(未指定)'}")
    if api_mode == 'anthropic_messages':
        print(f"  认证: {auth_mode}")
    print(f"  上游: {base_url}")

    try:
        status = subprocess.run([hermes_bin, 'gateway', 'status'], capture_output=True,
                                text=True, timeout=10)
        running = 'active (running)' in ((status.stdout or '') + (status.stderr or '')).lower()
    except Exception:
        running = False

    if running:
        print("  正在重启 Hermes Gateway...")
        try:
            subprocess.run([hermes_bin, 'gateway', 'stop'], timeout=20, check=False)
            time.sleep(1)
            subprocess.run([hermes_bin, 'gateway', 'start'], timeout=20, check=False)
            time.sleep(2)
            print("  Hermes Gateway 已重启")
        except Exception as exc:
            print(f"  ⚠ Gateway 重启失败，请手动执行 hermes gateway restart: {exc}")
    else:
        print("  提示: Hermes Gateway 未运行，启动时将自动加载新配置")

    if first_model:
        print("\n  新 CLI/Telegram 会话会自动使用新模型。")
        print("  若 Telegram 旧会话保留了覆盖，可发送:")
        print(f"     /model {first_model} --provider custom:ccswitch-selected")
    return True

# 执行对应的写入；apply_* 返回 False 表示失败，跳过 currentProvider 更新
result = {
    'claude':   apply_claude,
    'codex':    apply_codex,
    'gemini':   apply_gemini,
    'openclaw': apply_openclaw,
    'hermes':   apply_hermes,
}[app_type](cfg)

apply_ok = (result is not False)  # None/True 均视为成功

# 更新 ~/.cc-switch/settings.json 中的 currentProvider（仅成功时）
if CURRENT_KEY and apply_ok:
    cc_settings[CURRENT_KEY] = sel['id']
    try:
        with open(cc_settings_path, 'w') as f:
            json.dump(cc_settings, f, indent=4, ensure_ascii=False)
    except Exception:
        pass

if apply_ok:
    print(f"\n已切换 {SUPPORTED.get(app_type,'')} 套餐 → {sel['label']}")
else:
    print(f"\n切换失败，保留原套餐配置。")
conn.close()
PYEOF
