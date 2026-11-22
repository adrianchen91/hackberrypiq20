# P5: final pre-release review (1.2)

Reviewed 2026-11-23 against `PLAN-dts-driver-improvements.md` §3 (safety
protocol) and §4 (task acceptance). Scope: `git diff HEAD` plus the untracked
`tools/`, `tests/`, `docs/`, `.github/workflows/ci.yml`. The driver, the
maintainer scripts and the DTS were already reviewed line by line (P1.1, P2.2,
P3.1, P3.2). This review checks how the pieces fit together, walks through the
runbook, and checks the acceptance criteria.

## Verdict

**SIGN-OFF CONDITIONAL on the device matrix.** Nothing in the source can brick
boot. The overlay, the driver bindings and the DKMS packaging fit together.
Before P4.1/P4.2 runs, fix the four pre-device items (R1-R4). They are runbook
and changelog defects, not code defects. Then run the gates that could not run
here and the device matrix (see "Conditions for final sign-off").

## Evidence gathered here (read-only, no sudo)

| Check | Result |
|---|---|
| `tools/validate-overlay.sh hackberrypicm5.dts /boot/firmware/bcm2712-rpi-cm5-cm5io.dtb` | **375 passed, 0 failed** (about 9 s), every param set, both bus modes |
| Same tool on a broken copy (`status = "okay"` changed to `"disabled"`, in the scratchpad) | rc=1, **59 failed** (the gate does fail) |
| `tests/maintscripts/run.sh` (TMPDIR in the scratchpad) | **3738 passed, 0 failed** (dash, bash --posix, busybox sh, each with mawk and gawk); real `/boot/firmware`, keyring, sources and state dir unchanged |
| Driver built from a scratch copy, `make W=1` against `6.12.34+rpt-rpi-2712` | no warnings; aliases `of:...Chackberrypi,max17048-battery`, `i2c:max17048` |
| `tools/baseline.sh <scratch>` and `COUNT=2 tools/discharge-log.sh <scratch>.csv 1` | rc=0, no sudo; CSV has a header and timestamps |
| `dpkg-buildpackage -b -us -uc` on a scratch copy | **not run to completion**: `debhelper-compat (= 13)` is not installed. It reports source version **1.0-1** (see R1) |
| `shellcheck`, `checkpatch.pl`, `lintian`, `dch` | **not installed** on this host |
| Live facts | package not installed (`dpkg -l` empty); hand-copied module at `kernel/drivers/power/supply/hackberrypi-max17048.ko` (srcversion 478BC3...) is loaded; dkms 3.2.2; `MODULES=most`; no hackberrypi entry in `/etc/modules*`/`modprobe.d`; `/proc/device-tree/chosen/bootloader/tryboot` exists (= 0 now); deployed dtbo has `monitored-battery` to a 5675 mAh / 21 Wh `simple-battery` and `ip5306@75` |

## Cross-checks: do the pieces fit?

**Overlay vs driver.**
- Default compatible `hackberrypi,max17048-battery` matches the driver's only
  OF id. `fuelgauge_mainline` rewrites it to `maxim,max17048`. That matches
  `max17040_battery.ko.xz`, which ships in 6.12.34. Both bus-mode copies of
  the node (`fuel_gauge`, `fuel_gauge_hw`) are covered by every override.
- `monitored-battery` points to `battery_info` (fragment 5, merged in both
  modes, `simple-battery`). The driver calls `power_supply_get_battery_info()`
  after registration, with `of_node` set on 6.12, so the phandle resolves.
  The legacy `charge-full-design-microamp-hours` and
  `energy-full-design-microwatt-hours` are still on the node as the fallback,
  and `charge_uah`/`energy_uwh` write all three nodes, so the two sources
  cannot disagree. Defaults are 5000 mAh / 18.5 Wh (Q2). The driver's bounds
  (about 100 mAh-20 Ah, 0.5-100 Wh) accept both 5000/18.5 and 5675/21.
