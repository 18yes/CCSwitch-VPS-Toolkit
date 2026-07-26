# CC Switch VPS 同步脚本使用与开发记录

本文档说明 `~/Documents/code/071/` 中 CC Switch VPS 同步方案的使用方法、工作原理、开发过程和复用注意事项。

整理日期：2026-07-22

## 1. 先看结论

`text.text` 不是可执行脚本，而是此前开发和排查过程留下的对话记录。记录中有重复、截断和已经过时的命令，不应直接照着执行。

真正使用的是以下三个文件：

| 文件 | 在哪里运行 | 作用 |
|---|---|---|
| `sync-ccswitch-to-vps.sh` | 本机 macOS | 把本机 CC Switch 配置和切换脚本同步到 VPS |
| `ccswitch-select.sh` | 由同步脚本部署到 VPS | 在 VPS 上读取数据库并切换 Claude、Codex、Gemini、OpenClaw 套餐 |
| `claude_proxy.py` | 由同步脚本部署到 VPS | 将 Claude Code 的 Anthropic Messages 请求转换为 OpenAI Chat 请求 |
| `codex_proxy.py` | 由同步脚本部署到 VPS | Codex Responses 代理：剥离上游不兼容的工具字段（namespace 等），保持 Responses 协议 |
| `test-ccswitch-providers.py` | 本机或 VPS | 对 Claude/Codex 套餐发起真实 API 请求，检查连通性和模型映射 |

最常用的操作只有两步：

```bash
# 本机：同步到 VPS
bash ~/Documents/code/071/sync-ccswitch-to-vps.sh my-vps

# VPS：选择 Claude Code 套餐
ccswitch-select claude
```

完成同步后，本机 CC Switch 可以退出，本机也可以关机。VPS 已经持有数据库副本和所需配置，可以独立切换套餐并使用。

例外是以后在本机 CC Switch 中新增、删除或修改套餐时，需要重新同步一次，VPS 才能得到最新配置。

## 2. 整体架构

### 2.1 本机

```text
CC Switch GUI
    |
    | 写入套餐和当前选择
    v
~/.cc-switch/cc-switch.db
~/.cc-switch/settings.json
~/.claude/settings.json
    |
    | sync-ccswitch-to-vps.sh
    v
SSH + rsync
```

### 2.2 VPS

```text
~/.cc-switch/cc-switch.db
    |
    | ccswitch-select 查询 providers 表
    v
用户选择应用和套餐
    |
    +--> Claude Code: ~/.claude/settings.json (可能经 claude_proxy.py:18721)
    +--> Codex:       ~/.codex/config.toml + auth.json (可能经 codex_proxy.py:18722)
    +--> Gemini:      ~/.cc-switch/gemini.env
    +--> OpenClaw:    ~/.openclaw/config.json
```

VPS 不需要安装 CC Switch GUI。`ccswitch-select` 直接读取同步过来的 SQLite 数据库。

## 3. 新服务器第一次怎么用

以下示例把新服务器的 SSH 别名设为 `my-vps`。

### 3.1 在本机配置 SSH

编辑 `~/.ssh/config`：

```sshconfig
Host my-vps
    HostName 203.0.113.10
    User ubuntu
    IdentityFile ~/.ssh/my-vps.key
```

先确认免交互登录可用：

```bash
ssh -o BatchMode=yes my-vps "echo SSH_OK"
```

如果这里失败，应先修复 SSH 主机名、用户、密钥或服务器防火墙。同步脚本使用 `BatchMode=yes`，不会停下来询问密码。

### 3.2 安装 VPS 依赖

Ubuntu/Debian：

```bash
ssh my-vps "sudo apt-get update && sudo apt-get install -y python3 sqlite3 rsync"
```

本机也要有 `rsync`。macOS 通常已经自带：

```bash
command -v rsync
```

### 3.3 首次同步

在本机执行：

```bash
bash ~/Documents/code/071/sync-ccswitch-to-vps.sh my-vps
```

脚本会自动创建这些远端目录：

```text
~/.cc-switch/skills
~/.cc-switch/logs
~/.claude
~/.local/bin
```

并部署：

```text
~/.local/bin/ccswitch-select
~/.local/bin/test-ccswitch-providers
~/claude_proxy.py
~/codex_proxy.py
```

### 3.4 配置 VPS 的 PATH

只需要执行一次：

```bash
ssh my-vps \
  "grep -q 'HOME/.local/bin' ~/.bashrc || echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> ~/.bashrc"
```

重新登录 VPS：

```bash
ssh my-vps
```

确认命令可找到：

