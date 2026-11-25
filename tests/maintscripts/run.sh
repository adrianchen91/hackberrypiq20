#!/bin/sh
# Test harness for debian/hackberrypi-max17048-dkms.{preinst,postinst,postrm}.
#
# Builds a fake boot partition per scenario under $TMPDIR and replays the
# maintainer-script sequences dpkg runs:
#   install:  new preinst install; new postinst configure
#   upgrade:  new preinst upgrade <old>; (unpack); old postrm upgrade <new>;
#             new postinst configure <old>
#   remove:   postrm remove
#   purge:    postrm remove; postrm purge
# "Old" 1.1 scripts are taken from git (commit 1f7b8c9) with their hardcoded
# paths rewritten into the sandbox.
#
# Never touches the real /boot/firmware (read-only copies only) and refuses
# to run as root. The real files are checksummed before and after.
#
# Usage: tests/maintscripts/run.sh [-v]
#   MS_SHELLS  shells to run the scripts with (default: "dash bash busybox")
#   MS_AWKS    awk implementations          (default: "mawk gawk")

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
VERBOSE=0
[ "${1:-}" = "-v" ] && VERBOSE=1

OLD_REV="1f7b8c9"
OVL="hackberrypicm5"
REAL_BOOT="/boot/firmware"
REAL_BASE_DTB="$REAL_BOOT/bcm2712-rpi-cm5-cm5io.dtb"
REAL_FILES="$REAL_BOOT/config.txt $REAL_BOOT/overlays/$OVL.dtbo /usr/share/keyrings/hackberrypi-max17048.gpg /etc/apt/sources.list.d/hackberrypi-max17048.sources /var/lib/hackberrypi-max17048-dkms"
BM="# BEGIN hackberrypi (managed)"
EM="# END hackberrypi"

if [ "$(id -u)" = 0 ]; then
    echo "refusing to run as root" >&2
    exit 2
fi
for t in dtc git cmp sha256sum; do
    command -v "$t" > /dev/null 2>&1 || { echo "missing tool: $t" >&2; exit 2; }
done
if [ ! -f "$REAL_BASE_DTB" ]; then
    echo "missing $REAL_BASE_DTB (needed read-only as the dtmerge base)" >&2
    exit 2
fi

T="$(mktemp -d "${TMPDIR:-/tmp}/maintscripts.XXXXXX")" || exit 2
trap 'chmod -R u+w "$T" 2>/dev/null; rm -rf "$T"' EXIT

real_sums() {
    for f in $REAL_FILES; do
        if [ -d "$f" ]; then echo "dir $f"; elif [ -e "$f" ]; then sha256sum "$f"; else echo "absent $f"; fi
    done
}
REAL_BEFORE="$(real_sums)"

# ------------------------------------------------------------ fixtures

PASS=0
FAIL=0
FAILED_NAMES=""
CUR=""

ok() { PASS=$((PASS + 1)); [ "$VERBOSE" = 1 ] && echo "    ok   $CUR: $1"; return 0; }
bad() {
    FAIL=$((FAIL + 1))
    FAILED_NAMES="$FAILED_NAMES
  $COMBO $CUR: $1"
    echo "    FAIL $CUR: $1"
    return 0
}
check() { # check <description> <command...>
    hb_d="$1"; shift
    if "$@"; then ok "$hb_d"; else bad "$hb_d"; fi
}

# dh replaces EVERY occurrence of the debhelper token, comments included, so
# it must appear exactly once per script, alone on its line.
CUR="debhelper-token"
for hb_s in preinst postinst postrm; do
    hb_f="$REPO/debian/hackberrypi-max17048-dkms.$hb_s"
    [ -f "$hb_f" ] || continue
    check "$hb_s: token appears once" test "$(grep -c '#DEBHELPER#' "$hb_f")" = 1
    check "$hb_s: token alone on its line" test "$(grep -c '^#DEBHELPER#$' "$hb_f")" = 1
done

FIX="$T/fixtures"
mkdir -p "$FIX/old" "$FIX/new"
cp "$REPO/hackberrypicm5.dts" "$FIX/good.dts"
cp "$REAL_BASE_DTB" "$FIX/base.dtb"
# Once the package is installed the live config carries our managed block;
# the "live" fixture stands for a config before install, so drop the block.
sed "/^$BM\$/,/^$EM\$/d" "$REAL_BOOT/config.txt" > "$FIX/live-config.txt"
# The live config no longer carries the old GPIO3/4 i2c-gpio line once the
# package is installed; the "live" fixture must still have it to test the warning.
if ! grep -q '^dtoverlay=i2c-gpio,bus=11,i2c_gpio_sda=3,i2c_gpio_scl=4' "$FIX/live-config.txt"; then
    { echo "dtoverlay=i2c-gpio,bus=11,i2c_gpio_sda=3,i2c_gpio_scl=4"; cat "$FIX/live-config.txt"; } > "$FIX/live-config.tmp"
    mv "$FIX/live-config.tmp" "$FIX/live-config.txt"
fi
if [ -f "$REAL_BOOT/overlays/$OVL.dtbo" ]; then
    cp "$REAL_BOOT/overlays/$OVL.dtbo" "$FIX/deployed.dtbo"
else
    dtc -@ -q -I dts -O dtb -o "$FIX/deployed.dtbo" "$FIX/good.dts"
fi
# The installed blob must be exactly "dtc -@" output (what validate-overlay.sh checks).
dtc -@ -q -I dts -O dtb -o "$FIX/good.dtbo" "$FIX/good.dts" || { echo "repo DTS does not compile" >&2; exit 2; }
{ cat "$FIX/good.dts"; echo "this is not valid dts syntax {{{"; } > "$FIX/broken.dts"
cat > "$FIX/unmergeable.dts" << 'EOF'
/dts-v1/;
/plugin/;
/ {
	compatible = "brcm,bcm2712";
	fragment@0 {
		target = <&no_such_label_in_base_dtb>;
		__overlay__ { status = "okay"; };
	};
};
EOF

# New scripts with the literal #DEBHELPER# token removed.
for s in preinst postinst postrm; do
    grep -q '^#DEBHELPER#$' "$REPO/debian/hackberrypi-max17048-dkms.$s" ||
        { echo "#DEBHELPER# missing from $s" >&2; exit 2; }
    sed '/^#DEBHELPER#$/d' "$REPO/debian/hackberrypi-max17048-dkms.$s" > "$FIX/new/$s"
done

