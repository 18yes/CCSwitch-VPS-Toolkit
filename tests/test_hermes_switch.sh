#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
cleanup() {
  if [[ -f "$TMP_DIR/home/.hermes/ccswitch-auth-proxy.pid" ]]; then
    kill "$(cat "$TMP_DIR/home/.hermes/ccswitch-auth-proxy.pid")" 2>/dev/null || true
  fi
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

export HOME="$TMP_DIR/home"
export PATH="$TMP_DIR/bin:$PATH"
mkdir -p "$HOME/.cc-switch" "$HOME/.hermes" "$TMP_DIR/bin"

cat > "$TMP_DIR/bin/hermes" <<'HERMES'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-} ${2:-}" in
  "config check")
    if [[ "${HERMES_CHECK_FAIL:-0}" == 1 ]]; then
      echo "failed to parse test config" >&2
      exit 1
    fi
    ;;
  "gateway status")
    echo "inactive"
    ;;
  *)
    echo "unexpected fake hermes invocation: $*" >&2
    exit 2
    ;;
esac
HERMES
chmod +x "$TMP_DIR/bin/hermes"

python3 - "$HOME/.cc-switch/cc-switch.db" <<'PY'
import json
import sqlite3
import sys

path = sys.argv[1]
conn = sqlite3.connect(path)
conn.executescript('''
CREATE TABLE providers (
  id TEXT PRIMARY KEY,
  app_type TEXT NOT NULL,
  name TEXT NOT NULL,
  settings_config TEXT
);
CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT);
''')
providers = [
    (
        'hermes-gpt',
        'hermes',
        'GPT Responses',
        {
            'base_url': 'https://api.example.test/v1',
            'api_key': 'test-gpt-key',
            # Deliberately omit api_mode to exercise legacy inference.
            'models': [
                {'id': 'gpt-5.6-sol', 'name': 'GPT Sol', 'context_length': 200000},
                {'id': 'gpt-5.6-terra', 'name': 'GPT Terra'},
            ],
        },
    ),
    (
        'hermes-claude',
        'hermes',
        'Claude Messages',
        {
            'base_url': 'https://claude.example.test/v1',
            'api_key': 'test-claude-key',
            'api_mode': 'anthropic_messages',
            'models': [
                {'id': 'claude-sonnet-5', 'name': 'Claude Sonnet 5'},
                {'id': 'claude-opus-5', 'name': 'Claude Opus 5'},
            ],
        },
    ),
]
for provider_id, app_type, name, config in providers:
    conn.execute(
        'INSERT INTO providers (id, app_type, name, settings_config) VALUES (?, ?, ?, ?)',
        (provider_id, app_type, name, json.dumps(config)),
    )
conn.execute(
    'INSERT INTO settings (key, value) VALUES (?, ?)',
    ('universal_providers', json.dumps({})),
)
conn.commit()
PY

cat > "$HOME/.cc-switch/settings.json" <<'JSON'
{
  "currentProviderHermes": "before-test",
  "unrelatedSetting": true
}
JSON

# Migrate the dict form emitted by the original Hermes implementation.
cat > "$HOME/.hermes/config.yaml" <<'YAML'
theme: dark
custom_providers:
  ccswitch-selected:
    type: openai
    base_url: "https://stale.example.test/v1/v1"
    api_key: "stale-key"
telemetry:
  enabled: false
YAML
"$REPO_DIR/ccswitch-select.sh" hermes 1 > "$TMP_DIR/migration.out"
grep -q '^custom_providers:$' "$HOME/.hermes/config.yaml"
grep -q '^  - name: ccswitch-selected$' "$HOME/.hermes/config.yaml"
if grep -q '^  ccswitch-selected:$' "$HOME/.hermes/config.yaml"; then
  echo "legacy Hermes provider dict was not migrated" >&2
  exit 1
fi
grep -q '    api_mode: "codex_responses"' "$HOME/.hermes/config.yaml"
grep -q '    base_url: "https://api.example.test/v1"' "$HOME/.hermes/config.yaml"

# Also verify replacing one entry in a valid list preserves unrelated providers.
cat > "$HOME/.cc-switch/settings.json" <<'JSON'
{
  "currentProviderHermes": "before-test",
  "unrelatedSetting": true
}
JSON

cat > "$HOME/.hermes/config.yaml" <<'YAML'
theme: dark
model:
  default: old-model
  provider: custom:old
custom_providers:
  - name: existing-provider
    base_url: "https://keep.example.test/v1"
    api_key: "keep-key"
    api_mode: chat_completions
  - name: ccswitch-selected
    base_url: "https://stale.example.test/v1"
    api_key: "stale-key"
    api_mode: chat_completions
telemetry:
  enabled: false
YAML