```bash
command -v ccswitch-select
```

预期输出类似：

```text
/home/ubuntu/.local/bin/ccswitch-select
```

### 3.5 选择套餐

```bash
# 先选择应用，再选择套餐
ccswitch-select

# 直接进入 Claude Code 套餐列表
ccswitch-select claude

# 直接进入 Codex 套餐列表
ccswitch-select codex
```

选择完成后正常启动对应 CLI：

```bash
claude
codex
```

不要长期依赖固定套餐编号。套餐列表按照数据库顺序生成，本机增删或调整套餐后，编号可能改变。自动化前先运行一次交互命令确认当前编号。

## 4. 日常命令

### 4.1 本机修改套餐后同步

例如在 CC Switch 中修改了 DeepSeek、Kiro 或其他套餐：

```bash
# 本机
bash ~/Documents/code/071/sync-ccswitch-to-vps.sh my-vps

# VPS
ccswitch-select claude
```

同步数据库只表示 VPS 得到了新配置。需要在 VPS 上重新选择该套餐，才会把新配置写入 `~/.claude/settings.json`。

### 4.2 非交互切换

适合已经确认编号的自动化任务：

```bash
ccswitch-select claude 2
ccswitch-select codex 3
ccswitch-select gemini 1
ccswitch-select openclaw 1
```

参数格式：

```text
ccswitch-select <app_type> <套餐编号>
```

支持的 `app_type`：

| 参数 | 应用 |
|---|---|
| `claude` | Claude Code CLI |
| `codex` | Codex |
| `gemini` | Gemini CLI |
| `openclaw` | OpenClaw |

`claude-desktop` 是桌面 GUI 配置，VPS 脚本有意忽略。

### 4.3 实时监听

本机安装 `fswatch`：

```bash
brew install fswatch
```

启动监听：

```bash
bash ~/Documents/code/071/sync-ccswitch-to-vps.sh my-vps --watch
```

当前实现会先立即同步一次，然后监听以下文件：

```text
~/.cc-switch/cc-switch.db
~/.cc-switch/settings.json
~/.claude/settings.json
```

检测到变更后会再次同步。按 `Ctrl+C` 停止。

### 4.4 每 5 分钟定时同步

```bash
bash ~/Documents/code/071/sync-ccswitch-to-vps.sh my-vps --cron
```

查看任务：

```bash
crontab -l
```

查看日志：

```bash
tail -f /tmp/ccswitch-sync-my-vps.log
```

当前 cron 安装逻辑只维护一条 CC Switch 同步任务。再次对另一台 VPS 执行 `--cron` 会替换旧任务。

如果需要同时自动同步多台 VPS，应修改 cron 管理逻辑，或者为每台 VPS 手工添加独立的 crontab 行。

## 5. 同步了哪些文件

### 5.1 必需文件

| 本机 | VPS | 说明 |
|---|---|---|
| `~/.cc-switch/cc-switch.db` | 同路径 | 所有套餐的主数据库 |
| `~/.cc-switch/settings.json` | 同路径 | 当前套餐 ID |
| `~/.claude/settings.json` | 同路径 | 当前 Claude Code 配置 |
| `ccswitch-select.sh` | `~/.local/bin/ccswitch-select` | VPS 切换命令 |

### 5.2 可选文件

| 本机 | VPS |
|---|---|
| `~/.cc-switch/skills/` | `~/.cc-switch/skills/` |
| `~/.claude/litellm_config.yaml` | 同路径 |
| `~/.claude/settings.local.json` | 同路径 |

`skills/` 使用 `rsync --delete`。本机删除的 skill 会在下一次同步时从 VPS 删除，因此不要在 VPS 的这个目录里维护仅远端存在的文件。

### 5.3 自动部署的程序

同步脚本会从自身所在目录部署：

| 本机工具包文件 | VPS |
|---|---|
| `ccswitch-select.sh` | `~/.local/bin/ccswitch-select` |
| `claude_proxy.py` | `~/claude_proxy.py` |
| `codex_proxy.py` | `~/codex_proxy.py` |
| `test-ccswitch-providers.py` | `~/.local/bin/test-ccswitch-providers` |

因此应保持四个程序文件位于同一个工具包目录，不要只复制 `sync-ccswitch-to-vps.sh` 单独运行。

### 5.4 不会同步的数据

发布包和同步脚本不会包含或生成本机真实数据库的副本。运行同步时，才会从当前用户目录读取：

```text
~/.cc-switch/cc-switch.db
~/.cc-switch/settings.json
~/.claude/settings.json
```

发布包也不会包含运行时产生的：

