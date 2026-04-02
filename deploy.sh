#!/bin/bash
set -e

# ============================================================
# kiro-gateway 本地代理一键部署
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SETTINGS_FILE="$HOME/.claude/settings.json"
BACKUP_KIRO="$HOME/.claude/kiro.json"
ENV_FILE="$SCRIPT_DIR/.env"
VENV_DIR="$SCRIPT_DIR/.venv"
TARGET_CC_VERSION="2.1.71"

# 彩色日志
log_info()    { printf "\033[34m[INFO]\033[0m  %s\n" "$1"; }
log_success() { printf "\033[32m[OK]\033[0m    %s\n" "$1"; }
log_warn()    { printf "\033[33m[WARN]\033[0m  %s\n" "$1"; }
log_error()   { printf "\033[31m[ERROR]\033[0m %s\n" "$1"; }

# 用 python3 读取 settings.json 中的字段
read_settings_field() {
    python3 -c "
import json, sys
with open('$SETTINGS_FILE') as f:
    data = json.load(f)
print(data.get('env', {}).get('$1', ''))
"
}

# 用 python3 修改 settings.json 中 env 的两个字段，保留其他所有内容
update_settings_env() {
    local token="$1"
    local base_url="$2"
    python3 -c "
import json
with open('$SETTINGS_FILE') as f:
    data = json.load(f)
data.setdefault('env', {})
data['env']['ANTHROPIC_AUTH_TOKEN'] = '$token'
data['env']['ANTHROPIC_BASE_URL'] = '$base_url'
with open('$SETTINGS_FILE', 'w') as f:
    json.dump(data, f, indent=2)
    f.write('\n')
"
}

# ============================================================
# 欢迎
# ============================================================
echo ""
echo "  ╔══════════════════════════════════════╗"
echo "  ║     kiro-gateway 一键部署脚本        ║"
echo "  ╚══════════════════════════════════════╝"
echo ""

# ============================================================
# 1. 检测 Claude Code 版本
# ============================================================
if ! command -v claude &>/dev/null; then
    log_error "未检测到 Claude Code，请先安装: npm install -g @anthropic-ai/claude-code"
    exit 1
fi

CC_VERSION=$(claude --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || echo "unknown")
if [ "$CC_VERSION" = "$TARGET_CC_VERSION" ]; then
    log_success "Claude Code 版本: $CC_VERSION"
elif [ "$CC_VERSION" = "unknown" ]; then
    log_warn "无法获取 Claude Code 版本，继续执行..."
else
    log_warn "Claude Code 版本 $CC_VERSION != $TARGET_CC_VERSION，正在安装指定版本..."
    npm install -g "@anthropic-ai/claude-code@$TARGET_CC_VERSION"
    log_success "Claude Code 已更新到 $TARGET_CC_VERSION"
fi

# ============================================================
# 1.5 检测 Python 版本
# ============================================================
if ! command -v python3 &>/dev/null; then
    log_error "未检测到 python3，请先安装 Python 3"
    exit 1
fi

PY_VERSION=$(python3 -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')")
PY_MAJOR=$(python3 -c "import sys; print(sys.version_info.major)")
PY_MINOR=$(python3 -c "import sys; print(sys.version_info.minor)")

if [ "$PY_MAJOR" -lt 3 ] || { [ "$PY_MAJOR" -eq 3 ] && [ "$PY_MINOR" -lt 10 ]; }; then
    log_error "Python 版本过低: $(python3 --version)，需要 >= 3.10"
    exit 1
fi
log_success "Python 版本: $(python3 --version 2>&1 | head -1)"

# ============================================================
# 2. 配置 settings.json
# ============================================================
CURRENT_URL=$(read_settings_field "ANTHROPIC_BASE_URL")

if echo "$CURRENT_URL" | grep -qiE "localhost|127\.0\.0\.1"; then
    log_info "已经是本地代理模式，跳过配置修改"
else
    update_settings_env "my-super-secret-password-123" "http://127.0.0.1:8000"
    log_success "settings.json 已切换到本地代理模式"
fi

# 保存一份 kiro.json
cp "$SETTINGS_FILE" "$BACKUP_KIRO"
log_success "已保存 kiro 配置到 $BACKUP_KIRO"

# 3. Python 虚拟环境
if [ ! -d "$VENV_DIR" ]; then
    log_info "创建虚拟环境..."
    python3 -m venv "$VENV_DIR"
    log_success "虚拟环境已创建"
else
    log_info ".venv 已存在，跳过创建"
fi

source "$VENV_DIR/bin/activate"
log_info "安装 Python 依赖..."
pip install -q -r "$SCRIPT_DIR/requirements.txt"
log_success "Python 依赖就绪"

# 4. kiro-cli
if ! command -v kiro-cli &>/dev/null; then
    log_error "未检测到 kiro-cli"
    echo ""
    echo "  请先安装 kiro-cli:"
    echo "    curl -fsSL https://cli.kiro.dev/install | bash"
    echo ""
    echo "  安装后重新执行本脚本"
    exit 1
fi
log_success "kiro-cli 已安装"

# 检查 kiro-cli 登录状态
if ! kiro-cli whoami &>/dev/null; then
    log_warn "kiro-cli 未登录，请完成登录:"
    kiro-cli login
fi
log_success "kiro-cli 已登录"

# 5. .env 配置
if [ ! -f "$ENV_FILE" ]; then
    # 获取 kiro-cli 数据库路径
    KIRO_DB=$(kiro-cli db-path 2>/dev/null || echo "$HOME/.kiro/credentials.db")
    cat > "$ENV_FILE" <<ENVEOF
KIRO_CLI_DB_FILE=$KIRO_DB
PROXY_API_KEY=my-super-secret-password-123
ENVEOF
    log_success ".env 已创建"
else
    log_info ".env 已存在，跳过创建"
fi

# 6. 启动服务
echo ""
PORT=8000
PID_ON_PORT=$(lsof -ti :"$PORT" 2>/dev/null || true)
if [ -n "$PID_ON_PORT" ]; then
    log_warn "端口 $PORT 已被占用 (PID: $PID_ON_PORT)"
    read -rp "  是否终止占用进程? [y/N]: " KILL_CHOICE
    if [[ "$KILL_CHOICE" =~ ^[Yy]$ ]]; then
        kill "$PID_ON_PORT" 2>/dev/null || true
        sleep 1
        log_success "已终止进程 $PID_ON_PORT"
    else
        log_error "请手动停止占用端口 $PORT 的进程后重试"
        exit 1
    fi
fi

log_info "启动 kiro-gateway 服务..."
echo ""
echo "  ┌─────────────────────────────────────────────┐"
echo "  │  服务启动后，请在新终端运行:                │"
echo "  │  claude --model claude-opus-4.6              │"
echo "  │                                             │"
echo "  │  按 Ctrl+C 停止服务                         │"
echo "  └─────────────────────────────────────────────┘"
echo ""

python3 "$SCRIPT_DIR/main.py"
