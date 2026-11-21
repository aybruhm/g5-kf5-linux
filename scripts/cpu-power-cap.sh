#!/usr/bin/env bash
# cpu-power-cap.sh
#
# Caps the CPU package power (Intel RAPL) so the whole laptop stays under what a
# 100 W USB-C PD trigger cable can supply. Reverts on reboot or with "off".
#
#   sudo ./cpu-power-cap.sh status          # show current limits
#   sudo ./cpu-power-cap.sh on              # USB-C cap: 35 W sustained, 45 W burst
#   sudo ./cpu-power-cap.sh on 25 35        # custom: sustained W, burst W
#   sudo ./cpu-power-cap.sh off             # restore the limits saved before "on"
#
# PL1 (long_term) = sustained limit, PL2 (short_term) = burst limit.

set -euo pipefail

RAPL=/sys/class/powercap/intel-rapl:0
SAVE=/run/cpu-power-cap.saved

[[ -d "$RAPL" ]] || { echo "Intel RAPL not found at $RAPL" >&2; exit 1; }

limit_file() {  # $1 = long_term | short_term
  for c in "$RAPL"/constraint_*_name; do
    if [[ "$(cat "$c")" == "$1" ]]; then echo "${c%_name}_power_limit_uw"; return; fi
  done
  echo "No $1 constraint under $RAPL" >&2; exit 1
}

PL1="$(limit_file long_term)"
PL2="$(limit_file short_term)"

watts() { awk -v u="$(cat "$1")" 'BEGIN{printf "%.0f W", u/1e6}'; }

status() {
  echo "Sustained (PL1): $(watts "$PL1")"
  echo "Burst     (PL2): $(watts "$PL2")"
  [[ -f "$SAVE" ]] && echo "Cap is ON (originals saved; 'off' restores them)" || echo "Cap is OFF"
}

case "${1:-status}" in
  status)
    status
    ;;
  on)
    [[ $EUID -eq 0 ]] || { echo "Run with sudo" >&2; exit 1; }
    pl1_w="${2:-35}"; pl2_w="${3:-45}"
    (( pl2_w >= pl1_w )) || { echo "Burst must be >= sustained" >&2; exit 1; }
    [[ -f "$SAVE" ]] || printf '%s %s\n' "$(cat "$PL1")" "$(cat "$PL2")" > "$SAVE"
    echo $(( pl2_w * 1000000 )) > "$PL2"
    echo $(( pl1_w * 1000000 )) > "$PL1"
    status
    ;;
  off)
    [[ $EUID -eq 0 ]] || { echo "Run with sudo" >&2; exit 1; }
    if [[ -f "$SAVE" ]]; then
      read -r orig1 orig2 < "$SAVE"
      echo "$orig1" > "$PL1"
      echo "$orig2" > "$PL2"
      rm -f "$SAVE"
    else
      echo "No saved limits (cap was not on, or you rebooted, which already restored them)."
    fi
    status
    ;;
  *)
    echo "Usage: sudo $0 {status|on [sustained_W burst_W]|off}" >&2; exit 1
    ;;
esac