# Old (1.1) scripts: hardcoded paths are rewritten to placeholders that are
# resolved per scenario via env. Abort if any real path survives.
for s in preinst postinst postrm; do
    git -C "$REPO" show "$OLD_REV:debian/hackberrypi-max17048-dkms.$s" |
        sed -e '/^#DEBHELPER#$/d' \
            -e 's|/boot/firmware|${FAKE_BOOT}|g' \
            -e 's|/usr/share/keyrings/|${FAKE_KEYRINGS}/|g' \
            -e 's|/etc/apt/sources.list.d/|${FAKE_SOURCES}/|g' \
            -e 's|/usr/src/${DKMS_NAME}-${DKMS_VERSION}|${FAKE_SRC}|g' > "$FIX/old/$s"
    if grep -nE '/boot|/usr/share|/etc/|/usr/src' "$FIX/old/$s"; then
        echo "old $s still references real paths; refusing to run it" >&2
        exit 2
    fi
done

mkconfig() { # mkconfig <variant> <file>
    case "$1" in
        all) printf '%s\n' "# test config" "dtparam=audio=on" "[cm4]" "otg_mode=1" "[all]" \
                "dtoverlay=vc4-kms-v3d-pi5" > "$2" ;;
        cm4) printf '%s\n' "dtparam=audio=on" "[all]" "arm_boost=1" "[cm4]" "otg_mode=1" > "$2" ;;
        empty) : > "$2" ;;
        legacy) mkconfig all "$2"; echo "dtoverlay=$OVL" >> "$2" ;;
        legacy-cm4) mkconfig cm4 "$2"; echo "dtoverlay=$OVL" >> "$2" ;;
        conflict) mkconfig all "$2"
            printf '%s\n' "dtoverlay=i2c-gpio,bus=11,i2c_gpio_sda=3,i2c_gpio_scl=4" \
                "dtparam=i2c_arm=on" "dtoverlay=spi1-1cs" "#dtoverlay=i2c-gpio" >> "$2" ;;
        live) cp "$FIX/live-config.txt" "$2" ;;
        crlf-nonl) printf 'dtparam=audio=on\r\n[all]\r\narm_boost=1\r\n[cm5]\r\ndtoverlay=dwc2,dr_mode=host' > "$2" ;;
        include) printf '%s\n' "dtparam=audio=on" "[all]" "include extra.txt" > "$2" ;;
        userparam) mkconfig all "$2"; echo "dtoverlay=$OVL,touch_inv_x" >> "$2" ;;
        malformed) mkconfig all "$2"; printf '%s\n' "$BM" "dtoverlay=$OVL" >> "$2" ;;
        legacy-params) printf '%s\n' "# cfg" "dtparam=audio=on" "[all]" "dtoverlay=vc4-kms-v3d-pi5" \
                "dtoverlay=$OVL" "dtparam=touch_inv_x" "dtparam=pclk=35000000" "dtparam=fan_temp0=40000" \
                "[cm4]" "otg_mode=1" > "$2" ;;
        legacy-cm4-params) mkconfig cm4 "$2"; printf '%s\n' "dtoverlay=$OVL" "dtparam=touch_inv_y" >> "$2" ;;
        orphan) mkconfig all "$2"; echo "dtparam=touch_inv_x" >> "$2" ;;
        userref-comment) mkconfig all "$2"; echo "dtoverlay=$OVL #note" >> "$2" ;;
        userref-tab) mkconfig all "$2"; printf 'dtoverlay=%s\tx\n' "$OVL" >> "$2" ;;
        *) echo "unknown config variant $1" >&2; exit 2 ;;
    esac
}

# new_env <name> <config-variant>: sandbox with fake boot partition, apt
# keyring/sources (as the user's install instructions create them), src dir.
new_env() {
    CUR="$1"
    E="$T/$COMBO/$1"
    B="$E/boot"
    mkdir -p "$B/overlays" "$E/src" "$E/keyrings" "$E/sources" "$E/tmp"
    cp "$FIX/base.dtb" "$B/bcm2712-rpi-cm5-cm5io.dtb"
    cp "$FIX/good.dts" "$E/src/$OVL.dts"
    mkconfig "$2" "$B/config.txt"
    cp "$B/config.txt" "$E/config.pristine"
    echo "fake keyring" > "$E/keyrings/hackberrypi-max17048.gpg"
    echo "Types: deb" > "$E/sources/hackberrypi-max17048.sources"
    : > "$E/log"
}

# ms <new|old> <script> <args...>: run a maintainer script in the sandbox.
ms() {
    hb_ver="$1"; hb_s="$2"; shift 2
    echo "== $hb_ver $hb_s $*" >> "$E/log"
    env HACKBERRYPI_MAINTSCRIPT_TEST=1 BOOT_DIR="$B" \
        KEYRING="$E/keyrings/hackberrypi-max17048.gpg" \
        SOURCES_LIST="$E/sources/hackberrypi-max17048.sources" \
        SRC_DIR="$E/src" STATE_DIR="$E/state" TMPDIR="$E/tmp" \
        FAKE_BOOT="$B" FAKE_KEYRINGS="$E/keyrings" FAKE_SOURCES="$E/sources" FAKE_SRC="$E/src" \
        PATH="$AWKBIN:$PATH" \
        $MS_SHELL "$FIX/$hb_ver/$hb_s" "$@" >> "$E/log" 2>&1
    hb_rc=$?
    echo "== rc=$hb_rc" >> "$E/log"
    return "$hb_rc"
}

# Sequences (return the rc of the failing step, 0 otherwise).
do_install() { ms new preinst install && ms new postinst configure; }
do_install_old() { ms old preinst install && ms old postinst configure; }
do_upgrade() { # do_upgrade <old-scripts:old|new> <oldver> <newver>
    ms new preinst upgrade "$2" || return $?
    ms "$1" postrm upgrade "$3" || { hb_r=$?; ms new postrm failed-upgrade "$2" "$3"; return "$hb_r"; }
    ms new postinst configure "$2"
}
do_remove() { ms new postrm remove; }
do_purge() { ms new postrm remove && ms new postrm purge; }

# ------------------------------------------------------------ assertions
# Written independently of the scripts' own parser.

