#!/bin/bash
# Set global fan speed by target RPM (not an arbitrary duty %).
# Closed-loop: solves flat duty curves for wired and wireless fans
# independently, restarting the daemon and re-measuring telemetry each
# round, until both fan types converge on the requested RPM. Curves are
# flat across all temp breakpoints (no thermal ramp) — see comment above
# build_wired/build_wireless for why.
# Usage: lianli-fan-speed.sh <target-rpm>
#   e.g. lianli-fan-speed.sh 1200   (~1200 RPM on both fan types)
#        lianli-fan-speed.sh 800    (quieter)
#        lianli-fan-speed.sh 1600   (near max, may not be reachable on wireless)

set -e

TARGET="${1:?Usage: lianli-fan-speed.sh <target-rpm>}"

if (( $(echo "$TARGET < 0 || $TARGET > 2200" | bc -l) )); then
  echo "ERROR: target RPM must be 0-2200" >&2
  exit 1
fi

CONFIG="$HOME/.config/lianli/config.json"
SOCK="/run/user/$(id -u)/lianli-daemon.sock"

# Serialize against lianli-rgb-init.sh/lianli-profile.sh so we don't yank the
# daemon out from under an in-flight wireless RF push.
LOCKFILE="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/lianli-boot.lock"
exec {lock_fd}>"$LOCKFILE"
flock -w 60 "$lock_fd" || echo "WARNING: lianli-fan-speed: RGB lock busy >60s, proceeding anyway" >&2

python3 -c "
import json, subprocess, socket, time, sys

target = float($TARGET)
config_path = '$CONFIG'
sock_path = '$SOCK'

# Flat curves: same duty at every temp breakpoint, so the measured RPM
# reflects exactly the duty being solved for, regardless of current CPU temp.
# A temp-proportional ramp was tried and rejected: idle CPU temp isn't
# reliably pinned at the curve's first breakpoint, so the daemon was
# interpolating to a *different* (higher) duty than the one being measured,
# which broke the secant search's assumption that duty in == RPM out.
# Trade-off: fans no longer ramp up automatically under sustained load —
# re-run this script with a higher target if thermals call for it.
wired_temps = [30.0, 50.0, 65.0, 80.0, 90.0]
wireless_temps = [30.0, 45.0, 60.0, 75.0, 90.0]

def build_wired(duty):
    return [[t, duty] for t in wired_temps]

def build_wireless(duty):
    return [[t, duty] for t in wireless_temps]

def load_curve_names(config):
    names = [c['name'] for c in config.get('fan_curves', [])]
    def curve_name_for(prefix, pref):
        for e in config.get('fans', {}).get('speeds', []):
            if str(e.get('device_id', '')).startswith(prefix) and e.get('speeds'):
                name = e['speeds'][0]
                if name in names:
                    return name
        return pref if pref in names else None
    wired_name = curve_name_for('hid:', 'curve-2') or 'curve-2'
    wireless_name = curve_name_for('wireless:', 'wireless-boost') or 'wireless-boost'
    if wired_name not in names or wireless_name not in names:
        raise SystemExit('ERROR: config.json fan_curves missing wired/wireless curve')
    if wired_name == wireless_name:
        raise SystemExit('ERROR: wired and wireless fan curves resolve to the same entry')
    return wired_name, wireless_name

def apply_and_measure(wired_duty, wireless_duty):
    with open(config_path) as f:
        config = json.load(f)
    wired_name, wireless_name = load_curve_names(config)
    wired_curve = build_wired(wired_duty)
    wireless_curve = build_wireless(wireless_duty)
    for c in config['fan_curves']:
        if c['name'] == wired_name:
            c['curve'] = wired_curve
        elif c['name'] == wireless_name:
            c['curve'] = wireless_curve
    with open(config_path, 'w') as f:
        json.dump(config, f, indent=2)

    subprocess.run(['systemctl', '--user', 'restart', 'lianli-daemon'], check=True)
    time.sleep(20)  # settle time — big duty jumps carry rotational momentum;
                     # observed wireless fans still 100+ RPM off true value
                     # at 15s, settled by ~30s total (see second read below)

    def read_telemetry():
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.connect(sock_path)
        s.sendall(b'{\"method\":\"GetTelemetry\"}\n')
        resp = s.recv(65536)
        s.close()
        data = json.loads(resp.decode())['data']['fan_rpms']
        wired_rpms, wireless_rpms = [], []
        for dev, rpms in data.items():
            vals = [r for r in rpms if r > 0]
            if not vals:
                continue
            if dev.startswith('hid:'):
                wired_rpms.extend(vals)
            elif dev.startswith('wireless:'):
                wireless_rpms.extend(vals)
        w = sum(wired_rpms) / len(wired_rpms) if wired_rpms else 0.0
        wl = sum(wireless_rpms) / len(wireless_rpms) if wireless_rpms else 0.0
        return w, wl

    # Average two reads spaced apart — a single sample can catch a transient
    # (RGB RF push, USB re-enumeration, residual spin-up/down) and read
    # wildly off, especially on the wireless fans.
    w1, wl1 = read_telemetry()
    time.sleep(10)
    w2, wl2 = read_telemetry()
    return (w1 + w2) / 2.0, (wl1 + wl2) / 2.0