```text
~/proxy_config.json
~/claude_proxy.pid
~/claude_proxy.log
~/codex_proxy_config.json
~/codex_proxy.pid
~/codex_proxy.log
```

## 6. 路由和代理怎么处理

### 6.1 为什么部分套餐需要代理

Claude Code 使用 Anthropic Messages API。部分 Grok 或 GPT 套餐只提供 OpenAI Chat API，不能直接处理 `/v1/messages`。

本机 CC Switch 可以通过自己的路由代理转换格式。VPS 没有 CC Switch GUI，因此使用 `~/claude_proxy.py` 代替。

### 6.2 Codex 代理（codex_proxy.py）

Codex 使用 Responses API（`/v1/responses`），与 Claude Code 的 Messages API 完全独立。上游 `tokenskingdom.com` 接受 Responses 格式，但拒绝 Codex 客户端工具集中 `tools[].namespace`、`tools[].strict` 等字段，返回类型不兼容错误。

`codex_proxy.py` 负责：

```text
1. 接收 Codex 发来的标准 Responses 请求
2. 剥离 tools[].namespace、tools[].strict 等上游不支持的字段
3. 将净化后的请求原样转发到真实上游 /v1/responses
4. 流式/非流式响应均直接透传，不做格式转换
```

代理仅监听 `127.0.0.1:18722`，不对外暴露。Claude 代理使用独立的端口 `18721`，两者互不影响。

配置文件由 `ccswitch-select` 自动写入，无需手动编辑：

```text
~/codex_proxy_config.json   (权限 600)
~/codex_proxy.py            (权限 700)
~/codex_proxy.pid
~/codex_proxy.log
```

### 6.3 Claude 代理自动判断逻辑

`ccswitch-select` 读取套餐中的 `ANTHROPIC_MODEL`。

以下前缀默认直连：

```text
claude-
deepseek-
gemini-
gpt-image
```

其他模型默认按需要代理处理，例如 `grok-*`、`gpt-5.*`。

### 6.4 Codex 代理判断逻辑

`ccswitch-select` 读取套餐 TOML 中的 `wire_api` 字段：

```text
wire_api = "responses"  → 启动 codex_proxy.py，将 base_url 指向 127.0.0.1:18722
wire_api 为其他值       → 直连，停止 codex_proxy.py
```

不依赖模型名前缀推断协议。

### 6.5 选择需要代理的 Codex 套餐后发生什么

```text
1. 停止旧 codex_proxy.py 实例（如有）
2. 从套餐提取 base_url、api_key、model
3. 原子写入 ~/codex_proxy_config.json（权限 600）
4. 启动 python3 ~/codex_proxy.py --daemon
5. 轮询 http://127.0.0.1:18722/health 直到就绪（最多 5 秒）
6. 健康检查通过后，将 config.toml 的 base_url 改为 http://127.0.0.1:18722/v1
7. auth.json 的 key 值替换为占位符（代理自己管理真实 key）
8. 仅此时更新 currentProviderCodex
```

健康检查失败时保留原配置，不更新当前套餐。

切换回直连套餐时，停止 codex_proxy.py，写回真实上游 URL。

### 6.6 查看代理状态

Claude 代理：

```bash
cat ~/claude_proxy.pid
tail -n 100 ~/claude_proxy.log
```

Codex 代理：

```bash
cat ~/codex_proxy.pid
tail -n 100 ~/codex_proxy.log
curl -s http://127.0.0.1:18722/health
```

切换 Codex 套餐后，Codex CLI 需要重新启动才能读取新配置：

```bash
# 切换套餐
ccswitch-select codex

# 重启 Codex（退出当前会话后重新启动）
codex
```

## 7. 各应用的写入方式

### 7.1 Claude Code

目标文件：

```text
~/.claude/settings.json
```

脚本保留文件中与套餐无关的顶层设置，主要替换 `env`，并在套餐提供 `model` 时更新顶层 `model`。

### 7.2 Codex

目标文件：

```text
~/.codex/auth.json
~/.codex/config.toml
```

脚本优先读取 `modelCatalog.models[0].model`，用它更新 TOML 顶层的 `model`，同时尝试保留已有的 `[projects.*]`、`[tui.*]` 和 `[trust.*]` 本地配置块。

### 7.3 Gemini

目标文件：

```text
~/.cc-switch/gemini.env
```

首次使用需在 VPS 的 shell 配置中加载：

```bash
grep -q 'gemini.env' ~/.bashrc || \
  echo 'source ~/.cc-switch/gemini.env' >> ~/.bashrc
source ~/.bashrc
```