# Active lines that load our overlay (exact or with parameters).
refs() {
    awk -v o="$OVL" '{ t = $0; sub(/\r$/, "", t); sub(/^[ \t]+/, "", t); sub(/[ \t]+$/, "", t)
        if (t ~ ("^dtoverlay=" o "([ \t#,:.]|$)")) n++ } END { print n + 0 }' "$1"
}
# Every reference is in unconditional scope ([all] or before any filter,
# no include in between).
refs_unconditional() {
    awk -v o="$OVL" 'BEGIN { s = "all"; inc = 0; bad = 0 }
        { t = $0; sub(/\r$/, "", t); sub(/^[ \t]+/, "", t); sub(/[ \t]+$/, "", t)
          if (t ~ /^\[/) { s = tolower(t); sub(/^\[/, "", s); sub(/\].*$/, "", s); inc = 0 }
          else if (t ~ /^include/) inc = 1
          if (t ~ ("^dtoverlay=" o "([ \t#,:.]|$)") && (s != "all" || inc)) bad = 1 }
        END { exit bad }' "$1"
}
# Config with our marker block removed.
outside_block() { sed "/^$BM\$/,/^$EM\$/d" "$1"; }
# Pristine config with legacy bare lines (and the dtparam lines right after
# them that only set this overlay's parameters) removed, newline-terminated.
OVL_PARAMS_RE="^dtparam=((hw_i2c|touch_inv_x|touch_inv_y|touch_swap_xy|no_touch|no_fuelgauge|fuelgauge_mainline|charge_uah|energy_uwh|pclk|i2c_delay_us|i2c_hz|ethernet)(=[^,]*)?)(,(hw_i2c|touch_inv_x|touch_inv_y|touch_swap_xy|no_touch|no_fuelgauge|fuelgauge_mainline|charge_uah|energy_uwh|pclk|i2c_delay_us|i2c_hz|ethernet)(=[^,]*)?)*$"
expected_outside() {
    awk -v o="$OVL" -v re="$OVL_PARAMS_RE" '{ t = $0; sub(/\r$/, "", t); sub(/^[ \t]+/, "", t); sub(/[ \t]+$/, "", t)
        if (t == "dtoverlay=" o) { after = 1; next }
        if (after && t ~ re) next
        after = 0; print }' "$1"
}
# Config with only the marker lines removed (in-place wrap check).
without_markers() { grep -vxF -e "$BM" -e "$EM" "$1"; }
block_lines() { sed -n "/^$BM\$/,/^$EM\$/p" "$1" | tr '\n' '|'; }
hb_awk_of() { sed -n "/^HB_AWK='/,/^}'\$/p" "$1"; }
same_text() { [ "$(cat "$1"; echo x)" = "$(cat "$2"; echo x)" ]; }

dtbo_valid() { # dtbo_valid <dtbo>: parses and applies to the base dtb
    [ -s "$1" ] || return 1
    dtc -q -I dtb -O dts -o /dev/null "$1" || return 1
    if command -v dtmerge > /dev/null 2>&1; then
        # dtmerge rejects overlay paths >= ~256 chars: check a copy at a short path.
        cp "$1" "$T/chk.dtbo" || return 1
        dtmerge "$FIX/base.dtb" "$T/chk-merged.dtb" "$T/chk.dtbo" > /dev/null 2>&1 || return 1
    fi
    return 0
}

no_dangling() { # config.txt never references a missing/invalid dtbo
    [ "$(refs "$B/config.txt")" = 0 ] && return 0
    dtbo_valid "$B/overlays/$OVL.dtbo"
}
no_tmp_left() {
    [ -z "$(find "$B" "$E/tmp" -name '*.tmp' -o -name '*.tmp.1' -o -name '.hackberrypi-wtest*' -o -name 'hackberrypi.*' 2>/dev/null | head -n 1)" ]
}
markers_balanced() {
    [ "$(grep -cx "$BM" "$B/config.txt")" = "$(grep -cx "$EM" "$B/config.txt")" ]
}

# Common post-conditions for a bootable, enabled state.
assert_enabled() { # assert_enabled <expected-dtbo>
    check "exactly one overlay reference" [ "$(refs "$B/config.txt")" = 1 ]
    check "overlay reference is unconditional ([all])" refs_unconditional "$B/config.txt"
    check "no dangling dtbo reference" no_dangling
    check "dtbo is the expected one" cmp -s "$B/overlays/$OVL.dtbo" "$1"
    check "no temp files left" no_tmp_left
    check "markers balanced" markers_balanced
}
assert_preserved() { # lines outside the block are the pristine ones
    outside_block "$B/config.txt" > "$E/outside"
    expected_outside "$E/config.pristine" > "$E/expected"
    check "lines outside marker block preserved byte-for-byte" same_text "$E/outside" "$E/expected"
}
assert_disabled() {
    check "no overlay reference left" [ "$(refs "$B/config.txt")" = 0 ]
    check "no marker block left" [ "$(grep -c "hackberrypi (managed)" "$B/config.txt")" = 0 ]
    check "no dangling dtbo reference" no_dangling
    check "no temp files left" no_tmp_left
}
assert_apt_present() {
    check "apt keyring present" [ -f "$E/keyrings/hackberrypi-max17048.gpg" ]
    check "apt sources present" [ -f "$E/sources/hackberrypi-max17048.sources" ]
}
assert_apt_absent() {
    check "apt keyring removed" [ ! -e "$E/keyrings/hackberrypi-max17048.gpg" ]
    check "apt sources removed" [ ! -e "$E/sources/hackberrypi-max17048.sources" ]
}
rc_is() { [ "$1" = "$2" ]; }
backups_gone() {
    [ ! -e "$B/config.txt.hackberrypi.bak" ] && [ ! -e "$B/config.txt.hackberrypi.orig" ] &&
        [ ! -e "$B/overlays/$OVL.dtbo.prev" ]
}

# ------------------------------------------------------------ scenarios

