#!/bin/bash

DISPLAY_NUM="${DISPLAY:-:99}"
XVFB_SCREEN="${XVFB_SCREEN:-0}"
XVFB_WHD="${XVFB_WHD:-1920x1080x24}"
DISPLAY_LOCK="/tmp/.X${DISPLAY_NUM#:}-lock"
DISPLAY_SOCKET="/tmp/.X11-unix/X${DISPLAY_NUM#:}"

# Clean up any stale Xvfb lock left behind by a previous container instance.
rm -f "$DISPLAY_LOCK" "$DISPLAY_SOCKET"

# Start Xvfb for headed mode, then run the requested command.
Xvfb "$DISPLAY_NUM" -screen "$XVFB_SCREEN" "$XVFB_WHD" -nolisten tcp &
sleep 1
exec "$@"
