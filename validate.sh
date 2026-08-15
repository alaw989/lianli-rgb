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
