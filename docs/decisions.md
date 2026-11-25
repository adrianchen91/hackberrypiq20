# Decisions log

Recorded 2026-11-23 from the user's answers (PLAN-dts-driver-improvements.md §6).

| # | Decision | Consequence |
|---|---|---|
| Q1 | Yes: remove the conflicting `dtoverlay=i2c-gpio,bus=11,i2c_gpio_sda=3,i2c_gpio_scl=4` line from the user's live config.txt (user does this via tryboot). Pin our bus to **i2c-11** via `/aliases`. | Scripts only warn about the line, never edit it. P2.1 adds the alias. |
| Q2 | Canonical battery: **5000 mAh / 18.5 Wh**. The deployed 5675 mAh / 21 Wh becomes an overlay param (`charge_uah`, `energy_uwh`). | Overlay defaults keep 5000000 uAh / 18500000 uWh. |
| Q3 | `hw_i2c` ships **opt-in (default off)**; flip the default after a release of field testing. | P2.2 proceeds. |
| Q4 | **Drop `ip5306@75`** (schematic: non-I2C IP5306). Confirmed: `sudo i2cdetect -y -r 13 0x75 0x75` shows `--` (nothing answers at 0x75), run by the user on the old overlay before any new overlay was applied. The repo DTS never contained it. | Nothing to add in repo DTS. |
| Q3 (revised 2026-11-26) | **hw_i2c is the default, at 100 kHz.** Tested on the reference unit at 400 kHz (no errors, touch IRQ cost about 0.09 ms per report). 100 kHz is the default because of the 10k pull-ups, the 1V8/3V3 level shifter and Stemma-QT cable capacitance; `i2c_hz=400000` opts in. | Fragments 6/7 active, 0/1 dormant; `hw_i2c=off` selects i2c-gpio. Existing `dtparam=hw_i2c` lines keep working. |
| Q5 | **Fan curve and `display_auto_detect=0` ship with the package** (2026-11-26). The curve (47.5/60/67.5/75 C, 5 C hysteresis, PWM 125/150/175/250) is in the overlay; the stock PWM 75 first step stalls the Q20 fan. `display_auto_detect=0` is a firmware setting, so postinst writes it inside the managed block and postrm removes it. | Overlay fragments 9-13, `fan_stock` keeps the firmware curve. The block parser accepts exactly that one extra line. |
