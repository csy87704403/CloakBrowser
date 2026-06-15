#!/bin/bash
# CloakBrowser Linux VPS 一键启动脚本
#
# 功能：
#   - 检查并安装依赖（Xvfb、字体、Python 包）
#   - 检查 swap 空间，不足时提示添加
#   - 设置 PYTHONPATH 从源码运行
#   - 启动 low_memory_launcher.py
#
# 用法：
#   chmod +x run_vps.sh
#   ./run_vps.sh --url https://example.com
#   ./run_vps.sh --proxy http://user:pass@proxy:8080 --geoip --url https://example.com
#   ./run_vps.sh --verify --url https://example.com
#
# 环境要求：
#   - Linux (Ubuntu/Debian 推荐)
#   - Python 3.11+
#   - 至少 400MB 空闲内存 + 1.5GB swap

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; }

# ---------------------------------------------------------------------------
# 1. 系统依赖检查
# ---------------------------------------------------------------------------
check_system_deps() {
    info "检查系统依赖..."

    local missing=()

    # Xvfb
    if ! command -v Xvfb &>/dev/null; then
        missing+=("xvfb")
    fi

    # 字体（Windows 指纹一致性需要）
    if ! dpkg -l fonts-liberation &>/dev/null 2>&1; then
        missing+=("fonts-liberation")
    fi

    if ! dpkg -l fonts-noto-color-emoji &>/dev/null 2>&1; then
        missing+=("fonts-noto-color-emoji")
    fi

    # Chromium 系统依赖
    local chromium_deps=(
        libnss3 libnspr4 libatk1.0-0 libatk-bridge2.0-0 libcups2
        libdbus-1-3 libdrm2 libxkbcommon0 libatspi2.0-0 libxcomposite1
        libxdamage1 libxfixes3 libxrandr2 libgbm1 libpango-1.0-0
        libcairo2 libasound2 libx11-xcb1 libfontconfig1
    )

    for dep in "${chromium_deps[@]}"; do
        if ! dpkg -l "$dep" &>/dev/null 2>&1; then
            missing+=("$dep")
        fi
    done

    if [ ${#missing[@]} -gt 0 ]; then
        warn "缺少以下依赖包:"
        printf '  - %s\n' "${missing[@]}"
        echo ""
        read -p "是否自动安装？(y/N) " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            sudo apt-get update
            sudo apt-get install -y "${missing[@]}" ttf-mscorefonts-installer 2>/dev/null || true
            # ttf-mscorefonts-installer 可能因 EULA 弹窗失败，尝试非交互安装
            sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -q ttf-mscorefonts-installer 2>/dev/null || true
            sudo fc-cache -f -v &>/dev/null
            info "依赖安装完成"
        else
            error "请手动安装后重试"
            exit 1
        fi
    else
        info "系统依赖已满足"
    fi
}

# ---------------------------------------------------------------------------
# 2. Python 依赖检查
# ---------------------------------------------------------------------------
check_python_deps() {
    info "检查 Python 依赖..."

    if ! python3 -c "import playwright" &>/dev/null; then
        warn "playwright 未安装，正在安装..."
        pip install playwright
        playwright install chromium 2>/dev/null || true  # CloakBrowser 用自己的二进制，这里只是装依赖
    fi

    if ! python3 -c "from cloakbrowser import launch" &>/dev/null; then
        warn "cloakbrowser 模块不可用，尝试安装依赖..."
        cd "$SCRIPT_DIR"
        pip install -e ".[geoip]" 2>/dev/null || {
            warn "pip install -e 失败，将使用 PYTHONPATH 从源码运行"
        }
    fi

    info "Python 依赖已满足"
}

# ---------------------------------------------------------------------------
# 3. 内存 & Swap 检查
# ---------------------------------------------------------------------------
check_memory() {
    info "检查内存状况..."

    local mem_available
    mem_available=$(grep MemAvailable /proc/meminfo | awk '{print $2}')
    mem_available_mb=$((mem_available / 1024))

    local swap_total
    swap_total=$(grep SwapTotal /proc/meminfo | awk '{print $2}')
    swap_total_mb=$((swap_total / 1024))

    info "可用内存: ${mem_available_mb}MB | Swap: ${swap_total_mb}MB"

    if [ "$mem_available_mb" -lt 500 ] && [ "$swap_total_mb" -lt 500 ]; then
        warn "内存和 Swap 都不足！建议添加至少 1.5GB swap"
        echo ""
        echo "  快速添加 swap 的命令:"
        echo "    sudo fallocate -l 2G /swapfile"
        echo "    sudo chmod 600 /swapfile"
        echo "    sudo mkswap /swapfile"
        echo "    sudo swapon /swapfile"
        echo "    echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab"
        echo ""
        read -p "是否继续运行？(y/N) " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            exit 1
        fi
    elif [ "$mem_available_mb" -lt 500 ]; then
        warn "可用内存较低 (${mem_available_mb}MB)，将依赖 swap，速度可能较慢"
    fi
}

# ---------------------------------------------------------------------------
# 4. 主流程
# ---------------------------------------------------------------------------
main() {
    echo "=========================================="
    echo "  CloakBrowser Linux VPS 低内存启动器"
    echo "=========================================="
    echo ""

    check_memory
    check_system_deps
    check_python_deps

    # 设置 PYTHONPATH 以从源码导入
    export PYTHONPATH="$SCRIPT_DIR:${PYTHONPATH:-}"

    info "启动 low_memory_launcher.py..."
    echo ""

    python3 "$SCRIPT_DIR/low_memory_launcher.py" "$@"
}

main "$@"
