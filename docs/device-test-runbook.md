# On-device test runbook (P4.1, P4.2)

Run these yourself on the CM5. Nothing here is run by Claude. Every step that
touches `/boot/firmware` uses `sudo`, so read each command first.

Safety net: **tryboot is one-shot.** If the new overlay hangs or shows a black
screen, power-cycle the device. It boots the normal `config.txt` again.
Fallback: HDMI, or edit the SD card from another machine.

Run everything from the repo checkout (this worktree or the merged branch).

## Stage 0: preflight (read-only plus backups)

```bash
tools/baseline.sh ~/hbp-baseline-before
tools/validate-overlay.sh
```

Expect `Result: ... 0 failed across 4 base(s)`. Stop if it fails.

Back up the files you will touch:

```bash
sudo cp -a /boot/firmware/config.txt /boot/firmware/config.txt.pre-hbp
sudo cp -a /boot/firmware/overlays/hackberrypicm5.dtbo /boot/firmware/overlays/hackberrypicm5.dtbo.works
```

Start the discharge log in its own terminal (P3.2 needs a full discharge;
unplug USB-C once the battery is charged, let it run to empty):

```bash
tools/discharge-log.sh ~/discharge.csv
```

## Stage 1: new overlay and driver under tryboot

1. Build the overlay under a **different name**, so the normal boot keeps the
   old one:

```bash
dtc -@ -I dts -O dtb -o /tmp/hackberrypicm5-next.dtbo hackberrypicm5.dts
sudo cp /tmp/hackberrypicm5-next.dtbo /boot/firmware/overlays/hackberrypicm5-next.dtbo
sync
```

2. Build and stage the driver. `updates/` outranks the hand-copied module in
   `kernel/`. Rollback is to delete this file and run `depmod -a`.

```bash
make
sudo install -D -m 644 hackberrypi-max17048.ko /lib/modules/$(uname -r)/updates/dkms/hackberrypi-max17048.ko
sudo depmod -a
```

3. Create `tryboot.txt` (Q1: this also removes the conflicting GPIO3/4 line,
   so the i2c-11 alias cannot collide):

```bash
sudo cp /boot/firmware/config.txt /boot/firmware/tryboot.txt
sudo nano /boot/firmware/tryboot.txt
```

In `tryboot.txt` only:
- change `dtoverlay=hackberrypicm5` to `dtoverlay=hackberrypicm5-next`
- **delete** the line `dtoverlay=i2c-gpio,bus=11,i2c_gpio_sda=3,i2c_gpio_scl=4`

Leave `config.txt` unchanged. Then:

```bash
sudo reboot '0 tryboot'
```

## Stage 2: checks after the tryboot boot (matrix, section 5 of the plan)

Run these immediately after the boot.

**First, make sure the new driver is the one running.** The initramfs loads the
old hand-copied module before `updates/` is consulted. If the two srcversions
differ, swap it live (no reboot, no `/boot` write):

```bash
cat /sys/module/hackberrypi_max17048/srcversion; modinfo -F srcversion /lib/modules/$(uname -r)/updates/dkms/hackberrypi-max17048.ko
sudo rmmod hackberrypi_max17048 && sudo modprobe hackberrypi_max17048
```

```bash
ls /proc/device-tree/chosen/bootloader/tryboot && xxd /proc/device-tree/chosen/bootloader/tryboot; ls -l /sys/bus/i2c/devices/ | grep -E 'i2c-11|11-00'
sudo dmesg | grep -Ei 'i2c|edt|max17048|dpi|panel|ebusy'
cat /sys/class/power_supply/battery/uevent
```

| # | Check | Pass |
|---|---|---|
| 1 | Desktop is visible, 720x720 | yes |
| 2 | `i2c-11` exists with `11-0048` and `11-0036` bound, no `-EBUSY` in dmesg | yes |
| 3 | Touch: tap and drag in all four corners | correct mapping |
| 3 | `/sys/class/power_supply/battery/uevent` compared with `~/hbp-baseline-before` | same fields, sane values |
| 4 | Unplug and plug USB-C at about 50 % and above 95 %. Watch `watch -n5 cat /sys/class/power_supply/{battery,ac}/uevent` or `upower -d` | plug-in: Charging within about 1 min; unplug: about 2 min (chip-limited, see below); no flapping |
| 5 | 1 h soak: `sudo dmesg -w \| grep -Ei 'i2c\|edt\|max17048'` | zero errors |
| 6 | Stemma-QT sensor (for example DHT20 at 0x38) on the shared bus while touching: `i2cdetect -y 11` | both work |

I2C transactions per refresh (must be 3 or fewer). The driver caches for 2 s,
so wait 3 s, then trigger exactly one read of the battery. The tracepoint line
shows the target as `a=036` (0x36); read the trace as root:

