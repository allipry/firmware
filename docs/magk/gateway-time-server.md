# Gateway time server runbook (AD-4 / INF-4)

STAGED. UNTESTED ON HARDWARE. Off by default. Nothing here has run on a gateway.

## What it does

The MAGK gateway (Raspberry Pi 4 with an MM6108 HaLow module, OpenMANET image) runs chrony and answers NTP from the mesh subnet (default 10.41.0.0/16). The objective units point systemd-timesyncd at the gateway address (`server.time_source`, default gateway address 10.41.0.1). It is installed and configured only by `magk-provision-node` when `TIME_SERVER=1` and the role is `gateway`.

## Files in this change

| File | Purpose |
|---|---|
| `boards/ekh-bcm2711/time_diffconfig` | adds package `chrony` to the RPi4 images only |
| `files/usr/sbin/magk-time-server` | renders and applies the chrony config, firewall rules, DHCP option; `status` |
| `files/etc/init.d/magk-time-guard` | boot step before chronyd (START=14), inert unless `apply` created `/etc/chrony/magk-time-server.enabled` |
| `files/usr/sbin/magk-provision-node` | calls `magk-time-server apply` (gateway, TIME_SERVER=1) or `remove` (every other case) |
| `files/etc/magk-node.env.example` | documents `TIME_SERVER`, `TIME_UPSTREAM`, `TIME_GPS`, `TIME_LOCAL_STRATUM`, `TIME_ALLOW`, `TIME_DHCP_OPTION` |

## Stale-clock guard

Problem: a Pi 4 has no RTC, and `local stratum` would make the gateway serve whatever its clock reads after a power cut. Units would follow it, and a clock that is behind breaks TLS certificate checks.

Design (fake-hwclock pattern plus a gate on the local fallback):

1. While chronyd is synced to a real source (an upstream host or GPS, never the local fallback), cron runs `magk-time-server save-lastgood` every 10 minutes. It writes the clock to `/etc/chrony/lastgood`, at most once per hour (24 flash writes a day at most), never moves the record backwards, and ignores anything below the floor 2026-01-01 UTC.
2. At boot, before chronyd, `guard-start` sets the clock forward to `lastgood` if it is behind. So after an outage the gateway is late by at most the outage length plus up to 1 hour, not by the age of the image.
3. `local stratum` is written (to `/var/etc/chrony.d/20-magk-local.conf`, loaded by chrony's `confdir`) only when a `lastgood` exists. Until the gateway has synced once, the fallback is withheld, chronyd answers as unsynchronised, and units ignore it.
4. A gateway with no WAN and no GPS is seeded by an operator: check the clock against a trusted reference, set it with `date -s`, then run `magk-time-server seed`. This is an assertion by the operator and is logged.

What it does not fix: after an outage the gateway clock is behind real time by the outage length, and units that stayed up can be stepped back by that amount. Only an RTC on the gateway (DS3231 on I2C with `dtoverlay=i2c-rtc,ds3231`; OpenWrt `sysfixtime` already loads `/dev/rtc0` when present) or GPS removes that. That is recommended as the permanent fix and is a hardware decision.

Guard logic was exercised on a development machine with a stubbed clock and `chronyc` (no clock, no chronyd, no cron were involved). BENCH: tests G10 to G13 below.

## Enable (after approval, staging gateway first)

1. Build or obtain an RPi4 image that includes the `chrony` package.
2. In `/etc/magk-node.env` on the gateway set `TIME_SERVER="1"` and `TIME_UPSTREAM="<host>"` (or `TIME_GPS="1"`).
3. `magk-provision-node /etc/magk-node.env` (idempotent, it backs up network, wireless, dhcp and firewall).
4. On each unit set `server.time_source` to the gateway address and run `install.sh`.

## Rollback

1. Gateway: set `TIME_SERVER="0"` and re-run `magk-provision-node /etc/magk-node.env`. This stops and disables `chronyd` removes the cron line and `/var/etc/chrony.d/20-magk-local.conf`, disables `magk-time-guard`, and deletes the two firewall rules (`magk_ntp_wan_reject`, `magk_ntp_mesh_accept`) and the DHCP option 42 entry.
2. If the OpenWrt default client was disabled by apply, restore it: `uci set system.ntp.enabled=1; uci commit system; /etc/init.d/sysntpd enable; /etc/init.d/sysntpd start` (skip if the image has no `/etc/init.d/sysntpd`).
3. `/etc/chrony/lastgood` is left in place (harmless, one number). Delete it to force a fresh verification on the next enable.
4. Config backups from provisioning: `/etc/config/{wireless,network,dhcp,firewall}.bak.provision.<epoch>`.
5. Units: clear `server.time_source` is not allowed by `--check-config` (it fails while unset), so roll a unit back by pointing it at another reachable source, or leave it. A unit with an unreachable source keeps playing and queuing (R3-M4).
6. Image level: revert the branch, `boards/ekh-bcm2711/time_diffconfig` disappears and the next image has no chrony.

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
| G13 | WAN down, no GPS, delete `lastgood`, run `magk-time-server seed` with a verified clock | fallback becomes allowed and chronyd restarts; `seed` with the clock below 2026-01-01 refuses |

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
- the built chrony version and whether `ratelimit`, `clientloglimit` and `local stratum` parse (`chronyd -p -f /etc/chrony/chrony.conf` prints the parsed config and exits on this version, UNVERIFIED)
- that `/etc/init.d/sysntpd` exists in the image and that disabling it leaves one clock owner
- `chronyc -c tracking` field order used by `magk-time-server status`
- chronyd starts at boot before `br-ahwlan` has its address (init order START=15 versus network) and still answers once the address appears; it binds the wildcard address, so this should hold
