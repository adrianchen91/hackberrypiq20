# HackberryPi CM5 (Q20): DTS + MAX17048 driver improvement plan

Status: **plan only, nothing implemented**. Written 2026-11-23 from:
- the repo at `1f7b8c9` (`hackberrypicm5.dts`, `hackberrypi-max17048.c`, `debian/*`, CI),
- the live CM5 this repo runs on (kernel `6.12.34+rpt-rpi-2712`, read-only inspection),
- upstream [ZitaoTech/HackberryPiCM5](https://github.com/ZitaoTech/HackberryPiCM5): `Hardware/Schematic_HackberryPi_CM5_Q20.pdf`, `Operating System/hackberrypi.dts`, `Screen/Pre-Specification_TL040HDS30-B1620C_REV1.0.pdf`, `Battery/*` reports.

Priorities, in order: **boot safety > stability > performance > features**. Whatever touches `/boot/firmware` (the overlay, `config.txt`, the maintainer scripts) can leave the device with a black screen. These are the highest-risk changes and get the strictest gates.

---

## 1. Verified hardware map (schematic + live system)

| Function | Wiring (schematic) | Live confirmation | Implication |
|---|---|---|---|
| Touch + fuel gauge + Stemma-QT port | One bus: `TP_SDA`/`TP_SCL`. CN1 (SH1.0 4P) carries the same nets, with R34/R35 10 kΩ pull-ups to 3V3 | `13-0036` max17048, `13-0048` edt-ft5406 on `i2c-gpio` (GPIO10 SDA / GPIO11 SCL) | User sensors share this bus. Driver I²C traffic competes with touch traffic. |
| Touch IRQ | `TP_INT` → CM5 GPIO27 | pinctrl `gpio27` pull-up, falling edge, works | OK |
| Touch reset | `TP_RESET` only reaches the display FPC; not routed to CM5 | — | No `reset-gpios` possible |
| MAX17048 ALRT# | Only a 10 kΩ pull-up to 3V3; **no GPIO** | no IRQ in DT | The driver's IRQ path is dead code (and buggy, see D4) |
| MAX17048 QSTRT | Tied to GND | — | Quick-start isn't usable from hardware |
| Charger | IP5306 (U61) SOP8: LED1→LED2, LED2/3→R33/VBAT, **KEY = NC**, no SDA/SCL. IP5310 (U27) is the 5 V boost | the deployed overlay declares `ip5306@75` (no driver bound) | **It isn't the I²C variant.** No charger-state or VBUS-sense GPIO reaches the CM5, so "charging/mains online" can only be inferred from the gauge. |
| Backlight | `PANNELBLK_LEDK` comes from the keyboard BTB connector (the RP2040 keyboard MCU drives it) | — | No `backlight` node is possible from the CM5 side |
| DPI | `dpi_18bit_cpadhi_gpio0` = GPIO0-9, 12-17, 20-25 | 720×720, 36.832 MHz, 60.0 Hz | GPIO 10, 11, 18, 19, 26, 27 are free of DPI |
| HW I²C option | RP1 has the pin group `rp1_i2c1_10_11` (function `i2c1`; `i2c1` = `i2c_arm` = rp1 `i2c@74000`) | symbol present in the live DT | The bit-banged bus could become hardware I²C (P2.2) |
| Panel spec | TL040HDS30: 18-bit RGB, active area 71.93 mm, Fclk **typ 35 MHz** ("for reference only"), hfp 44, hpw 2, vfp 16, vpw 2 | the repo uses 36.832 MHz (60 Hz), upstream uses 35 MHz (≈57 Hz) | Keep the repo value; expose an override |
| Battery | Rated **5000 mAh / 18.5 Wh**, 2.75–4.2 V (UN38.3 report) | the **deployed** overlay says 5675 mAh / 21 Wh, and the driver clamps energy to 18.5 Wh | Decide the canonical value (Q2) |

## 2. Findings (ranked)

### Boot-critical / data-loss (packaging + `/boot`)
- **B1. `postrm` runs on `upgrade` too.** On every package upgrade it deletes the dtbo, the `dtoverlay=` line, **and the apt keyring/sources**. Only the dtbo and the config line get reinstalled. Result: after the first upgrade the apt repo is gone. If the new `postinst` fails part-way, the device boots with no DPI overlay (black screen).
- **B2. Non-atomic dtbo write.** `dtc … -o /boot/firmware/overlays/…` writes in place on FAT. A power loss or failure mid-write leaves a truncated overlay that `config.txt` still references. There's no backup of the previous good dtbo; the user keeps a manual `.dtbo.works`.
- **B3. `config.txt` append is section-blind.** `echo dtoverlay=… >> config.txt` lands inside whatever conditional section the file ends with (`[cm4]`, `[pi4]`, `[none]`…), so the overlay may silently never load. No backup is taken before editing.
- **B4. Conflicting line on the live device (outside the repo).** `config.txt` has `dtoverlay=i2c-gpio,bus=11,i2c_gpio_sda=3,i2c_gpio_scl=4`. GPIO3 is DPI HSYNC and GPIO4 is a DPI blue bit, and `i2c-11` is currently bound to them. It probably comes from upstream's "bus 11" docs, but it isn't needed: the real bus is GPIO10/11 in our overlay. It risks display glitches and wasted CPU. **The user removes it, through tryboot (Q1).** The scripts should detect and warn, never auto-edit.
- **B5. Drift: the deployed dtbo ≠ repo DTS.** The deployed version adds a `simple-battery` node, `ip5306@75`, different capacities and `__overrides__` (including a malformed `disable-touch = "-3-11"`). The deployed `.ko` (srcversion `478BC3…`) was copied into `kernel/drivers/power/supply/`, **not DKMS**, so it won't follow kernel upgrades. The repo needs to become the single source of truth.
- **B6. CI shell injection.** `dch … ${{ github.event.head_commit.message }}` is interpolated straight into bash.

### Driver stability
- **D1.** No chip presence or ID check in `probe`. A missing chip still registers `battery`, and every read fails (upower log spam). The functionality check is `SMBUS_BYTE`, but regmap needs word or plain I²C.
- **D2.** The poll worker runs on `system_wq` with no PM hooks, so it can touch I²C across suspend/resume. The reschedule is open-coded; use `devm_delayed_work_autocancel` (present in 6.12 headers).
- **D3.** `power_supply_changed()` fires unconditionally every 30 s for **both** supplies. Each one is a uevent, and upower re-reads every property.
- **D4.** The IRQ handler (only used if someone adds `interrupts`) reads STATUS but never clears `CONFIG.ALRT` or the STATUS alert bits. With `IRQF_TRIGGER_LOW` that's an **interrupt storm / hang**. The hardware has no ALRT GPIO, so remove the path, or fix it properly behind a DT property.
- **D5.** Sanity clamps are really battery constants (`MAX_ENERGY_UWH 18500000`). They silently clamp valid DT values, which explains the live inconsistency: charge 5.675 Ah next to energy 18.5 Wh.
- **D6.** The driver ignores the standard `monitored-battery` / `simple-battery` binding (`power_supply_get_battery_info`).

### Performance
- **P1.** Each property read issues its own I²C transactions. `capacity_level` = 3 reads, `status` = 2, mains `online` = 2. An upower refresh is about 20 bit-banged transactions on the bus the touchscreen uses. Fix: cache a snapshot (VCELL/SOC/CRATE) per poll, refreshed on demand when stale.
- **P2.** `i2c-gpio` bit-bangs with `udelay` spinning (≈100 kHz, `delay-us = 4`) for every touch report. Hardware RP1 `i2c1` on the same pins removes that CPU cost (opt-in, P2.2).

### Correctness of estimates
- **E1.** `TTE` is multiplied by `TUNING_FACTOR 8`, but `current_now` and `TTF` use the same CRATE unscaled. The base formula (225000·soc / 13·rate) is exact for 0.208 %/h, so the ×8 points to CRATE noise or lag, not to a formula error. The three values are mutually inconsistent.
- **E2.** `FULL` = soc ≥ 95 and |crate| small. On battery at 96 % while idle, that reports Full **and** mains online = 1. There's no hardware VBUS sense (see the map), so add hysteresis and use VCELL as well.

### Hygiene
- DTS: `interrupt-parent = <&gpio>` works only because Pi5 aliases `gpio` → `rp1_gpio`; make it explicit. The pinctrl node name `gpio27` can collide with other overlays. The touch node has superfluous `#address-cells`. `i2c-gpio` uses the deprecated `gpios` property instead of `sda-gpios`/`scl-gpios` with open-drain flags.
- Driver: 2-space indent (not kernel style), duplicated comment, non-const `of_device_id`, no `i2c_device_id`. The `fwnode` version guard is wrong (`power_supply_config.fwnode` already exists in 6.12).
- `debian/rules`: `override_dh_auto_clean` recipe is indented with spaces. `dkms.conf` version is duplicated against `VERSION`. README points to the upstream fork's apt repo. `control` should `Recommends: raspi-utils-dt` (for `dtmerge`).

## 3. Safety protocol (applies to every phase)

1. **Never apply an untested overlay to the boot config.** Use Pi 5/CM5 **tryboot**:
   ```
   sudo cp /boot/firmware/config.txt /boot/firmware/tryboot.txt
   # edit tryboot.txt: dtoverlay=hackberrypicm5-next   (new dtbo installed under that name)
   sudo reboot '0 tryboot'
   ```
   Tryboot is one-shot: a hang or a black screen recovers with a power cycle. Promote to `config.txt` only after the on-device checks pass. Recovery path: HDMI output, or edit the SD card from another machine.
2. **Offline validation gate** (`tools/validate-overlay.sh`, P0.2) must pass before any dtbo reaches a device. It runs `dtc -@ -Wall`, then `dtmerge` against `bcm2712-rpi-cm5-cm5io.dtb` for each override combination, then structural assertions on the merged tree.
3. Maintainer scripts **back up** `config.txt` and the previous dtbo before writing, write atomically (tmp → `sync` → `mv`), and never edit lines they didn't add (marker block).
4. The kernel module must never be on the boot path: not in initramfs, no `BUG_ON`, every error returned. DKMS build failure must not fail `apt` in a way that skips overlay install.
5. Every driver change gets a **1 h soak** on device: `dmesg` shows zero `i2c`/`edt_ft5x06`/`max17048` errors, touch still responsive.
6. Opus reviews every diff that touches `debian/*.post*`/`pre*`, the DTS fragment layout, or driver concurrency/PM, **before** it reaches a device.

## 4. Orchestration

- **Orchestrator: Sonnet 5.5** (`claude-sonnet-5-5`). Owns sequencing, the decisions log, merges and the on-device test runs with the user. It reads this file first.
- **Haiku 5.5** (`claude-haiku-5-5`) for self-contained tasks under 80k context with mechanical acceptance criteria.
- **Opus 5.5** (`claude-opus-5-5`) only where a subtle mistake bricks boot or hangs the kernel: maintainer-script semantics, driver concurrency/PM/IRQ, the HW-I²C fragment design, and the final pre-release review.
- One branch per phase. Each subagent gets: the task row below, the relevant section of this file, and the file paths. No subagent writes to `/boot` or runs `sudo`; on-device steps go through the orchestrator with the user.

| ID | Task | Model | Est. ctx | Depends | Acceptance |
|---|---|---|---|---|---|
| **P0.1** | `tools/baseline.sh`: read-only snapshot (power_supply uevents, `i2cdetect -l`, decompiled live dtbo, module srcversion, dmesg greps, config.txt copy) | Haiku | 15k | — | Runs without sudo; output saved; no writes outside the output dir |
| **P0.2** | `tools/validate-overlay.sh`: dtc -Wall + dtmerge per param combo + assertions (dpi okay, panel present, bus has @36/@48, GPIO27 pull-up, no claim on GPIO0-9/12-17/20-25 outside DPI) | Haiku | 30k | — | Fails on a deliberately broken DTS; passes on the current one |
| **P0.3** | Reconcile drift (B5): canonical DTS values, record decisions Q1-Q3 in `docs/decisions.md` | Sonnet (orch.) | — | P0.1, user | Decisions written |
| **P1.1** | Rewrite `preinst`/`postinst`/`postrm` (B1-B4): `$1`-aware (configure/upgrade/remove/purge), atomic dtbo + `.prev` backup, `config.txt` backup + marker block under `[all]`, keyring/sources removed **only on purge**, validate dtbo (dtmerge if present) before install, warn on conflicting `i2c-gpio`/`i2c_arm`/`spi` lines on DPI pins, abort cleanly if `/boot/firmware` isn't mounted rw | **Opus** | 50k | P0.2 | Scripts pass `shellcheck`; simulated upgrade 1.1→1.2, remove, purge and failed-dtc runs in a chroot/loop-mounted fake `/boot` all leave a bootable config |
| **P1.2** | `debian/rules` tab fix, `control` Recommends, single version source (`VERSION` → dkms.conf), README URLs + tryboot/recovery section | Haiku | 15k | — | `dpkg-buildpackage -b` clean, `lintian` no new errors |
| **P1.3** | CI: pass commit message via `env:` (B6), add the P0.2 step, build the module on an arm64 runner against rpi 6.12 and latest headers | Haiku (Sonnet review) | 25k | P0.2 | CI green; injection test commit message is inert |
| **P2.1** | DTS restructure: explicit `<&rp1_gpio>`; rename pinctrl node `hackberry_tp_int`; drop stray cells; `sda-gpios`/`scl-gpios` with `GPIO_OPEN_DRAIN` (keep `delay-us = <4>`); drop `ip5306@75` (Q4); add `simple-battery` + `monitored-battery` while keeping the legacy props for one release; `__overrides__`: `touch_inv_x`, `touch_inv_y`, `touch_swap_xy`, `no_touch`, `no_fuelgauge`, `fuelgauge_mainline` (compatible → `maxim,max17048`, a fallback if DKMS breaks after a kernel update), `charge_uah`, `energy_uwh`, `pclk`, `i2c_delay_us`; fixed bus number via `/aliases` if Q1 = yes | Sonnet | 40k | P0.2, P0.3 | P0.2 green for every param; tryboot passes on device; touch and battery identical to baseline |
| **P2.2** | *(opt-in, default off)* `hw_i2c` param: enable rp1 `i2c1` with `rp1_i2c1_10_11`, `clock-frequency = <100000>`, move the touch/gauge nodes under it and disable `i2c-gpio`. The fragment toggles must be mutually exclusive so both controllers can never drive GPIO10/11. | **Opus** design + review, Sonnet impl | 35k | P2.1 | dtmerge shows exactly one controller owning 10/11 per mode; on device, CPU during touch scribble measurably lower; 1 h soak clean |
| **P3.1** | Driver core (D1-D6, P1): VERSION-register probe check (→ `-ENODEV`), correct functionality check, cached snapshot under mutex with on-demand refresh, notify only on change (+ slow heartbeat), `system_freezable_power_efficient_wq` + `devm_delayed_work_autocancel` + PM ops, remove the IRQ path (or fix it: clear `CONFIG.ALRT` + STATUS), real sanity bounds (≈100 mAh–20 Ah, ≈0.5–100 Wh), `power_supply_get_battery_info` with legacy fallback | **Opus** | 45k | P0.1 | Builds warning-free on 6.12; probe fails cleanly with the gauge absent (test: `no_fuelgauge` + manual bind); I²C transactions per upower refresh ≤ 3 (count via `trace-cmd`/i2c tracepoints); 1 h soak clean |
| **P3.2** | Estimates (E1-E2): EMA-smoothed CRATE used consistently for current/TTE/TTF, drop the ×8 factor (or justify it with data); FULL/online with hysteresis + VCELL ≥ 4.15 V; document that mains is heuristic (no VBUS sense) | Sonnet | 30k | P3.1, P4.3 data | TTE within ±20 % of the measured discharge on one full cycle; no Full/online flapping at idle on battery |
| **P3.3** | Kernel coding style + `checkpatch.pl --strict` clean, const tables, `i2c_device_id`, fix the `fwnode` guard (field exists in 6.12; find the actual introducing version) | Haiku | 25k | P3.1, P3.2 | checkpatch clean; **no logic diff** (Sonnet verifies with `git diff -w` review) |
| **P4.1** | On-device install via DKMS (replace the hand-copied `.ko`), tryboot the new overlay, run the test matrix (§5) | Sonnet + user | — | P1-P3 | All §5 rows pass |
| **P4.2** | Package upgrade/remove/purge test on device (after backing up the SD card) | Sonnet + user | — | P1.1 | Overlay, config line and apt source survive upgrade; purge leaves config.txt identical to the pre-install backup |
| **P4.3** | `tools/discharge-log.sh`: 60 s CSV of uevent fields over a full discharge (feeds P3.2) | Haiku | 10k | — | CSV with timestamps, no root needed |
| **P5** | Final pre-release review of the whole diff against §3 | **Opus** | 60k | all | Written sign-off, or a list of blockers |

Parallelism: P0.1/P0.2/P1.2/P4.3 can run at once (Haiku). P1.1 and P3.1 (Opus) can run at once after P0. P2.x waits for P0.3's decisions.

## 5. On-device test matrix (P4.1)

| # | Check | Pass |
|---|---|---|
| 1 | Tryboot with the new dtbo: DPI shows the desktop at 720×720@60 | yes |
| 2 | Touch: tap/drag in all four corners, each inversion/swap param | correct mapping |
| 3 | `/sys/class/power_supply/battery/uevent` vs baseline | same fields; values sane |
| 4 | Unplug/plug USB-C at ~50 % and at >95 % | status/online settle within 2 polls, no flapping |
| 5 | 1 h soak, `dmesg -w` | zero I²C / edt / max17048 errors |
| 6 | Stemma-QT sensor (e.g. DHT20 @0x38) on the shared bus while touching | both work |
| 7 | `dkms autoinstall -k <other kernel>` | builds |
| 8 | `fuelgauge_mainline` param with the DKMS module removed | mainline `max17040_battery` binds, battery visible |
| 9 | (P2.2) `hw_i2c=on` vs off, `top` during 30 s scribble | lower CPU, no errors |

## 6. Decisions (answered by user 2026-11-23)

- **Q1 = yes.** Remove the conflicting GPIO3/4 `i2c-gpio` line (user does it via tryboot) and pin our bus to i2c-11 via `/aliases`.
- **Q2 = 5000 mAh / 18.5 Wh** canonical default (still an overlay param).
- **Q3 = opt-in.** `hw_i2c` ships default off.
- **Q4 = drop** `ip5306@75`.

Original questions, for reference:

- **Q1.** Remove the conflicting `dtoverlay=i2c-gpio,bus=11,i2c_gpio_sda=3,i2c_gpio_scl=4` line from your `config.txt`? It claims DPI pins. Then pin our bus to **i2c-11** (matches upstream docs and scripts) instead of the current dynamic `i2c-13`?
- **Q2.** Canonical battery: rated 5000 mAh / 18.5 Wh, or your deployed 5675 mAh / 21 Wh (a different pack?). Either way it becomes an overlay param.
- **Q3.** Ship `hw_i2c` as opt-in now and flip the default after a release of field testing? (recommended)
- **Q4.** OK to drop `ip5306@75`? The schematic shows the non-I²C IP5306. A read-only `sudo i2cdetect -y -r 13 0x75 0x75` before removal confirms whether anything ACKs there.
