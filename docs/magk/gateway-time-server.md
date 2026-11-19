# Gateway time server runbook (AD-4 / INF-4)

STAGED. UNTESTED ON HARDWARE. Off by default. Nothing here has run on a gateway.

## What it does

The MAGK gateway (Raspberry Pi 4 with an MM6108 HaLow module, OpenMANET image) runs chrony and answers NTP from the mesh subnet (default 10.41.0.0/16). The objective units point systemd-timesyncd at the gateway address (`server.time_source`, default gateway address 10.41.0.1). It is installed and configured only by `magk-provision-node` when `TIME_SERVER=1` and the role is `gateway`.

## Files in this change

| File | Purpose |
|---|---|
| `boards/common_extras/time_diffconfig` (symlinked from `boards/ekh-bcm2711/`) | adds package `chrony`. The setup script requires every non-target `*_diffconfig` in a board directory to be a symlink into `common_extras`. `MINIMAL=1` builds read only `target_diffconfig`, so they have no chrony and no time server (apply warns and does nothing). Other boards can opt in with `-x time` |
| `tests/time_server_guard_test.sh` | dev-machine harness (stubs only), 84 checks, see Tests below |
| `files/usr/sbin/magk-time-server` | renders and applies the chrony config, firewall rules, DHCP option; `status` |
| `files/etc/init.d/magk-time-guard` | boot step before chronyd (START=14), inert unless `apply` created `/etc/chrony/magk-time-server.enabled` |
| `files/usr/sbin/magk-provision-node` | calls `magk-time-server apply` (gateway, TIME_SERVER=1) or `remove` (every other case) with `MAGK_TIME_STAGE_ONLY=1`, so uci changes are staged and the provisioner's own single commit and reload applies them |
| `files/etc/magk-node.env.example` | documents `TIME_SERVER`, `TIME_UPSTREAM`, `TIME_GPS`, `TIME_LOCAL_STRATUM`, `TIME_ALLOW`, `TIME_DHCP_OPTION` |

## Stale-clock guard

Problem: a Pi 4 has no RTC, and `local stratum` would make the gateway serve whatever its clock reads after a power cut. Units would follow it, and a clock that is behind breaks TLS certificate checks.

Design (fake-hwclock pattern plus a gate on the local fallback):

