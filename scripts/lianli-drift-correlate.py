#!/usr/bin/env python3
"""Correlate wireless SL-INF RGB drift events against Bluetooth and WiFi-scan
activity, to find out what's actually causing the fans to revert to their
hardware-default rainbow.

Sources (journalctl, not modified by this script):
  - lianli-daemon (--user): drift detection + per-device MAC, and periodic
    "Set fan PWM for <mac> (rx=N, ch=M)" lines used as an RF-quality proxy.
  - wireplumber (--user): Bluetooth audio activity. Any "bluez" mention is
    treated as coarse activity; "Missing completion reports for packet" is
    a direct BT-transport-glitch marker.
  - NetworkManager (system unit): WiFi scan start events.

Output: one row per drift event to stdout (CSV) plus a summary at the end.
"""
import subprocess
import sys
import re
from datetime import datetime, timedelta

SINCE = sys.argv[1] if len(sys.argv) > 1 else "-13 days"

BT_WINDOW = timedelta(seconds=30)
BT_GLITCH_WINDOW = timedelta(seconds=10)
WIFI_WINDOW = timedelta(seconds=5)
RX_LOOKUP_WINDOW = timedelta(seconds=15)


def journal(unit, user=True, extra_args=None):
    cmd = ["journalctl", "--no-pager", "-o", "short-iso", "--since", SINCE]
    cmd += ["--user"] if user else []
    cmd += ["-u", unit]
    if extra_args:
        cmd += extra_args
    out = subprocess.run(cmd, capture_output=True, text=True, check=False).stdout
    return out.splitlines()


TS_RE = re.compile(r"^(\S+)\s+\S+\s+\S+:\s*(.*)$")


def parse_ts(line):
    m = TS_RE.match(line)
    if not m:
        return None, None
    try:
        ts = datetime.fromisoformat(m.group(1))
    except ValueError:
        return None, None
    return ts, m.group(2)


def load_lianli():
    """Returns (drift_events, pwm_samples).
    drift_events: list of (ts, [macs])
    pwm_samples: list of (ts, mac, rx, ch)
    """
    lines = journal("lianli-daemon")
    drift_events = []
    pwm_samples = []
    pending_ts = None
    pending_macs = []
    pwm_re = re.compile(r"Set fan PWM for ([0-9a-f:]+) \(rx=(\d+), ch=(\d+)\)")
    mac_re = re.compile(r"wireless:([0-9a-f:]+): device effect_index")
    for line in lines:
        ts, msg = parse_ts(line)
        if ts is None:
            continue
        if "Wireless RGB drift on" in msg:
            if pending_ts is not None:
                drift_events.append((pending_ts, pending_macs))
            pending_ts, pending_macs = ts, []
            continue
        if pending_ts is not None and mac_re.search(msg):
            pending_macs.append(mac_re.search(msg).group(1))
            continue
        if pending_ts is not None and ("drift cleared" in msg or "INFO" in line):
            drift_events.append((pending_ts, pending_macs))
            pending_ts, pending_macs = None, []
        m = pwm_re.search(msg)
        if m:
            pwm_samples.append((ts, m.group(1), int(m.group(2)), int(m.group(3))))
    if pending_ts is not None:
        drift_events.append((pending_ts, pending_macs))
    return drift_events, pwm_samples


def load_bt_events():
    lines = journal("wireplumber")
    bt_activity = []
    bt_glitch = []
    for line in lines:
        ts, msg = parse_ts(line)
        if ts is None:
            continue
        if "bluez" in msg.lower():
            bt_activity.append(ts)
        if "Missing completion reports" in msg:
            bt_glitch.append(ts)
    return bt_activity, bt_glitch


def load_wifi_scan_events():
    lines = journal("NetworkManager", user=False)
    scans = []
    for line in lines:
        ts, msg = parse_ts(line)
        if ts is None:
            continue
        if "-> scanning" in msg:
            scans.append(ts)
    return scans


def any_within(ts, sorted_list, window):
    # linear scan is fine at this data volume; lists are a few thousand max
    for t in sorted_list:
        if abs((t - ts).total_seconds()) <= window.total_seconds():
            return True
    return False


def nearest_rx(ts, mac, pwm_samples, window):
    best = None
    best_dt = None
    for t, m, rx, ch in pwm_samples:
        if m != mac:
            continue
        dt = abs((t - ts).total_seconds())
        if dt <= window.total_seconds() and (best_dt is None or dt < best_dt):
            best, best_dt = (rx, ch), dt
    return best if best else (None, None)


def main():
    drift_events, pwm_samples = load_lianli()
    bt_activity, bt_glitch = load_bt_events()
    wifi_scans = load_wifi_scan_events()

    print("timestamp,mac,rx,ch,bt_active,bt_glitch,wifi_scan")
    total = 0
    bt_active_ct = bt_glitch_ct = wifi_ct = 0
    per_device = {}
    for ts, macs in drift_events:
        macs = macs or ["unknown"]
        for mac in macs:
            total += 1
            rx, ch = nearest_rx(ts, mac, pwm_samples, RX_LOOKUP_WINDOW)
            bt_a = any_within(ts, bt_activity, BT_WINDOW)
            bt_g = any_within(ts, bt_glitch, BT_GLITCH_WINDOW)
            wifi = any_within(ts, wifi_scans, WIFI_WINDOW)
            bt_active_ct += bt_a
            bt_glitch_ct += bt_g
            wifi_ct += wifi
            d = per_device.setdefault(mac, {"count": 0, "rx_sum": 0, "rx_n": 0})
            d["count"] += 1
            if rx is not None:
                d["rx_sum"] += rx
                d["rx_n"] += 1
            print(f"{ts.isoformat()},{mac},{rx},{ch},{bt_a},{bt_g},{wifi}")

    print("\n# --- summary ---", file=sys.stderr)
    print(f"# total drift events: {total}", file=sys.stderr)
    if total:
        print(f"# with BT activity within ±{BT_WINDOW.seconds}s: {bt_active_ct} ({100*bt_active_ct/total:.1f}%)", file=sys.stderr)
        print(f"# with BT transport glitch within ±{BT_GLITCH_WINDOW.seconds}s: {bt_glitch_ct} ({100*bt_glitch_ct/total:.1f}%)", file=sys.stderr)
        print(f"# with WiFi scan within ±{WIFI_WINDOW.seconds}s: {wifi_ct} ({100*wifi_ct/total:.1f}%)", file=sys.stderr)
    print("# per-device breakdown:", file=sys.stderr)
    for mac, d in sorted(per_device.items(), key=lambda kv: -kv[1]["count"]):
        avg_rx = f"{d['rx_sum']/d['rx_n']:.2f}" if d["rx_n"] else "n/a"
        print(f"#   {mac}: {d['count']} drift events, avg rx={avg_rx} (n={d['rx_n']})", file=sys.stderr)
    print(f"# baseline BT activity rate (fraction of whole window {SINCE} with BT activity nearby) not computed — treat % above as relative signal, not absolute causation.", file=sys.stderr)


if __name__ == "__main__":
    main()
