#!/bin/bash
for d in /sys/class/hwmon/hwmon*/; do
  if [ "$(cat "$d/name" 2>/dev/null)" = "k10temp" ]; then
    awk '{print $1/1000}' "$d/temp1_input"
    break
  fi
done
