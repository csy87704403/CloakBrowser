#!/bin/bash
# CloakBrowser Linux VPS one-shot launcher

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; }

install_runtime_python_deps() {
    info "Installing Python runtime dependencies..."
    python3 -m pip install \
        "playwright>=1.40" \
        "httpx>=0.24" \
        "geoip2>=4.0" \
        "socksio>=1.0"
}

check_system_deps() {
    info "Checking system dependencies..."

    local missing=()

    if ! command -v Xvfb &>/dev/null; then
        missing+=("xvfb")
    fi

    if ! dpkg -l fonts-liberation &>/dev/null 2>&1; then
        missing+=("fonts-liberation")
    fi

    if ! dpkg -l fonts-noto-color-emoji &>/dev/null 2>&1; then
        missing+=("fonts-noto-color-emoji")
    fi

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
        warn "Missing system packages:"
        printf '  - %s\n' "${missing[@]}"
        echo ""
        read -p "Install them now? (y/N) " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            sudo apt-get update
            sudo apt-get install -y "${missing[@]}" ttf-mscorefonts-installer 2>/dev/null || true
            sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -q ttf-mscorefonts-installer 2>/dev/null || true
            sudo fc-cache -f -v &>/dev/null
            info "System dependencies installed"
        else
            error "Please install the missing packages and try again"
            exit 1
        fi
    else
        info "System dependencies are ready"
    fi
}

check_python_deps() {
    info "Checking Python dependencies..."

    if ! python3 -c "import playwright" &>/dev/null; then
        warn "playwright is missing, installing..."
        python3 -m pip install "playwright>=1.40"
        playwright install chromium 2>/dev/null || true
    fi

    if ! python3 -c "import httpx" &>/dev/null; then
        warn "httpx is missing, installing runtime dependencies..."
        install_runtime_python_deps
    fi

    if ! python3 -c "from cloakbrowser import launch" &>/dev/null; then
        warn "cloakbrowser is not importable, trying editable install..."
        cd "$SCRIPT_DIR"
        if ! python3 -m pip install -e ".[geoip]"; then
            warn "Editable install failed, falling back to source mode plus runtime deps"
            install_runtime_python_deps
        fi
    fi

    if ! PYTHONPATH="$SCRIPT_DIR:${PYTHONPATH:-}" python3 -c "from cloakbrowser import launch" &>/dev/null; then
        warn "Source import still failed, retrying runtime dependency install..."
        install_runtime_python_deps
    fi

    if ! PYTHONPATH="$SCRIPT_DIR:${PYTHONPATH:-}" python3 -c "from cloakbrowser import launch" &>/dev/null; then
        error "cloakbrowser still cannot be imported after dependency install"
        exit 1
    fi

    info "Python dependencies are ready"
}

check_memory() {
    info "Checking memory..."

    local mem_available
    mem_available=$(grep MemAvailable /proc/meminfo | awk '{print $2}')
    local mem_available_mb=$((mem_available / 1024))

    local swap_total
    swap_total=$(grep SwapTotal /proc/meminfo | awk '{print $2}')
    local swap_total_mb=$((swap_total / 1024))

    info "Available memory: ${mem_available_mb}MB | Swap: ${swap_total_mb}MB"

    if [ "$mem_available_mb" -lt 500 ] && [ "$swap_total_mb" -lt 500 ]; then
        warn "Both memory and swap are low. Recommended: at least 1.5GB swap."
        echo ""
        echo "  Quick swap setup:"
        echo "    sudo fallocate -l 2G /swapfile"
        echo "    sudo chmod 600 /swapfile"
        echo "    sudo mkswap /swapfile"
        echo "    sudo swapon /swapfile"
        echo "    echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab"
        echo ""
        read -p "Continue anyway? (y/N) " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            exit 1
        fi
    elif [ "$mem_available_mb" -lt 500 ]; then
        warn "Available memory is low (${mem_available_mb}MB). The browser will rely on swap and may be slow."
    fi
}

main() {
    echo "=========================================="
    echo "  CloakBrowser Linux VPS Low Memory Launcher"
    echo "=========================================="
    echo ""

    check_memory
    check_system_deps
    check_python_deps

    export PYTHONPATH="$SCRIPT_DIR:${PYTHONPATH:-}"

    info "Starting low_memory_launcher.py..."
    echo ""

    python3 "$SCRIPT_DIR/low_memory_launcher.py" "$@"
}

main "$@"