1. While chronyd is synced to a real source (an upstream host or GPS, never the local fallback), cron runs `magk-time-server save-lastgood` every 10 minutes. A reading is recorded only when all of these hold: stratum below 16, absolute system time offset below 1.0 s (`chronyc -c tracking` field 5, UNVERIFIED on the built version), the clock is inside the window 2026-01-01 to 2030-01-01 UTC (the upper bound becomes the image build stamp plus one year once `/etc/magk-build-ts` is stamped, TBR below), and the value is above the previous record. It writes at most once per hour (24 flash writes a day at most).
2. A reading that is more than 2 hours past the previous record plus the uptime since that record was written (the first record of a boot is bounded by the uptime since boot; the reference is a tmpfs file cleared at boot) is a "big jump". Measuring from the last write, not from boot, stops a gateway with a long uptime from storing a large forward step unconfirmed (round 2, N3). It is recorded only on a second sighting at least 5 minutes later whose wall-clock difference agrees with the monotonic uptime difference within 2 minutes. This stops a one-off bad reading. It does NOT stop an upstream that stays wrong for the whole period (plain NTP to pool hosts is unauthenticated, AD-9 D2).
3. At boot, before chronyd, `guard-start` sets the clock forward to `lastgood` if it is behind. A `lastgood` outside the window is ignored, so an already poisoned file does not move the clock.
4. `local stratum` (the fallback, written to `/var/etc/chrony.d/20-magk-local.conf`, loaded by chrony's `confdir`) is allowed as follows:
   - A gateway with `TIME_UPSTREAM` or `TIME_GPS` set ("gated", recorded as `gated=1` in `/etc/chrony/magk-time-server.enabled`): withheld at boot, and opened by the cron step on the first sighting synced to a real source, with a chronyd restart. This closes the window in which a freshly booted gateway answered from its saved clock before any upstream had replied, and it also opens the fallback after the first sync without a reboot.
   - A gateway with neither: allowed at boot when a `lastgood` exists. It has no source, so it is set by an operator.
   - A fitted RTC does NOT open it (round 2, N2, see the RTC section for why). The RTC only helps the kernel set the clock at boot.
5. Operator seed: check the clock against a trusted reference, set it with `date -s`, then run `magk-time-server seed`. This is an assertion by the operator, is logged, refuses a clock outside the window, writes the RTC when one is fitted, and opens the fallback. **On a gated gateway (upstream or GPS set) the seed opens the fallback for the current boot only.** After a reboot the fallback stays withheld until the first real sync, because `lastgood` does not open a gated gateway at boot. `seed` prints a warning to that effect, and `status` prints one on stderr when a gated gateway is serving the local fallback without a current real sync. A gateway that must serve a seeded time across reboots with no WAN and no GPS should leave `TIME_UPSTREAM` empty and `TIME_GPS` off, so it is not gated (N6).

Recovery from a bad `lastgood` (a wrong time recorded inside the window): `rm /etc/chrony/lastgood /etc/chrony/rtc-verified`, correct the clock (`date -s`, against a trusted reference), run `magk-time-server seed`, then `/etc/init.d/chronyd restart`. A `lastgood` above the window needs no action, it is ignored.

Trade-off of the gated rule: a gateway with an upstream configured but no WAN at boot serves nothing until the upstream answers, with or without an RTC. A gateway that is never meant to have WAN should leave `TIME_UPSTREAM` empty and be seeded.

A GPS-only gateway (`TIME_GPS=1`, no upstream) is also gated. With no GNSS fix (indoors, antenna blocked, cold start) chronyd never sees a real source, so the gateway serves nothing, and the seed is lost at reboot as above. Put the GNSS antenna where it has sky view and allow time for the first fix before treating the gateway as faulty (N6).

What it does not fix: after an outage the gateway clock is behind real time by the outage length, and units that stayed up can be stepped back by that amount. Only an RTC on the gateway (DS3231 on I2C with `dtoverlay=i2c-rtc,ds3231`; OpenWrt `sysfixtime` already loads `/dev/rtc0` when present) removes that, and only while the cell holds (after a dead, reset or swapped cell the gateway is late again), or GPS removes that. That is recommended as the permanent fix and is a hardware decision.

Guard logic is exercised by `tests/time_server_guard_test.sh` on a development machine with a stubbed clock, uptime, `chronyc`, `hwclock`, `uci` and init scripts (no real clock, chronyd, cron, uci or RTC are involved). Run it with `sh tests/time_server_guard_test.sh`; `SCRIPT=<older file>` compares an older version. BENCH: tests G10 to G15 below.

Unverified chrony behaviour this design depends on (and, for the RTC path, that the 24.10 `sysfixtime` matches the 23.05 one read for round 2): that chronyd rereads `confdir` only at start (hence the restart in step 4), that `chronyc -c tracking` has the field order above, and that `local stratum` behaves as the chrony manual describes. The chrony source is not in the local OpenWrt tree (only the package Makefile and files), so none of this was checked in source. The `orphan` option of `local` was NOT used: it changes when the local reference activates, but it does not by itself keep a freshly booted, not yet synced server from answering, so it would not close the pre-sync window.

## Enable (after approval, staging gateway first)

1. Build or obtain an RPi4 image that includes the `chrony` package.
2. In `/etc/magk-node.env` on the gateway set `TIME_SERVER="1"` and `TIME_UPSTREAM="<host>"` (or `TIME_GPS="1"`).
3. `magk-provision-node /etc/magk-node.env` (idempotent, it backs up network, wireless, dhcp and firewall).
4. On each unit set `server.time_source` to the gateway address and run `install.sh`.

## Rollback

1. Gateway: set `TIME_SERVER="0"` and re-run `magk-provision-node /etc/magk-node.env`. This stops and disables `chronyd` removes the cron line and `/var/etc/chrony.d/20-magk-local.conf`, disables `magk-time-guard`, and deletes the two firewall rules (`magk_ntp_wan_reject`, `magk_ntp_mesh_accept`) and the DHCP option 42 entry.
2. `remove` re-enables and starts the OpenWrt default client (`sysntpd`) if `apply` was the one that disabled it (marker `/etc/chrony/magk-sysntpd-disabled`). Check with `/etc/init.d/sysntpd enabled`; if the marker was lost, restore by hand: `uci set system.ntp.enabled=1; uci commit system; /etc/init.d/sysntpd enable; /etc/init.d/sysntpd start`.
3. `/etc/chrony/lastgood` is left in place (harmless, one number). Delete it to force a fresh verification on the next enable.
4. Config backups from provisioning: `/etc/config/{wireless,network,dhcp,firewall}.bak.provision.<epoch>`.
5. Units: clear `server.time_source` is not allowed by `--check-config` (it fails while unset), so roll a unit back by pointing it at another reachable source, or leave it. A unit with an unreachable source keeps playing and queuing (R3-M4).
6. Image level: revert the branch, `boards/common_extras/time_diffconfig` and its symlink disappear and the next image has no chrony.

## Test plan (per device independent, all BENCH, none run)

Gateway side (run on the gateway):

| # | Step | Pass |
|---|---|---|
| G1 | `magk-time-server status` after start | prints a state; `chronyc tracking` shows stratum below 16 |
| G2 | `chronyc sources -v` with `TIME_UPSTREAM` set and WAN up | one source marked `*`; `chronyc tracking` stratum is upstream stratum plus 1 |
| G3 | unplug WAN, wait for the source to go stale (several poll intervals) | `tracking` shows reference ID 7F7F0101 and the local stratum (default 10); `status` prints `local-only` |
| G4 | `netstat -lnu` or `ss -lnu` | chronyd bound on 123/udp; command port only on 127.0.0.1 |
| G5 | from a host on the WAN side, `ntpdate -q <gateway WAN address>` or `chronyc -h <addr> tracking` | no answer (zone input REJECT plus the explicit rule plus the allow list) |
| G6 | from a mesh host outside the allow subnet (if one can exist) | no answer |
| G7 | `nft list ruleset | grep -n 123` | both rules present |
| G8 | `chronyc clients` after units poll | each unit address listed; confirms client log is on |
| G9 | `chronyc -a serverstats` after a burst test of 20 requests in 2 s from one unit | `NTP packets dropped` counts rate limited packets, and normal 32 s polling is never dropped |
| G10 | fresh gateway, WAN down, no `lastgood` | `magk-time-server guard-start` logs the fallback as WITHHELD; `chronyc tracking` stratum 0 and leap `Not synchronised`; unit `diag time_source` becomes `unsynced` or `unreachable` |
| G11 | WAN up, wait 10 to 20 minutes | `/etc/chrony/lastgood` exists and holds a recent epoch; a second write does not occur within the hour |
| G12 | `date -s` the gateway 7 days back, `reboot` (WAN down) | after boot the clock is at or after `lastgood`, local fallback allowed, `status` prints `local-only` |
| G13 | WAN down, no GPS, delete `lastgood`, run `magk-time-server seed` with a verified clock | fallback becomes allowed and chronyd restarts; `seed` with the clock outside 2026-01-01 to 2030-01-01 refuses |
| G14 | gated gateway (upstream set), WAN up, reboot, poll the gateway from a unit every 5 s for the first 2 minutes | no answer with stratum 10 before `chronyc tracking` shows a real source; the fallback appears only after the first cron run that sees `synced` (up to 10 minutes) and chronyd restarts. Also record whether the restart drops the sync state |
| G15 | write `1900000000` into `/etc/chrony/lastgood`, reboot | the file is ignored (clock not moved forward, `guard-start` does not log a restore) |
| G16 | gated gateway, WAN up and synced, run `magk-time-server seed`, then pull WAN and `reboot` | after boot `guard-start` logs the fallback as withheld, `status` prints a warning only if the fallback is somehow open, units get no time until a real sync (N6) |
| G17 | GPS-only gateway (`TIME_GPS=1`, no upstream), indoors, reboot | `chronyc sources` shows no usable GPS source and no fallback is served, as documented (N6). Then move the antenna to sky view and record the time to first sync |

Unit side (any unit on the mesh):

| # | Step | Pass |
|---|---|---|
| U1 | associate over HaLow, `timedatectl timesync-status` | server is the gateway, `NTPSynchronized=yes` within 120 s (INF-4 criterion, TBR bound) |
| U2 | `timedatectl show -p NTPSynchronized` and the `diag time_source` in the next alive ping | `ok` |
| U3 | stop chronyd on the gateway (`/etc/init.d/chronyd stop`) | within 2 minutes the unit reports `unreachable`, keeps playing and queuing |
| U4 | restart chronyd | unit returns to `ok` without a reboot |
| U5 | gateway has no upstream (G3 state), unit syncs | unit reaches `ok` but time equals the gateway clock; record the gateway clock error against a trusted reference |
| U6 | long-off client: power the unit off for a long time (or set its clock back 30 days with the service stopped), power on | fake-hwclock restores the saved time, timesyncd steps to the gateway time, first TLS exchange succeeds after the sync |
| U7 | gateway clock deliberately wrong (set 7 days back with `date -s` while no upstream) then boot a unit | records what the unit does. Expected risk: the unit follows the gateway back in time. Do not field until Allison decides the mitigation in the report section 5 |

## Open facts to confirm at the bench

- crond is enabled in the image (the guard relies on cron) and `confdir` loads `20-magk-local.conf` after `10-uci.conf`
- `chronyc -c tracking` field 5 (system time offset) is a plain seconds value, used by the offset check
- the built chrony version and whether `ratelimit`, `clientloglimit` and `local stratum` parse (`chronyd -p -f /etc/chrony/chrony.conf` prints the parsed config and exits on this version, UNVERIFIED)
- that `/etc/init.d/sysntpd` exists in the image and that disabling it leaves one clock owner
- `chronyc -c tracking` field order used by `magk-time-server status`
- whether the 24.10 `sysfixtime` (the OpenMANET image base) behaves like the 23.05 script that was read (it raises the RTC to the newest `/etc` file time)
- chronyd starts at boot before `br-ahwlan` has its address (init order START=15 versus network) and still answers once the address appears; it binds the wildcard address, so this should hold

## Battery-backed RTC on the gateway (D9, approved by Allison 2026-11-18)

STAGED. UNTESTED. Nothing here has been wired, built or run. This is a hardware add-on for the RPi4 gateway only.

### Part

| Item | Choice | Source and status |
|---|---|---|
| RTC breakout | Adafruit DS3231 Precision RTC Breakout, Adafruit product 3013 (Adafruit, New York, USA, US vendor) | [Adafruit product page](https://www.adafruit.com/product/3013), [pinouts](https://learn.adafruit.com/adafruit-ds3231-precision-rtc-breakout/pinouts). Price in USD: UNVERIFIED. The page was fetched, but a price could not be read from it reliably this session. Check the live page before ordering. A STEMMA QT version (product 5188) exists and adds a Qwiic connector, not needed here |
| Backup battery | CR1220 12 mm lithium coin cell, one per breakout (the board takes a CR1220 on the back, + side up) | [Adafruit assembly page](https://learn.adafruit.com/adafruit-ds3231-precision-rtc-breakout/assembly). Price UNVERIFIED (low single dollars) |
| RTC chip | Analog Devices (Maxim) DS3231, I2C address 0x68 | [Analog Devices product page](https://www.analog.com/en/products/ds3231.html). Accuracy of 2 ppm from 0 C to +40 C and 3.5 ppm from -40 C to +85 C, from a mirror of the datasheet found by search ([mikrocontroller.net copy](https://www.mikrocontroller.net/attachment/135216/DS3231_DATASHEET.pdf)); the Analog PDF itself could not be downloaded this session, so read the current datasheet before relying on these numbers |

Breakout facts from Adafruit's pinout page (read this session): power range 2.3 V to 5.5 V on Vin, so 3.3 V from the Pi is fine and no level shifter is needed; SDA and SCL each have a 10 k pull-up to Vin; the BAT pad is the cell positive and the chip switches over when Vin is lost; SQW, 32K and RST are open-drain and unused here.

Why this part: it is a temperature-compensated RTC, it is supported by the stock Linux `rtc-ds1307` driver and by the Raspberry Pi `i2c-rtc` overlay, and it was named in the AD-4 documents as the unit-side option. ASSUMED: any DS3231 module with the same pinout works. Cheap clone boards often fit a charging circuit for a rechargeable LIR2032 and are unsafe with a CR1220 (the Adafruit board has no such circuit, ASSUMED from its guide; confirm by inspection of the board before inserting a non-rechargeable cell).

### Wiring to the Pi 4 40-pin header (3.3 V logic)

| Breakout pin | Pi 4 header pin | Pi signal |
|---|---|---|
| Vin | 1 | 3V3 |
| GND | 9 | GND (any ground pin) |
| SDA | 3 | GPIO2, I2C1 SDA |
| SCL | 5 | GPIO3, I2C1 SCL |

Pins 1, 3, 5 and 9 are not used by the HaLow SPI wiring documented in `docs/magk/portable-node-morse-spi-wiring.md` (that file lists GPIO10, 9, 11, 8, 17, 5, 23 and 24). The gateway uses a mini-PCIe HAT, and its own use of the header was NOT checked, so confirm that pins 1, 3, 5 and 9 are free on the HAT before wiring (BENCH). I2C bus speed: the Pi default of 100 kHz is correct for the DS3231 (it supports 400 kHz at most). Two 10 k pull-ups are on the breakout in parallel with the Pi's own 1.8 k pull-ups on GPIO2 and GPIO3, so no extra pull-ups are needed (the Pi 4 on-board pull-up value is from memory, UNVERIFIED).

### Kernel and packages (OpenMANET fork, kernel 6.6)

| Need | Item | Evidence |
|---|---|---|
| DS3231 driver | `kmod-rtc-ds1307` (the DS1307 driver covers DS3231 per its package description) | VERIFIED in `package/kernel/linux/modules/other.mk` of the fork: `KernelPackage/rtc-ds1307`, `CONFIG_RTC_DRV_DS1307`, depends on `kmod-i2c-core`, `kmod-regmap-i2c`, `kmod-hwmon-core`, autoloaded |
| I2C controller | `kmod-i2c-bcm2835` | VERIFIED in `target/linux/bcm27xx/modules/i2c.mk` |
| Overlay | Raspberry Pi `i2c-rtc` overlay with the `ds3231` parameter | VERIFIED in the fork's `target/linux/bcm27xx/patches-6.6/950-0040-...patch` (the `ds3231` parameter and node at 0x68) |
| hwclock tool | `/sbin/hwclock`, from BusyBox (`BUSYBOX_DEFAULT_HWCLOCK`) or the `hwclock` package of util-linux | The `sysfixtime` script needs `/sbin/hwclock`. Whether the built image has it at that path is UNVERIFIED. The util-linux package installs to `/usr/sbin/hwclock`, which would NOT satisfy `sysfixtime`. Check `ls -l /sbin/hwclock` on the bench image and use the BusyBox applet if needed |
| i2c-tools | `i2c-tools` (`i2cdetect`) | Already in `camera_diffconfig` of the board; `boards/common/kitchensink_diffconfig` has it as a module |

Staged diffconfig line to add when approved for a build (NOT added to the branch yet, so the current image is unchanged): `CONFIG_PACKAGE_kmod-rtc-ds1307=y`, `CONFIG_PACKAGE_kmod-i2c-bcm2835=y`, `CONFIG_PACKAGE_i2c-tools=y`.

### Boot configuration

Add to `config.txt` on the FAT boot partition, under `[all]` (the OpenWrt image's `config.txt` includes `distroconfig.txt` and leaves `[all]` for local settings; VERIFIED in `target/linux/bcm27xx/image/config.txt`):

```
dtparam=i2c_arm=on
dtoverlay=i2c-rtc,ds3231
```

`dtoverlay=i2c-rtc,ds3231` is the line given by [Adafruit's Raspberry Pi RTC guide](https://learn.adafruit.com/adding-a-real-time-clock-to-raspberry-pi/set-rtc-time). Whether the explicit `dtparam=i2c_arm=on` line is required with this overlay is UNVERIFIED; it is harmless. The card is edited on any computer, no SSH needed, which keeps this inside the no-SSH rule until a bench is approved. A reboot applies it.

Adafruit's guide for Raspberry Pi OS also says to remove `fake-hwclock` and edit a udev script. Neither applies to OpenWrt. OpenWrt's equivalent is `/etc/init.d/sysfixtime` (START=00), which VERIFIED in the fork does: load the RTC with `hwclock -s -u -f /dev/rtc0` at boot; if the clock is behind the newest file time under `/etc`, set the clock to that file time and write it back to the RTC; at stop, write the system clock to the RTC with `hwclock -w`.

### How it interacts with the stale-clock guard

Order at boot (start numbers): `sysfixtime` (00) loads the RTC, then `magk-time-guard` (14) runs `guard-start`, then `chronyd` (15).

Without an RTC (today) the guard's `lastgood` file is the only memory of real time. With an RTC the clock after boot is the RTC time, accurate to a few seconds a year while the cell lasts, so, while the cell holds, the outage no longer makes the gateway late. After a dead, reset or swapped cell it does again. The guard stays, with these rules (IMPLEMENTED in `magk-time-server`, covered by stub tests R1 to R10, N1 and N2 in `tests/time_server_guard_test.sh`, NOT run against a real RTC or `hwclock`; the RTC code is inert unless the kernel exposes `/sys/class/rtc/rtc0/since_epoch`):

1. `lastgood` becomes a sanity floor, not the main source. If the clock is behind `lastgood` at boot (RTC dead, unset or swapped), `guard-start` moves the clock forward to `lastgood`, as now.
2. `save-lastgood` also runs `hwclock -w -u -f /dev/rtc0` right after it records a synced time, so a new or unset RTC is written from a verified source (hourly at most). It does not rely on chrony's `rtcsync` alone: that keyword makes the kernel write the RTC about every 11 minutes while the clock is synced, but the build uses `--disable-rtc` for chronyd's own RTC tracking, and whether the kernel path works with this I2C RTC is UNVERIFIED. The `rtc-verified` marker records the epoch written, after a successful `hwclock -w`. Its only job now is to tell `save-lastgood` that the RTC has been written at least once.
3. **The RTC does not open the local fallback gate** (round 2, N1 and N2; this is a safe default chosen by the conductor on Allison's behalf, for her to overrule). Reason: the 23.05 `sysfixtime` `boot()` (VERIFIED by reading `package/base-files/files/etc/init.d/sysfixtime`; 24.10 UNVERIFIED) raises the clock to the newest file time under `/etc` when the RTC is behind it, and then writes that to the RTC. `rtc-verified` and `lastgood` are files under `/etc/chrony`, so after a dead or swapped coin cell the RTC comes back at or just above the marker. A check of the form "RTC is not below the marker" therefore passes after a failed cell, and cannot tell it from a good RTC. The gate opens only after one real upstream or GPS sync in this boot, or after an explicit `seed` (for this boot).
4. `seed` also writes the RTC (`hwclock -w`), so, while the cell holds, the clock a seeded gateway boots with is right to within the RTC drift.
5. At boot `guard-start` prints a warning when the system clock and the RTC differ by more than 60 s. That means `sysfixtime` did not load the RTC (for example `/sbin/hwclock` missing, or the RTC driver loaded after START=00) or the RTC is wrong. It is a report only: the script never sets the system clock from the RTC itself, and it only moves the clock forward to `lastgood`.
6. Residual: the RTC drifts (about 2 ppm from 0 C to +40 C is 63 seconds a year by calculation: 2e-6 x 31,536,000 s = 63 s) and a gateway with no upstream for a long time serves a time that is off by the accumulated drift. At 3.5 ppm over the full range the figure is 110 s a year. This is small next to what TLS certificate validity needs. Cell life is not computed, because the datasheet's battery current was not read this session; a CR1220 is expected to last years (ASSUMED), so plan to replace it on the maintenance schedule and bench-measure.

What fitting the RTC does protect: after a power cut the kernel starts with the RTC time (a few seconds a year of error while the cell holds), so units that sync to the gateway after its first real sync, and the gateway's own logs and certificates checks, do not start from a time months behind. What it does NOT protect: a dead, reset or swapped cell is invisible to this script (the RTC value looks plausible after `sysfixtime`), so the RTC cannot be used as evidence that the time is right. It does not let a gateway with no WAN and no GPS serve time at boot; use `seed` for that (non-gated gateway) or accept the wait for the first sync (gated gateway).

`sysfixtime` interaction: when the RTC is unset it reads 2000-01-01, which is behind the newest `/etc` file, so `sysfixtime` sets the clock to the newest `/etc` file's time and writes that into the RTC. That time is only as good as the last provisioning or the last `lastgood` write (which touches a file under `/etc/chrony`), and it is NOT a verified time. Earlier text claimed the `rtc-verified` marker kept this from opening the gate. That claim was wrong, and the marker no longer gates anything.

### Bench steps (all UNTESTED, to be run after approval, with the gateway powered off while wiring)

| # | Step | Pass |
|---|---|---|
| R1 | Power off. Fit a CR1220 (+ side up) in the breakout. Wire pins 1, 3, 5, 9 as above. Add the two `config.txt` lines. Boot an image that has the packages. | boots, `HaLow` and the mesh come up as before |
| R2 | `i2cdetect -y 1` | shows `UU` at 0x68 (driver bound), or `68` if the driver is not loaded |
| R3 | `dmesg | grep -i rtc` and `ls -l /dev/rtc0 /sbin/hwclock` | `rtc-ds1307` registered `rtc0`; `hwclock` exists at `/sbin/hwclock` |
| R4 | `hwclock -r -u -f /dev/rtc0` on a new RTC | a date is returned (likely 2000-01-01 or garbage) |
| R5 | With WAN up and chrony synced: `magk-time-server save-lastgood` (needs two cron runs 5 minutes or more apart on the first record) or `hwclock -w -u -f /dev/rtc0`, then `hwclock -r -u -f /dev/rtc0` | RTC time within 1 second of `date -u` |
| R6 | Power off for 10 minutes with WAN disconnected, then boot | clock after boot is within a few seconds of true time; `guard-start` does not warn about a clock/RTC difference; a gated gateway still withholds the fallback until a real sync |
| R7 | Remove the coin cell with main power off for 1 minute, restore it, boot | RTC reads an unset value, `sysfixtime` floors the clock and the RTC to the newest `/etc` file time (record the value), and the gate stays withheld on a gated gateway until a real sync or `seed`. The RTC value after boot looks plausible: that is expected, and why the RTC cannot open the gate (item 3). Also record whether the 24.10 `sysfixtime` does the same |
| R8 | `date -s` the system clock 7 days back with the RTC correct, reboot | clock returns to RTC time. Then break the load on purpose (rename `/sbin/hwclock`, reboot): `guard-start` warns that the clock differs from the RTC and the gate stays withheld |
| R9 | Hold the gateway on a bench 24 hours with no WAN, compare `date -u` to a trusted reference | drift against reference is recorded and is under 1 second a day (the 2 ppm figure gives 0.17 s a day, calculation) |

### Rollback (D9)

1. Power off, disconnect the four wires, remove the cell. Nothing else on the Pi was changed by the hardware.
2. Remove the two lines from `config.txt` on the boot partition (or leave them: with no device at 0x68 the driver does not bind and boot is unaffected, UNVERIFIED). Rebooting returns the gateway to no-RTC behavior, which the stale-clock guard section already covers.
3. Image level: drop the three diffconfig lines from a later build. The RTC code in `magk-time-server` is inert without `/sys/class/rtc/rtc0`, so no code rollback is needed; delete `/etc/chrony/rtc-verified` to drop the marker.
4. If the RTC holds a wrong time and the gateway is already serving it: set the clock correctly with `date -s`, run `hwclock -w -u -f /dev/rtc0`, then `magk-time-server seed`.

### Cost (USD, ALL UNVERIFIED; check live pages)

One breakout plus one CR1220 per gateway: low double digits of dollars before shipping. No price was verified, so this is an order-of-magnitude statement only (ASSUMED). Fleet quantity is one gateway today.


## Re-running the guard harness

`sh tests/time_server_guard_test.sh` runs the script under test as `sh "$SCRIPT"`, so the file does not need an executable bit for a run (the old-version comparison `SCRIPT=/tmp/old sh tests/time_server_guard_test.sh` works without `chmod`). `TS_SH=dash` or `TS_SH=bash` changes the shell that runs the script. The repo copy must keep its executable bit (check N5a, git mode 100755). A failing check prints the command that failed and the last lines of its output. The harness models what `sysfixtime` does to the RTC (see the comment above `sysfixtime_model`): a model written from reading the 23.05 script, not a run of it.

## Re-running the Configurator tests

The shared virtualenv at `/Users/allisonpryor/Code/MAGK-Configurator/.venv` has an editable install that points at another worktree. In the time-server worktree run `PYTHONPATH=src python -m pytest -q` (and `ruff check src tests`), otherwise the tests import the other tree and report false failures.

## TBR list (owner Allison unless stated)

| Item | Why open |
|---|---|
| Build stamp `/etc/magk-build-ts` | The clock ceiling is the constant 2030-01-01 until an image build writes the stamp (then stamp plus one year). Needs a build step (magkops). Raise the constant before 2030 |
| Wrong-ahead or reset RTC | Not detectable locally, and since round 2 it no longer matters for the gate (the RTC never opens it). It can still make a restarted gateway or a non-gated gateway start from a wrong clock. After a dead, reset or swapped cell a non-gated gateway with `lastgood` serves a clock that is late by the outage length, and units will receive it. See the RTC section and bench R6 to R8 |
| RTC may not open the gate (N2 decision) | Safe default chosen by the conductor on Allison's behalf. Allison can overrule it, at the cost of the dead-cell hole above. Without it, a gated gateway with no WAN waits for the first sync or a seed |
| Consistently wrong source (N4) | A source that stays wrong for the 5 minute two-sighting window, inside 2026 to 2030, is accepted into `lastgood`, and every later boot restores the clock to it. Recovery is the manual one above. NOT fixed in round 2: no behavior added. Options for Allison to decide: (a) require a second independent upstream and accept a reading only when two agree, or (b) NTS (authenticated NTP) to a pool or provider that offers it. Either needs a product and network decision, and a chrony build and config that has been tried. Owner: Allison |
| `sysfixtime` on 24.10 | The RTC analysis above was read in the 23.05 tree. Read the 24.10 script in the OpenMANET build tree before relying on any RTC statement |
| chrony facts | `confdir` read only at start, `-c tracking` field order, `local` semantics on the built version: bench G1 to G15 |
| Plain NTP upstream | Unauthenticated (AD-9 D2). Confirmation and bounds only stop one-off errors |