run_scenarios() {
    # 1. Fresh install on each config variant, then idempotent reconfigure.
    for v in all cm4 empty legacy legacy-cm4 conflict live crlf-nonl include; do
        new_env "install-$v" "$v"
        do_install; check "install exits 0" rc_is $? 0
        assert_enabled "$FIX/good.dtbo"
        assert_preserved
        check "config.txt.hackberrypi.orig is the pristine config" cmp -s "$B/config.txt.hackberrypi.orig" "$E/config.pristine"
        cp "$B/config.txt" "$E/after1"
        cp "$B/config.txt.hackberrypi.bak" "$E/bak1"
        ms new postinst configure 1.2; check "reconfigure exits 0" rc_is $? 0
        check "reconfigure is idempotent (config.txt unchanged)" cmp -s "$B/config.txt" "$E/after1"
        check "reconfigure does not clobber .bak" cmp -s "$B/config.txt.hackberrypi.bak" "$E/bak1"
        # Remove then purge from here.
        do_remove; check "remove exits 0" rc_is $? 0
        assert_disabled
        check "remove deletes dtbo" [ ! -e "$B/overlays/$OVL.dtbo" ]
        expected_outside "$E/config.pristine" > "$E/expected"
        check "remove restores pristine config (minus legacy line)" same_text "$B/config.txt" "$E/expected"
        check "remove keeps apt keyring/sources" [ -f "$E/keyrings/hackberrypi-max17048.gpg" ]
        ms new postrm purge; check "purge exits 0" rc_is $? 0
        assert_disabled
        assert_apt_absent
        check "purge removes backups" backups_gone
        check "purge removes state dir" [ ! -e "$E/state" ]
    done

    # 2. Section placement details.
    new_env "placement-cm4" cm4
    do_install
    check "[all] added inside block when file ends in [cm4]" \
        [ "$(sed -n "/^$BM\$/,/^$EM\$/p" "$B/config.txt" | tr '\n' '|')" = "$BM|[all]|dtoverlay=$OVL|$EM|" ]
    new_env "placement-all" all
    do_install
    check "no extra [all] when file already ends in [all]" \
        [ "$(sed -n "/^$BM\$/,/^$EM\$/p" "$B/config.txt" | tr '\n' '|')" = "$BM|dtoverlay=$OVL|$EM|" ]
    new_env "placement-include" include
    do_install
    check "[all] re-asserted after an include" \
        [ "$(sed -n "/^$BM\$/,/^$EM\$/p" "$B/config.txt" | tr '\n' '|')" = "$BM|[all]|dtoverlay=$OVL|$EM|" ]

    # 3. User adds settings after our [all]-carrying block, then removes the
    #    package: those settings must stay unconditional.
    new_env "remove-keeps-all-scope" cm4
    do_install
    echo "dtparam=user_after=1" >> "$B/config.txt"
    do_remove; check "remove exits 0" rc_is $? 0
    assert_disabled
    check "user line after block stays under [all]" \
        [ "$(tail -n 2 "$B/config.txt" | tr '\n' '|')" = "[all]|dtparam=user_after=1|" ]

    # 4. Upgrade 1.1 -> 1.2: old 1.1 installed, real dpkg order, old postrm.
    for v in all cm4 live; do
        new_env "upgrade-old-$v" "$v"
        do_install_old; check "old 1.1 install exits 0" rc_is $? 0
        cp "$FIX/deployed.dtbo" "$B/overlays/$OVL.dtbo"   # what the device actually runs
        cp "$B/config.txt" "$E/config.pristine"           # pre-upgrade state
        do_upgrade old 1.1 1.2; check "upgrade 1.1->1.2 exits 0" rc_is $? 0
        assert_enabled "$FIX/good.dtbo"
        assert_preserved
        assert_apt_present
        check "previous dtbo kept as .prev" cmp -s "$B/overlays/$OVL.dtbo.prev" "$FIX/deployed.dtbo"
        check "state dir cleaned after configure" [ ! -e "$E/state" ]
    done

    # 5. Upgrade 1.2 -> 1.3 (new scripts on both sides).
    for v in all cm4 legacy; do
        new_env "upgrade-new-$v" "$v"
        do_install
        cp "$B/config.txt" "$E/before"
        ms new postrm upgrade 1.3
        check "postrm upgrade leaves dtbo" cmp -s "$B/overlays/$OVL.dtbo" "$FIX/good.dtbo"
        check "postrm upgrade leaves config.txt" cmp -s "$B/config.txt" "$E/before"
        assert_apt_present
        ms new preinst upgrade 1.2 && ms new postinst configure 1.2
        check "upgrade 1.2->1.3 exits 0" rc_is $? 0
        assert_enabled "$FIX/good.dtbo"
        assert_preserved
        assert_apt_present
    done

    # 6. Failed dtc during upgrade (new -> new): nothing may change.
    new_env "faildtc-new" all
    do_install
    cp "$B/config.txt" "$E/before"
    cp "$FIX/broken.dts" "$E/src/$OVL.dts"
    do_upgrade new 1.2 1.3; check "failed-dtc upgrade exits 0" rc_is $? 0
    check "failed dtc keeps existing dtbo" cmp -s "$B/overlays/$OVL.dtbo" "$FIX/good.dtbo"
    check "failed dtc keeps config.txt" cmp -s "$B/config.txt" "$E/before"
    assert_enabled "$FIX/good.dtbo"
    assert_apt_present
    check "failed dtc is loud" grep -q "could not be built" "$E/log"

    # 7. Failed dtc during upgrade from 1.1 (old postrm deleted dtbo + line).
    for v in all cm4 live; do
        new_env "faildtc-old-$v" "$v"
        do_install_old
        cp "$FIX/deployed.dtbo" "$B/overlays/$OVL.dtbo"
        cp "$B/config.txt" "$E/config.pristine"
        cp "$FIX/broken.dts" "$E/src/$OVL.dts"
        do_upgrade old 1.1 1.2; check "failed-dtc upgrade from 1.1 exits 0" rc_is $? 0
        assert_enabled "$FIX/deployed.dtbo"
        assert_preserved
        assert_apt_present
    done

    # 8. dtmerge validation failure (compiles, does not apply to the base).
    if command -v dtmerge > /dev/null 2>&1; then
        new_env "unmergeable-upgrade" all
        do_install
        cp "$B/config.txt" "$E/before"
        cp "$FIX/unmergeable.dts" "$E/src/$OVL.dts"
        do_upgrade new 1.2 1.3; check "unmergeable upgrade exits 0" rc_is $? 0
        check "unmergeable keeps dtbo" cmp -s "$B/overlays/$OVL.dtbo" "$FIX/good.dtbo"
        check "unmergeable keeps config" cmp -s "$B/config.txt" "$E/before"
        new_env "unmergeable-fresh" cm4
        cp "$FIX/unmergeable.dts" "$E/src/$OVL.dts"
        do_install; check "unmergeable fresh install exits 0" rc_is $? 0
        assert_disabled
        check "unmergeable fresh: no dtbo installed" [ ! -e "$B/overlays/$OVL.dtbo" ]
        check "unmergeable fresh: config untouched" cmp -s "$B/config.txt" "$E/config.pristine"
    else
        echo "    SKIP dtmerge scenarios (dtmerge not installed)"
    fi

    # 9. Fresh install with broken DTS: no dtbo, no config line.
    new_env "faildtc-fresh" all
    cp "$FIX/broken.dts" "$E/src/$OVL.dts"
    do_install; check "failed-dtc fresh install exits 0" rc_is $? 0
    assert_disabled
    check "config untouched" cmp -s "$B/config.txt" "$E/config.pristine"

    # 10. Read-only boot partition.
    new_env "readonly-install" all
    chmod a-w "$B/overlays" "$B" "$B/config.txt"
    ms new preinst install; rc=$?
    check "preinst install aborts with 1 on read-only boot" rc_is "$rc" 1
    check "preinst message is clear" grep -q "not writable" "$E/log"
    ms new postinst configure; check "postinst on read-only boot exits 0" rc_is $? 0
    chmod u+w "$B" "$B/overlays" "$B/config.txt"
    check "read-only: config untouched" cmp -s "$B/config.txt" "$E/config.pristine"
    check "read-only: no dtbo" [ ! -e "$B/overlays/$OVL.dtbo" ]
    new_env "readonly-upgrade" all
    do_install
    cp "$B/config.txt" "$E/before"
    chmod a-w "$B/overlays" "$B" "$B/config.txt"
    ms new preinst upgrade 1.2; check "preinst upgrade aborts with 1 on read-only boot" rc_is $? 1
    ms new postrm remove; check "postrm remove never fails on read-only boot" rc_is $? 0
    ms new postrm purge; check "postrm purge never fails on read-only boot" rc_is $? 0
    chmod u+w "$B" "$B/overlays" "$B/config.txt"
    check "read-only remove: config untouched" cmp -s "$B/config.txt" "$E/before"
    assert_enabled "$FIX/good.dtbo"

    # 11. Missing boot partition.
    new_env "noboot" all
    rm -rf "$B"
    ms new preinst install; check "preinst install aborts with 1 when boot missing" rc_is $? 1
    ms new preinst abort-upgrade 1.2; check "preinst abort-upgrade never fails" rc_is $? 0
    ms new postrm remove; check "postrm remove exits 0 with boot missing" rc_is $? 0
    ms new postrm purge; check "postrm purge exits 0 with boot missing" rc_is $? 0

    # 12. config.txt cannot be replaced (boot dir not writable, overlays dir
    #     writable): new dtbo must be rolled back to the previous one.
    new_env "config-write-fails" legacy
    cp "$FIX/deployed.dtbo" "$B/overlays/$OVL.dtbo"
    chmod a-w "$B"
    ms new postinst configure; check "postinst exits 0 when config.txt unwritable" rc_is $? 0
    chmod u+w "$B"
    check "rollback: config untouched" cmp -s "$B/config.txt" "$E/config.pristine"
    check "rollback: previous dtbo still in place" cmp -s "$B/overlays/$OVL.dtbo" "$FIX/deployed.dtbo"
    check "no dangling dtbo reference" no_dangling
    # Same, but only the config file write fails (dir writable via probe, mv fails):
    new_env "config-mv-fails" legacy
    cp "$FIX/deployed.dtbo" "$B/overlays/$OVL.dtbo"
    mkdir "$B/config.txt.hackberrypi.tmp"   # tmp path occupied by a directory
    ms new postinst configure; check "postinst exits 0 when tmp write fails" rc_is $? 0
    rmdir "$B/config.txt.hackberrypi.tmp"
    check "rollback(2): config untouched" cmp -s "$B/config.txt" "$E/config.pristine"
    check "rollback(2): previous dtbo restored" cmp -s "$B/overlays/$OVL.dtbo" "$FIX/deployed.dtbo"
    check "rollback(2) is loud" grep -q "config.txt could not be updated" "$E/log"

    # 13. User-written parameterised line: not doubled; dtbo kept on remove.
    new_env "userparam" userparam
    do_install; check "install exits 0" rc_is $? 0
    check "user line kept, no managed block added" cmp -s "$B/config.txt" "$E/config.pristine"
    check "dtbo installed" cmp -s "$B/overlays/$OVL.dtbo" "$FIX/good.dtbo"
    do_purge; check "purge exits 0" rc_is $? 0
    check "dtbo kept while user line references it" [ -f "$B/overlays/$OVL.dtbo" ]
    check "no dangling dtbo reference" no_dangling

    # 14. Malformed marker block: never edited, dtbo never orphaned.
    new_env "malformed" malformed
    do_install; check "install exits 0" rc_is $? 0
    check "malformed config untouched" cmp -s "$B/config.txt" "$E/config.pristine"
    check "no dangling dtbo reference" no_dangling
    do_purge; check "purge exits 0" rc_is $? 0
    check "malformed config untouched by purge" cmp -s "$B/config.txt" "$E/config.pristine"
    check "no dangling dtbo reference after purge" no_dangling

    # 15. Conflict warnings (warn only, never edit).
    new_env "warnings" conflict
    do_install
    check "warns about i2c-gpio on GPIO3/4" grep -q "i2c-gpio on GPIO3/4 uses DPI" "$E/log"
    check "warns about i2c_arm" grep -q "i2c_arm (I2C1) uses GPIO2/3" "$E/log"
    check "warns about spi overlay" grep -q "dtoverlay=spi1-1cs -> SPI" "$E/log"
    check "commented line not warned" sh -c "! grep -q 'line [0-9]* \[[a-z0-9]*\]: #' '$E/log'"
    assert_preserved
    new_env "warnings-live" live
    do_install
    check "live config: warns about bus=11 sda=3/scl=4" grep -q "i2c_gpio_sda=3,i2c_gpio_scl=4 -> i2c-gpio on GPIO3/4" "$E/log"
    check "live config: no i2c_arm warning (it is off)" sh -c "! grep -q 'i2c_arm (I2C1)' '$E/log'"
    check "live config: no spi warning (it is off)" sh -c "! grep -q 'spi (SPI0)' '$E/log'"
    new_env "no-warnings" all
    do_install
    check "clean config: no conflict warning" sh -c "! grep -q 'may conflict' '$E/log'"

    # 16. failed-upgrade / abort-* are no-ops.
    new_env "noop-actions" all
    do_install
    cp "$B/config.txt" "$E/before"
    for a in "postrm failed-upgrade 1.2 1.3" "postrm abort-install" "postrm abort-upgrade 1.2" \
        "postrm disappear other 1" "postinst abort-upgrade 1.3" "postinst abort-remove" \
        "postinst abort-deconfigure"; do
        # shellcheck disable=SC2086
        ms new $a; check "$a exits 0" rc_is $? 0
    done
    check "no-op actions leave config.txt" cmp -s "$B/config.txt" "$E/before"
    assert_enabled "$FIX/good.dtbo"
    assert_apt_present

    # 17. Review fix 1: legacy line wrapped in place with its params.
    new_env "legacy-params-inplace" legacy-params
    do_install; check "install exits 0" rc_is $? 0
    assert_enabled "$FIX/good.dtbo"
    without_markers "$B/config.txt" > "$E/nomark"
    check "legacy line wrapped in place (config minus markers == pristine)" same_text "$E/nomark" "$E/config.pristine"
    check "our dtparam lines inside the block, others outside" \
        [ "$(block_lines "$B/config.txt")" = "$BM|dtoverlay=$OVL|dtparam=touch_inv_x|dtparam=pclk=35000000|$EM|" ]
    check "foreign dtparam stays right after the block" \
        sh -c 'grep -A1 -xF "$1" "$2" | tail -n 1 | grep -qx "dtparam=fan_temp0=40000"' x "$EM" "$B/config.txt"
    check "no orphan-param warning" sh -c "! grep -q 'parameters outside' '$E/log'"
    do_remove
    assert_disabled
    expected_outside "$E/config.pristine" > "$E/expected"
    check "remove drops block with its params, rest pristine" same_text "$B/config.txt" "$E/expected"

    new_env "upgrade-old-params" legacy-params
    do_install_old
    cp "$B/config.txt" "$E/config.pristine"
    do_upgrade old 1.1 1.2; check "upgrade 1.1->1.2 with params exits 0" rc_is $? 0
    assert_enabled "$FIX/good.dtbo"
    without_markers "$B/config.txt" > "$E/nomark"
    check "1.1 upgrade restores the line at its old position" same_text "$E/nomark" "$E/config.pristine"
    check "1.1 upgrade: params inside the block" \
        [ "$(block_lines "$B/config.txt")" = "$BM|dtoverlay=$OVL|dtparam=touch_inv_x|dtparam=pclk=35000000|$EM|" ]
    check ".orig is the pre-upgrade config" cmp -s "$B/config.txt.hackberrypi.orig" "$E/config.pristine"
    check "state cleared" [ ! -e "$E/state" ]

    new_env "upgrade-old-params-changed" legacy-params
    do_install_old
    ms new preinst upgrade 1.1; ms old postrm upgrade 1.2
    echo "user_edit_during_upgrade=1" >> "$B/config.txt"
    ms new postinst configure 1.1; check "fallback configure exits 0" rc_is $? 0
    check "fallback: one reference, unconditional" sh -c '[ "$1" = 1 ]' x "$(refs "$B/config.txt")"
    check "fallback: saved params re-added in the block" \
        [ "$(block_lines "$B/config.txt")" = "$BM|[all]|dtoverlay=$OVL|dtparam=touch_inv_x|dtparam=pclk=35000000|$EM|" ]
    check "fallback: orphaned copies are warned about" grep -q "line 5: dtparam=touch_inv_x" "$E/log"
    check "no dangling dtbo reference" no_dangling

    new_env "legacy-cm4-params" legacy-cm4-params
    do_install
    assert_enabled "$FIX/good.dtbo"
    assert_preserved
    check "conditional legacy line moved with its params under [all]" \
        [ "$(block_lines "$B/config.txt")" = "$BM|[all]|dtoverlay=$OVL|dtparam=touch_inv_y|$EM|" ]

    new_env "orphan-warning" orphan
    do_install
    assert_enabled "$FIX/good.dtbo"
    assert_preserved
    check "warns about our params outside the block" grep -q "parameters outside" "$E/log"
    check "warning names the line" grep -q "line 7: dtparam=touch_inv_x" "$E/log"

    # 18. Review fix 2: user dtparam/comment lines inside the block survive.
    new_env "params-in-block" all
    do_install
    sed -i "/^dtoverlay=$OVL\$/a dtparam=pclk=35000000\\
# my note" "$B/config.txt"
    cp "$B/config.txt" "$E/withparams"
    ms new postinst configure 1.2
    check "good block with params is not rewritten" cmp -s "$B/config.txt" "$E/withparams"
    echo "dtoverlay=$OVL" >> "$B/config.txt"        # forces a rebuild
    ms new postinst configure 1.2; check "rebuild exits 0" rc_is $? 0
    check "rebuild keeps dtparam and comment lines in the block" \
        [ "$(block_lines "$B/config.txt")" = "$BM|dtoverlay=$OVL|dtparam=pclk=35000000|# my note|$EM|" ]
    assert_enabled "$FIX/good.dtbo"

    # 19. Review fix 3: state survives a preinst re-run and a failed restore.
    new_env "state-rerun" legacy-params
    do_install_old
    cp "$B/config.txt" "$E/config.pristine"
    ms new preinst upgrade 1.1; ms old postrm upgrade 1.2
    ms new preinst upgrade 1.1                       # e.g. reinstall before configure
    ms new postinst configure 1.1; check "configure after preinst re-run exits 0" rc_is $? 0
    assert_apt_present
    check "keyring content restored" grep -qx "fake keyring" "$E/keyrings/hackberrypi-max17048.gpg"
    without_markers "$B/config.txt" > "$E/nomark"
    check "line restored in place after preinst re-run" same_text "$E/nomark" "$E/config.pristine"
    assert_enabled "$FIX/good.dtbo"

    new_env "state-restore-fails" all
    do_install_old
    ms new preinst upgrade 1.1; ms old postrm upgrade 1.2
    chmod a-w "$E/keyrings"
    ms new postinst configure 1.1; check "configure exits 0 when keyring restore fails" rc_is $? 0
    chmod u+w "$E/keyrings"
    check "saved keyring kept when restore failed" [ -f "$E/state/keyring" ]
    check "saved sources dropped once restored" [ ! -e "$E/state/sources" ]
    ms new postinst configure 1.1
    assert_apt_present
    check "state cleared after successful restore" [ ! -e "$E/state" ]

    # 20. Review fix 4: 1.1 -> 1.2 with config.txt unwritable after old postrm.
    new_env "dark-display" legacy
    do_install_old
    cp "$B/config.txt" "$E/config.pristine"
    ms new preinst upgrade 1.1; ms old postrm upgrade 1.2
    mkdir "$B/config.txt.hackberrypi.tmp"
    ms new postinst configure 1.1; check "configure exits 0" rc_is $? 0
    rmdir "$B/config.txt.hackberrypi.tmp"
    check "validated dtbo kept (not deleted)" cmp -s "$B/overlays/$OVL.dtbo" "$FIX/good.dtbo"
    check "message says the display will be dark" grep -q "THE DISPLAY WILL BE DARK" "$E/log"
    check "message does not claim boot as before" sh -c "! grep -q 'will boot as before' '$E/log'"
    check "overlay-enabled state kept for retry" [ -f "$E/state/overlay-enabled" ]
    check "no dangling dtbo reference" no_dangling
    ms new postinst configure 1.1; check "retry exits 0" rc_is $? 0
    assert_enabled "$FIX/good.dtbo"
    assert_preserved
    check "state cleared after retry" [ ! -e "$E/state" ]

    # 21. Review fix 5: commented/tabbed bare line counts as a user reference.
    for v in userref-comment userref-tab; do
        new_env "$v" "$v"
        do_install; check "install exits 0" rc_is $? 0
        check "no managed block added next to the user line" cmp -s "$B/config.txt" "$E/config.pristine"
        check "exactly one reference" [ "$(refs "$B/config.txt")" = 1 ]
        check "dtbo installed" cmp -s "$B/overlays/$OVL.dtbo" "$FIX/good.dtbo"
        do_purge
        check "dtbo kept while the user line references it" no_dangling
        check "user line untouched by purge" cmp -s "$B/config.txt" "$E/config.pristine"
    done

    # 22. Review fix 6: installed dtbo is the dtc -@ blob (has __symbols__).
    new_env "dtc-symbols" all
    do_install
    check "installed dtbo carries __symbols__ (dtc -@)" sh -c 'dtc -q -I dtb -O dts "$1" | grep -q __symbols__' x "$B/overlays/$OVL.dtbo"
    check "installed dtbo == dtc -@ of the DTS" cmp -s "$B/overlays/$OVL.dtbo" "$FIX/good.dtbo"

    # 24. Review-2 fix 1: foreign lines inside the block are never dropped.
    for extra in "gpu_mem=64" "dtoverlay=$OVL,touch_inv_x"; do
        new_env "block-foreign-$(printf '%s' "$extra" | tr -c 'a-z0-9' '_')" all
        do_install
        check "precondition: managed block installed" [ "$(block_lines "$B/config.txt")" = "$BM|dtoverlay=$OVL|$EM|" ]
        sed -i "/^dtoverlay=$OVL\$/a $extra" "$B/config.txt"
        echo "dtoverlay=$OVL" >> "$B/config.txt"      # would force a rebuild
        cp "$B/config.txt" "$E/before"
        ms new postinst configure 1.2; check "configure exits 0" rc_is $? 0
        check "config.txt untouched when block has foreign line ($extra)" cmp -s "$B/config.txt" "$E/before"
        check "foreign-line warning given" grep -q "contains lines other than" "$E/log"
        check "dtbo kept" cmp -s "$B/overlays/$OVL.dtbo" "$FIX/good.dtbo"
        do_purge; check "purge exits 0" rc_is $? 0
        check "purge leaves config.txt with foreign block alone" cmp -s "$B/config.txt" "$E/before"
        check "purge keeps dtbo (config still loads it)" no_dangling
        check "purge keeps dtbo file" [ -f "$B/overlays/$OVL.dtbo" ]
    done

    # 25. Review-2 fix 2: a failing redirect on ":" does not abort preinst.
    new_env "preinst-flag-unwritable" all
    do_install_old
    mkdir -p "$E/state/overlay-enabled"             # redirect target is a directory
    ms new preinst upgrade 1.1; check "preinst upgrade exits 0 when flag cannot be written" rc_is $? 0
    check "preinst warns instead of aborting" grep -q "could not record overlay state" "$E/log"
    check "preinst still saved config.pre" [ -f "$E/state/config.pre" ]

    # 26. Review-2 fix 3: overlay state only for upgrades from <= 1.1.
    new_env "state-not-from-new" all
    do_install
    ms new preinst upgrade 1.2; check "preinst upgrade from 1.2 exits 0" rc_is $? 0
    check "no config.pre saved when upgrading from >= 1.2" [ ! -e "$E/state/config.pre" ]
    check "no overlay flag saved when upgrading from >= 1.2" [ ! -e "$E/state/overlay-enabled" ]
    mkdir -p "$E/state"; : > "$E/state/overlay-enabled"; cp "$B/config.txt" "$E/state/config.pre"
    ms new preinst upgrade 1.2
    check "stale overlay state dropped on upgrade from >= 1.2" sh -c '[ ! -e "$1/overlay-enabled" ] && [ ! -e "$1/config.pre" ]' x "$E/state"
    new_env "state-from-1.1-1" all
    do_install_old
    ms new preinst upgrade 1.1-1
    check "1.1-1 counts as a destructive old version" [ -f "$E/state/overlay-enabled" ]
    ms new preinst abort-upgrade 1.1-1; check "preinst abort-upgrade exits 0" rc_is $? 0
    check "abort-upgrade drops overlay state" sh -c '[ ! -e "$1/overlay-enabled" ] && [ ! -e "$1/config.pre" ]' x "$E/state"
    check "abort-upgrade keeps saved keyring copy" [ -f "$E/state/keyring" ]

    # dtmerge path limit: a TMPDIR long enough to break dtmerge must not stop
    # validation (postinst falls back to /tmp).
    new_env "long-tmpdir" all
    hb_long="$E/tmp/$(printf '%0200d' 0)"
    mkdir -p "$hb_long"
    env HACKBERRYPI_MAINTSCRIPT_TEST=1 BOOT_DIR="$B" KEYRING="$E/keyrings/hackberrypi-max17048.gpg" \
        SOURCES_LIST="$E/sources/hackberrypi-max17048.sources" SRC_DIR="$E/src" STATE_DIR="$E/state" \
        TMPDIR="$hb_long" PATH="$AWKBIN:$PATH" $MS_SHELL "$FIX/new/postinst" configure >> "$E/log" 2>&1
    check "long TMPDIR: configure exits 0" rc_is $? 0
    if command -v dtmerge > /dev/null 2>&1; then
        check "long TMPDIR: dtmerge validation still ran" grep -q "validated overlay against" "$E/log"
    fi
    assert_enabled "$FIX/good.dtbo"
    rm -rf "$hb_long"

    # 27. Review-2 fix 5: build fails, dtbo missing, config.txt still loads it.
    new_env "missing-dtbo-prev" all
    do_install
    cp "$FIX/deployed.dtbo" "$B/overlays/$OVL.dtbo.prev"
    rm -f "$B/overlays/$OVL.dtbo"
    cp "$B/config.txt" "$E/before"
    cp "$FIX/broken.dts" "$E/src/$OVL.dts"
    ms new postinst configure 1.2; check "configure exits 0" rc_is $? 0
    check "dtbo restored from .prev while config.txt loads it" cmp -s "$B/overlays/$OVL.dtbo" "$FIX/deployed.dtbo"
    check "config.txt unchanged" cmp -s "$B/config.txt" "$E/before"
    check "no dangling dtbo reference" no_dangling
    new_env "missing-dtbo-noprev" all
    do_install
    rm -f "$B/overlays/$OVL.dtbo"
    cp "$FIX/broken.dts" "$E/src/$OVL.dts"
    ms new postinst configure 1.2; check "configure exits 0" rc_is $? 0
    check "message says the display will be dark" grep -q "THE DISPLAY WILL BE DARK" "$E/log"
    check "message does not claim config.txt does not load it" sh -c "! grep -q 'was NOT changed to load it' '$E/log'"

    # 28. os_prefix: the firmware reads <os_prefix>overlays/; postinst mirrors
    # the validated dtbo there, re-runs are no-ops, remove/purge clean it up.
    new_env "prefix" all
    echo "os_prefix=hb73/" >> "$B/config.txt"; cp "$B/config.txt" "$E/config.pristine"
    mkdir -p "$B/hb73/overlays"
    do_install; check "os_prefix: install exits 0" rc_is $? 0
    assert_enabled "$FIX/good.dtbo"
    check "os_prefix: dtbo mirrored into hb73/overlays" cmp -s "$B/hb73/overlays/$OVL.dtbo" "$B/overlays/$OVL.dtbo"
    check "os_prefix: no .prev on fresh install" [ ! -e "$B/hb73/overlays/$OVL.dtbo.prev" ]
    cp "$B/config.txt" "$E/after1"
    ms new postinst configure 1.2; check "os_prefix: reconfigure exits 0" rc_is $? 0
    check "os_prefix: reconfigure reports mirror up to date" grep -q "(os_prefix) is already up to date" "$E/log"
    check "os_prefix: reconfigure leaves config.txt unchanged" cmp -s "$B/config.txt" "$E/after1"
    echo "stale overlay" > "$E/stale.dtbo"; cp "$E/stale.dtbo" "$B/hb73/overlays/$OVL.dtbo"
    ms new postinst configure 1.2; check "os_prefix: stale mirror refresh exits 0" rc_is $? 0
    check "os_prefix: stale mirror replaced" cmp -s "$B/hb73/overlays/$OVL.dtbo" "$B/overlays/$OVL.dtbo"
    check "os_prefix: stale mirror kept as .prev" cmp -s "$B/hb73/overlays/$OVL.dtbo.prev" "$E/stale.dtbo"
    check "os_prefix: no tmp left in mirror dir" sh -c '! ls "$1"/*.tmp > /dev/null 2>&1' x "$B/hb73/overlays"
    do_remove; check "os_prefix: remove exits 0" rc_is $? 0
    check "os_prefix: remove deletes mirrored dtbo" [ ! -e "$B/hb73/overlays/$OVL.dtbo" ]
    ms new postrm purge; check "os_prefix: purge exits 0" rc_is $? 0
    check "os_prefix: purge deletes mirrored .prev" [ ! -e "$B/hb73/overlays/$OVL.dtbo.prev" ]
    new_env "prefix-nodir" all
    echo "os_prefix=hb73/" >> "$B/config.txt"
    do_install; check "os_prefix without dir: install exits 0" rc_is $? 0
    assert_enabled "$FIX/good.dtbo"
    check "os_prefix without dir: warns" grep -q "does not exist" "$E/log"
    check "os_prefix without dir: dir not created" [ ! -e "$B/hb73" ]
    new_env "prefix-unsafe" all
    echo "os_prefix=../x/" >> "$B/config.txt"
    do_install; check "os_prefix with ..: install exits 0" rc_is $? 0
    check "os_prefix with ..: nothing written outside boot" [ ! -e "$E/x" ]

    # 23. The config parser is byte-identical in postinst and postrm.
    hb_awk_of "$REPO/debian/hackberrypi-max17048-dkms.postinst" > "$T/awk.postinst"
    hb_awk_of "$REPO/debian/hackberrypi-max17048-dkms.postrm" > "$T/awk.postrm"
    CUR="parser-sync"
    check "HB_AWK identical in postinst and postrm" cmp -s "$T/awk.postinst" "$T/awk.postrm"
    check "HB_AWK extracted" [ -s "$T/awk.postinst" ]
}

