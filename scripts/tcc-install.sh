#!/usr/bin/env bash
# tcc-install.sh
#
# Installs TUXEDO Control Center (TCC) on the Gigabyte G5 KF5 on top of the
# patched DKMS build from clevo-drivers-g5.sh.
#
#   sudo ./tcc-install.sh            # dry run
#   sudo ./tcc-install.sh --apply    # install
#   sudo ./tcc-install.sh --remove   # uninstall TCC, shim and repo (drivers stay)
#
# What it does:
#   1. Adds the tuxedo_io module (TCC's hardware interface) to the existing DKMS build
#   2. Builds a tiny shim RPM that "Provides: tuxedo-drivers", so TCC's dependency is
#      met by your patched build instead of TUXEDO's unpatched driver package
#   3. Adds TUXEDO's Fedora repo restricted to tuxedo-control-center only
#   4. Installs TCC and stops kbd-neon (both would write the keyboard colour)

set -euo pipefail

PKG="tuxedo-drivers-clevo"
VER="4.25.0"
SRC_DIR="/usr/src/${PKG}-${VER}"
DKMS_CONF="${SRC_DIR}/dkms.conf"
REPO_FILE="/etc/yum.repos.d/tuxedo.repo"
FEDORA_VER="$(rpm -E %fedora)"
SHIM_NAME="tuxedo-drivers-clevo-shim"

MODE="dry"
case "${1:-}" in
  --apply)  MODE="apply" ;;
  --remove) MODE="remove" ;;
  "") ;;
  *) echo "Usage: sudo $0 [--apply|--remove]" >&2; exit 1 ;;
esac
[[ $EUID -eq 0 ]] || { echo "Run as root: sudo $0 [--apply|--remove]" >&2; exit 1; }

head_() { printf '\n== %s ==\n' "$*"; }
run() {
  if [[ "$MODE" == "dry" ]]; then printf '  [dry-run] %s\n' "$*"
  else printf '  + %s\n' "$*"; "$@"; fi
}
fail() { echo "  STOP: $*" >&2; exit 1; }

rebuild_dkms() {
  run dkms remove "${PKG}/${VER}" --all
  run dkms add "${PKG}/${VER}"
  run dkms build "${PKG}/${VER}"
  run dkms install "${PKG}/${VER}"
}

# ---------------------------------------------------------------------------
if [[ "$MODE" == "remove" ]]; then
  head_ "Removing TCC, shim and repo"
  systemctl disable --now tccd.service tccd-sleep.service 2>/dev/null || true
  dnf remove -y tuxedo-control-center "$SHIM_NAME" || true
  rm -f "$REPO_FILE"
  if grep -q 'tuxedo_io' "$DKMS_CONF" 2>/dev/null; then
    sed -i '/^# tuxedo_io (TCC)/,/^DEST_MODULE_LOCATION\[4\]/d' "$DKMS_CONF"
    modprobe -r tuxedo_io 2>/dev/null || true
    MODE="apply" rebuild_dkms
  fi
  echo "Done. Your keyboard/charge-limit drivers are untouched."
  echo "Re-enable software neon if you want it: sudo systemctl enable --now kbd-neon"
  exit 0
fi

[[ "$MODE" == "dry" ]] && echo "DRY RUN. Nothing will change. Re-run with --apply to execute."

# ---------------------------------------------------------------------------
head_ "1. Pre-flight"
[[ -f "$DKMS_CONF" ]] || fail "$DKMS_CONF missing. Run clevo-drivers-g5.sh --apply first."
dkms status "${PKG}/${VER}" | grep -q installed || fail "DKMS build not installed. Run clevo-drivers-g5.sh --apply first."
echo "  OK  patched DKMS build present: $(dkms status "${PKG}/${VER}" | head -1)"
echo "  Fedora release: ${FEDORA_VER}"

# ---------------------------------------------------------------------------
head_ "2. Add tuxedo_io (TCC hardware interface) to the DKMS build"
if grep -q 'tuxedo_io' "$DKMS_CONF"; then
  echo "  already in dkms.conf"
else
  echo "  appends to $DKMS_CONF:"
  echo '    BUILT_MODULE_NAME[4]="tuxedo_io"  BUILT_MODULE_LOCATION[4]="tuxedo_io/"'
  if [[ "$MODE" == "apply" ]]; then
    cat >> "$DKMS_CONF" <<'EOF'
