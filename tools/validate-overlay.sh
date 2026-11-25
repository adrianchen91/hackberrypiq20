#!/usr/bin/env bash
# Offline gate for the HackberryPi CM5 overlay (PLAN-dts-driver-improvements.md, task P0.2;
# bus modes and assertion list in docs/p2.2-design.md).
#
# Usage: tools/validate-overlay.sh [overlay.dts] [base.dtb]
#   overlay.dts  default: hackberrypicm5.dts in the repository root
#   base.dtb     default: every readable /boot/firmware/bcm2712-rpi-cm5{,l}-cm{5,4}io.dtb,
#                each run separately (per-base results; fails if any base fails).
#                An explicit base.dtb is run alone.
#
# Steps per base: dtmerge per param set, then structural assertions on the
# decompiled merged tree. The overlay is compiled once with dtc (only errors fail).
# Exits non-zero on any failure.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Bus paths. A check id with an '@hw' suffix runs on HW_BUS, otherwise on DEFAULT_BUS.
DEFAULT_BUS=/i2c-gpio
HW_BUS=/axi/pcie@1000120000/rp1/i2c@74000
RP1_GPIO_NODE=/axi/pcie@1000120000/rp1/gpio@d0000

# Param sets: "label|dtmerge params (space separated, may be empty)|assertions"
# Assertion ids (suffix @hw = run on HW_BUS):
#   dpi panel touch touch_irq fuelgauge gpio27 i2c_pins claims touch_off fuel_off alias
#   one_owner no_i2cgpio alias_hw i2c1_hz i2c1_hz=0xHEX i2c1_off unique_devs monbat eth_off eth_on
#   has=TEXT nohas=TEXT  (fixed-string match on the merged tree; TEXT must not contain , or |)
ALL_CHECKS="dpi,panel,touch,touch_irq,fuelgauge,gpio27,i2c_pins,claims,eth_off"
BASE_CHECKS="${ALL_CHECKS},alias,has=max17048-battery\",has=sda-gpios,has=monitored-battery,has=simple-battery"
HW_BASE_CHECKS="dpi,panel,touch@hw,touch_irq@hw,fuelgauge@hw,gpio27,claims,one_owner,no_i2cgpio,alias_hw,unique_devs,monbat@hw,eth_off"
HW_CHECKS="${HW_BASE_CHECKS},i2c1_hz"
PARAM_SETS=(
  "default||${BASE_CHECKS},one_owner,unique_devs,nohas=hackberry-i2c1-is-i2c11"
  "touch_inv_x|touch_inv_x|${ALL_CHECKS},has=touchscreen-inverted-x;"
  "touch_inv_y|touch_inv_y|${ALL_CHECKS},has=touchscreen-inverted-y;"
  "touch_swap_xy|touch_swap_xy|${ALL_CHECKS},has=touchscreen-swapped-x-y;"
  "no_touch|no_touch|dpi,panel,fuelgauge,gpio27,i2c_pins,claims,touch_off"
  "no_fuelgauge|no_fuelgauge|dpi,panel,touch,touch_irq,gpio27,i2c_pins,claims,fuel_off"
  "fuelgauge_mainline|fuelgauge_mainline|${ALL_CHECKS},has=max17048\";,nohas=max17048-battery"
  "battery_5675|charge_uah=5675000 energy_uwh=21000000|${ALL_CHECKS},has=<0x5697f8>,has=<0x1406f40>"
  "pclk_40M|pclk=40000000|${ALL_CHECKS},has=clock-frequency = <0x2625a00>;"
  "i2c_delay_8|i2c_delay_us=8|${ALL_CHECKS},has=delay-us = <0x08>;"
  "ethernet|ethernet|${ALL_CHECKS/eth_off/eth_on}"
  "ethernet_on|ethernet=on|${ALL_CHECKS/eth_off/eth_on}"
  "ethernet_off|ethernet=off|${ALL_CHECKS}"
  "i2c_hz_nohw|i2c_hz=400000|${BASE_CHECKS},one_owner,unique_devs,i2c1_off"
  "hw_i2c_hz_400k|hw_i2c i2c_hz=400000|${HW_BASE_CHECKS},i2c1_hz=0x61a80"
  "hw_ethernet|hw_i2c ethernet|${HW_BASE_CHECKS/eth_off/eth_on},i2c1_hz"
  "all_flags|touch_inv_x touch_inv_y touch_swap_xy no_fuelgauge|dpi,panel,touch,touch_irq,gpio27,i2c_pins,claims,fuel_off"
  "hw_i2c_off|hw_i2c=off|${BASE_CHECKS},one_owner,unique_devs"
  "hw_i2c_0|hw_i2c=0|${BASE_CHECKS},one_owner,unique_devs"
  "hw_i2c|hw_i2c|${HW_CHECKS}"
  "hw_i2c_on|hw_i2c=on|${HW_CHECKS}"
  "hw_i2c_1|hw_i2c=1|${HW_CHECKS}"
  "hw_i2c_twice|hw_i2c hw_i2c|${HW_CHECKS}"
  "hw_on_off|hw_i2c=on hw_i2c=off|${BASE_CHECKS},one_owner"
  "hw_last|touch_inv_x hw_i2c|${HW_CHECKS},has=touchscreen-inverted-x;"
  "hw_touch_inv_x|hw_i2c touch_inv_x|${HW_CHECKS},has=touchscreen-inverted-x;"
  "hw_touch_inv_y|hw_i2c touch_inv_y|${HW_CHECKS},has=touchscreen-inverted-y;"
  "hw_touch_swap_xy|hw_i2c touch_swap_xy|${HW_CHECKS},has=touchscreen-swapped-x-y;"
  "hw_no_touch|hw_i2c no_touch|dpi,panel,fuelgauge@hw,gpio27,claims,one_owner,no_i2cgpio,alias_hw,i2c1_hz,touch_off@hw"
  "hw_no_fuelgauge|hw_i2c no_fuelgauge|dpi,panel,touch@hw,touch_irq@hw,gpio27,claims,one_owner,no_i2cgpio,alias_hw,i2c1_hz,fuel_off@hw"
  "hw_fuelgauge_mainline|hw_i2c fuelgauge_mainline|${HW_CHECKS},has=max17048\";,nohas=max17048-battery"
  "hw_battery_5675|hw_i2c charge_uah=5675000 energy_uwh=21000000|${HW_CHECKS},has=<0x5697f8>,has=<0x1406f40>"
  "hw_pclk_40M|hw_i2c pclk=40000000|${HW_CHECKS},has=clock-frequency = <0x2625a00>;"
  "hw_i2c_delay_8|hw_i2c i2c_delay_us=8|${HW_CHECKS},nohas=delay-us = <0x08>;"
  "hw_all_flags|hw_i2c touch_inv_x touch_inv_y touch_swap_xy no_fuelgauge|dpi,panel,touch@hw,touch_irq@hw,gpio27,claims,one_owner,no_i2cgpio,alias_hw,i2c1_hz,fuel_off@hw"
)

