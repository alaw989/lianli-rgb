# lianli-rgb

Versioned source of truth for the Lian Li RGB control stack (previously
unversioned in `~/.local/bin` and `~/.config/lianli`).

## Layout

- `scripts/` — `lianli-*.sh` scripts (installed live at `~/.local/bin`, symlinked here)
- `profiles/` — color profiles (`~/.config/lianli/profiles/`, symlinked)
- `config.json` — daemon config template (regenerated on every profile apply)
- `systemd/` — user service/timer units (`~/.config/systemd/user/`)

## Live paths

The repo is the source of truth; live paths are symlinks into this repo:

- `~/.local/bin/lianli-*.sh` → `~/lianli-rgb/scripts/`
- `~/.config/lianli/profiles` → `~/lianli-rgb/profiles/`

## Applying a profile

```bash
lianli-profile.sh <name>   # reads profiles/<name>.json, updates daemon config,
                           # pushes Direct RGB, restarts daemon
```

## Key services

- `lianli-daemon.service` — fan + RGB control (IPC socket)
- `lianli-rgb-watchdog.timer` — 60s keepalive vs wireless rainbow revert
- `openrgb-server.service` — OpenRGB SDK (RAM / motherboard JRAINBOW1)

See AGENTS.md "RGB Fan Architecture" for the full hardware mapping.
