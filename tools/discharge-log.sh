#!/bin/sh
# discharge-log.sh - append one CSV row per interval with battery uevent fields.
#
# Usage: discharge-log.sh [OUTFILE] [INTERVAL_SECONDS]
#   OUTFILE   default ./discharge-YYYYmmdd-HHMMSS.csv
#   INTERVAL  arg 2, else env INTERVAL, else 60
#   COUNT     env; stop after this many samples (0 or unset = run until Ctrl-C)
# No root needed; reads /sys/class/power_supply/*/uevent.
set -u

PS=/sys/class/power_supply
BAT=$PS/battery/uevent
OUT=${1:-./discharge-$(date +%Y%m%d-%H%M%S).csv}
INTERVAL=${2:-${INTERVAL:-60}}
COUNT=${COUNT:-0}

# Fixed column order so the CSV stays stable across runs.
COLS="status present technology cycle_count voltage_now current_now capacity capacity_level charge_now charge_full charge_full_design energy_now energy_full time_to_empty_now time_to_full_now temp"

case $INTERVAL in ''|*[!0-9]*) echo "discharge-log: bad INTERVAL: $INTERVAL" >&2; exit 2 ;; esac
case $COUNT in ''|*[!0-9]*) echo "discharge-log: bad COUNT: $COUNT" >&2; exit 2 ;; esac

if [ ! -r "$BAT" ]; then
    echo "discharge-log: cannot read $BAT" >&2
    exit 1
fi

# Find the Mains supply (may be absent).
MAINS=
for d in "$PS"/*; do
    [ -r "$d/type" ] || continue
    read -r t < "$d/type" || continue
    if [ "$t" = Mains ]; then
        MAINS=$d/uevent
        break
    fi
done

# extract FILE KEY...: print values for the given lowercase keys, comma separated, empty if absent.
extract() {
    awk -F= -v cols="$2" '
        /^POWER_SUPPLY_/ {
            k = substr($1, 14)
            map[tolower(k)] = substr($0, length($1) + 2)
        }
        END {
            n = split(cols, c, " ")
            for (i = 1; i <= n; i++) {
                printf "%s%s", (i > 1 ? "," : ""), (c[i] in map ? map[c[i]] : "")
            }
            printf "\n"
        }' "$1"
}

# Header only when starting a new (or empty) file, so appends keep one header.
if [ ! -s "$OUT" ]; then
    hdr="iso_timestamp,epoch"
    for c in $COLS; do hdr="$hdr,$c"; done
    printf '%s,online\n' "$hdr" > "$OUT" || exit 1
fi

stop() {
    echo "discharge-log: stopped after $n sample(s) -> $OUT" >&2
    exit 0
}
trap stop INT TERM

n=0
while :; do
    ts=$(date +%Y-%m-%dT%H:%M:%S%z)
    ep=$(date +%s)
    fields=$(extract "$BAT" "$COLS")
    online=
    if [ -n "$MAINS" ] && [ -r "$MAINS" ]; then
        online=$(extract "$MAINS" "online" | tr -d '\n')
    fi
    printf '%s,%s,%s,%s\n' "$ts" "$ep" "$fields" "$online" >> "$OUT" || exit 1
    n=$((n + 1))
    if [ "$COUNT" -gt 0 ] && [ "$n" -ge "$COUNT" ]; then
        break
    fi
    sleep "$INTERVAL"
done
echo "discharge-log: wrote $n sample(s) -> $OUT" >&2