# dtc 1.8.1 rejects -Wall, so the check names are listed explicitly.
DTC_WARN=(
  -W unit_address_vs_reg -W unit_address_format -W pci_bridge
  -W pci_device_bus_num -W pci_device_reg -W simple_bus_reg -W i2c_bus_reg
  -W spi_bus_reg -W avoid_unnecessary_addr_size -W alias_paths -W graph_port
  -W graph_endpoint -W unique_unit_address -W interrupt_provider
  -W node_name_chars -W node_name_format -W property_name_chars
)

die() { echo "ERROR: $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# awk helpers, prepended to every awk program that needs them.
# ---------------------------------------------------------------------------
AWK_LIB='
function hexval(s,   i, n) {
  s = tolower(s); sub(/^0x/, "", s); n = 0
  for (i = 1; i <= length(s); i++) n = n * 16 + index("0123456789abcdef", substr(s, i, 1)) - 1
  return n
}
# Value of property KEY in a flattened props string ("k = v ;; k2 = v2"), trailing ";" removed.
function propget(props, key,   n, parts, i, v) {
  n = split(props, parts, " ;; ")
  for (i = 1; i <= n; i++)
    if (index(parts[i], key " = ") == 1) {
      v = substr(parts[i], length(key) + 4); sub(/;$/, "", v); return v
    }
  return ""
}
# Decimal values of a "<0x1 0x2>" cell list, as " 1 2" (leading space).
function phlist(v,   s, n, a, i, out) {
  s = v; gsub(/[<>]/, "", s); n = split(s, a, " "); out = ""
  for (i = 1; i <= n; i++) out = out " " hexval(a[i])
  return out
}
# Pins claimed by "[sda-|scl-]gpios = <ctrl pin flags ...>" groups in s (decimal, space separated).
function gpio_pins(s,   out, seg, n, cells, i) {
  out = ""
  while (match(s, /gpios = <[^>]*>/)) {
    seg = substr(s, RSTART, RLENGTH); s = substr(s, RSTART + RLENGTH)
    sub(/^gpios = </, "", seg); sub(/>$/, "", seg)
    n = split(seg, cells, " ")
    for (i = 1; i + 1 <= n; i += 3) out = out " " hexval(cells[i + 1])
  }
  return out
}
# Pins named by "gpioN" strings (pinctrl pins property), decimal, space separated.
function gpio_names(s,   out, seg) {
  out = ""
  while (match(s, /"gpio[0-9]+"/)) {
    seg = substr(s, RSTART + 5, RLENGTH - 6); out = out " " (seg + 0)
    s = substr(s, RSTART + RLENGTH)
  }
  return out
}
function forbidden(p) { return (p <= 9 || (p >= 12 && p <= 17) || (p >= 20 && p <= 25)) }
'

# Flatten a decompiled DTS into one line per node: "<node path><TAB><props>".
# Props of a node are joined with " ;; " (child node props are on their own lines).
flatten_dts() {
  awk -F'\t' '
    function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
    {
      line = trim($0)
      if (line == "" || line ~ /^\/(dts-v1|plugin|memreserve)\//) next
      if (line ~ /\{$/) {
        name = line; sub(/[ \t]*\{$/, "", name)
        while (name ~ /^[A-Za-z_][A-Za-z0-9_]*: /) sub(/^[A-Za-z_][A-Za-z0-9_]*: /, "", name)
        depth++; stack[depth] = name; props[depth] = ""
        next
      }
      if (line ~ /^\};?$/) {
        p = ""
        for (i = 1; i <= depth; i++) if (stack[i] != "/") p = p "/" stack[i]
        if (p == "") p = "/"
        print p "\t" props[depth]
        depth--
        next
      }
      if (depth > 0) props[depth] = (props[depth] == "" ? line : props[depth] " ;; " line)
    }' "$1"
}

# count_nodes PATH_REGEX [PROP_REGEX ...]: number of flattened nodes whose path
# matches and whose props match every given regex.
count_nodes() {
  local path=$1; shift
  awk -F'\t' -v pr="$path" -v p1="${1:-}" -v p2="${2:-}" -v p3="${3:-}" '
    $1 ~ pr && (p1 == "" || $2 ~ p1) && (p2 == "" || $2 ~ p2) && (p3 == "" || $2 ~ p3) { n++ }
    END { print n + 0 }' "$FLAT"
}

# node_prop EXACT_PATH PROP: value of PROP on that node in the merged tree (empty if absent).
node_prop() {
  awk -F'\t' -v path="$1" -v key="$2" "$AWK_LIB"'
    $1 == path { v = propget($2, key); if (v != "") { print v; exit } }' "$FLAT"
}

# node_pins EXACT_PATH: sorted unique GPIO numbers claimed by that node's gpio props.
node_pins() {
  awk -F'\t' -v path="$1" "$AWK_LIB"'
    $1 == path { print gpio_pins($2) }' "$FLAT" \
    | tr ' ' '\n' | sed '/^$/d' | sort -un | paste -sd' ' -
}

# PIN_GROUPS file: one line per pin group in the merged tree, "phandle<TAB>node name<TAB>gpio numbers".
build_groups() {
  awk -F'\t' "$AWK_LIB"'
    {
      ph = propget($2, "phandle"); pins = propget($2, "pins")
      if (ph == "" || pins == "") next
      name = $1; sub(/.*\//, "", name)
      list = phlist(ph); sub(/^ +/, "", list)
      printf "%s\t%s\t%s\n", list, name, gpio_names(pins)
    }' "$FLAT" > "$PIN_GROUPS"
}

# ---------------------------------------------------------------------------
# Assertions. Each returns 0 (pass) or 1 (fail) and may print detail on stdout.
# Globals per param set: FLAT, MERGED_DTS, ADDED, TOUCHED, PIN_GROUPS, BASE_FLAT;
# BUS is set by run_check_by_id from the id suffix.
# ---------------------------------------------------------------------------
chk_dpi()       { [[ $(count_nodes '/dpi(@[0-9a-f]+)?$' 'status = "okay";') -ge 1 ]] && dpi_group_ok; }
chk_panel()     { [[ $(count_nodes '/panel$' 'compatible = "panel-dpi";') -ge 1 &&
                     $(count_nodes '/panel-timing$') -ge 1 ]]; }
chk_touch()     { [[ $(count_nodes "^$BUS/[^/]+\$" 'reg = <0x48>;' 'compatible = "edt,edt-ft5406";') -ge 1 ]]; }
chk_touch_irq() { [[ $(count_nodes "^$BUS/[^/]+\$" 'reg = <0x48>;' 'interrupts = <0x1b[ >]') -ge 1 ]]; }
chk_fuelgauge() { [[ $(count_nodes "^$BUS/[^/]+\$" 'reg = <0x36>;') -ge 1 ]]; }
chk_gpio27()    { [[ $(count_nodes '' 'pins = "gpio27";' 'bias-pull-up;') -ge 1 ]]; }
chk_i2c_pins()  { [[ "$(node_pins '/i2c-gpio')" == "10 11" ]] || { echo "i2c-gpio claims GPIO [$(node_pins '/i2c-gpio')], expected [10 11]"; return 1; }; }

chk_touch_off() { [[ $(count_nodes "^$BUS/[^/]+\$" 'reg = <0x48>;' 'status = "disabled";') -ge 1 ]]; }
chk_fuel_off()  { [[ $(count_nodes "^$BUS/[^/]+\$" 'reg = <0x36>;' 'status = "disabled";') -ge 1 ]]; }
chk_alias()     { grep -qF 'i2c11 = "/i2c-gpio";' "$MERGED_DTS"; }

# dpi pinctrl-0 must resolve to exactly the group dpi_18bit_cpadhi_gpio0 (node name rp1_dpi_18bit_cpadhi_gpio0).
dpi_group_ok() {
  awk -F'\t' "$AWK_LIB"'
    FNR == NR { G[$1] = $2; next }
    $1 ~ /\/dpi(@[0-9a-f]+)?$/ {
      list = phlist(propget($2, "pinctrl-0")); m = split(list, ph, " ")
      if (m == 1 && (ph[1] in G) && (G[ph[1]] == "rp1_dpi_18bit_cpadhi_gpio0" || G[ph[1]] == "dpi_18bit_cpadhi_gpio0")) { found = 1; exit 0 }
      print "dpi pinctrl-0 does not resolve to group dpi_18bit_cpadhi_gpio0 (phandles:" list ")"; exit 1
    }
    END { exit (found ? 0 : 1) }' "$PIN_GROUPS" "$FLAT"
}

# Overlay-added lines must not claim GPIO 0-9, 12-17 or 20-25 (literal gpio props and strings).
# Touched nodes (new or changed vs the base) must not reach such a pin through pinctrl-N,
# resolved by phandle to the pins of the group in the merged tree. The dpi node may use
# its own group dpi_18bit_cpadhi_gpio0 and nothing else.
chk_claims() {
  local rc=0
  awk "$AWK_LIB"'
    {
      n = split(gpio_pins($0) " " gpio_names($0), pins, " ")
      for (i = 1; i <= n; i++) {
        p = pins[i] + 0
        if (forbidden(p)) { print "forbidden GPIO " p " claimed: " $0; bad++ }
      }
    }
    END { exit (bad > 0) }' "$ADDED" || rc=1
  awk -F'\t' "$AWK_LIB"'
    FNR == NR { G[$1] = $2; P[$1] = " " $3 " "; next }
    {
      n = split($2, parts, " ;; ")
      for (i = 1; i <= n; i++) {
        key = parts[i]; sub(/ = .*/, "", key)
        if (key !~ /^pinctrl-[0-9]+$/) continue
        m = split(phlist(propget($2, key)), ph, " ")
        for (j = 1; j <= m; j++) {
          k = ph[j]
          if (!(k in G)) continue
          mp = split(P[k], pins, " ")
          for (q = 1; q <= mp; q++) {
            if (!forbidden(pins[q] + 0)) continue
            if ($1 ~ /\/dpi(@[0-9a-f]+)?$/ && (G[k] == "rp1_dpi_18bit_cpadhi_gpio0" || G[k] == "dpi_18bit_cpadhi_gpio0")) continue
            print "forbidden GPIO " pins[q] " via " key " of " $1 " -> group " G[k]; bad++
          }
        }
      }
    }
    END { exit (bad > 0) }' "$PIN_GROUPS" "$TOUCHED" || rc=1
  return $rc
}

# GPIO10/11 owners: enabled nodes with a *gpios cell on the RP1 gpio controller pin 10 or 11,
# or a pinctrl-N group containing gpio10 or gpio11. Must be exactly the expected bus node:
# /i2c-gpio in default mode, HW_BUS in hw mode.
chk_one_owner() {
  local exp own rp1
  if [[ $(count_nodes '^/i2c-gpio$') -ge 1 ]]; then exp=/i2c-gpio; else exp=$HW_BUS; fi
  rp1=$(node_prop "$RP1_GPIO_NODE" phandle)
  own=$(awk -F'\t' -v rpv="$rp1" "$AWK_LIB"'
    FNR == NR { P[$1] = " " $3 " "; next }
    {
      if (propget($2, "status") == "\"disabled\"") next
      rpn = phlist(rpv) + 0; own_node = 0
      n = split($2, parts, " ;; ")
      for (i = 1; i <= n; i++) {
        key = parts[i]; sub(/ = .*/, "", key)
        if (key ~ /gpios$/) {
          m = split(phlist(propget($2, key)), c, " ")
          for (j = 1; j + 1 <= m; j += 3)
            if (c[j] + 0 == rpn && (c[j + 1] + 0 == 10 || c[j + 1] + 0 == 11)) own_node = 1
        }
        if (key ~ /^pinctrl-[0-9]+$/) {
          m = split(phlist(propget($2, key)), ph, " ")
          for (j = 1; j <= m; j++)
            if ((ph[j] in P) && (index(P[ph[j]], " 10 ") || index(P[ph[j]], " 11 "))) own_node = 1
        }
      }
      if (own_node) print $1
    }' "$PIN_GROUPS" "$FLAT")
  [[ $own == "$exp" ]] || { echo "GPIO10/11 owners: [${own//$'\n'/, }], expected [$exp]"; return 1; }
}

chk_no_i2cgpio() { [[ $(count_nodes '^/i2c-gpio$') -eq 0 ]]; }

chk_alias_hw() {
  local a11 a1
  a11=$(node_prop /aliases i2c11); a1=$(node_prop /aliases i2c1)
  [[ $a11 == "\"$HW_BUS\"" && $a1 != "\"$HW_BUS\"" ]] || { echo "i2c11=[$a11] i2c1=[$a1]"; return 1; }
}

# HZ_EXPECT: expected clock-frequency cell (hex, as dtc prints it); 0x186a0 = 100 kHz.
chk_i2c1_hz() {
  local hz st
  hz=$(node_prop "$HW_BUS" clock-frequency); st=$(node_prop "$HW_BUS" status)
  [[ $hz == "<${HZ_EXPECT}>" && $st == '"okay"' ]] || { echo "clock-frequency=[$hz] status=[$st] on $HW_BUS"; return 1; }
}

# Exactly one enabled edt touch at reg 0x48 and one enabled max17048 gauge at reg 0x36, tree-wide.
chk_unique_devs() {
  local c
  c=$(awk -F'\t' "$AWK_LIB"'
    {
      if (propget($2, "status") == "\"disabled\"") next
      reg = propget($2, "reg"); comp = propget($2, "compatible")
      if (reg == "<0x48>" && index(comp, "\"edt,edt-ft5406\"")) t++
      if (reg == "<0x36>" && index(comp, "max17048")) g++
    }
    END { print t + 0, g + 0 }' "$FLAT")
  [[ $c == "1 1" ]] || { echo "enabled touch(0x48) and gauge(0x36) counts: [$c], expected [1 1]"; return 1; }
}

# The gauge on BUS monitors /hackberry-battery (phandle compare).
chk_monbat() {
  local ph mb
  ph=$(node_prop /hackberry-battery phandle)
  mb=$(node_prop "$BUS/battery@36" monitored-battery)
  [[ -n $ph && $mb == "$ph" ]] || { echo "monitored-battery=[$mb] /hackberry-battery phandle=[$ph] on $BUS/battery@36"; return 1; }
}

ETH_NODE=/axi/pcie@1000120000/rp1/ethernet@100000
chk_i2c1_off() { local st; st=$(node_prop "$HW_BUS" status); [[ $st == '"disabled"' ]] || { echo "status=[$st] on $HW_BUS"; return 1; }; }
chk_eth_off() { [[ $(node_prop "$ETH_NODE" status) == '"disabled"' ]] || { echo "status=[$(node_prop "$ETH_NODE" status)] on $ETH_NODE"; return 1; }; }
chk_eth_on()  { local st; st=$(node_prop "$ETH_NODE" status); [[ $(count_nodes "^$ETH_NODE\$") -ge 1 && ( -z $st || $st == '"okay"' ) ]] || { echo "status=[$st] on $ETH_NODE"; return 1; }; }

chk_has()   { grep -qF -- "$TXT" "$MERGED_DTS"; }
chk_nohas() { ! grep -qF -- "$TXT" "$MERGED_DTS"; }

FAILS=0
PASSES=0
SET_LABEL=""

report() {
  if [[ $1 == PASS ]]; then PASSES=$((PASSES + 1)); else FAILS=$((FAILS + 1)); fi
  printf '  [%s] %s %s\n' "$1" "$SET_LABEL" "$2"
}

# run_check ID DESCRIPTION FUNCTION: prints PASS/FAIL, plus a short detail on failure.
run_check() {
  local id=$1 desc=$2 fn=$3 out rc=0
  out=$("$fn" 2>&1) || rc=$?
  if (( rc == 0 )); then
    report PASS "$id: $desc"
  else
    report FAIL "$id: $desc"
    if [[ -n $out ]]; then
      printf '%s\n' "$out" | head -n 5 | sed 's/^/          /'
    fi
  fi
  return 0
}

# run_check_by_id ID: '@hw' suffix selects HW_BUS for the device checks.
run_check_by_id() {
  local id=$1 base=$1
  BUS=$DEFAULT_BUS
  if [[ $id == *@hw ]]; then BUS=$HW_BUS; base=${id%@hw}; fi
  case $base in
    dpi)        run_check "$id" 'dpi node has status "okay" and pinctrl-0 is dpi_18bit_cpadhi_gpio0' chk_dpi ;;
    panel)      run_check "$id" 'panel-dpi compatible and panel-timing node present' chk_panel ;;
    touch)      run_check "$id" "edt,edt-ft5406 at reg 0x48 on $BUS" chk_touch ;;
    touch_irq)  run_check "$id" "touch node on $BUS interrupt is GPIO27" chk_touch_irq ;;
    fuelgauge)  run_check "$id" "device at reg 0x36 on $BUS" chk_fuelgauge ;;
    gpio27)     run_check "$id" 'GPIO27 pinctrl group with bias-pull-up' chk_gpio27 ;;
    i2c_pins)   run_check "$id" 'i2c-gpio uses GPIO 10 and 11 only' chk_i2c_pins ;;
    touch_off)  run_check "$id" "touch node on $BUS disabled" chk_touch_off ;;
    fuel_off)   run_check "$id" "fuel gauge node on $BUS disabled" chk_fuel_off ;;
    alias)      run_check "$id" 'i2c11 alias points at /i2c-gpio' chk_alias ;;
    claims)     run_check "$id" 'overlay adds no claim on GPIO 0-9/12-17/20-25 (incl. pinctrl groups)' chk_claims ;;
    one_owner)  run_check "$id" 'exactly one enabled owner of GPIO10/11 (i2c-gpio or i2c@74000)' chk_one_owner ;;
    no_i2cgpio) run_check "$id" 'no /i2c-gpio node' chk_no_i2cgpio ;;
    alias_hw)   run_check "$id" "i2c11 alias points at $HW_BUS, i2c1 does not" chk_alias_hw ;;
    i2c1_hz)    HZ_EXPECT=0x186a0; run_check "$id" 'i2c@74000 at 100 kHz and status okay' chk_i2c1_hz ;;
    i2c1_hz=*)  HZ_EXPECT=${base#i2c1_hz=}; run_check "$id" "i2c@74000 clock-frequency $HZ_EXPECT and status okay" chk_i2c1_hz ;;
    i2c1_off)   run_check "$id" "$HW_BUS stays disabled" chk_i2c1_off ;;
    eth_off)    run_check "$id" 'RP1 ethernet disabled' chk_eth_off ;;
    eth_on)     run_check "$id" 'RP1 ethernet present and not disabled' chk_eth_on ;;
    unique_devs) run_check "$id" 'one enabled touch at 0x48 and one gauge at 0x36' chk_unique_devs ;;
    monbat)     run_check "$id" "gauge on $BUS monitored-battery is /hackberry-battery" chk_monbat ;;
    has=*)      TXT=${id#has=};   run_check "$id" "merged tree contains: $TXT" chk_has ;;
    nohas=*)    TXT=${id#nohas=}; run_check "$id" "merged tree lacks: $TXT" chk_nohas ;;
    *) die "unknown assertion id in PARAM_SETS: $id" ;;
  esac
}