def secant_step(x0, y0, x1, y1, target, lo, hi, max_step):
    if y1 == y0:
        # flat/stalled response — nudge in the direction of the error
        step = max_step / 3.0 if target > y1 else -max_step / 3.0
        return min(max(x1 + step, lo), hi)
    x2 = x1 + (target - y1) * (x1 - x0) / (y1 - y0)
    # damp large jumps — the wired curve has a steep RPM cliff around
    # 24-25% duty, and an undamped secant step can fly across it
    x2 = min(max(x2, x1 - max_step), x1 + max_step)
    return min(max(x2, lo), hi)

WIRED_TOL = 30.0      # wired RPM reading is tight and repeatable
WIRELESS_TOL = 50.0   # wireless has more per-fan spread and run-to-run drift
MAX_ITERS = 8
WIRED_STEP = 4.0       # max duty-% change per iteration
WIRELESS_STEP = 4.0    # wireless response near target has been as steep as
                       # ~60 RPM per 1% duty — an 8% step overshot by 400+ RPM

# Seed guesses bracket the known calibrated operating ranges (duty %). These
# drift session to session (hardware/RF conditions), so treat as a starting
# bracket for the secant search, not a fixed answer.
wired_x0, wired_x1 = 22.0, 26.0
wireless_x0, wireless_x1 = 45.0, 60.0

print(f'Target: {target:.0f} RPM')

wired_y0, wireless_y0 = apply_and_measure(wired_x0, wireless_x0)
if abs(wired_y0 - target) <= WIRED_TOL and abs(wireless_y0 - target) <= WIRELESS_TOL:
    wired_x1, wired_y1 = wired_x0, wired_y0
    wireless_x1, wireless_y1 = wireless_x0, wireless_y0
else:
    wired_y1, wireless_y1 = apply_and_measure(wired_x1, wireless_x1)

    for i in range(MAX_ITERS):
        wired_done = abs(wired_y1 - target) <= WIRED_TOL
        wireless_done = abs(wireless_y1 - target) <= WIRELESS_TOL
        if wired_done and wireless_done:
            break

        next_wired_x = wired_x1 if wired_done else secant_step(wired_x0, wired_y0, wired_x1, wired_y1, target, 0.0, 100.0, WIRED_STEP)
        next_wireless_x = wireless_x1 if wireless_done else secant_step(wireless_x0, wireless_y0, wireless_x1, wireless_y1, target, 0.0, 100.0, WIRELESS_STEP)

        next_wired_y, next_wireless_y = apply_and_measure(next_wired_x, next_wireless_x)

        wired_x0, wired_y0 = wired_x1, wired_y1
        wired_x1, wired_y1 = next_wired_x, next_wired_y
        wireless_x0, wireless_y0 = wireless_x1, wireless_y1
        wireless_x1, wireless_y1 = next_wireless_x, next_wireless_y

print(f'Wired:    {wired_x1:.1f}% duty -> {wired_y1:.0f} RPM (target {target:.0f})')
print(f'Wireless: {wireless_x1:.1f}% duty -> {wireless_y1:.0f} RPM (target {target:.0f})')
if abs(wired_y1 - target) > WIRED_TOL or abs(wireless_y1 - target) > WIRELESS_TOL:
    print('WARNING: one or more fan groups did not converge within tolerance — target may be outside the reachable range (wired stalls below ~500 RPM, wireless below ~600 RPM; wireless tops out lower than wired).', file=sys.stderr)
"
PY_STATUS=$?

# Re-push RGB with proper spacing after daemon restart (avoids RF saturation
# from the daemon's startup burst leaving some wireless zones uncolored)
systemctl --user start lianli-rgb-init.service >/dev/null 2>&1
flock -u "$lock_fd"

exit $PY_STATUS
