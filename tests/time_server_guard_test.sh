#!/bin/sh
# Dev-machine harness for files/usr/sbin/magk-time-server and the board diffconfig layout.
# Run:  sh tests/time_server_guard_test.sh            (tests the script in this tree)
#       SCRIPT=/path/to/older/magk-time-server sh tests/time_server_guard_test.sh   (before/after comparison)
#       TS_SH=dash|bash|sh   shell that runs the script under test (default sh, as on the node, where /bin/sh is ash)
# The script is always started as `$TS_SH "$SCRIPT"`, so SCRIPT needs no executable bit for these runs. The
# repo copy must still be executable (check N5a), because the node runs it directly from cron and init.
#
# WHAT THIS IS: stubbed chronyc, hwclock, uci and init scripts, a fake root directory, a fake clock
# (MAGK_TIME_NOW) and a fake uptime (MAGK_TIME_UPTIME). WHAT IT IS NOT: a test of a real chronyd,
# real clock, real cron, real uci, a real RTC or a real node. Nothing here is hardware evidence.
# Needs: sh, awk, sed, grep, mktemp. Exit status = number of failed checks.
set -u

HERE="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="${SCRIPT:-$HERE/files/usr/sbin/magk-time-server}"
TS_SH="${TS_SH:-sh}"
FAILS=0
PASSES=0

ok()   { PASSES=$((PASSES+1)); echo "PASS $1"; }
bad()  { FAILS=$((FAILS+1)); echo "FAIL $1"; }
check() { # name, then a command that must succeed; a failure prints the command and its last output lines
  n="$1"; shift
  if o="$("$@" 2>&1)"; then ok "$n"; else bad "$n"; echo "     reason: command failed: $*"; [ -z "$o" ] || printf '%s\n' "$o" | tail -n 5 | sed 's/^/     | /'; fi
}
check_not() {
  n="$1"; shift
  if o="$("$@" 2>&1)"; then bad "$n"; echo "     reason: command succeeded but must fail: $*"; [ -z "$o" ] || printf '%s\n' "$o" | tail -n 5 | sed 's/^/     | /'; else ok "$n"; fi
}

W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT INT TERM
BIN="$W/bin"; mkdir -p "$BIN"

# chronyc stub: `chronyc -c tracking` prints $STUB_TRACKING
cat > "$BIN/chronyc" <<'EOF'
#!/bin/sh
[ "$1" = "-c" ] && [ "$2" = "tracking" ] && { printf '%s\n' "${STUB_TRACKING:-}"; exit 0; }
exit 1
EOF
# hwclock stub: records its arguments
cat > "$BIN/hwclock" <<'EOF'
#!/bin/sh
echo "hwclock $*" >> "${STUB_LOG:-/dev/null}"
exit "${STUB_HWCLOCK_RC:-0}"
EOF
# uci stub: logs calls; `uci show firewall` prints $STUB_UCI_SHOW; `uci add` prints a name
cat > "$BIN/uci" <<'EOF'
#!/bin/sh
echo "uci $*" >> "${STUB_LOG:-/dev/null}"
case "$*" in
  *"show firewall"*) [ -n "${STUB_UCI_SHOW:-}" ] && printf '%s\n' "$STUB_UCI_SHOW"; exit 0;;
  "add firewall rule"*) echo "cfg_stub"; exit 0;;
esac
exit 0
EOF
chmod +x "$BIN/chronyc" "$BIN/hwclock" "$BIN/uci"
PATH="$BIN:$PATH"; export PATH

SYNCED='C0A80001,192.168.0.1,3,1795200000.0,0.000123,0.0001,0.0002,1.0,0.1,0.1,0.01,0.01,64.0,Normal'
LOCALONLY='7F7F0101,,10,1795200000.0,0.0,0.0,0.0,1.0,0.1,0.1,0.0,0.0,64.0,Normal'
UNSYNC='00000000,,0,0.0,0.0,0.0,0.0,0.0,0.0,0.0,0.0,0.0,0.0,Not synchronised'
STRAT16='C0A80001,192.168.0.1,16,1795200000.0,0.000123,0.0001,0.0002,1.0,0.1,0.1,0.01,0.01,64.0,Normal'
BIGOFF='C0A80001,192.168.0.1,3,1795200000.0,5.5,0.0001,0.0002,1.0,0.1,0.1,0.01,0.01,64.0,Normal'

