#!/usr/bin/env bash
# Hourly wireless-RGB drift logger. Counts daemon "drift on" events (each = one
# rainbow revert detected and re-sent) since the last run and appends one CSV
# row. Run by lianli-drift-logger.timer; safe to run manually to seed.
#
# Output: ~/.local/share/lianli/drift-log.csv  (persists across reboots)
#   columns: run_ts, run_local, since_ts, since_local, drift_count

LOG="$HOME/.local/share/lianli/drift-log.csv"
STATE="$HOME/.local/share/lianli/drift-logger.state"

mkdir -p "$(dirname "$LOG")"

RUN=$(date +%s)
if [ -f "$STATE" ]; then
  SINCE=$(cat "$STATE")
else
  SINCE=$((RUN - 3600))
fi

COUNT=$(journalctl --user -u lianli-daemon --since "@$SINCE" --no-pager 2>/dev/null | grep -c "drift on")

if [ ! -f "$LOG" ]; then
  echo "run_ts,run_local,since_ts,since_local,drift_count" > "$LOG"
fi
echo "$RUN,$(date -d "@$RUN" '+%m-%d %H:%M'),$SINCE,$(date -d "@$SINCE" '+%m-%d %H:%M'),$COUNT" >> "$LOG"

echo "$RUN" > "$STATE"
