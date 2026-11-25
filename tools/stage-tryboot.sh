#!/usr/bin/env bash
# Stage the repo overlay plus config.txt tuning for a one-shot tryboot test.
#
# Usage: sudo tools/stage-tryboot.sh [--params P] [--no-config-tweaks] [--dry-run]
#   --params P          overlay params for the test, comma separated
#                       (default "hw_i2c,i2c_hz=400000"; "" tests the overlay alone)
#   --no-config-tweaks  only swap the overlay; leave the display lines alone
#   --dry-run           write nothing; print the tryboot.txt diff (no root needed)
#
# What it does (never touches config.txt or the installed hackberrypicm5.dtbo):
#   1. Compiles hackberrypicm5.dts to hackberrypicm5-next.dtbo and installs it
#      atomically into overlays/ and, if config.txt sets os_prefix, into
#      <os_prefix>overlays/ as well (the firmware reads overlays from there).
#   2. Writes tryboot.txt = config.txt with:
#      - the managed dtoverlay=hackberrypicm5 line pointed at hackberrypicm5-next,P
#        (dtparam lines inside the managed block are dropped: P replaces them)
#      - config tweaks (unless --no-config-tweaks):
#          display_auto_detect=0 (the overlay drives the panel; skips DSI probing)
#          enable_dpi_lcd, display_default_lcd, dpi_group removed (legacy
#            firmware-framebuffer DPI settings, unused with KMS + this overlay)
#      The fan curve is not a config tweak: the overlay sets it (fragments
#      9-13, "fan_stock" keeps the firmware's), so dtparam=fan_temp* lines are
#      left alone and the overlay overrides them.
#
# Then: sudo reboot '0 tryboot'. A hang or black screen recovers with a power
# cycle, which boots the normal config.txt. See docs/device-test-runbook.md
# ("Stage 5") for the checks and how to promote the result.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# sudo's secure_path can omit /usr/local/bin, where dtmerge is often installed.
case ":$PATH:" in *:/usr/local/bin:*) ;; *) PATH="$PATH:/usr/local/sbin:/usr/local/bin" ;; esac
export PATH
FW=${HB_FIRMWARE_DIR:-/boot/firmware}
CONFIG="$FW/config.txt"
TRYBOOT="$FW/tryboot.txt"
DTS="$REPO_ROOT/hackberrypicm5.dts"
NEXT=hackberrypicm5-next
PARAMS="hw_i2c,i2c_hz=400000"
TWEAKS=1
DRY=0

die() { echo "stage-tryboot: $*" >&2; exit 1; }

while (($#)); do
  case $1 in
    --params) [[ $# -ge 2 ]] || die "--params needs a value"; PARAMS=$2; shift 2 ;;
    --no-config-tweaks) TWEAKS=0; shift ;;
    --dry-run) DRY=1; shift ;;
    -h|--help) sed -n '2,27p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[[ $PARAMS =~ ^[A-Za-z0-9_=,]*$ ]] || die "params may only contain letters, digits, _ = ,"
[[ -r $CONFIG ]] || die "cannot read $CONFIG"
command -v dtc >/dev/null || die "dtc not found (apt install device-tree-compiler)"
if ((!DRY)); then
  [[ $EUID -eq 0 ]] || die "run with sudo (or use --dry-run)"
  touch "$FW/.hb-rw-test" 2>/dev/null && rm -f "$FW/.hb-rw-test" || die "$FW is not writable"
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# 1. Compile. -@ keeps __symbols__ so later overlays can reference our labels.
dtc -q -@ -I dts -O dtb -o "$WORK/$NEXT.dtbo" "$DTS" || die "dtc failed on $DTS"
if [[ -x $REPO_ROOT/tools/validate-overlay.sh ]]; then
  "$REPO_ROOT/tools/validate-overlay.sh" "$DTS" >"$WORK/validate.log" 2>&1 ||
    { tail -n 20 "$WORK/validate.log" >&2; die "tools/validate-overlay.sh failed; not staging"; }
fi

# Last os_prefix= line wins in the firmware too (conditional sections ignored:
# this board only ever matches [all]/[cm5]/[pi5]).
# Same parsing as the package postinst (prefix_overlay_dir).
OS_PREFIX=$(sed -n 's/^[[:space:]]*os_prefix=\([^[:space:]#]*\).*/\1/p' "$CONFIG" | tail -n 1)
[[ $OS_PREFIX != *..* && $OS_PREFIX != /* ]] || die "unexpected os_prefix '$OS_PREFIX'"
OVL_DIRS=("$FW/overlays")
[[ -n $OS_PREFIX ]] && OVL_DIRS+=("$FW/${OS_PREFIX}overlays")

# 2. Build tryboot.txt.
LINE="dtoverlay=$NEXT${PARAMS:+,$PARAMS}"
awk -v line="$LINE" -v tweaks="$TWEAKS" '
  BEGIN { inblk = 0; done = 0 }
  /^# BEGIN hackberrypi \(managed\)/ { inblk = 1; print; next }
  /^# END hackberrypi/              { inblk = 0; print; next }
  inblk && /^dtoverlay=hackberrypicm5([,[:space:]]|$)/ {
    if (!done) print line; done = 1; next
  }
  # The test params replace the block'"'"'s own dtparam lines (--params "" must
  # really mean no params, and the default must not set them twice).
  inblk && /^[[:space:]]*dtparam=/ { next }
  tweaks && /^[[:space:]]*display_auto_detect=/ { print "display_auto_detect=0"; next }
  tweaks && /^[[:space:]]*(enable_dpi_lcd|display_default_lcd|dpi_group)=/ { next }
  { print }
  END { if (!done) exit 3 }
' "$CONFIG" >"$WORK/tryboot.txt" || {
  rc=$?
  ((rc == 3)) && die "no dtoverlay=hackberrypicm5 line inside the managed block of $CONFIG"
  die "building tryboot.txt failed"
}

if ((DRY)); then
  echo "== would install $NEXT.dtbo into: ${OVL_DIRS[*]}"
  echo "== tryboot.txt vs config.txt:"
  diff -u --label config.txt --label tryboot.txt "$CONFIG" "$WORK/tryboot.txt" || true
  exit 0
fi

# Atomic install: temp file in the target dir, sync, rename.
install_atomic() { # SRC DEST
  local tmp="$2.tmp.$$"
  cp "$1" "$tmp" && sync "$tmp" && mv -f "$tmp" "$2" && sync "$(dirname "$2")"
}
for d in "${OVL_DIRS[@]}"; do
  [[ -d $d ]] || die "overlay dir $d does not exist; nothing was written"
done
for d in "${OVL_DIRS[@]}"; do
  install_atomic "$WORK/$NEXT.dtbo" "$d/$NEXT.dtbo"
  echo "installed $d/$NEXT.dtbo"
done
[[ -e $TRYBOOT ]] && cp -a "$TRYBOOT" "$TRYBOOT.prev"
install_atomic "$WORK/tryboot.txt" "$TRYBOOT"
echo "wrote $TRYBOOT:"
diff -u --label config.txt --label tryboot.txt "$CONFIG" "$TRYBOOT" || true
cat <<EOF

Next: sudo reboot '0 tryboot'
A hang or black screen: power-cycle; the normal config.txt boots.
EOF
