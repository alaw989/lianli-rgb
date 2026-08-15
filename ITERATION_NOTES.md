# Iteration Notes

## Goal
Make RGB profiles capabilities-aware: one profile spec renders a unified color theme across all devices via a capabilities.json table (wireless SL-INF 8/36 split, wired AL V2 8/12 split, motherboard JRAINBOW1 72 LEDs, RAM), with persistence that never reverts to rainbow

## State
Iteration 8 (of many): KILLED the last hardcoded wireless zone literal — all three renderers now loop `$WIRELESS_ZONES` (exported by lianli-capabilities.sh from capabilities.json, asserted uniform across wireless instances). Changed: lianli-profile.sh uses `range($WIRELESS_ZONES)` in the config-writer, lianli-rgb-init.sh + lianli-rgb-watchdog.sh use `for zone in $(seq 0 $((WIRELESS_ZONES - 1)))`; validate.sh now FAILS on any `range(3)` / `in 0 1 2` in scripts/ (regression guard added iter-8). Verified: bash -n clean, loader emits WIRELESS_ZONES=3, embedded renderer emits 3 zones x 44 LEDs per wireless device, init/watchdog loops expand 0..2, negative guard test fails on a hardcoded loop, full validate.sh ALL CHECKS PASSED.

NEXT: none — all four capability-driven refactors are done (profile spec collapsed iter-7, fan speeds iter-5, fan_curves iter-6, zones iter-8). Goal reached: one profile spec renders a unified theme across all devices from capabilities.json (wireless 8/36 split, wired 8/12 split, MB JRAINBOW1 72, RAM) with persistence via config.json + init + watchdog.

GOTCHAS:
- `validate.sh` live checks (services/socket) need the daemon running; JSON checks are offline-safe.
- `lianli-capabilities.sh` must be sourced (not executed); it needs `readlink -f` so it works via `~/.local/bin` symlinks. The eval'd python emits quoted space-separated strings for device lists — do NOT switch them to bash arrays, the scripts iterate with `for dev in $WIRELESS_DEVICES`. `$WIRELESS_ZONES` is a single int (asserted identical across instances).
- Profile spec is now `name`/`description`/`ram`/`wired`/`motherboard` only — a `wireless` section fails validate.sh (regression guard added iter-7).
- Motherboard coloring assumes JRAINBOW1 is the FIRST `led_count` LEDs of the OpenRGB MOTHERBOARD device (replaced the old name-scan heuristic); if a board enumerates headers out of order, revisit with a per-header index map in capabilities.json.

## Log

- iter-1: Created capabilities.json (device capability table: wireless SL-INF 8/36, wired AL V2 8/12, JRAINBOW1 72, RAM). Added validate.sh checks for it + profile split consistency. Verified all 88 profiles + full validate.sh pass.
- iter-2: Added scripts/lianli-capabilities.sh shared loader (sources wireless split/devices, wired groups, MB LED count from capabilities.json). Refactored lianli-profile.sh / lianli-rgb-init.sh / lianli-rgb-watchdog.sh to use it, removing hardcoded MAC lists and profile-count literals. Verified via live symlinks + temp config-writer run + full validate.sh pass.
- iter-3: Motherboard renderer in lianli-profile.sh + lianli-rgb-watchdog.sh now colors the first $MB_LED_COUNT LEDs of the OpenRGB MOTHERBOARD device (from capabilities.json) and zeros the rest, dropping the 'JRAINBOW' name-scan heuristic. Verified: compile of embedded blocks, full-block stub runtime tests (72/100 colored) for both scripts, full validate.sh pass.
- iter-4: validate.sh "Device ids sourced from capabilities.json" check (script literal scan + config.json drift vs capabilities). Verified negative tests + clean pass.
- iter-5: lianli-profile.sh config rewrite reconciles fans.speeds wireless ids from capabilities.json (existing speeds preserved positionally, default-curve fallback for new devices). Verified stale-MAC drop + fallback tests + validate.sh pass.
- iter-6: lianli-fan-speed.sh resolves wired/wireless fan_curves by name from config.json (curve names read from fans.speeds by device_id prefix) instead of positional [0]/[1] indexing. Verified renamed+reordered and live-config rewrites, missing-curve error path, validate.sh pass.
- iter-7: Collapsed profile spec — removed the `wireless` section from all 88 profiles (colors matched `wired` on all; split is capabilities-driven). lianli-rgb-init.sh/lianli-rgb-watchdog.sh read `wired.inner`/`outer` for wireless colors; validate.sh forbids `wireless` in profiles and removed-field refs in scripts; AGENTS.md schema updated. Verified full validate.sh pass.
- iter-8: Replaced the last hardcoded wireless zone literal (3) with `$WIRELESS_ZONES` exported from lianli-capabilities.sh (asserted uniform across instances). lianli-profile.sh `range($WIRELESS_ZONES)`, lianli-rgb-init.sh/lianli-rgb-watchdog.sh `seq 0 $((WIRELESS_ZONES-1))` loops; validate.sh guard fails on `range(3)`/`in 0 1 2` in scripts/. Verified renderer emits 3 zones x 44 LEDs per device, negative guard test, full validate.sh pass. NEXT list complete — goal reached.
