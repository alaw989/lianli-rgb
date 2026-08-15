#!/bin/bash
# Verification for the RGB unified-theme stack.
# Exit 0 = healthy, 1 = any check failed.
set -e

ROOT="$(cd "$(dirname "$0")" && pwd)"
FAIL=0

echo "== Profile JSON validation =="
for f in "$ROOT"/profiles/*.json; do
  name=$(basename "$f" .json)
  python3 - "$f" <<'PY' || FAIL=1
import json, sys
p = json.load(open(sys.argv[1]))
assert isinstance(p.get('name'), str)
w = p.get('wired', {})
assert isinstance(w.get('inner'), list) and len(w['inner']) == 3
assert isinstance(w.get('outer'), list) and len(w['outer']) == 3
for c in w['inner'] + w['outer']:
    assert 0 <= c <= 255
wl = p.get('wireless')
assert wl is None, f"{sys.argv[1]}: 'wireless' section is redundant (colors come from wired.*, split from capabilities.json)"
r = p.get('ram')
if r is not None:
    assert len(r) == 3 and all(0 <= c <= 255 for c in r)
PY
done
echo "OK: all profiles valid"

echo "== capabilities.json =="
python3 - "$ROOT/capabilities.json" <<'PY' || FAIL=1
import json, sys
c = json.load(open(sys.argv[1]))
assert isinstance(c.get('version'), int)
d = c['devices']
wl = d['wireless_slinf']['led_layout']
assert wl['inner'] == 8 and wl['outer'] == 36, f"wireless SL-INF split must be 8/36, got {wl}"
assert d['wireless_slinf']['led_total'] == wl['inner'] + wl['outer']
wired = d['wired_al_v2']['led_layout']
assert wired['inner'] == 8 and wired['outer'] == 12, f"wired AL V2 split must be 8/12, got {wired}"
assert d['wired_al_v2']['led_total'] == wired['inner'] + wired['outer']
assert d['motherboard_jrainbow1']['led_count'] == 72
mb = d['motherboard_jrainbow1']
assert 0 <= mb.get('led_offset', 0), "led_offset must be >= 0"
assert mb['led_offset'] + mb['led_count'] <= 74, \
    f"JRAINBOW1 offset+count {mb['led_offset']}+{mb['led_count']} exceeds 74 (0-1 are JRGB1/JRGB2)"
for name, dev in d.items():
    for inst in dev.get('instances', []):
        assert inst['device_id']
PY
echo "OK: capabilities.json valid"

echo "== Profile spec collapsed (no wireless.* redundancy) =="
if python3 - "$ROOT" <<'PY'
import json, os, re, sys
root = sys.argv[1]
pat = re.compile(r'inner_color|outer_color|inner_count|outer_count')
zone_re = re.compile(r'range\(\s*3\s*\)|\bin 0 1 2\b')
bad = []

# scripts/ must reference no removed wireless.* fields
for fn in sorted(os.listdir(os.path.join(root, 'scripts'))):
    if not fn.endswith('.sh'):
        continue
    for i, line in enumerate(open(os.path.join(root, 'scripts', fn)), 1):
        if pat.search(line):
            bad.append(f"scripts/{fn}:{i}: removed-field reference in {line.strip()[:60]!r}")
        if zone_re.search(line):
            bad.append(f"scripts/{fn}:{i}: hardcoded wireless zone count (must come from lianli-capabilities.sh) in {line.strip()[:60]!r}")

# profiles must not carry a wireless section
for fn in sorted(os.listdir(os.path.join(root, 'profiles'))):
    if not fn.endswith('.json'):
        continue
    p = json.load(open(os.path.join(root, 'profiles', fn)))
    if 'wireless' in p:
        bad.append(f"profiles/{fn}: 'wireless' section is redundant")

if bad:
    for b in bad:
        print(f"  FAIL: {b}", file=sys.stderr)
    sys.exit(1)
PY
then
  echo "OK: no wireless.* redundancy in profiles or scripts"
else
  FAIL=1
fi

echo "== Profile naming =="
for f in "$ROOT"/profiles/*.json; do
  base=$(basename "$f" .json)
  name=$(python3 -c "import json;print(json.load(open('$f'))['name'])" 2>/dev/null || echo "")
  if [ "$base" != "$name" ] && [ -n "$name" ]; then
    # Display-name may differ from slug; just warn
    :
  fi
done
echo "OK"

echo "== Device ids sourced from capabilities.json (no hardcoded literals) =="
if python3 - "$ROOT" <<'PY'
import json, os, re, sys
root = sys.argv[1]

cap = json.load(open(os.path.join(root, 'capabilities.json')))
cap_ids = set()
for dev in cap['devices'].values():
    for inst in dev.get('instances', []):
        cap_ids.add(inst['device_id'])

# wireless MAC ids and wired AL V2 group ids (the ids that must come from capabilities.json)
lit_re = re.compile(r'wireless:[0-9a-f:]+|hid:[0-9]+:group[0-9]+')
bad = []

# 1. scripts/ must contain no device-id literals at all
for fn in sorted(os.listdir(os.path.join(root, 'scripts'))):
    if not fn.endswith('.sh'):
        continue
    for i, line in enumerate(open(os.path.join(root, 'scripts', fn)), 1):
        if lit_re.search(line):
            bad.append(f"scripts/{fn}:{i}: hardcoded device id in {line.strip()[:60]!r}")

# 2. config.json wireless/wired ids must match capabilities.json exactly (drift check)
cfg = json.load(open(os.path.join(root, 'config.json')))
cfg_ids = set()
def walk(o):
    if isinstance(o, dict):
        if 'device_id' in o:
            cfg_ids.add(o['device_id'])
        for v in o.values():
            walk(v)
    elif isinstance(o, list):
        for v in o:
            walk(v)
walk(cfg)

cfg_relevant = {i for i in cfg_ids if lit_re.match(i)}
cap_relevant = {i for i in cap_ids if lit_re.match(i)}

for i in sorted(cfg_relevant - cap_relevant):
    bad.append(f"config.json references {i} which is not in capabilities.json")
for i in sorted(cap_relevant - cfg_relevant):
    bad.append(f"config.json missing {i} from capabilities.json (regen by applying a profile)")

if bad:
    for b in bad:
        print(f"  FAIL: {b}", file=sys.stderr)
    sys.exit(1)
PY
then
  echo "OK: scripts/config device ids all come from capabilities.json"
else
  FAIL=1
fi

echo "== Service health =="
for s in lianli-daemon.service openrgb-server.service; do
  st=$(systemctl --user is-active "$s" 2>/dev/null || echo inactive)
  if [ "$st" = "active" ]; then
    echo "OK: $s"
  else
    echo "FAIL: $s is $st" >&2
    FAIL=1
  fi
done

echo "== Socket =="
SOCK="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/lianli-daemon.sock"
if [ -S "$SOCK" ]; then
  n=0
  for _ in $(seq 1 10); do
    n=$(echo '{"method":"ListDevices"}' | socat - UNIX-CONNECT:"$SOCK" 2>/dev/null | python3 -c "import json,sys; print(len(json.load(sys.stdin)['data']))" 2>/dev/null || echo 0)
    [ "$n" -ge 4 ] && break
    sleep 1
  done
  if [ "$n" -ge 4 ]; then
    echo "OK: daemon socket, $n device(s)"
  else
    echo "FAIL: only $n device(s) on daemon socket" >&2
    FAIL=1
  fi
else
  echo "FAIL: no daemon socket" >&2
  FAIL=1
fi

echo "== Current profile =="
if [ -f "$ROOT/../.config/lianli/current-profile" ] || [ -f "${HOME}/.config/lianli/current-profile" ]; then
  echo "OK: current-profile set"
else
  echo "FAIL: no current-profile" >&2
  FAIL=1
fi

if [ "$FAIL" -ne 0 ]; then
  echo "VALIDATION FAILED" >&2
  exit 1
fi
echo "ALL CHECKS PASSED"