NOW0=1795200000   # 2026-11-19 UTC, plausible
newroot() { R="$(mktemp -d "$W/root.XXXXXX")"; mkdir -p "$R/etc/chrony" "$R/var/etc/chrony.d" "$R/tmp"; : > "$W/log"; }
run() { # run the script under the fake root: run NOW UPTIME args...
  _n="$1"; _u="$2"; shift 2
  MAGK_TIME_ROOT="$R" MAGK_TIME_NOW="$_n" MAGK_TIME_UPTIME="$_u" STUB_LOG="$W/log" $TS_SH "$SCRIPT" "$@"
}
lg() { cat "$R/etc/chrony/lastgood" 2>/dev/null; }
localconf() { cat "$R/var/etc/chrony.d/20-magk-local.conf" 2>/dev/null; }
local_open() { grep -q '^local stratum' "$R/var/etc/chrony.d/20-magk-local.conf" 2>/dev/null; }
mark_gated() { printf 'gated=1\n' > "$R/etc/chrony/magk-time-server.enabled"; }

echo "== script under test: $SCRIPT (run with: $TS_SH)"

# ---------------------------------------------------------------- N5 harness hygiene
check "N5a the repo copy of magk-time-server has its executable bit" test -x "$HERE/files/usr/sbin/magk-time-server"
check "N5b the script under test is readable" test -r "$SCRIPT"