assert_state() {
  local expected_id="$1"
  local expected_url="$2"
  local expected_mode="$3"
  local expected_model="$4"
  python3 - "$HOME/.hermes/config.yaml" "$HOME/.cc-switch/settings.json" \
    "$expected_id" "$expected_url" "$expected_mode" "$expected_model" <<'PY'
import json
import re
import sys

config_path, settings_path, expected_id, expected_url, expected_mode, expected_model = sys.argv[1:]
with open(config_path) as fh:
    text = fh.read()
with open(settings_path) as fh:
    settings = json.load(fh)

# Keep this test dependency-free: JSON-quoted scalar values are valid YAML.
assert 'theme: dark\n' in text, text
assert 'telemetry:\n  enabled: false\n' in text, text
assert 'custom_providers:\n' in text, text
assert '  - name: existing-provider\n' in text, text
assert '    base_url: "https://keep.example.test/v1"\n' in text, text
assert '  ccswitch-selected:' not in text, text  # old dict form
selected_match = re.search(
    r'(?ms)^  - name: ccswitch-selected\n(.*?)(?=^  - name:|^[A-Za-z_][A-Za-z0-9_-]*:|\Z)',
    text,
)
assert selected_match, text
selected = selected_match.group(1)
assert f'    base_url: {json.dumps(expected_url)}\n' in selected, selected
assert '/v1/v1' not in selected, selected
assert f'    api_mode: {json.dumps(expected_mode)}\n' in selected, selected
assert f'      - id: {json.dumps(expected_model)}\n' in selected, selected
assert f'    default_model: {json.dumps(expected_model)}\n' in selected, selected
expected_model_block = (
    'model:\n'
    f'  default: {json.dumps(expected_model)}\n'
    '  provider: custom:ccswitch-selected\n'
)
assert expected_model_block in text, text
assert settings['currentProviderHermes'] == expected_id, settings
assert settings['unrelatedSetting'] is True, settings
PY
}

"$REPO_DIR/ccswitch-select.sh" hermes 1 > "$TMP_DIR/gpt.out"
assert_state \
  hermes-gpt \
  https://api.example.test/v1 \
  codex_responses \
  gpt-5.6-sol

grep -q '协议: codex_responses' "$TMP_DIR/gpt.out"
if grep -q 'test-gpt-key' "$TMP_DIR/gpt.out"; then
  echo "API key leaked to command output" >&2
  exit 1
fi

"$REPO_DIR/ccswitch-select.sh" hermes 2 > "$TMP_DIR/claude.out"
assert_state \
  hermes-claude \
  https://claude.example.test/v1 \
  anthropic_messages \
  claude-sonnet-5

grep -q '协议: anthropic_messages' "$TMP_DIR/claude.out"
if grep -q 'test-claude-key' "$TMP_DIR/claude.out"; then
  echo "API key leaked to command output" >&2
  exit 1
fi

# Hermes validation failures must restore config.yaml and leave currentProvider unchanged.
cp "$HOME/.hermes/config.yaml" "$TMP_DIR/config-before-failure.yaml"
cp "$HOME/.cc-switch/settings.json" "$TMP_DIR/settings-before-failure.json"
HERMES_CHECK_FAIL=1 "$REPO_DIR/ccswitch-select.sh" hermes 1 > "$TMP_DIR/failure.out"
cmp "$TMP_DIR/config-before-failure.yaml" "$HOME/.hermes/config.yaml"
cmp "$TMP_DIR/settings-before-failure.json" "$HOME/.cc-switch/settings.json"
grep -q 'Hermes 配置校验失败，已恢复备份' "$TMP_DIR/failure.out"
grep -q '切换失败，保留原套餐配置' "$TMP_DIR/failure.out"

# A Claude Code ANTHROPIC_AUTH_TOKEN with the same key and API root means the
# gateway requires Bearer auth. The switcher should start the loopback bridge.
mkdir -p "$HOME/.claude"
cat > "$HOME/.claude/settings.json" <<'JSON'
{
  "env": {
    "ANTHROPIC_BASE_URL": "https://claude.example.test",
    "ANTHROPIC_AUTH_TOKEN": "test-claude-key"
  }
}
JSON
cp "$REPO_DIR/hermes_auth_proxy.py" "$HOME/hermes_auth_proxy.py"
chmod 700 "$HOME/hermes_auth_proxy.py"
export CCSWITCH_HERMES_PROXY_PORT
CCSWITCH_HERMES_PROXY_PORT="$(python3 - <<'PY'
import socket
with socket.socket() as sock:
    sock.bind(('127.0.0.1', 0))
    print(sock.getsockname()[1])
PY
)"
"$REPO_DIR/ccswitch-select.sh" hermes 2 > "$TMP_DIR/bearer.out"
assert_state \
  hermes-claude \
  "http://127.0.0.1:$CCSWITCH_HERMES_PROXY_PORT" \
  anthropic_messages \
  claude-sonnet-5
grep -q '认证: bearer' "$TMP_DIR/bearer.out"
python3 - "$HOME/.hermes/ccswitch-auth-proxy.json" "$CCSWITCH_HERMES_PROXY_PORT" <<'PY'
import json, os, stat, sys
path, expected_port = sys.argv[1:]
with open(path) as fh:
    config = json.load(fh)
assert config['upstream_base_url'] == 'https://claude.example.test/v1', config
assert config['api_key'] == 'test-claude-key', config
assert config['auth_mode'] == 'bearer', config
assert config['listen_host'] == '127.0.0.1', config
assert config['listen_port'] == int(expected_port), config
assert stat.S_IMODE(os.stat(path).st_mode) == 0o600
PY
python3 - "$CCSWITCH_HERMES_PROXY_PORT" <<'PY'
import sys, urllib.request
with urllib.request.urlopen(f'http://127.0.0.1:{sys.argv[1]}/health', timeout=2) as response:
    assert response.status == 200
PY

# Switching back to a native Responses provider must stop the auth bridge.
proxy_pid="$(cat "$HOME/.hermes/ccswitch-auth-proxy.pid")"
"$REPO_DIR/ccswitch-select.sh" hermes 1 > "$TMP_DIR/back-to-native.out"
assert_state \
  hermes-gpt \
  https://api.example.test/v1 \
  codex_responses \
  gpt-5.6-sol
if kill -0 "$proxy_pid" 2>/dev/null; then
  echo "Hermes auth proxy was not stopped after native switch" >&2
  exit 1
fi

echo "PASS: Hermes native routing, Bearer bridge, config preservation, switching, and rollback"
