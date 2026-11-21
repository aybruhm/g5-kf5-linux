# Gigabyte G5 KF5 on Linux

Scripts that make the Gigabyte G5 KF5 (2024) work properly on Fedora: keyboard backlight, Fn lighting keys, a battery charge limit, TUXEDO Control Center, and a way to measure real power draw.

The G5 KF5 is a Clevo-built laptop. It exposes Clevo's firmware interfaces, but the mainline kernel has no driver for them, so out of the box the keyboard light, the Fn lighting keys and the charge limit do nothing. TUXEDO Computers maintains open-source drivers for Clevo hardware, but they refuse to load on non-TUXEDO machines. These scripts build those drivers with that check patched out, sign them for Secure Boot, and set up the tools on top.

Tested on: Gigabyte G5 KF5 (i7-13620H, RTX 4060), Fedora 44, KDE Plasma 6, kernel 7.3, Secure Boot enabled.

## What each script does

| Script | Purpose | Needs root |
| --- | --- | --- |
| [`scripts/clevo-drivers-g5.sh`](scripts/clevo-drivers-g5.sh) | Builds TUXEDO's upstream drivers (`clevo_wmi`, `clevo_acpi`, `tuxedo_keyboard`) with DKMS, patches out the TUXEDO-only compatibility check, and signs the modules with your akmods Secure Boot key. Gives you the RGB keyboard backlight, the Fn + numpad lighting keys, and the battery charge limit (Clevo Flexicharger). Rebuilds automatically on kernel updates. | Yes |
| [`scripts/tcc-install.sh`](scripts/tcc-install.sh) | Installs TUXEDO Control Center (TCC) on top of step 1. Adds the `tuxedo_io` module to the DKMS build, installs a placeholder package so TCC uses your patched drivers instead of TUXEDO's, and adds TUXEDO's Fedora repo restricted to the Control Center only. | Yes |
| [`scripts/kbd-neon-install.sh`](scripts/kbd-neon-install.sh) | A small systemd service that sets the keyboard brightness at boot and, optionally, cycles the keyboard through the colour wheel ("neon"). The G5 has a single-zone RGB keyboard, so the whole keyboard changes colour together. | Yes |
| [`scripts/battery-draw.sh`](scripts/battery-draw.sh) | Measures real power draw on battery in two independent ways: current x voltage, and the drop in the battery's charge counter. Useful for checking power-saving changes, because `upower`'s rate can be inflated on some firmware. | No |

Every script that changes the system runs as a **dry run by default** and only prints what it would do. Add `--apply` to make changes and `--remove` to undo them.

## Installation

Run the steps in order. Each step depends on the one before it.

### Step 0: Prerequisites

1. **A Secure Boot signing key enrolled in MOK.** The drivers are signed with the akmods key. If you already use `akmod-nvidia` from RPM Fusion, you have one. Check:

   ```bash
   sudo mokutil --test-key /etc/pki/akmods/certs/public_key.der
   ```

   If it says the key is not enrolled, or the file does not exist:

   ```bash
   sudo dnf install akmods
   sudo kmodgenca -a                                              # creates the key pair if missing
   sudo mokutil --import /etc/pki/akmods/certs/public_key.der     # set a one-time password
   sudo reboot                                                    # MokManager: Enroll MOK > Continue > Yes > password > Reboot
   ```

   Run `mokutil` with `sudo`: the key directory is readable by root only, so without it you get "Failed to open".

2. **Confirm the Clevo firmware interfaces exist** (the scripts check this too):

   ```bash
   ls /sys/bus/wmi/devices/ | grep -i ABBC0F6D
   grep -l CLV0001 /sys/bus/acpi/devices/*/hid
   ```

   Both should print a match.

3. **Back up your signing keys.** Losing them means re-enrolling a new key:

   ```bash
   sudo tar czf ~/akmods-keys-$(date +%F).tar.gz -C /etc/pki akmods
   ```

   The archive contains the private key. Keep it somewhere safe.

### Step 1: Drivers (keyboard backlight, Fn keys, charge limit)

```bash
chmod +x scripts/*.sh
sudo ./scripts/clevo-drivers-g5.sh            # dry run: checks hardware, key enrollment, shows the patch
sudo ./scripts/clevo-drivers-g5.sh --apply
```

At the end it reports what appeared. Expected:

- **Keyboard backlight:** `rgb:kbd_backlight`
- **Charge limit:** `charge_control_end_threshold`, allowed values `60 70 80 90 100`

Then restart KDE's power service so it picks up the new keyboard backlight (only needed this once; after a reboot the driver loads before login):

```bash
systemctl --user restart plasma-powerdevil.service
```

Now these work:

- **Keyboard brightness** from the Brightness and Color applet and the Fn + numpad lighting keys
- **Keyboard colour** from the same applet (follow accent colour, or a custom colour)
- **Charge limit** in System Settings > Power Management > Charge Limit. Use 80 for a laptop that is mostly plugged in, 90 if you are often unplugged. 85 is not supported by the firmware.

