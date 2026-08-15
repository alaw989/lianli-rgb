#!/bin/bash
# Gentle RGB keepalive for wireless Lian Li fans.
# The daemon's RGB loop (30fps) handles the main color push with proper
# RF scheduling. This script is a backup that fires every 60s to catch
# any missed transmissions after daemon restarts / fan speed changes.
# Each SetRgbDirect takes 5 seconds to transmit over RF (compressed
# packets), so commands for different zones are spaced 6s apart to
# avoid saturating the 2.4GHz channel.
set -e

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
. "$SCRIPT_DIR/lianli-capabilities.sh"

SOCKET="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/lianli-daemon.sock"
PROFILE_FILE="${HOME}/.config/lianli/current-profile"
PROFILE_DIR="${HOME}/.config/lianli/profiles"

[ -S "$SOCKET" ] || exit 0
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

# One gentle pass per device, zones spaced 6s apart to stay within the
# 5-second RF transmission window per SetRgbDirect.
for dev in $WIRELESS_DEVICES; do
  for zone in $(seq 0 $((WIRELESS_ZONES - 1))); do
    send_direct "$dev" "$zone" "$WIRELESS"
    sleep 6
  done
done

# Motherboard JRAINBOW1 via OpenRGB SDK
python3 -c "
import json
from openrgb import OpenRGBClient
from openrgb.utils import RGBColor

p = json.load(open('$PROFILE_JSON'))
mb = p.get('motherboard', {})
mb_color = mb.get('color', p.get('wired', {}).get('outer', [255,200,50]))

c = OpenRGBClient('127.0.0.1', 6742, name='watchdog')
for dev in c.devices:
    if dev.type.name == 'MOTHERBOARD' and 'MSI' in dev.name:
        start = $MB_LED_OFFSET
        count = min($MB_LED_COUNT, len(dev.leds) - start)
        colors = [RGBColor(0, 0, 0)] * len(dev.leds)
        colors[start:start + count] = [RGBColor(*mb_color)] * count
        dev.set_mode('Direct')
        dev.set_colors(colors)
        break
c.disconnect()
" 2>/dev/null
