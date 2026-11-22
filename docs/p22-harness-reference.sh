#!/usr/bin/env bash
# ad-hoc P2.2 checks: usage p22test.sh overlay.dts base.dtb
set -u
OVL=$1; B=$2; W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
dtc -q -@ -I dts -O dtb -o $W/o.dtbo "$OVL" || { echo COMPILE FAIL; exit 1; }
I2C1=/axi/pcie@1000120000/rp1/i2c@74000
PH=$(fdtget $B /axi/pcie@1000120000/rp1/gpio@d0000/rp1_i2c1_10_11 phandle)
fail=0
run() { label=$1; mode=$2; shift 2
  if ! dtmerge $B $W/m.dtb $W/o.dtbo "$@" >/dev/null 2>&1; then echo "[FAIL] $label merge"; fail=1; return; fi
  M=$W/m.dtb; res=""
  g=0; fdtget $M /i2c-gpio compatible >/dev/null 2>&1 && { st=$(fdtget -ts $M /i2c-gpio status 2>/dev/null || echo okay); [[ $st == okay ]] && g=1; }
  h=0; st=$(fdtget -ts $M $I2C1 status); p0=$(fdtget $M $I2C1 pinctrl-0); [[ $st == okay && $p0 == $PH ]] && h=1
  # any other enabled node referencing rp1_i2c1_10_11 phandle?
  others=$(dtc -q -I dtb -O dts $M | grep -c "pinctrl-0 = <$(printf '0x%x' $PH)>")
  owners=$((g+h)); a11=$(fdtget -ts $M /aliases i2c11); a1=$(fdtget -ts $M /aliases i2c1)
  if [[ $mode == gpio ]]; then P=/i2c-gpio; else P=$I2C1; fi
  n48=$(dtc -q -I dtb -O dts $M | grep -c 'touchscreen@48 {'); n36=$(dtc -q -I dtb -O dts $M | grep -c 'battery@36 {')
  ok=1
  [[ $owners == 1 && $g == $([[ $mode == gpio ]] && echo 1 || echo 0) ]] || { ok=0; res+=" owners=$owners(g=$g,h=$h)"; }
  [[ $others == $h ]] || { ok=0; res+=" i2c1_10_11-refs=$others"; }
  [[ $n48 == 1 && $n36 == 1 ]] || { ok=0; res+=" n48=$n48 n36=$n36"; }
  [[ $a11 == $P ]] || { ok=0; res+=" i2c11=$a11"; }
  [[ $mode == gpio || $a1 != $I2C1 ]] || { ok=0; res+=" i2c1alias=$a1"; }
  fdtget -ts $M $P/touchscreen@48 compatible >/dev/null 2>&1 || { ok=0; res+=" touch-not-under-$P"; }
  irq=$(fdtget $M $P/touchscreen@48 interrupts 2>/dev/null); [[ $irq == "27 2" ]] || { ok=0; res+=" irq=$irq"; }
  mb=$(fdtget $M $P/battery@36 monitored-battery 2>/dev/null); bp=$(fdtget $M /hackberry-battery phandle)
  [[ -n $mb && $mb == $bp ]] || { ok=0; res+=" monitored-battery=$mb!=$bp"; }
  [[ $mode == gpio ]] || { hz=$(fdtget $M $I2C1 clock-frequency); [[ $hz == 100000 ]] || { ok=0; res+=" hz=$hz"; }; }
  # dpi always okay
  [[ $(fdtget -ts $M /axi/pcie@1000120000/rp1/dpi@148000 status) == okay ]] || { ok=0; res+=" dpi-off"; }
  T=$P/touchscreen@48; F=$P/battery@36
  extra=$(for kv in "$@"; do case $kv in
    touch_inv_x*) [[ $kv == *=0 || $kv == *=off ]] || fdtget $M $T touchscreen-inverted-x >/dev/null 2>&1 || echo inv_x;;
    touch_inv_y*) fdtget $M $T touchscreen-inverted-y >/dev/null 2>&1 || echo inv_y;;
    touch_swap_xy*) fdtget $M $T touchscreen-swapped-x-y >/dev/null 2>&1 || echo swap;;
    no_touch*) [[ $(fdtget -ts $M $T status 2>/dev/null) == disabled ]] || echo no_touch;;
    no_fuelgauge*) [[ $(fdtget -ts $M $F status 2>/dev/null) == disabled ]] || echo no_fg;;
    fuelgauge_mainline*) [[ $(fdtget -ts $M $F compatible) == maxim,max17048 ]] || echo mainline;;
    charge_uah=*) v=${kv#*=}; [[ $(fdtget $M $F charge-full-design-microamp-hours) == $v && $(fdtget $M /hackberry-battery charge-full-design-microamp-hours) == $v ]] || echo charge;;
    energy_uwh=*) v=${kv#*=}; [[ $(fdtget $M $F energy-full-design-microwatt-hours) == $v && $(fdtget $M /hackberry-battery energy-full-design-microwatt-hours) == $v ]] || echo energy;;
    pclk=*) [[ $(fdtget $M /panel/panel-timing clock-frequency) == ${kv#*=} ]] || echo pclk;;
    i2c_delay_us=*) [[ $mode == hw ]] || [[ $(fdtget $M /i2c-gpio i2c-gpio,delay-us) == ${kv#*=} ]] || echo delay;;
  esac; done)
  [[ $mode == gpio ]] && [[ " $* " != *touch_inv_x* ]] && fdtget $M $T touchscreen-inverted-x >/dev/null 2>&1 && extra+=" stray-inv_x"
  [[ -z $extra ]] || { ok=0; res+=" params:$extra"; }
  if ((ok)); then echo "[PASS] $label ($mode)"; else echo "[FAIL] $label ($mode):$res"; fail=1; fi
}
run default gpio
run hw_i2c_off gpio hw_i2c=off
run hw_i2c_0 gpio hw_i2c=0
run hw_i2c hw hw_i2c
run hw_i2c_on hw hw_i2c=on
run hw_i2c_1 hw hw_i2c=1
for p in touch_inv_x touch_inv_y touch_swap_xy no_touch no_fuelgauge fuelgauge_mainline "charge_uah=5675000 energy_uwh=21000000" pclk=40000000 i2c_delay_us=8; do
  run "gpio:$p" gpio $p; run "hw:$p" hw hw_i2c $p; run "hw-last:$p" hw $p hw_i2c
done
run "hw:all" hw hw_i2c touch_inv_x touch_inv_y touch_swap_xy no_fuelgauge charge_uah=5675000 energy_uwh=21000000 fuelgauge_mainline
run "gpio:all" gpio touch_inv_x touch_inv_y touch_swap_xy no_touch no_fuelgauge hw_i2c=off
run "hw:twice" hw hw_i2c hw_i2c
run "hw:on-then-off" gpio hw_i2c=on hw_i2c=off
exit $fail
