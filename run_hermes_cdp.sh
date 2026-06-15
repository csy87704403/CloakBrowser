#!/bin/bash
# Start a CloakBrowser CDP endpoint for Hermes/Playwright agents.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_DIR="$SCRIPT_DIR/output"

DISPLAY_NUM="${DISPLAY:-:99}"
XVFB_WHD="${XVFB_WHD:-1280x800x24}"
CDP_PORT="${CDP_PORT:-9222}"
PROFILE_DIR="${PROFILE_DIR:-$OUTPUT_DIR/hermes-profile}"
IDLE_TIMEOUT="${IDLE_TIMEOUT:-0}"
FINGERPRINT_SEED="${FINGERPRINT_SEED:-424242}"
TIMEZONE_ID="${TIMEZONE_ID:-America/New_York}"
LOCALE_ID="${LOCALE_ID:-en-US}"

mkdir -p "$OUTPUT_DIR" "$PROFILE_DIR"

ensure_serve_deps() {
    if python3 -c "import aiohttp, websockets" >/dev/null 2>&1; then
        return
    fi

    echo "[INFO] Installing CloakBrowser CDP server dependencies..."
    python3 -m pip install "aiohttp>=3.9" "websockets>=12.0"
}

can_connect_x_socket() {
    local socket_path="/tmp/.X11-unix/X${DISPLAY_NUM#:}"
    python3 - "$socket_path" <<'PY'
import socket
import sys

path = sys.argv[1]
client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
client.settimeout(0.5)
try:
    client.connect(path)
except OSError:
    sys.exit(1)
finally:
    client.close()
PY
}

start_xvfb_if_needed() {
    if can_connect_x_socket; then
        echo "[INFO] Reusing existing Xvfb DISPLAY=$DISPLAY_NUM"
        return
    fi

    echo "[INFO] Starting Xvfb DISPLAY=$DISPLAY_NUM ($XVFB_WHD)"
    Xvfb "$DISPLAY_NUM" -screen 0 "$XVFB_WHD" -ac -nolisten tcp \
        >"$OUTPUT_DIR/hermes-xvfb.log" 2>&1 &
    echo "$!" > "$OUTPUT_DIR/hermes-xvfb.pid"
    sleep 1

    if ! can_connect_x_socket; then
        echo "[ERROR] Xvfb did not become ready. Log: $OUTPUT_DIR/hermes-xvfb.log" >&2
        tail -n 40 "$OUTPUT_DIR/hermes-xvfb.log" >&2 || true
        exit 1
    fi
}

ensure_serve_deps
start_xvfb_if_needed

export DISPLAY="$DISPLAY_NUM"
export PYTHONPATH="$SCRIPT_DIR:${PYTHONPATH:-}"
export CLOAKBROWSER_AUTO_UPDATE="${CLOAKBROWSER_AUTO_UPDATE:-false}"

echo "[INFO] Starting CloakBrowser CDP endpoint on http://127.0.0.1:$CDP_PORT"
echo "[INFO] Hermes should connect with: playwright.chromium.connect_over_cdp(\"http://127.0.0.1:$CDP_PORT?fingerprint=$FINGERPRINT_SEED\")"

exec python3 "$SCRIPT_DIR/bin/cloakserve" \
    --port="$CDP_PORT" \
    --headless=false \
    --data-dir="$PROFILE_DIR" \
    --idle-timeout="$IDLE_TIMEOUT" \
    --fingerprint="$FINGERPRINT_SEED" \
    --fingerprint-timezone="$TIMEZONE_ID" \
    --fingerprint-locale="$LOCALE_ID" \
    --disable-dev-shm-usage \
    --no-zygote \
    --window-size=1280,800 \
    --fingerprint-screen-width=1280 \
    --fingerprint-screen-height=800 \
    --blink-settings=imagesEnabled=false \
    --js-flags=--max-old-space-size=512
