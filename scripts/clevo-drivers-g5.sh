#!/usr/bin/env bash
# clevo-drivers-g5.sh
#
# Builds upstream TUXEDO drivers (clevo_wmi, clevo_acpi, tuxedo_keyboard) for a
# non-TUXEDO Clevo laptop (Gigabyte G5 KF5) via DKMS, with the TUXEDO-only
# compatibility check patched out, signed with the existing akmods MOK key.
#
# What it can give you, IF the G5 firmware implements them:
#   - keyboard backlight  -> /sys/class/leds/*kbd_backlight*
#   - charge limit        -> /sys/class/power_supply/BAT0/charge_control_end_threshold
#                            (Clevo "Flexicharger"; end values 60/70/80/90/100)
#
#   sudo ./clevo-drivers-g5.sh            # dry run: checks + prints every step
#   sudo ./clevo-drivers-g5.sh --apply    # do it
#   sudo ./clevo-drivers-g5.sh --remove   # undo everything this script installed

set -euo pipefail

TAG="v4.25.0"
VER="${TAG#v}"
PKG="tuxedo-drivers-clevo"
SRC_DIR="/usr/src/${PKG}-${VER}"
REPO="https://github.com/tuxedocomputers/tuxedo-drivers.git"
DKMS_CONF_DIR="/etc/dkms/framework.conf.d"
DKMS_SIGN_CONF="${DKMS_CONF_DIR}/akmods-key.conf"
AKMODS_KEY="/etc/pki/akmods/private/private_key.priv"
AKMODS_CERT="/etc/pki/akmods/certs/public_key.der"
COMPAT_FILE="tuxedo_compatibility_check/tuxedo_compatibility_check.c"

MODE="dry"
case "${1:-}" in
  --apply)  MODE="apply" ;;
  --remove) MODE="remove" ;;
  "")       ;;
  *) echo "Usage: sudo $0 [--apply|--remove]" >&2; exit 1 ;;
esac
[[ $EUID -eq 0 ]] || { echo "Run as root: sudo $0 [--apply|--remove]" >&2; exit 1; }

