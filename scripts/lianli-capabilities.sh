#!/bin/bash
# Shared helper: expose device topology from capabilities.json (source of truth).
# Sourced by lianli-rgb-init.sh, lianli-rgb-watchdog.sh, lianli-profile.sh.
# Usage: . "$(dirname "$(readlink -f "$0")")/lianli-capabilities.sh"
# After sourcing:
#   $WIRELESS_INNER $WIRELESS_OUTER  wireless SL-INF LED split
#   $WIRELESS_DEVICES                space-separated wireless device ids
#   $WIRELESS_ZONES                  zone count per wireless instance
#   $WIRED_GROUPS                    space-separated wired AL V2 group ids
#   $MB_LED_COUNT                    motherboard JRAINBOW1 LED count
#   $MB_LED_OFFSET                   index of JRAINBOW1's first LED in OpenRGB MOTHERBOARD device

CAPABILITIES_FILE="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../capabilities.json"

eval "$(python3 - "$CAPABILITIES_FILE" <<'PY'
import json, sys
c = json.load(open(sys.argv[1]))
d = c['devices']
wl = d['wireless_slinf']
wired = d['wired_al_v2']
print(f"WIRELESS_INNER={wl['led_layout']['inner']}")
print(f"WIRELESS_OUTER={wl['led_layout']['outer']}")
print(f"WIRELESS_DEVICES='{' '.join(i['device_id'] for i in wl['instances'])}'")
zonemap = {i['zones'] for i in wl['instances']}
assert len(zonemap) == 1, f"all wireless instances must share one zone count, got {zonemap}"
print(f"WIRELESS_ZONES={zonemap.pop()}")
print(f"WIRED_GROUPS='{' '.join(i['device_id'] for i in wired['instances'])}'")
print(f"MB_LED_COUNT={d['motherboard_jrainbow1']['led_count']}")
print(f"MB_LED_OFFSET={d['motherboard_jrainbow1'].get('led_offset', 0)}")
PY
)"