```bash
sudo sh -c 'echo 1 > /sys/kernel/tracing/events/i2c/enable; echo > /sys/kernel/tracing/trace'
sleep 3; cat /sys/class/power_supply/battery/uevent > /dev/null
sudo sh -c 'echo 0 > /sys/kernel/tracing/events/i2c/enable'
sudo grep ' a=036 ' /sys/kernel/tracing/trace
```

Count the transfers to address 0x36. If the grep prints nothing, look at
`sudo head -30 /sys/kernel/tracing/trace` to see the actual format before
trusting a zero. A background 30 s poll may add one burst; repeat if you see
more than 3.

Probe with the gauge absent (`no_fuelgauge` needs another tryboot, see below):
there must be no `battery` supply and dmesg shows no gauge error loop.

### Parameter variants (one tryboot each; edit only `tryboot.txt`)

Use `dtoverlay=hackberrypicm5-next,<params>`:

- `touch_inv_x`, `touch_inv_y`, `touch_swap_xy`: check the touch mapping.
- `no_fuelgauge`: no battery supply.
- `fuelgauge_mainline`: mainline `max17040_battery` binds the gauge
  (`ls /sys/bus/i2c/drivers/max17040`), battery visible.
- `charge_uah=5675000,energy_uwh=21000000`: uevent shows the new capacity.
- `hw_i2c` (row 9): `ls -l /sys/bus/i2c/devices/i2c-11` resolves to
  `.../i2c@74000`; compare CPU during a 30 s scribble in both modes
  (`top -b -n 30 -d 1 | grep -E 'irq|edt|Cpu'`); then a 1 h soak.

## Stage 3: promote or roll back

If everything passes, go to Stage 4 (the package does the promotion).
If not, no cleanup is needed for the boot: the next normal boot uses
`config.txt`. Remove the staged module if it misbehaves:

```bash
sudo rm /lib/modules/$(uname -r)/updates/dkms/hackberrypi-max17048.ko && sudo depmod -a
```

## Stage 4: package install, upgrade, remove, purge (P4.2)

Back up the SD card first. Needs `sudo apt install debhelper dh-dkms dkms`.

**Before installing the package, do all of these** (they remove the manual
Stage 1 changes so nothing conflicts):

1. Remove the GPIO3/4 line from the real `config.txt` too (the package then
   adds the overlay; with the old line still present, both buses ask for
   i2c-11 and touch and the gauge are lost):
   `sudo nano /boot/firmware/config.txt`, delete
   `dtoverlay=i2c-gpio,bus=11,i2c_gpio_sda=3,i2c_gpio_scl=4`.
2. Remove the staged and the old hand-copied modules, so DKMS owns the module
   (neither has a MODULE_VERSION, and dkms may refuse to install over them):

```bash
sudo rm -f /lib/modules/$(uname -r)/updates/dkms/hackberrypi-max17048.ko
sudo mv /lib/modules/$(uname -r)/kernel/drivers/power/supply/hackberrypi-max17048.ko ~/hbp-old-kernel-module.ko
sudo depmod -a
sudo update-initramfs -u
```

   The initramfs carries its own copy of the old module and loads it at boot,
   ahead of `updates/`. `update-initramfs -u` rewrites it (it lives under
   `/boot/firmware`), so it is your step. Check after every boot that the
   running build is the new one:
   `cat /sys/module/hackberrypi_max17048/srcversion` must equal
   `modinfo -F srcversion /lib/modules/$(uname -r)/updates/dkms/hackberrypi-max17048.ko`.

3. Remove the staged tryboot overlay: `sudo rm /boot/firmware/overlays/hackberrypicm5-next.dtbo`
   (the package installs `hackberrypicm5.dtbo`, with `.prev` as the backup of
   the one you had).

Then:

```bash
dpkg-buildpackage -b -us -uc
sudo apt install ../hackberrypi-max17048-dkms_1.2-1_all.deb
```

Check: `grep -n hackberrypi /boot/firmware/config.txt` (one managed block),
`ls -l /boot/firmware/overlays/hackberrypicm5.dtbo*`, `dkms status`, and
`sudo dkms autoinstall -k <other installed kernel>` builds (matrix row 7).
Reboot and repeat the Stage 2 checks.

Upgrade test: add a new changelog entry `1.2-2` (or `1.3-1`), rebuild, install
over the first, and confirm the overlay, config block and apt keyring/sources
all survive. Remove: the overlay and block go, nothing dangles. Purge:
`config.txt` equals the backup, apart from the GPIO3/4 line you removed
(`diff /boot/firmware/config.txt /boot/firmware/config.txt.pre-hbp`).

## Stage 5: bus speed, Ethernet off, fan and display tuning (2026-11-26)

The overlay now disables RP1 Ethernet by default (the Q20 schematic has no
Ethernet nets) and takes `i2c_hz` for the hw_i2c clock. `tools/stage-tryboot.sh`
stages all of it for one tryboot boot and never edits `config.txt`:

