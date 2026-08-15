#!/bin/bash
# Boot-time oneshot: push SetRgbDirect to wireless fans with 6-second spacing
# to avoid saturating the 2.4GHz RF channel (each transmission takes ~5s).
# Runs once after the daemon starts. The daemon's built-in periodic refresh
# handles maintenance after this.
set -e

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
. "$SCRIPT_DIR/lianli-capabilities.sh"

SOCKET="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/lianli-daemon.sock"
PROFILE_FILE="${HOME}/.config/lianli/current-profile"
PROFILE_DIR="${HOME}/.config/lianli/profiles"

# Wait up to 30s for daemon socket
for i in $(seq 1 30); do
  [ -S "$SOCKET" ] && break
  sleep 1
done
[ -S "$SOCKET" ] || exit 1

[ -f "$PROFILE_FILE" ] || exit 0
PROFILE_NAME=$(cat "$PROFILE_FILE")
PROFILE_JSON="${PROFILE_DIR}/${PROFILE_NAME}.json"
[ -f "$PROFILE_JSON" ] || exit 0

WIRELESS=$(python3 -c "
import json
p = json.load(open('$PROFILE_JSON'))
inner = p['wired']['inner']
outer = p['wired']['outer']
colors = [inner] * $WIRELESS_INNER + [outer] * $WIRELESS_OUTER
print(json.dumps(colors))
")

send_direct() {
  local dev=$1 zone=$2 colors=$3
  local payload
  payload=$(python3 -c "
import json
cmd = {'method': 'SetRgbDirect', 'params': {'device_id': '$dev', 'zone': $zone, 'colors': $colors}}
print(json.dumps(cmd, separators=(',',':')))
")
  echo "$payload" | socat - UNIX-CONNECT:"$SOCKET" >/dev/null 2>&1
}

# Two full passes per device, zones spaced 6s apart to fit within the
# 5-second RF transmission window per SetRgbDirect.
for pass in 1 2; do
  for dev in $WIRELESS_DEVICES; do
    for zone in $(seq 0 $((WIRELESS_ZONES - 1))); do
      send_direct "$dev" "$zone" "$WIRELESS"
      sleep 6
    done
  done
done