head_() { printf '\n== %s ==\n' "$*"; }
run() {
  if [[ "$MODE" == "dry" ]]; then printf '  [dry-run] %s\n' "$*"
  else printf '  + %s\n' "$*"; "$@"; fi
}
fail() { echo "  STOP: $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
if [[ "$MODE" == "remove" ]]; then
  head_ "Removing ${PKG} ${VER}"
  modprobe -r clevo_wmi clevo_acpi tuxedo_keyboard tuxedo_compatibility_check 2>/dev/null || true
  if dkms status "${PKG}/${VER}" 2>/dev/null | grep -q .; then
    dkms remove "${PKG}/${VER}" --all
  fi
  rm -rf "$SRC_DIR"
  rm -f "$DKMS_SIGN_CONF"
  depmod -a
  echo "Done. Reboot to clear any state the modules set."
  exit 0
fi

[[ "$MODE" == "dry" ]] && echo "DRY RUN. Nothing will change. Re-run with --apply to execute."

# ---------------------------------------------------------------------------
head_ "1. Pre-flight checks"
echo "  Board:   $(cat /sys/class/dmi/id/board_vendor 2>/dev/null) / $(cat /sys/class/dmi/id/board_name 2>/dev/null)"
echo "  Product: $(cat /sys/class/dmi/id/sys_vendor 2>/dev/null) / $(cat /sys/class/dmi/id/product_name 2>/dev/null)"
echo "  Kernel:  $(uname -r)"

if compgen -G "/sys/bus/wmi/devices/ABBC0F6D*" >/dev/null; then
  echo "  OK  Clevo WMI interface present"
else
  echo "  --  Clevo WMI interface not found"
fi
if grep -qs CLV0001 /sys/bus/acpi/devices/*/hid; then
  echo "  OK  Clevo ACPI device present"
else
  echo "  --  Clevo ACPI device not found"
fi

[[ -r "$AKMODS_KEY" && -r "$AKMODS_CERT" ]] || fail "akmods key pair missing under /etc/pki/akmods"
echo "  OK  akmods key pair present"
KEY_CN="$(openssl x509 -inform DER -in "$AKMODS_CERT" -noout -subject 2>/dev/null | sed -n 's/.*CN *= *//p')"
echo "  akmods key CN: ${KEY_CN:-unknown}"
TEST_OUT="$(mokutil --test-key "$AKMODS_CERT" 2>&1 || true)"
echo "  mokutil --test-key says: $TEST_OUT"
if grep -qi "already enrolled" <<<"$TEST_OUT"; then
  echo "  OK  akmods key enrolled in MOK"
elif [[ -n "$KEY_CN" ]] && grep -qF "$KEY_CN" /proc/keys 2>/dev/null; then
  echo "  OK  akmods key is loaded in the kernel keyring (trusted for module loading)"
elif [[ -n "$KEY_CN" ]] && mokutil --list-enrolled 2>/dev/null | grep -qF "$KEY_CN"; then
  echo "  OK  akmods key found in MOK enrolled list"
else
  fail "akmods key not found in MOK or the kernel keyring. Enroll it first."
fi
echo "  Secure Boot: $(mokutil --sb-state 2>/dev/null | head -1)"

# ---------------------------------------------------------------------------
head_ "2. Remove the COPR tuxedo-drivers packages (they conflict)"
mapfile -t COPR_PKGS < <(rpm -qa --qf '%{NAME}\n' | grep -E '^(akmod-tuxedo-drivers|tuxedo-drivers|kmod-tuxedo-drivers.*)$' || true)
if (( ${#COPR_PKGS[@]} )); then
  run dnf remove -y "${COPR_PKGS[@]}"
else
  echo "  none installed"
fi
if dnf copr list 2>/dev/null | grep -q 'darrencocco/tuxedo-drivers-kmod'; then
  run dnf copr disable -y darrencocco/tuxedo-drivers-kmod
fi

# ---------------------------------------------------------------------------
head_ "3. Build dependencies"
run dnf install -y dkms git gcc make "kernel-devel-$(uname -r)"

# ---------------------------------------------------------------------------
head_ "4. Make DKMS sign modules with the enrolled akmods key"
echo "  writes $DKMS_SIGN_CONF:"
echo "    mok_signing_key=$AKMODS_KEY"
echo "    mok_certificate=$AKMODS_CERT"
if [[ "$MODE" == "apply" ]]; then
  mkdir -p "$DKMS_CONF_DIR"
  printf 'mok_signing_key="%s"\nmok_certificate="%s"\n' "$AKMODS_KEY" "$AKMODS_CERT" > "$DKMS_SIGN_CONF"
fi

# ---------------------------------------------------------------------------
head_ "5. Fetch upstream ${TAG} and patch the compatibility check"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
# The clone is read-only inspection, so it runs in dry-run mode too.
git clone -q --depth 1 --branch "$TAG" "$REPO" "$TMP/td"
grep -q 'bool tuxedo_is_compatible(void) {' "$TMP/td/src/$COMPAT_FILE" \
  || fail "compatibility function not found in ${TAG}; upstream layout changed"
sed -i 's|bool tuxedo_is_compatible(void) {|bool tuxedo_is_compatible(void) {\n\treturn true; /* patched: allow non-TUXEDO Clevo hardware */|' \
  "$TMP/td/src/$COMPAT_FILE"
echo "  patched function:"
sed -n '/bool tuxedo_is_compatible(void) {/,/^}/p' "$TMP/td/src/$COMPAT_FILE" | sed 's/^/    /'

cat > "$TMP/td/src/dkms.conf" <<EOF
PACKAGE_NAME="${PKG}"
PACKAGE_VERSION="${VER}"
MAKE[0]="make -C \${kernel_source_dir} M=\${dkms_tree}/\${PACKAGE_NAME}/\${PACKAGE_VERSION}/build modules"
CLEAN="make -C \${kernel_source_dir} M=\${dkms_tree}/\${PACKAGE_NAME}/\${PACKAGE_VERSION}/build clean"
BUILT_MODULE_NAME[0]="tuxedo_compatibility_check"
BUILT_MODULE_LOCATION[0]="tuxedo_compatibility_check/"
DEST_MODULE_LOCATION[0]="/extra"
BUILT_MODULE_NAME[1]="tuxedo_keyboard"
DEST_MODULE_LOCATION[1]="/extra"
BUILT_MODULE_NAME[2]="clevo_wmi"
DEST_MODULE_LOCATION[2]="/extra"
BUILT_MODULE_NAME[3]="clevo_acpi"
DEST_MODULE_LOCATION[3]="/extra"
AUTOINSTALL="yes"
EOF
echo "  dkms.conf: installs tuxedo_compatibility_check, tuxedo_keyboard, clevo_wmi, clevo_acpi only"

# ---------------------------------------------------------------------------
head_ "6. Install source and build with DKMS"
run rm -rf "$SRC_DIR"
run cp -a "$TMP/td/src" "$SRC_DIR"
run dkms add "${PKG}/${VER}"
run dkms build "${PKG}/${VER}"
run dkms install "${PKG}/${VER}"

# ---------------------------------------------------------------------------
head_ "7. Load and report"
run modprobe clevo_wmi
run modprobe clevo_acpi || true

if [[ "$MODE" == "apply" ]]; then
  sleep 1
  echo
  echo "  Keyboard backlight:"
  found=0
  for l in /sys/class/leds/*kbd*; do [[ -e "$l" ]] && { echo "    $(basename "$l")"; found=1; }; done
  (( found )) || echo "    not exposed"
  echo "  Charge limit:"
  if [[ -e /sys/class/power_supply/BAT0/charge_control_end_threshold ]]; then
    echo "    end threshold now:  $(cat /sys/class/power_supply/BAT0/charge_control_end_threshold)%"
    echo "    allowed end values: $(cat /sys/class/power_supply/BAT0/charge_control_end_available_thresholds 2>/dev/null)"
    echo "    Set it in KDE: System Settings > Power Management > Charge Limit"
    echo "    or: echo 90 | sudo tee /sys/class/power_supply/BAT0/charge_control_end_threshold"
  else
    echo "    not exposed (firmware has no Flexicharger)"
  fi
  echo
  echo "  Kernel log:"
  journalctl -k -b --no-pager | grep -iE 'clevo|tuxedo|flexicharger' | tail -10 | sed 's/^/    /' || true
  echo
  echo "If neither feature appeared, undo with: sudo $0 --remove"
fi
