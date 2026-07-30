#!/usr/bin/env bash
# 用法:
#   bash sync-ccswitch-to-vps.sh [主机名]           # 一次性同步（默认 oracle-us-12）
#   bash sync-ccswitch-to-vps.sh [主机名] --watch   # 监听本地变更，自动同步
#   bash sync-ccswitch-to-vps.sh [主机名] --cron    # 安装定时任务（每5分钟）
#
# 示例:
#   bash sync-ccswitch-to-vps.sh                    # 同步到 oracle-us-12
#   bash sync-ccswitch-to-vps.sh oracle-jp-4        # 同步到 oracle-jp-4
#   bash sync-ccswitch-to-vps.sh oracle-sg-6 --watch
set -euo pipefail

# 解析参数：VPS名（非--开头）和模式标志分开
VPS="oracle-us-12"
MODE=""
for arg in "$@"; do
  case "$arg" in
    --watch|--cron) MODE="$arg" ;;
    *)              VPS="$arg" ;;
  esac
done
SSH_OPTS="-o StrictHostKeyChecking=accept-new -o BatchMode=yes"
LOCAL_CC_SWITCH="$HOME/.cc-switch"
LOCAL_CLAUDE="$HOME/.claude"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SWITCHER_SCRIPT="$SCRIPT_DIR/ccswitch-select.sh"
PROXY_SCRIPT="$SCRIPT_DIR/claude_proxy.py"
CODEX_PROXY_SCRIPT="$SCRIPT_DIR/codex_proxy.py"
HERMES_AUTH_PROXY_SCRIPT="$SCRIPT_DIR/hermes_auth_proxy.py"
TEST_SCRIPT="$SCRIPT_DIR/test-ccswitch-providers.py"

log()  { echo "[$(date '+%H:%M:%S')] $*"; }
die()  { echo "ERROR: $*" >&2; exit 1; }

# ---------- 核心同步函数 ----------
do_sync() {
  log "开始同步 → $VPS"

  # 确保远端目录存在
  ssh $SSH_OPTS "$VPS" \
    "mkdir -p ~/.cc-switch/skills ~/.cc-switch/logs ~/.claude ~/.local/bin" \
    2>/dev/null

  # cc-switch 数据库（主配置）
  rsync -az -e "ssh $SSH_OPTS" \
    "$LOCAL_CC_SWITCH/cc-switch.db" \
    "$VPS:~/.cc-switch/cc-switch.db"

  # cc-switch settings.json（当前选中套餐）
  rsync -az -e "ssh $SSH_OPTS" \
    "$LOCAL_CC_SWITCH/settings.json" \
    "$VPS:~/.cc-switch/settings.json"

  # skills 目录
  if [[ -d "$LOCAL_CC_SWITCH/skills" ]]; then
    rsync -az --delete -e "ssh $SSH_OPTS" \
      "$LOCAL_CC_SWITCH/skills/" \
      "$VPS:~/.cc-switch/skills/"
  fi

  # ~/.claude/settings.json（含当前活跃套餐的 API key）
  rsync -az -e "ssh $SSH_OPTS" \
    "$LOCAL_CLAUDE/settings.json" \
    "$VPS:~/.claude/settings.json"

  # litellm 和 settings.local（如有）
  for f in litellm_config.yaml settings.local.json; do
    [[ -f "$LOCAL_CLAUDE/$f" ]] && \
      rsync -az -e "ssh $SSH_OPTS" "$LOCAL_CLAUDE/$f" "$VPS:~/.claude/$f"
  done

  # 部署 VPS 端切换脚本
  if [[ -f "$SWITCHER_SCRIPT" ]]; then
    rsync -az -e "ssh $SSH_OPTS" "$SWITCHER_SCRIPT" "$VPS:~/.local/bin/ccswitch-select"
    ssh $SSH_OPTS "$VPS" "chmod +x ~/.local/bin/ccswitch-select"
  fi

  # 部署 OpenAI Chat -> Anthropic Messages 格式转换代理
  if [[ -f "$PROXY_SCRIPT" ]]; then
    rsync -az -e "ssh $SSH_OPTS" "$PROXY_SCRIPT" "$VPS:~/claude_proxy.py"
    ssh $SSH_OPTS "$VPS" "chmod 700 ~/claude_proxy.py"
  fi

  # 部署 Codex Responses 代理
  if [[ -f "$CODEX_PROXY_SCRIPT" ]]; then
    rsync -az -e "ssh $SSH_OPTS" "$CODEX_PROXY_SCRIPT" "$VPS:~/codex_proxy.py"
    ssh $SSH_OPTS "$VPS" "chmod 700 ~/codex_proxy.py"
  fi

  # 部署 Hermes Anthropic Bearer 认证桥（仅回环监听，不转换协议）
  if [[ -f "$HERMES_AUTH_PROXY_SCRIPT" ]]; then
    rsync -az -e "ssh $SSH_OPTS" "$HERMES_AUTH_PROXY_SCRIPT" "$VPS:~/hermes_auth_proxy.py"
    ssh $SSH_OPTS "$VPS" "chmod 700 ~/hermes_auth_proxy.py"
  fi

  # 部署连通性测试工具
  if [[ -f "$TEST_SCRIPT" ]]; then
    rsync -az -e "ssh $SSH_OPTS" "$TEST_SCRIPT" "$VPS:~/.local/bin/test-ccswitch-providers"
    ssh $SSH_OPTS "$VPS" "chmod 700 ~/.local/bin/test-ccswitch-providers"
  fi

  # 数据库和应用配置中含 API key，限制为仅远端用户可读写
  ssh $SSH_OPTS "$VPS" \
    "chmod 700 ~/.cc-switch ~/.claude; chmod 600 ~/.cc-switch/cc-switch.db ~/.cc-switch/settings.json ~/.claude/settings.json" \
    2>/dev/null

  log "同步完成。"
  log "在 VPS 上运行 'ccswitch-select' 可切换套餐。"
}

# ---------- 安装本地 cron 定时同步 ----------
install_cron() {
  CRON_LOG="/tmp/ccswitch-sync-$VPS.log"
  CRON_CMD="*/5 * * * * /bin/bash \"$SCRIPT_DIR/sync-ccswitch-to-vps.sh\" \"$VPS\" >> \"$CRON_LOG\" 2>&1"
  # 先删除旧的同名条目再添加
  (crontab -l 2>/dev/null | grep -v "sync-ccswitch-to-vps.sh"; echo "$CRON_CMD") | crontab -
  log "已安装 cron 定时任务（每5分钟自动同步到 $VPS）。"
  log "查看日志: tail -f $CRON_LOG"
  log "删除任务: crontab -e  然后删除含 sync-ccswitch-to-vps 的行"
}

# ---------- fswatch 监听模式 ----------
watch_mode() {
  command -v fswatch &>/dev/null || die "需要 fswatch，请先安装: brew install fswatch"
  do_sync
  log "监听模式已启动，检测到变更后自动同步..."
  log "按 Ctrl+C 停止"
  WATCH_TARGETS=(
    "$LOCAL_CC_SWITCH/cc-switch.db"
    "$LOCAL_CC_SWITCH/settings.json"
    "$LOCAL_CLAUDE/settings.json"
  )
  fswatch -o "${WATCH_TARGETS[@]}" | while read -r _; do
    log "检测到配置变更，开始同步..."
    do_sync
  done
}

# ---------- 主入口 ----------
case "$MODE" in
  --watch) watch_mode ;;
  --cron)  install_cron ;;
  *)       do_sync ;;
esac
