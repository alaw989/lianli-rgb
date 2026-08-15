#!/bin/bash
# Set global fan speed as a single percentage (0-100).
# Scales both wired and wireless curves proportionally while maintaining RPM balance.
# Usage: lianli-fan-speed.sh <percentage>
#   e.g. lianli-fan-speed.sh 80   (20% quieter)
#        lianli-fan-speed.sh 50   (half speed)
#        lianli-fan-speed.sh 100  (full calibrated speed)

set -e

SPEED="${1:?Usage: lianli-fan-speed.sh <0-100>}"

if (( $(echo "$SPEED < 0 || $SPEED > 100" | bc -l) )); then
  echo "ERROR: Speed must be 0-100" >&2
  exit 1
fi

CONFIG="$HOME/.config/lianli/config.json"

python3 -c "
import json, sys

speed = float($SPEED) / 100.0

# Base curves calibrated at speed=1.0 to produce matched RPMs
# Wired AL V2 (curve-2): naturally faster fan, lower duty needed
wired_base = [
    [30.0, 25.0],
    [50.0, 35.0],
    [65.0, 55.0],
    [80.0, 75.0],
    [90.0, 100.0],
]

# Wireless SL-INF (wireless-boost): needs ~2.5x duty to match wired RPM
wireless_base = [
    [30.0, 90.0],
    [45.0, 93.0],
    [60.0, 97.0],
    [75.0, 100.0],
    [90.0, 100.0],
]

def scale_curve(base, factor):
    # Scale duty values by factor, clamp to 100
    # Preserve the min duty floor to prevent stalls
    return [[t, min(d * factor, 100.0)] for t, d in base]

MIN_STARTUP = 25.0  # AL V2 needs ≥25% PWM to start from standstill
wired_scaled = [[t, max(d, MIN_STARTUP)] for t, d in scale_curve(wired_base, speed)]
wireless_scaled = scale_curve(wireless_base, speed)

with open('$CONFIG') as f:
    config = json.load(f)

# Update curve-2 (wired)
config['fan_curves'][0]['curve'] = wired_scaled

# Update wireless-boost (wireless)
config['fan_curves'][1]['curve'] = wireless_scaled

with open('$CONFIG', 'w') as f:
    json.dump(config, f, indent=2)

print(f'Speed set to {$SPEED}%')
print(f'  Wired curve:   ', [[f'{d:.0f}' for _, d in wired_scaled]])
print(f'  Wireless curve:', [[f'{d:.0f}' for _, d in wireless_scaled]])
"

systemctl --user restart lianli-daemon >/dev/null 2>&1
sleep 4

# Re-push RGB with proper 6s spacing after daemon restart (avoids RF saturation
# from the daemon's startup burst leaving some wireless zones uncolored)
systemctl --user start lianli-rgb-init.service >/dev/null 2>&1

TEMP=$(/home/alaw989/.local/bin/lianli-temp.sh)
echo "  CPU: ${TEMP}°C"

echo '{"method":"GetTelemetry"}' | socat - UNIX-CONNECT:/run/user/1000/lianli-daemon.sock | python3 -c "
import json, sys
data = json.load(sys.stdin)['data']
for dev, rpms in data['fan_rpms'].items():
    if rpms and any(r > 0 for r in rpms):
        label = 'Wired AL V2' if 'port' in dev else 'Wireless SL-INF'
        avg = sum(r for r in rpms if r > 0) // len([r for r in rpms if r > 0])
        print(f'  {label}: avg {avg} RPM')
"