### 7.4 OpenClaw

目标文件：

```text
~/.openclaw/config.json
```

脚本会更新 `models.providers` 为当前选择的 provider 配置。

## 8. 测试脚本怎么用

`test-ccswitch-providers.py` 支持独立测试 Claude 或 Codex 套餐。同步完成后，它位于 VPS 的 `~/.local/bin`。

```bash
# 只测 Claude 套餐（默认行为，与旧版兼容）
test-ccswitch-providers

# 只测 Codex 套餐（Responses API）
test-ccswitch-providers --codex

# Claude + Codex 全部测试
test-ccswitch-providers --all
```

Claude 套餐测试检查：

```text
套餐是否包含 URL 和 API key
Anthropic 或 OpenAI 请求格式是否可访问
请求模型和响应模型是否大致一致
/model 的 haiku、sonnet、opus、fable 映射
```

Codex 套餐测试检查：

```text
套餐是否包含 base_url、api_key、model 且 wire_api=responses
非流式 Responses 请求是否返回 200
流式 Responses 首行 SSE 格式是否正常
```

注意：

```text
每个套餐都会产生真实 API 请求，可能计费。
默认超时为 15 秒。
Codex 测试仅测 wire_api=responses 的套餐，其他格式自动跳过。
测试结果受上游服务、余额、限流和网络状态影响。
```

## 9. 安全注意事项

以下文件包含或可能包含 API key：

```text
~/.cc-switch/cc-switch.db
~/.cc-switch/settings.json
~/.claude/settings.json
~/.codex/auth.json
~/proxy_config.json
~/codex_proxy_config.json
```

`codex_proxy.py` 不记录 Authorization、API key、完整请求体或工具参数。日志只包含模型名、`stream` 标志、工具数量和 HTTP 状态码。

要求：

```text
不要提交到 Git。
不要粘贴到公开聊天、工单或日志。
只通过 SSH/rsync 等加密通道传输。
VPS 账号和私钥泄露后应立即轮换 API key。
```

同步脚本会把 VPS 上的核心数据库和设置文件权限设为 `600`，目录权限设为 `700`。

检查权限：

```bash
ls -ld ~/.cc-switch ~/.claude
ls -l ~/.cc-switch/cc-switch.db ~/.cc-switch/settings.json ~/.claude/settings.json
```

## 10. 常见故障

### 10.1 `ssh` 或 `rsync` 失败

检查：

```bash
ssh -o BatchMode=yes my-vps "echo OK"
rsync --version
ssh my-vps "rsync --version"
```

常见原因：

```text
SSH 别名不存在
远端用户名错误
密钥权限或路径错误
服务器没有安装 rsync
服务器防火墙未开放 SSH
```

### 10.2 `ccswitch-select: command not found`

```bash
ls -l ~/.local/bin/ccswitch-select
export PATH="$HOME/.local/bin:$PATH"
source ~/.bashrc
```

### 10.3 `数据库不存在`

说明尚未成功同步：

```bash
ls -l ~/.cc-switch/cc-switch.db
```

回到本机重新执行：

```bash
bash ~/Documents/code/071/sync-ccswitch-to-vps.sh my-vps
```

### 10.4 代理套餐切换失败

检查：

```bash
ls -l ~/claude_proxy.py
cat ~/claude_proxy.pid
tail -n 100 ~/claude_proxy.log
```

如果 `claude_proxy.py` 不存在，确认使用的是完整工具包，并从本机重新运行同步脚本。

### 10.5 本机改了套餐，VPS 仍使用旧配置

按顺序执行：

```bash
# 本机重新同步
bash ~/Documents/code/071/sync-ccswitch-to-vps.sh my-vps

# VPS 重新选择套餐
ccswitch-select claude
```

只同步而不重新选择时，数据库已经更新，但当前应用配置可能仍是旧值。

### 10.6 API 返回 401、403 或 429

```text
401：通常是 API key 无效或认证头不匹配。
403：可能是套餐不允许当前 API 格式，需要代理转换。
429：通常是余额、速率限制或并发限制。
```

先确认当前 URL、模型和代理日志，不要把 API key 打印到终端历史或发给他人。

## 11. 开发过程记录

### 阶段 1：确认需求

目标是在本机继续使用 CC Switch GUI 管理套餐，同时让无 GUI 的 Linux VPS 使用相同套餐。

核心约束：

```text
VPS 不能运行 macOS 的 CC Switch 应用。
套餐配置保存在本机 SQLite 数据库中。
配置包含密钥，必须通过 SSH 加密传输。
VPS 需要独立切换，不应依赖本机持续在线。
```

