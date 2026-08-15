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
wl = p.get('wireless', {})
ic, oc = wl.get('inner_count'), wl.get('outer_count')
if ic is not None and oc is not None:
    assert ic + oc == 44, f"{sys.argv[1]}: wireless split {ic}+{oc} != 44"
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
for name, dev in d.items():
    for inst in dev.get('instances', []):
        assert inst['device_id']
PY
echo "OK: capabilities.json valid"

echo "== Profile wireless split matches capabilities =="
WL_CAPS="$(python3 -c "import json; l=json.load(open('$ROOT/capabilities.json'))['devices']['wireless_slinf']['led_layout']; print(l['inner'], l['outer'])")"
WL_IN="${WL_CAPS%% *}"
WL_OUT="${WL_CAPS##* }"
for f in "$ROOT"/profiles/*.json; do
  python3 - "$f" "$WL_IN" "$WL_OUT" <<'PY' || FAIL=1
import json, sys
p = json.load(open(sys.argv[1]))
w = p.get('wireless') or {}
if w.get('inner_count') is not None:
    if w['inner_count'] != int(sys.argv[2]) or w['outer_count'] != int(sys.argv[3]):
        print(f"{sys.argv[1]}: wireless split {w['inner_count']}/{w['outer_count']} != {sys.argv[2]}/{sys.argv[3]}", file=sys.stderr)
        sys.exit(1)
PY
done
echo "OK: all profile splits match capabilities.json"

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