### Step 2: Choose how to control the keyboard (pick one)

The keyboard colour has one owner at a time. Choose one of these:

**Option A: TUXEDO Control Center** (also gives fan readings, fan profiles, CPU profiles)

```bash
sudo ./scripts/tcc-install.sh                 # dry run
sudo ./scripts/tcc-install.sh --apply
```

**Option B: KDE plus the neon service** (lighter; no extra kernel module or app)

```bash
sudo ./scripts/kbd-neon-install.sh
```

Settings live in `/etc/kbd-neon.conf` (brightness, `neon` or `static` mode, cycle speed, colour). After editing:

```bash
sudo systemctl restart kbd-neon
```

If you install TCC, `tcc-install.sh` stops `kbd-neon` for you. Also turn off KDE's keyboard colour option, so KDE, TCC and `kbd-neon` do not overwrite each other.

### Step 3: Measure (optional, any time)

Unplug the charger, keep your normal workload running, then:

```bash
./scripts/battery-draw.sh            # 60 s run, 2 s samples
./scripts/battery-draw.sh 300 5      # 5 min run, 5 s samples
```

The two methods should roughly agree. On the G5 KF5 with the NVIDIA GPU suspended and the power-saver profile, light coding typically lands around 8 to 12 W.

## TUXEDO Control Center on the G5: what works

| Feature | Status |
| --- | --- |
| Fan readings | Working (fan percentage tracks load; 0% at idle is normal, the fans stop around 45 °C) |
| Keyboard colour and brightness | Working |
| Charge thresholds | Working |
| CPU governor and power profiles | Working (generic Linux interfaces) |
| Custom fan curves | Untested. Test any custom curve under load before relying on it (see below) |

**Testing a fan profile:** run these in two terminals and check that the fan percentage rises and the package temperature levels off well below 100 °C. If the temperature climbs past about 90 °C with the fans low, press Ctrl+C and switch back to the default profile.

```bash
watch -n1 'sensors | grep -i package'
stress-ng --cpu 0 --timeout 60s
```

**TCC and KDE overlap.** TCC sets CPU profiles and charge limits itself. Let one tool own each setting.

## Troubleshooting

| Symptom | Fix |
| --- | --- |
| Fn lighting keys do nothing | `systemctl --user restart plasma-powerdevil.service` |
| Keyboard light or charge limit gone after a kernel update | `sudo dkms status` should show `tuxedo-drivers-clevo/4.25.0` as `installed` for the running kernel. If not, rerun `sudo ./scripts/clevo-drivers-g5.sh --apply` |
| `modprobe: ERROR: could not insert ... Key was rejected by service` | The akmods key is not enrolled in MOK on this machine. Redo Step 0 |
| `modprobe: ERROR: could not insert ... No such device` | The compatibility check is not patched (you are running TUXEDO's stock package). Remove it and use `clevo-drivers-g5.sh` |
| Colour key does nothing | `kbd-neon` is overwriting it. `sudo systemctl disable --now kbd-neon` |

## Uninstalling

Undo in reverse order:

```bash
sudo ./scripts/kbd-neon-install.sh --remove
sudo ./scripts/tcc-install.sh --remove
sudo ./scripts/clevo-drivers-g5.sh --remove
sudo reboot
```

## Notes and limitations

- **Single-zone keyboard.** The G5 KF5's keyboard is one RGB zone with 15 firmware colours. Rainbow or wave effects across the keys are not possible on this hardware. Arbitrary RGB values may be rounded to the nearest firmware colour.
- **Firmware effects** (breathe, wave, and so on) are not exposed by the driver for this keyboard type. The neon effect in `kbd-neon` is done in software.
- **Driver version.** The scripts pin TUXEDO drivers `v4.25.0`. To move to a newer release, change `TAG` in `clevo-drivers-g5.sh` and rerun it with `--apply`.
- **Risk.** These drivers were written and tested by TUXEDO for TUXEDO laptops. On the G5 they work, but Flexicharger detection reads a firmware value and writes it straight back, and fan control goes through firmware commands TUXEDO never validated on Gigabyte hardware. Use at your own risk.
- **No USB-C charging.** The G5 KF5 charges only from its 19.5 V / 150 W barrel jack (5.5 x 2.5 mm). A USB-C PD "trigger" cable at 20 V works for light use, but USB-C at 20 V tops out at 100 W.

## Credits

- [TUXEDO Computers](https://github.com/tuxedocomputers/tuxedo-drivers) for the drivers (GPL-2.0-or-later) and [TUXEDO Control Center](https://github.com/tuxedocomputers/tuxedo-control-center) (GPL-3.0). These scripts download and build their code; they do not redistribute it.
