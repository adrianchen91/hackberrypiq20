# Decisions log

Recorded 2026-11-23 from the user's answers (PLAN-dts-driver-improvements.md §6).

| # | Decision | Consequence |
|---|---|---|
| Q1 | Yes: remove the conflicting `dtoverlay=i2c-gpio,bus=11,i2c_gpio_sda=3,i2c_gpio_scl=4` line from the user's live config.txt (user does this via tryboot). Pin our bus to **i2c-11** via `/aliases`. | Scripts only warn about the line, never edit it. P2.1 adds the alias. |
| Q2 | Canonical battery: **5000 mAh / 18.5 Wh**. The deployed 5675 mAh / 21 Wh becomes an overlay param (`charge_uah`, `energy_uwh`). | Overlay defaults keep 5000000 uAh / 18500000 uWh. |
| Q3 | `hw_i2c` ships **opt-in (default off)**; flip the default after a release of field testing. | P2.2 proceeds. |
| Q4 | **Drop `ip5306@75`** (schematic: non-I2C IP5306). Confirmed: `sudo i2cdetect -y -r 13 0x75 0x75` shows `--` (nothing answers at 0x75), run by the user on the old overlay before any new overlay was applied. The repo DTS never contained it. | Nothing to add in repo DTS. |
