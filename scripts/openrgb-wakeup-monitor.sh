#!/usr/bin/env bash
# Monitor KDE screen locker D-Bus for unlock events and re-apply OpenRGB theme.
# Runs as a systemd user service alongside openrgb-server.
# Signal format: ActiveChanged (false,) means screen unlocked.

gdbus monitor --session --dest org.freedesktop.ScreenSaver 2>/dev/null | grep --line-buffered "(false,)" | while read -r _; do
    sleep 1
    # Toggle the GPU HDMI audio card profile off/on instead of restarting the whole
    # PipeWire daemon: this clears the same stuck HDMI audio sub-channel (see
    # feedback_hdmi_audio_drop memory) without dropping every client's PipeWire
    # connection, which previously crashed EasyEffects on every unlock.
    pactl set-card-profile alsa_card.pci-0000_01_00.1 off
    sleep 1
    pactl set-card-profile alsa_card.pci-0000_01_00.1 output:hdmi-stereo
    systemctl --user restart openrgb-server.service
    sleep 8
    /usr/bin/python3 /home/alaw989/.config/openrgb-theme.py
done
