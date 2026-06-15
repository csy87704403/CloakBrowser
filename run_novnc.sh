#!/bin/bash
# Start public noVNC for manual CloakBrowser testing on a VPS.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_DIR="$SCRIPT_DIR/output"

DISPLAY_NUM="${DISPLAY:-:99}"
XVFB_WHD="${XVFB_WHD:-1280x800x24}"
VNC_PORT="${VNC_PORT:-5900}"
NOVNC_PORT="${NOVNC_PORT:-6080}"
NOVNC_LISTEN="${NOVNC_LISTEN:-0.0.0.0}"
URL="${1:-https://example.com}"
PROFILE_DIR="${PROFILE_DIR:-$OUTPUT_DIR/novnc-profile}"
FINGERPRINT_SEED="${FINGERPRINT_SEED:-424242}"
TIMEZONE_ID="${TIMEZONE_ID:-America/New_York}"
LOCALE_ID="${LOCALE_ID:-en-US}"
VNC_PASSWORD="${VNC_PASSWORD:-}"
VNC_PASS_FILE="$OUTPUT_DIR/novnc-vnc.pass"

XVFB_PID=""
X11VNC_PID=""
WEBSOCKIFY_PID=""

mkdir -p "$OUTPUT_DIR" "$PROFILE_DIR"

require_command() {
    command -v "$1" >/dev/null 2>&1
}

install_novnc_deps() {
    local missing=()

    require_command Xvfb || missing+=("xvfb")
    require_command x11vnc || missing+=("x11vnc")
    if ! require_command websockify && ! require_command novnc_proxy; then
        missing+=("novnc" "websockify")
    fi

    if [ ${#missing[@]} -eq 0 ]; then
        return
    fi

    echo "[WARN] Missing packages: ${missing[*]}"
    echo "[INFO] Installing noVNC dependencies..."
    if [ "$(id -u)" -eq 0 ]; then
        apt-get update
        apt-get install -y "${missing[@]}"
    else
        sudo apt-get update
        sudo apt-get install -y "${missing[@]}"
    fi
}

ensure_vnc_password() {
    if [ -z "$VNC_PASSWORD" ]; then
        VNC_PASSWORD="$(python3 - <<'PY'
import secrets
import string

alphabet = string.ascii_letters + string.digits
print("".join(secrets.choice(alphabet) for _ in range(12)))
PY
)"
    fi

    x11vnc -storepasswd "$VNC_PASSWORD" "$VNC_PASS_FILE" >/dev/null
    chmod 600 "$VNC_PASS_FILE"
}

detect_public_ip() {
    local ip=""
    if require_command curl; then
        ip="$(curl -fsS --max-time 3 https://api.ipify.org 2>/dev/null || true)"
    fi
    if [ -z "$ip" ]; then
        ip="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
    fi
    echo "${ip:-YOUR_VPS_PUBLIC_IP}"
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
        >"$OUTPUT_DIR/novnc-xvfb.log" 2>&1 &
    XVFB_PID="$!"
    echo "$XVFB_PID" > "$OUTPUT_DIR/novnc-xvfb.pid"
    sleep 1

    if ! can_connect_x_socket; then
        echo "[ERROR] Xvfb did not become ready. Log: $OUTPUT_DIR/novnc-xvfb.log" >&2
        tail -n 40 "$OUTPUT_DIR/novnc-xvfb.log" >&2 || true
        exit 1
    fi
}

start_x11vnc() {
    echo "[INFO] Starting x11vnc on 127.0.0.1:$VNC_PORT"
    x11vnc \
        -display "$DISPLAY_NUM" \
        -localhost \
        -rfbauth "$VNC_PASS_FILE" \
        -forever \
        -shared \
        -rfbport "$VNC_PORT" \
        -o "$OUTPUT_DIR/x11vnc.log" \
        >/dev/null 2>&1 &
    X11VNC_PID="$!"
    echo "$X11VNC_PID" > "$OUTPUT_DIR/x11vnc.pid"
    sleep 1
}

start_novnc() {
    echo "[INFO] Starting public noVNC on http://$NOVNC_LISTEN:$NOVNC_PORT/vnc.html"

    if require_command websockify; then
        websockify \
            --web=/usr/share/novnc/ \
            "$NOVNC_LISTEN:$NOVNC_PORT" \
            "127.0.0.1:$VNC_PORT" \
            >"$OUTPUT_DIR/novnc.log" 2>&1 &
    else
        novnc_proxy \
            --listen "$NOVNC_LISTEN:$NOVNC_PORT" \
            --vnc "127.0.0.1:$VNC_PORT" \
            >"$OUTPUT_DIR/novnc.log" 2>&1 &
    fi

    WEBSOCKIFY_PID="$!"
    echo "$WEBSOCKIFY_PID" > "$OUTPUT_DIR/novnc.pid"
    sleep 1
}

cleanup() {
    echo
    echo "[INFO] Cleaning up noVNC session..."
    [ -n "$WEBSOCKIFY_PID" ] && kill "$WEBSOCKIFY_PID" >/dev/null 2>&1 || true
    [ -n "$X11VNC_PID" ] && kill "$X11VNC_PID" >/dev/null 2>&1 || true
    [ -n "$XVFB_PID" ] && kill "$XVFB_PID" >/dev/null 2>&1 || true
}

trap cleanup EXIT INT TERM

install_novnc_deps
ensure_vnc_password
start_xvfb_if_needed
start_x11vnc
start_novnc

export DISPLAY="$DISPLAY_NUM"
export PYTHONPATH="$SCRIPT_DIR:${PYTHONPATH:-}"
export CLOAKBROWSER_AUTO_UPDATE="${CLOAKBROWSER_AUTO_UPDATE:-false}"

PUBLIC_IP="$(detect_public_ip)"
PUBLIC_URL="http://${PUBLIC_IP}:${NOVNC_PORT}/vnc.html?autoconnect=true&resize=scale"

echo "[INFO] noVNC is ready."
echo "[INFO] Public URL: $PUBLIC_URL"
echo "[INFO] VNC password: $VNC_PASSWORD"
echo "[WARN] Keep port $NOVNC_PORT open only while testing. Stop this script with Ctrl+C when done."
echo "[INFO] Launching CloakBrowser at: $URL"

python3 - "$URL" "$PROFILE_DIR" "$FINGERPRINT_SEED" "$TIMEZONE_ID" "$LOCALE_ID" <<'PY'
import sys
import time

from cloakbrowser import launch_persistent_context

url, profile_dir, seed, timezone_id, locale_id = sys.argv[1:]

ctx = launch_persistent_context(
    profile_dir,
    headless=False,
    timezone=timezone_id,
    locale=locale_id,
    humanize=True,
    viewport=None,
    args=[
        f"--fingerprint={seed}",
        "--disable-dev-shm-usage",
        "--no-zygote",
        "--window-size=1280,800",
        "--fingerprint-screen-width=1280",
        "--fingerprint-screen-height=800",
        "--js-flags=--max-old-space-size=512",
    ],
)

page = ctx.pages[0] if ctx.pages else ctx.new_page()
try:
    page.goto(url, wait_until="commit", timeout=60000)
except Exception as exc:
    print(f"[WARN] Initial navigation failed, keeping browser open for manual use: {exc}", flush=True)

print("[INFO] Browser is open. Press Ctrl+C here to stop noVNC and close CloakBrowser.", flush=True)
try:
    while True:
        time.sleep(3600)
except KeyboardInterrupt:
    pass
finally:
    ctx.close()
PY
