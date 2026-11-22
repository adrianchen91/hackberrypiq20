#!/bin/sh
# baseline.sh - READ-ONLY snapshot of a HackberryPi CM5 device (P0.1).
#
# Usage: tools/baseline.sh [OUTDIR]
#   OUTDIR defaults to ./baseline-<hostname>-<YYYYmmdd-HHMMSS>
#
# Never uses sudo, never writes to /boot, and only writes inside OUTDIR.
# Every item is optional: a missing command or unreadable file is recorded
# as "n/a" or "needs root" in its output file and the script carries on.
set -eu

OUT=${1:-./baseline-$(hostname)-$(date +%Y%m%d-%H%M%S)}
mkdir -p "$OUT"
LOG="$OUT/summary.txt"
: > "$LOG"

note() {
    printf '%s\n' "$*" >> "$LOG"
}

# run_to NAME CMD [ARGS...]
# Runs CMD, capturing stdout+stderr into $OUT/NAME. Never aborts.
run_to() {
    name=$1
    shift
    dest=$OUT/$name
    mkdir -p "$(dirname "$dest")"
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "n/a: $1 not found" > "$dest"
        note "$name: n/a ($1 not found)"
        return 0
    fi
    rc=0
    "$@" > "$dest" 2>&1 || rc=$?
    if [ "$rc" -ne 0 ]; then
        if grep -qiE 'permission denied|operation not permitted|must be root|need.*root' "$dest"; then
            echo "needs root" >> "$dest"
            note "$name: needs root"
        else
            echo "n/a: exit $rc" >> "$dest"
            note "$name: n/a (exit $rc)"
        fi
    else
        note "$name: ok"
    fi
    return 0
}

{
    echo "host: $(hostname)"
    echo "date: $(date '+%Y-%m-%d %H:%M:%S %z')"
    echo "user: $(id -un 2>/dev/null || echo unknown) (uid $(id -u 2>/dev/null || echo ?))"
} > "$OUT/host.txt"
note "host.txt: ok"

# 1. power_supply uevents
mkdir -p "$OUT/power_supply"
ps_found=0
for d in /sys/class/power_supply/*; do
    [ -e "$d/uevent" ] || continue
    ps_found=1
    n=$(basename "$d")
    if ! cat "$d/uevent" > "$OUT/power_supply/$n.uevent" 2>&1; then
        echo "n/a: unreadable" > "$OUT/power_supply/$n.uevent"
    fi
done
if [ "$ps_found" -eq 1 ]; then
    note "power_supply/*.uevent: ok"
else
    echo "n/a: no /sys/class/power_supply/*/uevent" > "$OUT/power_supply/none.txt"
    note "power_supply/*.uevent: n/a (none present)"
fi

# 2. I2C buses
run_to i2cdetect-l.txt i2cdetect -l

# 3. Kernel release
run_to uname-r.txt uname -r

# 4. Live overlay, decompiled read-only (dtc writes to stdout only)
if [ -r /boot/firmware/overlays/hackberrypicm5.dtbo ]; then
    run_to hackberrypicm5.dtbo.dts dtc -q -I dtb -O dts /boot/firmware/overlays/hackberrypicm5.dtbo
else
    echo "n/a: /boot/firmware/overlays/hackberrypicm5.dtbo not readable" > "$OUT/hackberrypicm5.dtbo.dts"
    note "hackberrypicm5.dtbo.dts: n/a (not readable)"
fi

# 5. /proc/device-tree summary of i2c-gpio nodes and their children
dt_out=$OUT/device-tree-i2c-gpio.txt
: > "$dt_out"
# prop FILE: print a DT property as text, or "(none)" if absent (errors silenced).
prop() {
    if [ -r "$1" ]; then
        tr '\0' ' ' < "$1" 2>/dev/null
        echo
    else
        echo "(none)"
    fi
}
if [ -d /proc/device-tree/ ]; then
    find /proc/device-tree/ -name compatible 2>/dev/null | while read -r f; do
        if tr '\0' '\n' < "$f" 2>/dev/null | grep -q 'i2c-gpio'; then
            node=$(dirname "$f")
            {
                echo "== $node"
                echo "compatible: $(prop "$f")"
                echo "status: $(prop "$node/status")"
                for c in "$node"/*/; do
                    [ -d "$c" ] || continue
                    echo "  child: $(basename "$c")"
                    echo "    compatible: $(prop "$c/compatible")"
                    if [ -r "$c/reg" ]; then
                        echo "    reg: $(od -An -tx1 "$c/reg" 2>/dev/null | tr -s ' ')"
                    else
                        echo "    reg: (none)"
                    fi
                done
            } >> "$dt_out"
        fi
    done
    if [ -s "$dt_out" ]; then
        note "device-tree-i2c-gpio.txt: ok"
    else
        echo "n/a: no i2c-gpio nodes found in /proc/device-tree" >> "$dt_out"
        note "device-tree-i2c-gpio.txt: n/a (no i2c-gpio nodes)"
    fi
else
    echo "n/a: /proc/device-tree not present" > "$dt_out"
    note "device-tree-i2c-gpio.txt: n/a (no /proc/device-tree)"
fi

# 6. Module srcversion and file path for both module name spellings
run_to modinfo-max17048.txt sh -c 'for m in hackberrypi_max17048 hackberrypi-max17048; do echo "== $m"; echo "srcversion: $(modinfo -F srcversion "$m" 2>&1)"; echo "path: $(modinfo -n "$m" 2>&1)"; done; true'

# 7. dmesg, filtered (only if readable without root)
dmesg_out=$(dmesg 2>&1) && dmesg_rc=0 || dmesg_rc=$?
if [ "$dmesg_rc" -ne 0 ]; then
    if printf '%s' "$dmesg_out" | grep -qiE 'permission denied|operation not permitted|must be root'; then
        echo "needs root" > "$OUT/dmesg-filtered.txt"
        note "dmesg-filtered.txt: needs root"
    else
        echo "n/a: dmesg exit $dmesg_rc" > "$OUT/dmesg-filtered.txt"
        note "dmesg-filtered.txt: n/a (dmesg exit $dmesg_rc)"
    fi
else
    printf '%s\n' "$dmesg_out" | grep -Ei 'i2c|edt_ft5x06|max17048|dpi|panel' > "$OUT/dmesg-filtered.txt" || true
    note "dmesg-filtered.txt: ok"
fi

# 8. config.txt, readable copy only (never written)
if cat /boot/firmware/config.txt > "$OUT/config.txt" 2>"$OUT/config.txt.err"; then
    rm -f "$OUT/config.txt.err"
    note "config.txt: ok"
else
    if grep -qiE 'permission denied|operation not permitted' "$OUT/config.txt.err"; then
        echo "needs root" > "$OUT/config.txt"
        note "config.txt: needs root"
    else
        echo "n/a: /boot/firmware/config.txt not readable" > "$OUT/config.txt"
        note "config.txt: n/a (not readable)"
    fi
    rm -f "$OUT/config.txt.err"
fi

# 9. Loaded max17 modules
run_to lsmod-max17.txt sh -c 'lsmod | grep -i max17 || echo "no max17 module loaded"'

# 10. DKMS status
run_to dkms-status.txt dkms status

note "done: output in $OUT"
cat "$LOG"
exit 0