- hw_i2c: `!0!1=6=7` swaps the bus fragments. The validator confirms exactly
  one enabled owner of GPIO10/11, `i2c11` pointing to the active controller,
  and `i2c1` redirected in hw mode.
- Compatibility of the new module with the old overlay matters during runbook
  Stage 1-3, because the staged module also loads on normal boots. The
  deployed dtbo uses the same compatible and has `monitored-battery`, so the
  new driver binds and reports 5675 mAh / 21 Wh. That is expected, and it is
  not on the boot path.
- **Overlap (F1):** the new `i2c_device_id "max17048"` is the same id that
  mainline `max17040_battery` uses. For an OF client with compatible
  `maxim,max17048`, `client->name` is `max17048`, so if our module is loaded,
  `i2c_device_match()` falls back to our id table and our driver can claim the
  node meant for the mainline driver. It is not autoloaded in that mode,
  because OF clients emit only the `of:` modalias, so the risk is low. It
  still weakens the fallback.

**DKMS packaging.**
- `debian/rules`: `version` is the changelog version with the revision
  stripped. `dh_install` puts the files in
  `/usr/src/hackberrypi-max17048-$(version)/`, and `dh_dkms -V$(version)`
  replaces `#MODULE_VERSION#` in `debian/hackberrypi-max17048-dkms.dkms`
  (installed as that directory's `dkms.conf`).
- CI runs `dch -v "$(cat VERSION)"` and gets 1.2 throughout:
  `/usr/src/hackberrypi-max17048-1.2`, dkms 1.2, package 1.2. **Consistent.**
- postinst `find_dts()` uses `dpkg-query -L` and falls back to the version
  with the revision stripped, so it matches the same directory. The preinst
  gate `lt 1.2~` treats every <= 1.1 build (including `1.1-1`) as destructive
  and every 1.2 build as fixed. Correct for CI builds.
- **Without CI it is not consistent (R1):** `debian/changelog` is still
  `1.0-1`. A local `dpkg-buildpackage`, which runbook Stage 4 uses, produces
  package 1.0-1, `/usr/src/...-1.0` and dkms 1.0, against `VERSION` 1.2. It is
  also a native (3.0) source with a Debian revision.
- The top-level `dkms.conf` now holds the unreplaced placeholder. It is not
  installed (`dh_install` lists only `.c`, `.dts` and `Makefile`), but a
  manual `dkms add .` from the repo would get version `#MODULE_VERSION#` (F6).
- `debian/control`: `Recommends: raspi-utils-dt`. This host's apt cache has no
  such package (`dtmerge` here is `/usr/local/bin`). A missing Recommends is
  harmless, and postinst falls back to dtc-only validation (F7).

**CI.**
- `build_n_deploy.yml` passes the commit message through `env:` and uses `--`
  in the quoted `dch` call (B6 fixed).
- The validate job's base-dtb step is `continue-on-error`. The sparse checkout
  holds only `arch/arm64/boot/dts` and `include`, so the step may fail on
  every run and only emit a warning, while the release job still runs (F2).
- `ci.yml` builds the module only against Ubuntu `linux-headers-generic`. It
  does not build against the rpi 6.12 headers that P1.3 asks for (F3).

## Runbook walk-through (`docs/device-test-runbook.md`)

What is right:
- The new dtbo goes in under a different name (`hackberrypicm5-next`), and
  only `tryboot.txt` is edited.
- `sudo reboot '0 tryboot'` is the correct Pi 5/CM5 invocation. Tryboot is
  one-shot: the flag is lost on a power cycle, and a normal reboot reads
  `config.txt`.
- The config.txt and dtbo backups are taken first.
- `updates/` does take precedence over `kernel/`: there is no depmod.d
  override, so the default search order applies.
- Rollback is `rm` plus `depmod -a`.
- The module is not in the initramfs: with `MODULES=most` there is no
  power/supply hook and nothing calls `update-initramfs`. Confirm with
  `lsinitramfs /boot/firmware/initramfs_2712 | grep -i max17048`, which
  should print nothing.

No step can brick boot or lose data. The defects:

- **R2: the conflicting GPIO3/4 line is never removed from `config.txt`.** It
  is deleted only in `tryboot.txt`. Stage 4 says "verify it is gone" but has
  no step that removes it, and the package only warns. After the package
  promotes the overlay, a normal boot has two adapters that want bus 11, and
  one of them fails. That loses touch and the gauge, but DPI keeps working,
  because it works with that line today. Add an explicit step: back up, then
  delete the line in `config.txt` before the Stage 4 reboot. Also note that
  the purge diff against `config.txt.pre-hbp` will then differ by exactly
  that line.
- **R3: old modules are never retired.** Two copies would remain: the
  hand-copied `kernel/drivers/power/supply/hackberrypi-max17048.ko` (B5) and
  the copy staged in Stage 1 under `updates/dkms/`. Neither has a
  `MODULE_VERSION`, so dkms 3.2.2's version check may refuse or skip the
  install ("exactly matches"), or take the "multiple modules found" path. B5
  needs DKMS to own the module. Before Stage 4: remove the staged copy, move
  the `kernel/` copy out of `/lib/modules`, then run `depmod -a`. Afterwards,
  check that `modinfo -n hackberrypi-max17048` gives `.../updates/dkms/...`
  and that `dkms status` shows `installed`.
- **R4a: the tryboot check reads the wrong place.** `grep tryboot /proc/cmdline`
  prints nothing, because the firmware does not put the flag on the kernel
  command line. Use
  `od -An -tu4 --endian=big /proc/device-tree/chosen/bootloader/tryboot`
  (1 = tryboot boot). On this device it reads 0 now, as expected.
- **R4b: the I2C-count check cannot fail.** The `i2c_write` and `i2c_read`
  tracepoints print the address in hex (`a=036`), not as `addr=54`, so the
  grep counts 0 and the "≤ 3" criterion passes falsely. Check the format on
  the first trace line. `upower -d` only dumps the daemon's cache, so it does
  not cause a sysfs read. Instead, trace while running
  `cat /sys/class/power_supply/battery/uevent` (with the cache stale, that is,
  more than one poll after the last read) and count
  `grep -c 'i2c_write.*a=036'`.
- R1 also affects Stage 4: see the packaging section above. Either bump the
  changelog to 1.2, or build with `dch -v 1.2` first (needs devscripts) or use
  the CI artifact. Otherwise the P4.2 upgrade test from a local `1.0-x` build
  runs the legacy `< 1.2~` path, not the 1.2 → 1.2.x path it is meant to test.
- Minor:
  - Stage 0 "4 bases" holds only if all four cm5/cm5l × cm5io/cm4io dtbs are
    readable.
  - Stage 4 also needs `dpkg-dev`; this host lacks `debhelper`.
  - If the DKMS build fails, the package stays half-configured: apt errors,
    but the overlay is already installed because it runs before
    `#DEBHELPER#`. Recover with `sudo dpkg --configure -a` after fixing the
    headers.

## §3 safety protocol

| Rule | Status | Evidence |
|---|---|---|
| 1 Tryboot first | MET (procedure) | Runbook Stage 1-3, README section. R4a fixes the verification command |
| 2 Offline gate before any device | MET locally / PARTIAL in CI | 375/0 on cm5io, negative test fails; postinst re-validates with dtmerge when present. CI may skip (F2) |
| 3 Backup, atomic, marker block | MET (offline) | Harness 3738/0; real /boot untouched. NEEDS-DEVICE for P4.2 |
| 4 Module off the boot path | MET (offline) | No `BUG`/`panic` in driver; errors returned; not in initramfs (`MODULES=most`, no hook); overlay runs before `#DEBHELPER#` |
| 5 1 h soak per driver change | NEEDS-DEVICE | Matrix row 5 |
| 6 Opus review of risky diffs | MET | P1.1, P2.2, P3.1 reviews, plus this P5 |

## §4 acceptance criteria

| ID | Criterion | Status | Evidence / gap |
|---|---|---|---|
| P0.1 | No sudo, output saved, no writes outside out dir | MET | Ran to scratch, rc=0 |
| P0.2 | Fails on a broken DTS, passes on the current one | MET | 59 failures vs 375/0 |
| P0.3 | Decisions written | MET | `docs/decisions.md` Q1-Q4 |
| P1.1 | `shellcheck` clean | **NOT MET** (tool absent) | CI runs only `sh -n`/`bash -n` |
| P1.1 | Simulated upgrade 1.1→1.2, remove, purge, failed dtc leave a bootable config | MET (offline) | Harness 3738/0, 3 shells × 2 awks |
| P1.2 | rules tab, Recommends, single version source, README URLs + tryboot | MET | diff |
| P1.2 | `dpkg-buildpackage -b` clean, `lintian` no new errors | **NOT VERIFIED** | debhelper/lintian absent; changelog 1.0-1 (R1) |
| P1.3 | Commit message via env, inert | MET (inspection) | `COMMIT_MSG` env, quoted, `--` |
| P1.3 | P0.2 step added | PARTIAL | Present but may be skipped silently (F2) |
| P1.3 | arm64 build against rpi 6.12 + latest headers; CI green | **NOT MET / NOT VERIFIED** | Ubuntu generic headers only; never pushed |
| P2.1 | P0.2 green for every param | MET | 375/0 (cm5io; Stage 0 covers all 4 bases) |
| P2.1 | Tryboot passes; touch/battery same as baseline | NEEDS-DEVICE | Rows 1-3 |
| P2.2 | Exactly one controller on 10/11 per mode | MET | `one_owner` passes in both modes |
| P2.2 | Lower CPU during scribble; 1 h soak | NEEDS-DEVICE | Row 9 |
| P3.1 | Builds warning-free on 6.12 | MET | `make W=1`, 0 warnings |
| P3.1 | Clean probe failure with the gauge absent | NEEDS-DEVICE | `no_fuelgauge` + manual bind |
| P3.1 | ≤ 3 I2C transactions per refresh | NEEDS-DEVICE | Runbook command broken (R4b) |
| P3.1 | 1 h soak | NEEDS-DEVICE | Row 5 |
| P3.2 | ×8 dropped, EMA, VCELL ≥ 4.15 V hysteresis | MET (code) | No `TUNING_FACTOR`; `MAX17048_FULL_VCELL_UV 4150000` |
| P3.2 | TTE within ±20 % on a full discharge | NEEDS-DEVICE | Needs the `discharge-log.sh` CSV of a full cycle |
| P3.2 | No Full/online flapping at idle | NEEDS-DEVICE | Row 4 |
| P3.3 | `checkpatch.pl --strict` clean | **NOT MET** (tool absent) | — |
| P3.3 | const tables, `i2c_device_id` | MET | See F1 about the id string |
| P3.3 | Fix the fwnode guard | **NOT MET (deferred)** | Kept at 6.18 on purpose, with a comment; works on 6.12 and 6.18 |
| P3.3 | No logic diff (`git diff -w`) | NOT VERIFIED here | — |
| P4.1 | All §5 rows pass | NEEDS-DEVICE | After R1-R4 |
| P4.2 | Survives upgrade; purge gives back the backup | NEEDS-DEVICE | After R1, R2 |
| P4.3 | CSV with timestamps, no root | MET | 2-sample smoke run |

## Blockers

Pre-device, all cheap. None is a boot or data-loss risk in the source.

- **R1** `debian/changelog` is still `1.0-1`. Add a `1.2` entry, and make CI's
  `dch -v "$(cat VERSION)"` tolerate an equal top version (or suffix it, for
  example `+ci<run>`, which still satisfies `ge 1.2~`). Or use the CI `.deb`
  for P4.2.
- **R2** Runbook: add the explicit, backed-up removal of the GPIO3/4
  `i2c-gpio` line from `config.txt` before the Stage 4 reboot.
- **R3** Runbook: retire the hand-copied `kernel/` module and the Stage 1
  staged module before the DKMS install, then verify `modinfo -n` and
  `dkms status`.
- **R4** Runbook: correct the tryboot check (DT property) and the I2C-count
  check (`a=036`, sysfs read instead of `upower -d`).

Release gates not yet run, needed for final sign-off: shellcheck, checkpatch
`--strict`, `dpkg-buildpackage -b` and lintian, CI green on a pushed branch,
and the device matrix.

## Non-blocking follow-ups

- **F1** Rename the `i2c_device_id` to `"max17048-battery"`, or drop it, so it
  no longer shares an id with mainline `max17040_battery`. This keeps
  `fuelgauge_mainline` unambiguous. Low effort; ideally before release.
- **F2** CI overlay gate: commit a reference base dtb, or fail the release
  when validation is skipped. The sparse checkout likely misses include paths.
- **F3** Add an rpi-6.12 headers build (for example the rpi kernel source with
  `bcm2712_defconfig` and `modules_prepare`).
- **F4** Resolve the fwnode guard version (P3.3).
- **F5** CI rebuilds with an unchanged `VERSION` produce the same package
  version, so apt never upgrades. Suffix it with the run number.
- **F6** Remove or document the top-level `dkms.conf` placeholder.
- **F7** Confirm the `raspi-utils-dt` package name in the RPi OS archive.
- **F8** Consider `MODULE_VERSION` (from `VERSION`) so the dkms version check
  works properly.
- **F9** README: note `dpkg --configure -a` recovery after a DKMS build
  failure.

## Conditions for final sign-off

1. R1-R4 fixed. Re-run `tests/maintscripts/run.sh` and
   `tools/validate-overlay.sh` (all bases) afterwards.
2. On a host with the tools: `shellcheck` on `debian/*.p*` and `tools/*.sh`,
   `checkpatch.pl --strict -f hackberrypi-max17048.c`, and
   `dpkg-buildpackage -b -us -uc` plus `lintian`, all clean or with justified
   waivers.
3. CI green on the pushed branch (both workflows). The validate job actually
   runs, not the skip warning.
4. Device matrix §5 rows 1-9 pass under tryboot, then after the package
   install, including the 1 h soaks (default mode and `hw_i2c`), the
   `no_fuelgauge` probe test, `dkms autoinstall -k <other kernel>`, and
   `fuelgauge_mainline` with the DKMS module removed.
5. I2C count ≤ 3 per refresh, measured with the corrected trace command.
6. P3.2: one full discharge CSV with TTE within ±20 % of the measured time to
   empty, and no Full/online flapping at idle on battery.
7. P4.2 on a backed-up SD card: install, upgrade to a higher 1.2.x, remove,
   purge. The overlay, block and apt source survive the upgrade. After purge,
   `config.txt` equals `config.txt.pre-hbp` except for the GPIO3/4 line the
   user removed.

## Resolution of pre-device blockers (orchestrator, 2026-11-23)

- R1: `debian/changelog` bumped to `1.2-1` (matches `VERSION` 1.2).
- R2: runbook Stage 4 now removes the GPIO3/4 line from the real `config.txt` before installing the package.
- R3: runbook Stage 4 removes the staged module and moves the hand-copied `kernel/` module away before the DKMS install, then runs `depmod -a`.
- R4: tryboot check uses `/proc/device-tree/chosen/bootloader/tryboot`; the I2C count greps ` a=036 ` after a sysfs read (with a 3 s cache wait) and tells the user to check the real trace format first.
- F1: driver `i2c_device_id` renamed to `max17048-battery` so it no longer shadows the mainline driver's id.
- Still open (non-blocking): F2 (CI overlay gate can be skipped silently), shellcheck/checkpatch/lintian not run, `dpkg-buildpackage` not run here.
- Final sign-off still requires the device matrix (runbook stages 1-4) and the discharge-log TTE check.