# run_base BASE_DTB: all param sets against one base. Uses OVL_DTBO and WORK.
run_base() {
  local base=$1 entry p0 f0 BW
  local SET_PARAMS SET_EXPECT PARAMS CHECKS id
  p0=$PASSES; f0=$FAILS
  BW="$WORK/$(basename "$base" .dtb)"
  mkdir -p "$BW"
  echo
  echo "########## base: $base"

  dtc -q -I dtb -O dts -o "$BW/base.dts" "$base" || die "cannot decompile base dtb: $base"
  LC_ALL=C sort -u "$BW/base.dts" > "$BW/base.sorted"
  BASE_FLAT="$BW/base.flat"
  flatten_dts "$BW/base.dts" > "$BASE_FLAT"

  for entry in "${PARAM_SETS[@]}"; do
    IFS='|' read -r SET_LABEL SET_PARAMS SET_EXPECT <<< "$entry"
    read -ra PARAMS <<< "$SET_PARAMS"
    MERGED_DTB="$BW/$SET_LABEL.dtb"
    MERGED_DTS="$BW/$SET_LABEL.dts"
    FLAT="$BW/$SET_LABEL.flat"
    ADDED="$BW/$SET_LABEL.added"
    TOUCHED="$BW/$SET_LABEL.touched"
    PIN_GROUPS="$BW/$SET_LABEL.groups"

    echo "== param set '$SET_LABEL' (dtmerge params: ${SET_PARAMS:-none})"
    if ! dtmerge "$base" "$MERGED_DTB" "$OVL_DTBO" ${PARAMS[@]+"${PARAMS[@]}"} >/dev/null \
       || [[ ! -s $MERGED_DTB ]]; then
      report FAIL "dtmerge: merge failed for params '${SET_PARAMS:-none}'"
      continue
    fi
    report PASS "dtmerge: merge succeeded"

    dtc -q -I dtb -O dts -o "$MERGED_DTS" "$MERGED_DTB" || { report FAIL "decompile: merged dtb"; continue; }
    flatten_dts "$MERGED_DTS" > "$FLAT"
    LC_ALL=C sort -u "$MERGED_DTS" | LC_ALL=C comm -13 "$BW/base.sorted" - > "$ADDED"
    awk 'FNR == NR { seen[$0] = 1; next } !($0 in seen)' "$BASE_FLAT" "$FLAT" > "$TOUCHED"
    build_groups

    IFS=',' read -ra CHECKS <<< "$SET_EXPECT"
    for id in "${CHECKS[@]}"; do
      run_check_by_id "$id"
    done
  done

  printf 'base %s: %d passed, %d failed\n' "$(basename "$base")" $((PASSES - p0)) $((FAILS - f0))
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
OVL_DTS="${1:-$REPO_ROOT/hackberrypicm5.dts}"
BASE_ARG="${2:-}"

[[ -r $OVL_DTS ]] || die "overlay not readable: $OVL_DTS"
command -v dtc >/dev/null || die "dtc not found (apt install device-tree-compiler)"
command -v dtmerge >/dev/null || die "dtmerge not found (/usr/local/bin/dtmerge or raspi-utils-dt)"

if [[ -n $BASE_ARG ]]; then
  BASES=("$BASE_ARG")
else
  BASES=()
  for c in cm5-cm5io cm5-cm4io cm5l-cm5io cm5l-cm4io; do
    f=/boot/firmware/bcm2712-rpi-$c.dtb
    if [[ -r $f ]]; then BASES+=("$f"); else echo "skip (not readable): $f"; fi
  done
  (( ${#BASES[@]} > 0 )) || die "no readable bcm2712-rpi-cm5{,l}-cm{5,4}io.dtb in /boot/firmware; pass a base dtb as the second argument"
fi
for b in "${BASES[@]}"; do [[ -r $b ]] || die "base dtb not readable: $b"; done

WORK="$(mktemp -d)"
trap 'rm -rf -- "$WORK"' EXIT

echo "overlay: $OVL_DTS"
echo "bases:   ${BASES[*]}"

OVL_DTBO="$WORK/overlay.dtbo"
echo "== dtc compile"
dtc -@ -I dts -O dtb "${DTC_WARN[@]}" -o "$OVL_DTBO" "$OVL_DTS" \
  || die "dtc compile failed (see errors above)"
echo "  [PASS] dtc: overlay compiles (warnings above are advisory)"

for b in "${BASES[@]}"; do
  run_base "$b"
done

echo
echo "Result: $PASSES passed, $FAILS failed across ${#BASES[@]} base(s)"
(( FAILS == 0 )) || exit 1