# ------------------------------------------------------------ matrix

: "${MS_SHELLS:=dash bash busybox}"
: "${MS_AWKS:=mawk gawk}"
for sh_name in $MS_SHELLS; do
    case "$sh_name" in
        busybox) command -v busybox > /dev/null 2>&1 || continue; MS_SHELL="busybox sh" ;;
        bash) command -v bash > /dev/null 2>&1 || continue; MS_SHELL="bash --posix" ;;
        *) command -v "$sh_name" > /dev/null 2>&1 || continue; MS_SHELL="$sh_name" ;;
    esac
    for awk_name in $MS_AWKS; do
        command -v "$awk_name" > /dev/null 2>&1 || continue
        COMBO="$sh_name+$awk_name"
        AWKBIN="$T/awkbin-$awk_name"
        mkdir -p "$AWKBIN"
        ln -sf "$(command -v "$awk_name")" "$AWKBIN/awk"
        f0=$FAIL; p0=$PASS
        echo "--- scripts run with '$MS_SHELL', awk=$awk_name"
        run_scenarios
        echo "    $((PASS - p0)) passed, $((FAIL - f0)) failed"
    done
done

REAL_AFTER="$(real_sums)"
if [ "$REAL_BEFORE" != "$REAL_AFTER" ]; then
    echo "FATAL: real system files changed during the test!" >&2
    printf '%s\n' "$REAL_BEFORE" > "$T/before"; printf '%s\n' "$REAL_AFTER" > "$T/after"
    diff "$T/before" "$T/after" >&2
    FAIL=$((FAIL + 1))
else
    echo "real /boot/firmware, keyring, sources and state dir unchanged: ok"
fi

echo "TOTAL: $PASS passed, $FAIL failed"
if [ "$FAIL" != 0 ]; then
    echo "Failures:$FAILED_NAMES"
    if [ -n "${MS_KEEP:-}" ]; then
        trap - EXIT
        echo "sandbox kept at $T"
    fi
    exit 1
fi
exit 0