### 阶段 2：定位数据源

确认主数据位于：

```text
~/.cc-switch/cc-switch.db
```

核心表是 `providers`：

```text
id
app_type
name
settings_config
```

`settings_config` 是 JSON，不同 `app_type` 的结构不同。`settings.json` 记录各应用当前选择的 provider ID。

截至 2026-07-22，本机数据库快照包含：

| app_type | 数量 |
|---|---:|
| `claude` | 8 |
| `claude-desktop` | 6 |
| `codex` | 4 |
| `gemini` | 6 |
| `openclaw` | 2 |

这些数字只是当前快照，不应写入自动化逻辑。

### 阶段 3：设计同步脚本

`sync-ccswitch-to-vps.sh` 使用 SSH 和 rsync：

```text
SSH config 管理主机、用户和密钥。
rsync 传输数据库、设置和 skills。
同步时自动部署 ccswitch-select。
支持一次性、watch 和 cron 三种模式。
```

这样避免在脚本中硬编码 IP、用户名和私钥。

### 阶段 4：设计 VPS 切换脚本

采用 Bash 外壳加内嵌 Python：

```text
Bash 负责入口、参数和依赖检查。
Python 标准库 sqlite3 负责查询数据库。
Python json 负责解析和写入应用配置。
```

没有引入额外 Python 包，方便在新 VPS 上部署。

### 阶段 5：解决交互输入问题

内嵌 Python 通过 heredoc 接收代码，标准输入已经被 heredoc 占用，直接使用 `input()` 会读到 EOF。

最终实现：

```text
有第二个参数时直接使用套餐编号。
交互模式优先从 /dev/tty 读取。
无法读取 /dev/tty 时再回退到 stdin。
```

### 阶段 6：处理认证和连通性测试

测试中发现：

```text
ANTHROPIC_AUTH_TOKEN 通常对应 Authorization: Bearer。
ANTHROPIC_API_KEY 通常对应 x-api-key。
部分网关会拦截 Python urllib 默认 User-Agent。
```

测试脚本因此根据环境变量选择认证头，并设置 `User-Agent: claude-cli/1.0`。

### 阶段 7：修复 Codex 模型不同步

CC Switch GUI 修改 Codex 模型时，实际模型可能只更新到：

```text
modelCatalog.models[0].model
```

而 `settings_config.config` 中的 TOML 文本仍保留旧模型。

`apply_codex` 因此优先使用 `modelCatalog`，再替换 TOML 顶层 `model`。

### 阶段 8：处理 Grok/GPT 路由

部分套餐只支持 OpenAI API，Claude Code 需要 Anthropic Messages API。

最终方案：

```text
根据模型名前缀判断是否需要代理。
代理套餐自动生成 proxy_config.json。
VPS 启动 claude_proxy.py 监听 127.0.0.1:18721。
切换回直连套餐时停止代理。
```

这对应本机 CC Switch 的路由功能，但不要求 VPS 运行 CC Switch GUI。

### 阶段 9：2026-07-22 文档化和部署修正

本次整理以实际代码为准，完成以下修正：

```text
首次同步自动创建 VPS 的 ~/.local/bin。
同步后收紧数据库和设置文件权限。
--cron 保留用户指定的 VPS 名称，并使用按主机区分的日志文件。
--watch 启动时先立即同步一次。
同步脚本自动部署 claude_proxy.py 和测试工具。
将 text.text 明确标记为历史记录，不作为可执行说明。
```

## 12. 复用和维护清单

给另一位开发者或 AI 接手时，按以下顺序阅读：

```text
1. 先读本文件，了解架构和操作边界。
2. 读 sync-ccswitch-to-vps.sh，确认同步范围和目标路径。
3. 读 ccswitch-select.sh，确认各 app_type 的写入逻辑。
4. 读 claude_proxy.py，确认 Anthropic 与 OpenAI Chat 的转换边界。
5. 只在需要真实连通性测试时运行 test-ccswitch-providers.py。
6. 不要把 text.text 当作当前实现的事实来源。
```

修改脚本后至少执行：

```bash
cd ~/Documents/code/071
bash -n sync-ccswitch-to-vps.sh
bash -n ccswitch-select.sh
python3 -m py_compile claude_proxy.py
python3 -m py_compile test-ccswitch-providers.py
```

发布到测试 VPS 后验证：

```bash
bash sync-ccswitch-to-vps.sh my-vps
ssh my-vps "command -v ccswitch-select"
ssh my-vps "ccswitch-select claude"
```

测试时不要在共享日志中输出数据库内容、完整环境变量或 API key。
