#!/usr/bin/env bash
# Measure drift-event rate over a window. Usage: drift-bench.sh <minutes> [label]
MIN=${1:-10}
LABEL=${2:-$(date +%H:%M)}
START=$(date +%s)
C0=$(journalctl --user -u lianli-daemon --no-pager 2>&1 | grep -c "drift on")
echo "[$LABEL] sampling drift for ${MIN} min (start count=$C0) @ $(date +%H:%M:%S)"
sleep $((MIN*60))
C1=$(journalctl --user -u lianli-daemon --no-pager 2>&1 | grep -c "drift on")
EL=$(( $(date +%s) - START ))
D=$((C1-C0))
RATE=$(echo "scale=2; $D*60/$EL" | bc)
echo "[$LABEL] END count=$C1  drift_events=$D  over ${EL}s  rate=${RATE}/min"
