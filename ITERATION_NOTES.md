# Iteration Notes

## Goal
Make RGB profiles capabilities-aware: one profile spec renders a unified color theme across all devices via a capabilities.json table (wireless SL-INF 8/36 split, wired AL V2 8/12 split, motherboard JRAINBOW1 72 LEDs, RAM), with persistence that never reverts to rainbow

## State
Iteration 3 (of many): motherboard renderer is now capability-driven. In `lianli-profile.sh` + `lianli-rgb-watchdog.sh` the OpenRGB MSI-board block no longer name-matches `'JRAINBOW' in led.name` while iterating `dev.leds`; it colors the first `$MB_LED_COUNT` (72, from capabilities.json) LEDs of the MOTHERBOARD device and zeros the rest: `colors = [RGBColor(*mb)] * count + [RGBColor(0,0,0)] * (len(dev.leds) - count)` with `count = min($MB_LED_COUNT, len(dev.leds))`. Verified: bash -n clean, exact embedded python blocks compile, full-block stub runtime test (100-LED fake board -> 72 colored / 28 off, Direct mode) passes for both scripts, full validate.sh passes.

NEXT: remaining refactors to RENDER from capabilities.json:
1. Add a validate.sh check that no script/config in the repo still hardcodes the wireless MAC literals (`wireless:24:12:76...`, `wireless:a8:87...`) or the wired group ids — grep the scripts/ and config.json for those strings and fail if found.
2. `config.json` (daemon config) still hardcodes the same MACs + 44-length arrays — it's regenerated on every profile apply by `lianli-profile.sh`, which now reads from capabilities. The validate.sh grep check above will surface any remaining literals; the config rewrite itself already reads from capabilities.
3. Eventually collapse the profile spec: `wired.inner`/`wired.outer` already equal wireless colors on all 88 profiles — a capability-aware renderer can drop `wireless.inner_color/outer_color` redundancy.

GOTCHAS:
- `validate.sh` live checks (services/socket) need the daemon running; JSON checks are offline-safe.
- `lianli-capabilities.sh` must be sourced (not executed); it needs `readlink -f` so it works via `~/.local/bin` symlinks. The eval'd python emits quoted space-separated strings for device lists — do NOT switch them to bash arrays, the scripts iterate with `for dev in $WIRELESS_DEVICES`.
- Profile `wired` colors and `wireless.*_color` are identical across all 88 profiles (verified) — redundancy safe to remove later.
- Motherboard coloring assumes JRAINBOW1 is the FIRST `led_count` LEDs of the OpenRGB MOTHERBOARD device (replaced the old name-scan heuristic); if a board enumerates headers out of order, revisit with a per-header index map in capabilities.json.

## Log

- iter-1: Created capabilities.json (device capability table: wireless SL-INF 8/36, wired AL V2 8/12, JRAINBOW1 72, RAM). Added validate.sh checks for it + profile split consistency. Verified all 88 profiles + full validate.sh pass.
- iter-2: Added scripts/lianli-capabilities.sh shared loader (sources wireless split/devices, wired groups, MB LED count from capabilities.json). Refactored lianli-profile.sh / lianli-rgb-init.sh / lianli-rgb-watchdog.sh to use it, removing hardcoded MAC lists and profile-count literals. Verified via live symlinks + temp config-writer run + full validate.sh pass.
- iter-3: Motherboard renderer in lianli-profile.sh + lianli-rgb-watchdog.sh now colors the first $MB_LED_COUNT LEDs of the OpenRGB MOTHERBOARD device (from capabilities.json) and zeros the rest, dropping the 'JRAINBOW' name-scan heuristic. Verified: compile of embedded blocks, full-block stub runtime tests (72/100 colored) for both scripts, full validate.sh pass.
