#!/bin/bash
# Apply a named RGB color profile to all Lian Li fans.
# Usage: lianli-profile.sh <profile-name>
# Profiles stored in ~/.config/lianli/profiles/<name>.json

set -e

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
. "$SCRIPT_DIR/lianli-capabilities.sh"

PROFILE_NAME="${1:?Usage: lianli-profile.sh <profile-name>}"
PROFILE_DIR="${HOME}/.config/lianli/profiles"
PROFILE_FILE="${PROFILE_DIR}/${PROFILE_NAME}.json"
SOCKET="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/lianli-daemon.sock"

if [ ! -f "$PROFILE_FILE" ]; then
  echo "ERROR: Profile not found: ${PROFILE_FILE}" >&2
  echo "Available profiles:" >&2
  ls -1 "${PROFILE_DIR}"/*.json 2>/dev/null | xargs -I{} basename {} .json >&2
  exit 1
fi

if [ ! -S "$SOCKET" ]; then
  echo "ERROR: lianli-daemon not running (socket not found)" >&2
  exit 1
fi

PROFILE=$(cat "$PROFILE_FILE")
echo "Applying profile: $(echo "$PROFILE" | python3 -c 'import json,sys; print(json.load(sys.stdin)["name"])')"

# --- Extract colors ---
INNER=$(echo "$PROFILE" | python3 -c "import json,sys; p=json.load(sys.stdin); print(json.dumps(p['wired']['inner']))")
OUTER=$(echo "$PROFILE" | python3 -c "import json,sys; p=json.load(sys.stdin); print(json.dumps(p['wired']['outer']))")

# --- Wireless fans: handled by lianli-rgb-init.sh after daemon restart ---
# (Proper 6-second spacing avoids RF channel saturation)

# --- Wired fans: Static mode with Inner/Outer scope ---
for group in $WIRED_GROUPS; do
  # Inner ring
  echo "{\"method\":\"SetRgbEffect\",\"params\":{\"device_id\":\"$group\",\"zone\":0,\"effect\":{\"mode\":\"Static\",\"colors\":[$INNER],\"speed\":2,\"brightness\":4,\"direction\":\"Clockwise\",\"scope\":\"Inner\"}}}" \
    | socat - UNIX-CONNECT:"$SOCKET" >/dev/null 2>&1
  # Outer ring
  echo "{\"method\":\"SetRgbEffect\",\"params\":{\"device_id\":\"$group\",\"zone\":0,\"effect\":{\"mode\":\"Static\",\"colors\":[$OUTER],\"speed\":2,\"brightness\":4,\"direction\":\"Clockwise\",\"scope\":\"Outer\"}}}" \
    | socat - UNIX-CONNECT:"$SOCKET" >/dev/null 2>&1
done
echo "  Wired fans: done"

# --- OpenRGB server readiness (RAM + motherboard need it) ---
# Bounded wait: covers boot (openrgb-server has a 15s ExecStartPre sleep) and
# gamemode-end restart races. Falls through silently if never ready.
if [ -n "$(echo "$PROFILE" | python3 -c "import json,sys; p=json.load(sys.stdin); r=p.get('ram'); print(json.dumps(r) if r else '')" 2>/dev/null)" ] || echo "$PROFILE" | python3 -c "import json,sys; exit(0 if json.load(sys.stdin).get('motherboard') else 1)" 2>/dev/null; then
  for _ in $(seq 1 15); do
    if timeout 2 bash -c 'echo > /dev/tcp/127.0.0.1/6742' 2>/dev/null; then
      break
    fi
    sleep 2
  done
fi

# --- RAM: OpenRGB SDK (if profile has ram color) ---
RAM_COLOR=$(echo "$PROFILE" | python3 -c "import json,sys; p=json.load(sys.stdin); r=p.get('ram'); print(json.dumps(r) if r else '')" 2>/dev/null)

if [ -n "$RAM_COLOR" ]; then
  python3 -c "
from openrgb import OpenRGBClient
from openrgb.utils import RGBColor
c = OpenRGBClient('127.0.0.1', 6742, name='profile')
for dev in c.ee_devices:
    if dev.type.name == 'DRAM':
        dev.set_mode('Static')
        dev.set_color(RGBColor(*$RAM_COLOR))
c.disconnect()
" 2>/dev/null && echo "  RAM: done" || echo "  RAM: skipped (OpenRGB server not ready)"
fi

# --- Motherboard ARGB (JRAINBOW1): via OpenRGB SDK ---
MB_COLOR=$(echo "$PROFILE" | python3 -c "
import json, sys
p = json.load(sys.stdin)
mb = p.get('motherboard', {})
c = mb.get('color', p.get('wired', {}).get('outer', [255,200,50]))
print(json.dumps(c))
" 2>/dev/null)

if [ -n "$MB_COLOR" ]; then
  python3 -c "
from openrgb import OpenRGBClient
from openrgb.utils import RGBColor
c = OpenRGBClient('127.0.0.1', 6742, name='profile')
for dev in c.devices:
    if dev.type.name == 'MOTHERBOARD' and 'MSI' in dev.name:
        start = $MB_LED_OFFSET
        count = min($MB_LED_COUNT, len(dev.leds) - start)
        colors = [RGBColor(0, 0, 0)] * len(dev.leds)
        colors[start:start + count] = [RGBColor(*$MB_COLOR)] * count
        dev.set_mode('Direct')
        dev.set_colors(colors)
        break
c.disconnect()
" 2>/dev/null && echo "  Motherboard: done" || echo "  Motherboard: skipped"
fi

# --- Persist: write current profile name for watchdog ---
mkdir -p "${HOME}/.config/lianli"
echo "$PROFILE_NAME" > "${HOME}/.config/lianli/current-profile"

# --- Persist: write config file on disk so daemon restarts pick it up ---
CONFIG_FILE="${HOME}/.config/lianli/config.json"
WIRELESS_DEVS_JSON="$(python3 -c "import json,sys; print(json.dumps('''$WIRELESS_DEVICES'''.split()))")"
python3 -c "
import json

inner = $INNER
outer = $OUTER
wireless_devices = json.loads('$WIRELESS_DEVS_JSON')
wireless_full = [inner] * $WIRELESS_INNER + [outer] * $WIRELESS_OUTER

with open('$CONFIG_FILE') as f:
    config = json.load(f)

config['rgb']['enabled'] = True

new_devices = []
for d in config['rgb']['devices']:
    if d['device_id'].startswith('wireless:'):
        continue
    for z in d['zones']:
        if z['effect'].get('scope') == 'Inner':
            z['effect']['colors'] = [inner]
        else:
            z['effect']['colors'] = [outer]
    new_devices.append(d)

for did in wireless_devices:
    zones = []
    for z in range($WIRELESS_ZONES):
        zones.append({
            'effect': {'mode': 'Direct', 'colors': wireless_full, 'speed': 2, 'brightness': 4, 'direction': 'Clockwise', 'scope': 'All'},
            'swap_lr': False, 'swap_tb': False, 'zone_index': z
        })
    new_devices.append({'device_id': did, 'mb_rgb_sync': False, 'zones': zones})

config['rgb']['devices'] = new_devices

# Reconcile fans.speeds wireless device ids from capabilities.json so a MAC
# change needs no manual config edit. Existing speeds arrays are kept
# positionally; new devices fall back to a curve that exists in fan_curves.
fan_speeds = config.get('fans', {}).get('speeds')
if fan_speeds is not None:
    old_wl = [e['speeds'] for e in fan_speeds if e['device_id'].startswith('wireless:')]
    curve_names = [c['name'] for c in config.get('fan_curves', [])]
    default_name = 'wireless-boost' if 'wireless-boost' in curve_names else (curve_names[0] if curve_names else 'curve-2')
    default_speeds = [default_name, default_name, default_name, 0]
    config['fans']['speeds'] = [e for e in fan_speeds if not e['device_id'].startswith('wireless:')]
    for i, did in enumerate(wireless_devices):
        speeds = old_wl[i] if i < len(old_wl) else list(default_speeds)
        config['fans']['speeds'].append({'device_id': did, 'speeds': speeds})

with open('$CONFIG_FILE', 'w') as f:
    json.dump(config, f, indent=2)
print('  Config file: written')
" 2>/dev/null || true

# Restart daemon so RGB controller re-reads config from file.
# Serialize against lianli-rgb-init.sh/lianli-fan-speed.sh so this restart
# can't interrupt one of their in-flight wireless RF pushes.
LOCKFILE="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/lianli-boot.lock"
exec {lock_fd}>"$LOCKFILE"
flock -w 60 "$lock_fd" || echo "WARNING: lianli-profile: RGB lock busy >60s, restarting daemon anyway" >&2
systemctl --user restart lianli-daemon
flock -u "$lock_fd"

# Wait for socket
for i in $(seq 1 15); do
  [ -S "$SOCKET" ] && break
  sleep 1
done

# Push Direct mode with proper 6-second spacing
(/home/alaw989/.local/bin/lianli-rgb-init.sh) &

echo "Profile applied!"
