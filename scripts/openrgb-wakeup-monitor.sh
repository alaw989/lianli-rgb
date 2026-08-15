#!/usr/bin/env bash
# Monitor KDE screen locker D-Bus for unlock events and re-apply OpenRGB theme.
# Runs as a systemd user service alongside openrgb-server.
# Signal format: ActiveChanged (false,) means screen unlocked.

gdbus monitor --session --dest org.freedesktop.ScreenSaver 2>/dev/null | grep --line-buffered "(false,)" | while read -r _; do
    sleep 1
    systemctl --user restart pipewire wireplumber
    systemctl --user restart openrgb-server.service
    sleep 8
    /usr/bin/python3 /home/alaw989/.config/openrgb-theme.py
done
