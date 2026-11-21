#!/usr/bin/env bash
# kbd-neon-install.sh
#
# Software "neon" (smooth colour cycling) for the G5 KF5 keyboard backlight,
# plus a fixed boot brightness. Runs as a small systemd service that rotates
# the hue by writing /sys/class/leds/rgb:kbd_backlight/multi_intensity.
#
#   sudo ./kbd-neon-install.sh            # install and start
#   sudo ./kbd-neon-install.sh --remove   # stop and uninstall
#
# Tune later in /etc/kbd-neon.conf, then: sudo systemctl restart kbd-neon

set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "Run as root: sudo $0 [--remove]" >&2; exit 1; }

BIN=/usr/local/bin/kbd-neon
UNIT=/etc/systemd/system/kbd-neon.service
CONF=/etc/kbd-neon.conf

if [[ "${1:-}" == "--remove" ]]; then
  systemctl disable --now kbd-neon.service 2>/dev/null || true
  rm -f "$BIN" "$UNIT" "$CONF"
  systemctl daemon-reload
  echo "Removed. The keyboard keeps its last colour until reboot."
  exit 0
fi

[[ -e /sys/class/leds/rgb:kbd_backlight/multi_intensity ]] \
  || { echo "rgb:kbd_backlight not found. Is clevo_wmi loaded?" >&2; exit 1; }

# --- config ----------------------------------------------------------------
if [[ ! -e "$CONF" ]]; then
cat > "$CONF" <<'EOF'
# kbd-neon settings
BRIGHTNESS=191        # 0-255; 191 = 75%
MODE=neon             # neon = cycle colours, static = fixed STATIC_RGB
CYCLE_SECONDS=12      # time for one full trip around the colour wheel
STEP_SECONDS=0.1      # update interval; lower = smoother, more firmware calls
STATIC_RGB="0 255 255"
STATIC_ON_BATTERY=0   # 1 = stop cycling on battery and show STATIC_RGB
EOF
fi

# --- worker ----------------------------------------------------------------
cat > "$BIN" <<'EOF'
#!/usr/bin/env python3
"""Rotate the keyboard backlight hue (software neon). Config: /etc/kbd-neon.conf"""
import colorsys, os, shlex, time

LED = "/sys/class/leds/rgb:kbd_backlight"
AC = "/sys/class/power_supply/AC/online"

def conf():
    c = {"BRIGHTNESS": "191", "MODE": "neon", "CYCLE_SECONDS": "12",
         "STEP_SECONDS": "0.1", "STATIC_RGB": "0 255 255", "STATIC_ON_BATTERY": "0"}
    try:
        with open("/etc/kbd-neon.conf") as f:
            for line in f:
                line = line.split("#", 1)[0].strip()
                if "=" in line:
                    k, v = line.split("=", 1)
                    c[k.strip()] = " ".join(shlex.split(v))
    except FileNotFoundError:
        pass
    return c

def write(name, value):
    with open(f"{LED}/{name}", "w") as f:
        f.write(value)

def on_battery():
    try:
        with open(AC) as f:
            return f.read().strip() == "0"
    except OSError:
        return False

# The driver may load after this service starts at boot: wait up to 60 s.
for _ in range(120):
    if os.path.exists(f"{LED}/multi_intensity"):
        break
    time.sleep(0.5)
else:
    raise SystemExit("rgb:kbd_backlight never appeared; is clevo_wmi loaded?")

c = conf()
write("brightness", c["BRIGHTNESS"])          # set once; KDE may still adjust it later
static = c["STATIC_RGB"]
step = max(float(c["STEP_SECONDS"]), 0.03)
inc = step / max(float(c["CYCLE_SECONDS"]), 1.0)
static_on_batt = c["STATIC_ON_BATTERY"] == "1"

if c["MODE"] == "static":
    write("multi_intensity", static)
    raise SystemExit(0)

hue, last = 0.0, None
while True:
    if static_on_batt and on_battery():
        if last != static:
            write("multi_intensity", static); last = static
        time.sleep(2); continue
    r, g, b = (round(x * 255) for x in colorsys.hsv_to_rgb(hue, 1.0, 1.0))
    val = f"{r} {g} {b}"
    if val != last:
        write("multi_intensity", val); last = val
    hue = (hue + inc) % 1.0
    time.sleep(step)
EOF
chmod 755 "$BIN"

# --- service ---------------------------------------------------------------
cat > "$UNIT" <<'EOF'
[Unit]
Description=Software neon effect and boot brightness for keyboard backlight
After=systemd-modules-load.service

[Service]
Type=simple
ExecStart=/usr/local/bin/kbd-neon
Restart=on-failure
RestartSec=3
Nice=10
# Hardening: it only needs to write two sysfs files
ProtectSystem=strict
ReadWritePaths=/sys/class/leds /sys/devices
ProtectHome=yes
PrivateTmp=yes
NoNewPrivileges=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now kbd-neon.service
sleep 1
systemctl --no-pager --lines=3 status kbd-neon.service || true
echo
echo "Installed. Settings: $CONF  (then: sudo systemctl restart kbd-neon)"
