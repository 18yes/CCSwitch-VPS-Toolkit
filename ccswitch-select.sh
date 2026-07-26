#!/usr/bin/env bash
# VPS 端：交互式切换 cc-switch 套餐（支持所有 app 类型）
# 用法: ccswitch-select [app类型]
#   ccswitch-select           # 交互式选择 app 类型
#   ccswitch-select claude    # 直接切换 Claude Code CLI 套餐
#   ccswitch-select codex     # 直接切换 Codex 套餐
#   ccswitch-select gemini    # 直接切换 Gemini 套餐
#   ccswitch-select openclaw  # 直接切换 OpenClaw 套餐
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

# 执行对应的写入；apply_* 返回 False 表示失败，跳过 currentProvider 更新
result = {
    'claude':   apply_claude,
    'codex':    apply_codex,
    'gemini':   apply_gemini,
    'openclaw': apply_openclaw,
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
