#!/bin/bash
# Apply default RGB profile to all fans and RAM.
# Runs after lianli-daemon starts via systemd service.
set -e

SOCKET="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/lianli-daemon.sock"

# Wait for daemon socket to appear
for i in $(seq 1 30); do
  [ -S "$SOCKET" ] && break
  sleep 0.5
done

if [ ! -S "$SOCKET" ]; then
  echo "ERROR: lianli-daemon socket not found at $SOCKET" >&2
  exit 1
fi

# Wait for wireless devices to be discovered and wireless link to stabilize
sleep 8

# Apply default profile (reads current-profile, falls back to carbon-fiber)
PROFILE="carbon-fiber"
if [ -f "${HOME}/.config/lianli/current-profile" ]; then
  PROFILE=$(cat "${HOME}/.config/lianli/current-profile")
fi
/home/alaw989/.local/bin/lianli-profile.sh "$PROFILE"