# ---------------------------------------------------------------- B1
# Dry copy of scripts/openmanet_setup.sh:255-261 for the ekh-bcm2711 board.
b1_check() {
  d="$HERE/boards/ekh-bcm2711"; rc=0
  for file in "$d"/*_diffconfig; do
    [ "$(basename "$file")" = target_diffconfig ] && continue
    [ -h "$file" ] || { echo "not a symlink: $file"; rc=1; }
    [ -e "$file" ] || { echo "dangling: $file"; rc=1; }
  done
  return $rc
}
check "B1 every non-target *_diffconfig in boards/ekh-bcm2711 is a live symlink" b1_check
check "B1 time_diffconfig lives in boards/common_extras" test -f "$HERE/boards/common_extras/time_diffconfig"
check "B1 setup script still has the symlink rule this check mirrors" grep -q 'is not a symlink; aborting' "$HERE/scripts/openmanet_setup.sh"

# ---------------------------------------------------------------- guard basics
newroot
run $NOW0 1000 guard-start >/dev/null 2>&1
check_not "A  first boot, no lastgood: fallback withheld" local_open

newroot; STUB_TRACKING="$SYNCED"; export STUB_TRACKING
run $NOW0 1000 save-lastgood >/dev/null 2>&1
check_not "B1 first ever save is not stored on one sighting (needs confirmation)" test -s "$R/etc/chrony/lastgood"
run $((NOW0+400)) 1400 save-lastgood >/dev/null 2>&1
[ "$(lg)" = "$((NOW0+400))" ] && ok "B2 second consistent sighting 400 s later stores lastgood" || bad "B2 second consistent sighting 400 s later stores lastgood (got '$(lg)')"

# existing behaviour kept: not-synced never saves
newroot; STUB_TRACKING="$LOCALONLY"; export STUB_TRACKING
run $NOW0 1000 save-lastgood >/dev/null 2>&1; run $((NOW0+400)) 1400 save-lastgood >/dev/null 2>&1
check_not "G  local-only state is never saved" test -s "$R/etc/chrony/lastgood"
STUB_TRACKING="$UNSYNC"; export STUB_TRACKING
run $NOW0 1000 save-lastgood >/dev/null 2>&1; run $((NOW0+400)) 1400 save-lastgood >/dev/null 2>&1
check_not "H  unsynchronised state is never saved" test -s "$R/etc/chrony/lastgood"

newroot; echo abc > "$R/etc/chrony/lastgood"
run $NOW0 1000 guard-start >/dev/null 2>&1
check_not "I  damaged lastgood is treated as absent" local_open

# non-gated (no upstream, no GPS): lastgood opens the fallback, as designed
newroot; echo $((NOW0-100)) > "$R/etc/chrony/lastgood"
run $NOW0 1000 guard-start >/dev/null 2>&1
check "D  non-gated gateway with lastgood and clock ahead: fallback allowed" local_open
newroot; echo $((NOW0+5000)) > "$R/etc/chrony/lastgood"
run $NOW0 1000 guard-start >/dev/null 2>&1
check "C  clock behind lastgood: fallback allowed, restore message printed" local_open

# ---------------------------------------------------------------- M2 poison
newroot; STUB_TRACKING="$SYNCED"; export STUB_TRACKING
POISON=1900000000   # 2030-03-17, the reviewer's case
run $POISON 1000 save-lastgood >/dev/null 2>&1; run $((POISON+400)) 1400 save-lastgood >/dev/null 2>&1
check_not "E  M2 a 2030 reading is never stored (above the ceiling)" test -s "$R/etc/chrony/lastgood"
run $NOW0 5000 save-lastgood >/dev/null 2>&1; run $((NOW0+400)) 5400 save-lastgood >/dev/null 2>&1
[ "$(lg)" = "$((NOW0+400))" ] && ok "F  M2 correct time afterwards is still accepted" || bad "F  M2 correct time afterwards is still accepted (got '$(lg)')"

# a lastgood already poisoned on a unit is ignored by the guard (recovers without operator action)
newroot; echo $POISON > "$R/etc/chrony/lastgood"
run $NOW0 1000 guard-start >/dev/null 2>&1
check_not "L  M2 already-poisoned lastgood above the ceiling is ignored" local_open

# a value inside the ceiling but far ahead of lastgood + uptime needs two consistent sightings
newroot; echo $NOW0 > "$R/etc/chrony/lastgood"; STUB_TRACKING="$SYNCED"; export STUB_TRACKING
JUMP=$((NOW0+30*86400))
run $JUMP 2000 save-lastgood >/dev/null 2>&1
[ "$(lg)" = "$NOW0" ] && ok "E2 M2 a 30-day forward jump on first sighting leaves lastgood unchanged" || bad "E2 M2 a 30-day forward jump on first sighting leaves lastgood unchanged (got '$(lg)')"
run $((JUMP+7200)) 2000 save-lastgood >/dev/null 2>&1
[ "$(lg)" = "$NOW0" ] && ok "E3 M2 a sighting inconsistent with the monotonic clock is not accepted" || bad "E3 M2 inconsistent sighting not accepted (got '$(lg)')"
run $((JUMP+7200+400)) 2400 save-lastgood >/dev/null 2>&1
[ "$(lg)" = "$((JUMP+7600))" ] && ok "E4 M2 two consistent sightings after a real outage are accepted" || bad "E4 M2 two consistent sightings accepted (got '$(lg)')"

# a normal in-boot save needs no confirmation
newroot; echo $NOW0 > "$R/etc/chrony/lastgood"
run $((NOW0+3700)) 3800 save-lastgood >/dev/null 2>&1
[ "$(lg)" = "$((NOW0+3700))" ] && ok "E5 M2 normal hourly save inside uptime bound is stored at once" || bad "E5 normal hourly save (got '$(lg)')"

# stratum and offset sanity
newroot; STUB_TRACKING="$STRAT16"; export STUB_TRACKING
run $NOW0 1000 save-lastgood >/dev/null 2>&1; run $((NOW0+400)) 1400 save-lastgood >/dev/null 2>&1
check_not "K1 M2 stratum 16 is refused" test -s "$R/etc/chrony/lastgood"
newroot; STUB_TRACKING="$BIGOFF"; export STUB_TRACKING
run $NOW0 1000 save-lastgood >/dev/null 2>&1; run $((NOW0+400)) 1400 save-lastgood >/dev/null 2>&1
check_not "K2 M2 a 5.5 s system offset is refused" test -s "$R/etc/chrony/lastgood"

# seed respects the ceiling
newroot
run $POISON 1000 seed >/dev/null 2>&1
check_not "K3 M2 seed refuses a clock above the ceiling" test -s "$R/etc/chrony/lastgood"
run $NOW0 1000 seed >/dev/null 2>&1
[ "$(lg)" = "$NOW0" ] && ok "K4 seed at a plausible clock still records it" || bad "K4 seed plausible (got '$(lg)')"

# ---------------------------------------------------------------- M1 / m5 first-sync gate
newroot; mark_gated; echo $((NOW0-100)) > "$R/etc/chrony/lastgood"
run $NOW0 1000 guard-start >/dev/null 2>&1
check_not "M1 gated gateway with lastgood does NOT open the fallback at boot" local_open
STUB_TRACKING="$UNSYNC"; export STUB_TRACKING
run $((NOW0+60)) 1060 save-lastgood >/dev/null 2>&1
check_not "M1b still withheld while chrony is unsynchronised" local_open
STUB_TRACKING="$SYNCED"; export STUB_TRACKING
run $((NOW0+120)) 1120 save-lastgood >/dev/null 2>&1
check "m5 fallback opens after the first real sync, without a reboot" local_open
newroot; mark_gated; STUB_TRACKING="$LOCALONLY"; export STUB_TRACKING
run $NOW0 1000 save-lastgood >/dev/null 2>&1
check_not "M1c local-only state does not open the fallback" local_open

# ---------------------------------------------------------------- M3 RTC (round 2: the RTC never opens the gate)
rtc_fake() { mkdir -p "$R/sys/class/rtc/rtc0" "$R/dev"; echo "$1" > "$R/sys/class/rtc/rtc0/since_epoch"; }
# Model of OpenWrt sysfixtime boot() (package/base-files/files/etc/init.d/sysfixtime, 23.05 tree, VERIFIED by reading;
# 24.10 UNVERIFIED): hwclock_load sets the clock from the RTC; maxtime = newest mtime under /etc; if the clock is
# behind maxtime, set the clock to maxtime and hwclock_save writes it to the RTC. In the fake root a file under
# /etc/chrony is written at the fake time it contains, so its mtime equals that value (lastgood and rtc-verified).
# Input: RTC value after power loss. Output: SYS_NOW (the clock guard-start sees) and the RTC value rewritten.
sysfixtime_model() { # rtc_value_at_boot
  SYS_NOW="$1"; newest=0
  for f in "$R/etc/chrony/lastgood" "$R/etc/chrony/rtc-verified"; do
    [ -f "$f" ] || continue
    v="$(cat "$f")"; [ "$v" -le "$newest" ] || newest="$v"
  done
  if [ "$SYS_NOW" -lt "$newest" ]; then SYS_NOW="$newest"; rtc_fake "$SYS_NOW"; fi
}
newroot; mark_gated; rtc_fake $NOW0
run $NOW0 1000 guard-start >/dev/null 2>&1
check_not "R1 M3 RTC present but never written from a verified time: fallback withheld" local_open
STUB_TRACKING="$SYNCED"; export STUB_TRACKING
run $NOW0 1000 save-lastgood >/dev/null 2>&1
check_not "R2 M3 first sighting does not write the RTC" test -e "$R/etc/chrony/rtc-verified"
run $((NOW0+400)) 1400 save-lastgood >/dev/null 2>&1
check "R3 M3 verified save writes the RTC (hwclock -w called)" grep -q 'hwclock -w -u -f' "$W/log"
check "R4 M3 rtc-verified marker written after a successful hwclock -w" test -s "$R/etc/chrony/rtc-verified"
# N2 decision: a verified, healthy RTC at boot does NOT open the gate on a gated gateway
rtc_fake $((NOW0+500)); run $((NOW0+600)) 100 guard-start >/dev/null 2>&1
check_not "R5 N2 verified RTC at or above the marker does NOT open the gate on a gated gateway" local_open
rtc_fake $((NOW0-5000)); run $((NOW0+600)) 100 guard-start >/dev/null 2>&1
check_not "R6 M3 RTC behind the marker does not open the gate" local_open
rtc_fake 1950000000; run $((NOW0+600)) 100 guard-start >/dev/null 2>&1
check_not "R7 M3 RTC above the ceiling does not open the gate" local_open
newroot; mark_gated; : > "$W/log"; rtc_fake $NOW0; STUB_HWCLOCK_RC=1; export STUB_HWCLOCK_RC
run $NOW0 1000 save-lastgood >/dev/null 2>&1; run $((NOW0+400)) 1400 save-lastgood >/dev/null 2>&1
check_not "R8 M3 failed hwclock -w writes no marker" test -e "$R/etc/chrony/rtc-verified"
unset STUB_HWCLOCK_RC
# F3 (round 3): non-gated, system clock far behind lastgood and an RTC 104 days AHEAD of both. Gate and
# restore follow lastgood, not the RTC. Then an RTC far BEHIND the clock changes nothing either.
newroot; echo $NOW0 > "$R/etc/chrony/lastgood"; rtc_fake $((NOW0+104*86400))
run $((NOW0-104*86400)) 40 guard-start >/dev/null 2>&1
check "F3a non-gated, clock behind lastgood, RTC far ahead: the gate opens from lastgood" local_open
check "F3b the restore step names lastgood as the target" sh -c "MAGK_TIME_ROOT='$R' MAGK_TIME_NOW=$((NOW0-104*86400)) MAGK_TIME_UPTIME=40 STUB_LOG='$W/log' $TS_SH '$SCRIPT' guard-start 2>&1 | grep -q 'behind last good time $NOW0'"
newroot; echo $NOW0 > "$R/etc/chrony/lastgood"; rtc_fake $((NOW0-104*86400))
run $((NOW0+600)) 100 guard-start >/dev/null 2>&1
check "F3c non-gated, RTC far behind the clock: the gate still opens and the RTC is not used" local_open
newroot; STUB_TRACKING="$SYNCED"; export STUB_TRACKING
run $NOW0 1000 save-lastgood >/dev/null 2>&1; run $((NOW0+400)) 1400 save-lastgood >/dev/null 2>&1
check_not "R9 M3 no RTC device: hwclock never called, nothing changes" grep -q hwclock "$W/log"
newroot; rtc_fake $NOW0; run $NOW0 1000 seed >/dev/null 2>&1
check "R10 M3 seed writes the RTC and the marker" test -s "$R/etc/chrony/rtc-verified"

# N2: dead coin cell. The gateway ran, wrote the RTC + marker at T, was off, the cell died (RTC reads 2000-01-01),
# sysfixtime raised the clock and the RTC to the newest /etc file time. Then guard-start runs.
newroot; mark_gated; rtc_fake $NOW0; STUB_TRACKING="$SYNCED"; export STUB_TRACKING
run $NOW0 1000 save-lastgood >/dev/null 2>&1; run $((NOW0+400)) 1400 save-lastgood >/dev/null 2>&1
check "N2h setup: the gateway wrote the RTC and the marker at $((NOW0+400)) while it had a good cell" test "$(cat "$R/etc/chrony/rtc-verified")" = "$((NOW0+400))"
rtc_fake 946684800   # the cell died: the RTC reads 2000-01-01
sysfixtime_model 946684800
[ "$(cat "$R/sys/class/rtc/rtc0/since_epoch")" = "$((NOW0+400))" ] && ok "N2a model: sysfixtime lifts the dead RTC (2000-01-01) to the marker time" || bad "N2a model: sysfixtime lifts the dead RTC (got '$(cat "$R/sys/class/rtc/rtc0/since_epoch")')"
run $SYS_NOW 30 guard-start >/dev/null 2>&1
check_not "N2b dead coin cell on a gated gateway: RTC at the marker (rewritten by sysfixtime) does NOT open the gate" local_open
STUB_TRACKING="$UNSYNC"; export STUB_TRACKING
run $((SYS_NOW+120)) 150 save-lastgood >/dev/null 2>&1
check_not "N2c still withheld while chronyd has no real source" local_open
STUB_TRACKING="$SYNCED"; export STUB_TRACKING
run $((SYS_NOW+240)) 270 save-lastgood >/dev/null 2>&1
check "N2d the gate opens after one real sync in this boot" local_open
# non-gated gateway, RTC reset, no lastgood: the RTC cannot open the gate either
newroot; rtc_fake $((NOW0+500)); printf '%s\n' "$NOW0" > "$R/etc/chrony/rtc-verified"
run $((NOW0+600)) 100 guard-start >/dev/null 2>&1
check_not "N2e non-gated, RTC marker present, no lastgood: withheld (RTC alone does not open it)" local_open
# operator seed on a gated gateway still opens it for this boot (explicit assertion)
newroot; mark_gated; rtc_fake $NOW0
run $NOW0 1000 seed >/dev/null 2>&1
check "N2f an operator seed opens the gate on a gated gateway" local_open
check "N2g the seed on a gated gateway warns that it does not survive a reboot" sh -c "MAGK_TIME_ROOT='$R' MAGK_TIME_NOW=$NOW0 MAGK_TIME_UPTIME=1000 STUB_LOG='$W/log' $TS_SH '$SCRIPT' seed 2>&1 | grep -q 'THIS boot only'"
run $((NOW0+3000)) 20 guard-start >/dev/null 2>&1
check_not "N6a after a reboot the seeded gated gateway is withheld again until a real sync" local_open
newroot; rtc_fake $NOW0
check_not "N6b a seed on a NON-gated gateway prints no reboot warning" sh -c "MAGK_TIME_ROOT='$R' MAGK_TIME_NOW=$NOW0 MAGK_TIME_UPTIME=1000 STUB_LOG='$W/log' $TS_SH '$SCRIPT' seed 2>&1 | grep -q 'THIS boot only'"

# N1: system clock and RTC far apart (sysfixtime did not load the RTC). 104 days, the reviewer's case.
newroot; mark_gated; STUB_TRACKING="$SYNCED"; export STUB_TRACKING
run $NOW0 1000 save-lastgood >/dev/null 2>&1; rtc_fake $((NOW0+400)); run $((NOW0+400)) 1400 save-lastgood >/dev/null 2>&1
rtc_fake $((NOW0+500)); SKEWCLK=$((NOW0+500-104*86400))
run $SKEWCLK 30 guard-start >/dev/null 2>&1
check_not "N1a trusted-looking RTC (marker ok) with the system clock 104 days behind: gate stays closed" local_open
check "N1b the 104-day skew between system clock and RTC is reported at boot" sh -c "MAGK_TIME_ROOT='$R' MAGK_TIME_NOW=$SKEWCLK MAGK_TIME_UPTIME=30 STUB_LOG='$W/log' $TS_SH '$SCRIPT' guard-start 2>&1 | grep -q 'differs from the RTC'"
check_not "N1c a 10 s skew (normal) prints no skew warning" sh -c "MAGK_TIME_ROOT='$R' MAGK_TIME_NOW=$((NOW0+495)) MAGK_TIME_UPTIME=30 STUB_LOG='$W/log' $TS_SH '$SCRIPT' guard-start 2>&1 | grep -q 'differs from the RTC'"
# same skew on a non-gated gateway with no lastgood: still withheld
newroot; rtc_fake $((NOW0+500)); printf '%s\n' "$NOW0" > "$R/etc/chrony/rtc-verified"
run $SKEWCLK 30 guard-start >/dev/null 2>&1
check_not "N1d non-gated, RTC and clock 104 days apart, no lastgood: withheld" local_open

# N3: jump bound uses the uptime since the LAST SAVE in this boot, not the total uptime
newroot; STUB_TRACKING="$SYNCED"; export STUB_TRACKING
echo $NOW0 > "$R/etc/chrony/lastgood"
run $((NOW0+3700)) 2592000 save-lastgood >/dev/null 2>&1          # first save this boot, up = 30 days
[ "$(lg)" = "$((NOW0+3700))" ] && ok "N3a first save of a boot is bounded by uptime and is stored at once" || bad "N3a first save (got '$(lg)')"
run $((NOW0+3700+30*86400)) 2592600 save-lastgood >/dev/null 2>&1  # 10 min later by the monotonic clock, +30 days by the wall clock
[ "$(lg)" = "$((NOW0+3700))" ] && ok "N3b a +30 day reading 10 minutes after the last save is held for confirmation, not stored" || bad "N3b 30-day jump after 30 days of uptime was stored (got '$(lg)')"
run $((NOW0+3700+3700)) $((2592000+3700)) save-lastgood >/dev/null 2>&1
[ "$(lg)" = "$((NOW0+7400))" ] && ok "N3c the next normal hourly save is stored at once" || bad "N3c normal hourly save after N3b (got '$(lg)')"
# a reboot clears the reference: guard-start removes it, the next boot's bound is lastgood + uptime again
check "N3d the per-boot save reference exists after a save" test -f "$R/tmp/magk-time-saveup"
run $((NOW0+7400+90000)) 40 guard-start >/dev/null 2>&1
check_not "N3e after guard-start (a new boot) the save reference is gone" test -e "$R/tmp/magk-time-saveup"

# N6: status warns on stderr (stdout format unchanged) for a gated gateway serving the fallback without a sync
newroot; mark_gated; echo "local stratum 10" > "$R/var/etc/chrony.d/20-magk-local.conf"; STUB_TRACKING="$LOCALONLY"; export STUB_TRACKING
check "N6c status on a gated gateway serving local-only warns that it stays withheld after a reboot until a real sync" sh -c "MAGK_TIME_ROOT='$R' $TS_SH '$SCRIPT' status 2>&1 >/dev/null | grep -q 'after a reboot it stays withheld until the first real sync'"
check "N6d the status stdout line is unchanged (still starts with state=local-only)" sh -c "MAGK_TIME_ROOT='$R' $TS_SH '$SCRIPT' status 2>/dev/null | grep -q '^state=local-only stratum=10'"
STUB_TRACKING="$SYNCED"; export STUB_TRACKING
check_not "N6e status prints no warning while really synced" sh -c "MAGK_TIME_ROOT='$R' $TS_SH '$SCRIPT' status 2>&1 >/dev/null | grep -q 'without a current real sync'"

# F1 (round 3): a genuine first sync, then WAN loss, must not print seed wording
newroot; mark_gated; echo $((NOW0-100)) > "$R/etc/chrony/lastgood"; STUB_TRACKING="$SYNCED"; export STUB_TRACKING
run $((NOW0+600)) 1600 save-lastgood >/dev/null 2>&1
STUB_TRACKING="$LOCALONLY"; export STUB_TRACKING
check "F1a real sync then WAN loss: status warns the fallback is served without a current real sync" sh -c "MAGK_TIME_ROOT='$R' $TS_SH '$SCRIPT' status 2>&1 >/dev/null | grep -q 'without a current real sync'"
check_not "F1b real sync then WAN loss: the warning does not mention a seed" sh -c "MAGK_TIME_ROOT='$R' $TS_SH '$SCRIPT' status 2>&1 >/dev/null | grep -qi 'seed'"
check "F1c the warning says it stays withheld after a reboot until the first real sync" sh -c "MAGK_TIME_ROOT='$R' $TS_SH '$SCRIPT' status 2>&1 >/dev/null | grep -q 'after a reboot it stays withheld until the first real sync'"
STUB_TRACKING="$SYNCED"; export STUB_TRACKING

# ---------------------------------------------------------------- m6 prefix floor
v() { MAGK_TIME_ROOT="$W/none" TIME_ALLOW="$1" $TS_SH "$SCRIPT" render; }
check_not "m6a 0.0.0.0/1 rejected" v 0.0.0.0/1
check_not "m6b ./. rejected" v ./.
check_not "m6c 10.0.0.0/7 rejected" v 10.0.0.0/7
check_not "m6d 10.0.0.0/33 rejected" v 10.0.0.0/33
check_not "m6e 10.0.0/16 (three octets) rejected" v 10.0.0/16
check_not "m6f 10.0.0.256/16 rejected" v 10.0.0.256/16
check "m6g 10.0.0.0/8 accepted" v 10.0.0.0/8
check "m6h 10.41.0.0/16 accepted" v 10.41.0.0/16

# ---------------------------------------------------------------- apply / remove with stubs (m1, m2, m3, m4)
sysenv() { # run with system operations enabled but rooted in the fake root
  MAGK_TIME_ROOT="$R" MAGK_TIME_STUBS=1 MAGK_TIME_NOW="$NOW0" MAGK_TIME_UPTIME=1000 STUB_LOG="$W/log" \
    MAGK_NO_RELOAD="${NORELOAD:-0}" MAGK_TIME_STAGE_ONLY="${STAGE:-0}" TIME_UPSTREAM="${UP-pool.example}" $TS_SH "$SCRIPT" "$@"
}
mkinit() { # name enabled(0/1)
  mkdir -p "$R/etc/init.d"
  cat > "$R/etc/init.d/$1" <<EOF
#!/bin/sh
echo "$1 \$*" >> "$W/log"
[ "\$1" = enabled ] && exit $((1-$2))
exit 0
EOF
  chmod +x "$R/etc/init.d/$1"
}
newapply() { newroot; for s in chronyd cron magk-time-guard dnsmasq firewall; do mkinit $s 0; done; mkinit sysntpd 1; mkdir -p "$R/etc/crontabs" "$R/etc/config"; echo '0 3 * * * keep' > "$R/etc/crontabs/root"; }

newapply; STAGE=0 NORELOAD=0 sysenv apply >"$W/out" 2>&1
check "ap1 apply records that it disabled sysntpd" test -e "$R/etc/chrony/magk-sysntpd-disabled"
check "ap2 apply marks the gateway as gated when an upstream is set" grep -q '^gated=1' "$R/etc/chrony/magk-time-server.enabled"
check "m4a apply creates NAMED firewall sections" grep -q 'uci set firewall.magk_ntp_wan_reject=rule' "$W/log"
check "m4b apply does not use an anonymous add" sh -c "! grep -q 'uci add firewall rule' '$W/log'"
check "m2a unstaged apply commits itself (old behaviour for standalone use)" grep -q 'uci commit' "$W/log"
STAGE=0 sysenv remove >>"$W/out" 2>&1
check "m1 remove re-enables sysntpd" grep -qx 'sysntpd enable' "$W/log"
check "m1b remove restores system.ntp.enabled=1" grep -q "system.ntp.enabled=1" "$W/log"
check "m1c remove clears the marker" sh -c "[ ! -e '$R/etc/chrony/magk-sysntpd-disabled' ]"
check "ap3 remove keeps unrelated crontab lines" grep -q keep "$R/etc/crontabs/root"
check "ap3b remove removes the guard cron line" sh -c "! grep -q save-lastgood '$R/etc/crontabs/root'"

newapply; STAGE=1 sysenv apply >"$W/out" 2>&1
check_not "m2b staged apply does not run uci commit" grep -q 'uci commit' "$W/log"
check_not "m2c staged apply does not reload firewall or dnsmasq" grep -Eq '^(firewall|dnsmasq) reload' "$W/log"
STAGE=1 sysenv remove >>"$W/out" 2>&1
check_not "m2d staged remove does not run uci commit" grep -q 'uci commit' "$W/log"

# a node that never had sysntpd enabled by us: remove must not enable it
newapply; mkinit sysntpd 0; sysenv apply >/dev/null 2>&1; sysenv remove >/dev/null 2>&1
check_not "m1d remove leaves sysntpd alone when apply did not disable it" grep -qx 'sysntpd enable' "$W/log"

# legacy anonymous rules are removed highest index first
newapply; STUB_UCI_SHOW="firewall.@rule[1].name='magk_ntp_wan_reject'
firewall.@rule[4].name='magk_ntp_wan_reject'"; export STUB_UCI_SHOW
sysenv remove >/dev/null 2>&1; unset STUB_UCI_SHOW
first="$(grep -n 'delete firewall.@rule\[' "$W/log" | head -1)"
case "$first" in *'@rule[4]'*) ok "m4c legacy anonymous rules are deleted highest index first";; *) bad "m4c legacy anonymous rules deleted highest index first (got '$first')";; esac

# ungated: no upstream and no GPS => no gated flag
newapply; UP="" sysenv apply >/dev/null 2>&1
check_not "ap4 no upstream and no GPS: not gated" grep -q '^gated=1' "$R/etc/chrony/magk-time-server.enabled"

echo
echo "passed=$PASSES failed=$FAILS"
exit "$FAILS"
