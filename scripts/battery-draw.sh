#!/usr/bin/env bash
# battery-draw.sh
#
# Measures real system power draw on battery, two independent ways:
#   1. Instantaneous: current_now x voltage_now (or power_now where exposed),
#      averaged over the run
#   2. Charge counter: drop in charge_now (or energy_now) over the run,
#      converted to watts. Slower, but immune to a noisy current sensor.
# upower's energy-rate can be inflated on some firmware; these read sysfs directly.
#
#   ./battery-draw.sh            # 60 s run, 2 s samples
#   ./battery-draw.sh 300 5      # 300 s run, 5 s samples
#
# Unplug the charger first. No root needed.

set -euo pipefail

DURATION="${1:-60}"
INTERVAL="${2:-2}"

PS_DIR="${PS_DIR:-/sys/class/power_supply}"   # override only for testing
BAT="$(find "$PS_DIR" -maxdepth 1 -name 'BAT*' | sort | head -1)"
[[ -n "$BAT" ]] || { echo "No battery found under $PS_DIR" >&2; exit 1; }

status="$(cat "$BAT/status")"
if [[ "$status" != "Discharging" ]]; then
  echo "Battery status is '$status'. Unplug the charger and run again." >&2
  exit 1
fi

read_file() { [[ -r "$BAT/$1" ]] && cat "$BAT/$1" || echo ""; }

# Instantaneous power in microwatts
inst_uw() {
  local p v i
  p="$(read_file power_now)"
  if [[ -n "$p" && "$p" != "0" ]]; then echo "$p"; return; fi
  v="$(read_file voltage_now)"; i="$(read_file current_now)"
  [[ -n "$v" && -n "$i" ]] || { echo 0; return; }
  i="${i#-}"                               # some firmware reports negative current
  echo $(( i * v / 1000000 ))              # uA * uV / 1e6 = uW
}

# Stored energy in microwatt-hours (from energy_now, or charge_now x voltage)
energy_uwh() {
  local e c v
  e="$(read_file energy_now)"
  if [[ -n "$e" ]]; then echo "$e"; return; fi
  c="$(read_file charge_now)"; v="$(read_file voltage_min_design)"
  [[ -n "$v" && "$v" != "0" ]] || v="$(read_file voltage_now)"
  echo $(( c * v / 1000000 ))              # uAh * uV / 1e6 = uWh
}

echo "Battery: $BAT   capacity: $(read_file capacity)%   run: ${DURATION}s, sample every ${INTERVAL}s"
echo "Keep your normal workload running. Ctrl+C stops early and still prints results."
echo

samples=0; sum_uw=0
start_e="$(energy_uwh)"; start_t="$(date +%s)"

report() {
  local end_e end_t dt avg_w counter_w
  end_e="$(energy_uwh)"; end_t="$(date +%s)"; dt=$(( end_t - start_t ))
  echo
  if (( samples > 0 )); then
    avg_w="$(awk -v s="$sum_uw" -v n="$samples" 'BEGIN{printf "%.1f", s/n/1e6}')"
    echo "Instantaneous (current x voltage), average of $samples samples: ${avg_w} W"
  fi
  if (( dt > 0 && start_e > end_e )); then
    counter_w="$(awk -v d=$(( start_e - end_e )) -v t="$dt" 'BEGIN{printf "%.1f", d/1e6*3600/t}')"
    echo "Charge counter, over ${dt}s:                               ${counter_w} W"
  else
    echo "Charge counter: no drop recorded yet (run longer; the gauge updates in steps)"
  fi
  local full_wh
  full_wh="$(awk -v e="$end_e" 'BEGIN{printf "%.1f", e/1e6}')"
  if [[ -n "${avg_w:-}" ]] && awk -v w="$avg_w" 'BEGIN{exit !(w>0)}'; then
    echo "Remaining at this rate: $(awk -v e="$full_wh" -v w="$avg_w" 'BEGIN{printf "%.1f", e/w}') h (${full_wh} Wh left)"
  fi
  exit 0
}
trap report INT

end=$(( start_t + DURATION ))
while (( $(date +%s) < end )); do
  uw="$(inst_uw)"
  sum_uw=$(( sum_uw + uw )); samples=$(( samples + 1 ))
  printf '  %3ds  %6.1f W\n' "$(( $(date +%s) - start_t ))" "$(awk -v u="$uw" 'BEGIN{print u/1e6}')"
  sleep "$INTERVAL"
done
report