# tuxedo_io (TCC)
BUILT_MODULE_NAME[4]="tuxedo_io"
BUILT_MODULE_LOCATION[4]="tuxedo_io/"
DEST_MODULE_LOCATION[4]="/extra"
EOF
  fi
  rebuild_dkms
fi
run modprobe tuxedo_io
if [[ "$MODE" == "apply" ]]; then
  [[ -e /dev/tuxedo_io ]] && echo "  OK  /dev/tuxedo_io present" || fail "/dev/tuxedo_io missing after modprobe"
fi

# ---------------------------------------------------------------------------
head_ "3. Shim package: Provides tuxedo-drivers = ${VER}"
if rpm -q "$SHIM_NAME" >/dev/null 2>&1; then
  echo "  already installed"
else
  run dnf install -y rpm-build
  if [[ "$MODE" == "apply" ]]; then
    TOP="$(mktemp -d)"
    mkdir -p "$TOP"/{SPECS,RPMS,BUILD,SOURCES,SRPMS}
    cat > "$TOP/SPECS/shim.spec" <<EOF
Name:      ${SHIM_NAME}
Version:   ${VER}
Release:   1%{?dist}
Summary:   Satisfies tuxedo-drivers dependency with a local patched DKMS build
License:   GPL-2.0-or-later
BuildArch: noarch
Provides:  tuxedo-drivers = ${VER}
Conflicts: tuxedo-drivers < ${VER}
%description
Placeholder. The real modules come from the local DKMS package ${PKG}/${VER}
(patched to run on non-TUXEDO Clevo hardware). Installed by tcc-install.sh.
%files
EOF
    rpmbuild -bb --define "_topdir $TOP" "$TOP/SPECS/shim.spec" >/dev/null
    run dnf install -y "$TOP"/RPMS/noarch/${SHIM_NAME}-*.rpm
    rm -rf "$TOP"
  else
    echo "  [dry-run] rpmbuild a noarch ${SHIM_NAME} with 'Provides: tuxedo-drivers = ${VER}' and install it"
  fi
fi

# ---------------------------------------------------------------------------
head_ "4. TUXEDO repo, restricted to tuxedo-control-center"
echo "  writes $REPO_FILE (includepkgs=tuxedo-control-center)"
if [[ "$MODE" == "apply" ]]; then
  cat > "$REPO_FILE" <<EOF
[tuxedo]
name=TUXEDO Computers (Control Center only)
baseurl=https://rpm.tuxedocomputers.com/fedora/${FEDORA_VER}/x86_64/base
enabled=1
gpgcheck=1
gpgkey=https://rpm.tuxedocomputers.com/fedora/${FEDORA_VER}/0x54840598.pub.asc
skip_if_unavailable=False
includepkgs=tuxedo-control-center
EOF
  dnf makecache --repo tuxedo >/dev/null 2>&1 \
    || { rm -f "$REPO_FILE"; fail "TUXEDO repo for Fedora ${FEDORA_VER} not reachable; repo file removed. Nothing else changed in this step."; }
  echo "  OK  repo reachable"
fi

# ---------------------------------------------------------------------------
head_ "5. Stop kbd-neon (TCC manages keyboard colour)"
if systemctl list-unit-files kbd-neon.service >/dev/null 2>&1 && systemctl is-enabled kbd-neon.service >/dev/null 2>&1; then
  run systemctl disable --now kbd-neon.service
else
  echo "  not active"
fi

# ---------------------------------------------------------------------------
head_ "6. Install TUXEDO Control Center"
run dnf install -y tuxedo-control-center
if [[ "$MODE" == "apply" ]]; then
  systemctl enable --now tccd.service 2>/dev/null || true
  systemctl --no-pager --lines=5 status tccd.service || true
  cat <<'EOF'

Installed. Open "TUXEDO Control Center" from the app menu.

First-run advice for non-TUXEDO hardware:
  - Leave fan control on the default/automatic profile until you have watched
    temperatures under load (sensors, or TCC's dashboard).
  - TCC sets CPU governor/EPP per profile; it will override tuned/KDE power
    profiles while active. Pick one tool to own power management.
  - Charge limit: set it in TCC OR KDE, not both.
EOF
fi