```bash
tools/stage-tryboot.sh --dry-run          # review the tryboot.txt diff first
sudo tools/stage-tryboot.sh               # hw_i2c at 400 kHz + config tweaks
sudo reboot '0 tryboot'
```

Its config tweaks are `display_auto_detect=0`, `enable_dpi_lcd`,
`display_default_lcd` and `dpi_group` removed, and a fan curve based on the Pi 5 default
(50/60/67.5/75 C at PWM 125/150/175/250, 5 C hysteresis) instead of the 40 C start. To test one change
at a time: `--params ""` (Ethernet off only), `--params hw_i2c` (100 kHz),
`--no-config-tweaks` (overlay only).

Why 400 kHz is a test and not the default: the bus has 10 kOhm pull-ups, a
1V8/3V3 level shifter to the touch controller and the Stemma-QT cable, so rise
times can exceed the fast-mode limit. If 400 kHz shows errors, try
`--params hw_i2c,i2c_hz=200000`.

Checks after the tryboot boot:

| # | Check | Pass |
|---|---|---|
| 1 | Desktop on DPI at 720x720 | yes |
| 2 | `readlink -f /sys/bus/i2c/devices/i2c-11` ends in `i2c@74000`; `cat /sys/firmware/devicetree/base/axi/pcie@1000120000/rp1/i2c@74000/clock-frequency \| od -An -tx1` shows `00 06 1a 80` | yes |
| 3 | Scribble on the touchscreen for 30 s with `top -d 1` open: no `irq/*-edt` thread near the top, compared with the same run on the normal boot | lower CPU |
| 4 | `dmesg \| grep -iE 'i2c\|edt\|max17048'` after 30 min, with a Stemma-QT sensor attached if you have one | no errors |
| 5 | `ip -br link` | no `eth0` |
| 6 | `cat /sys/class/hwmon/hwmon*/fan1_input` at idle, and `vcgencmd measure_temp` after 5 min of `stress-ng --cpu 4` | fan off at idle under 50 C; temp stays below 80 C |

Promote: copy the tested lines from `tryboot.txt` into `config.txt` (the
overlay parameters go on the `dtoverlay=hackberrypicm5` line inside the managed
block, which the package keeps), and install the new overlay under its normal
name, either by installing the package or by copying `hackberrypicm5-next.dtbo`
over `hackberrypicm5.dtbo` in **both** `overlays/` and `hb73/overlays/`.
The firmware reads overlays from `<os_prefix>overlays/`; the package postinst
mirrors the overlay there (with a `.prev`) since 2026-11-26.

Fan speeds: the base DT parameter is `fan_tempN_speed`. `fan_tempN_fan` is
silently ignored, so a curve written with it runs at the stock speeds
(PWM 75 at 50 C, which this fan stalls at).

## Measured results (2026-11-23, tryboot, new driver)

- Plug-in detection: voltage steps +186 mV at once, status Charging after
  49-56 s (the rate register has to cross +5 LSB).
- Unplug detection: voltage steps -191 mV at once, but status stays Charging for
  about 2 min (2:45 and 2:00 in two runs). The MAX17048 rate register averages
  over a couple of minutes, so it cannot flip sooner. With no ALRT line and no
  VBUS sense there is no non-polling signal. A voltage-step rule was rejected:
  the cell's internal resistance is about 0.13 ohm, so a 1.5 A load swing while
  charging gives the same 190 mV step, and the rule would report false
  Discharging under a CPU burst.
- The "about 1 min" criterion therefore holds for plug-in only.
- Open: bottom-right touch corner slightly off under KDE (the kernel reports
  719,718 correctly); not compared against the old overlay.
- Soak (row 5): stopped early by choice after about 25 min (started 10:40,
  tryboot config with hand-staged module): no i2c, edt or max17048 errors in
  dmesg. NOT the full hour; repeat on the packaged install.
- Packaged install (1.2-1): first attempt failed in postinst because a comment
  held the literal debhelper token, which dh expands everywhere. Fixed; the
  harness now asserts the token appears once per script. Rebuilt and installed
  over it; config.txt has one managed block, overlay equals the repo source.

## Measured results (2026-11-26, Stage 5, promoted to config.txt)

- tryboot, then normal boot: i2c-11 on RP1 `i2c@74000` at 400 kHz, touch and
  gauge bound, no i2c/edt/max17048 errors in dmesg, no `eth0`.
- Touch IRQ thread: 455 interrupts cost 40 ms CPU in total (about 0.09 ms per
  report) with hw_i2c.
- Fan: the first config used `fan_tempN_fan`, which the firmware ignores; the
  stock PWM 75 step stalls this fan at 50-60 C (kicks then stops). With
  `fan_tempN_speed`: cooling-levels `0 125 150 175 250`, 1275 rpm at 52.9 C.
- Maintainer scripts: re-run over a copy of this device's /boot/firmware is a
  byte-for-byte no-op (both overlay copies "already up to date"); fresh
  install, remove and purge on the same config round-trip cleanly.
