#!/bin/sh
# ath10k-watchdog: keep the WCN3990 (ath10k_snoc) Wi-Fi usable on lavender.
#
# Installed by userspace/wifi/install.sh as /usr/local/sbin/ath10k-watchdog.sh
# and started by ath10k-watchdog.service.
#
# Every LOOP seconds it re-applies the throughput fix (power save off; the
# offloads off), because a driver restart resets both, and checks the link:
#   * the default gateway on wlan0 must answer a 4-second ping;
#   * the kernel log is scanned for ath10k_snoc failures.
#
# It recovers with a **soft reconnect only**:
#   ip link set wlan0 up; nmcli device set wlan0 managed yes;
#   nmcli connection up <profile>           (retried once)
#
# This covers the realistic recoverable case: the firmware crashes, ath10k
# recovers by itself, but wlan0 comes back DOWN without DHCP (see
# docs/FINDINGS.md section I6). Everything below needs a reboot and is NOT done:
#
#   * `modprobe -r ath10k_snoc` and a live `18800000.wifi` unbind/bind: both tear
#     down the WLAN subsystem inside the shared MSS (`4080000.remoteproc`) so the
#     next probe fails with `msa info req rejected: 90`,
#     `qmi not waiting for msa_ready indicator`, `qmi-board-id=0` /
#     `failed to fetch board-2.bin`, and wlan0 never returns (FINDINGS section I5).
#   * `nmcli radio wifi off/on`: on a *working* link this can also leave the WCNSS
#     wedged (`failed to create WMI vdev 0: -108`). Worse, NetworkManager
#     persists `WirelessEnabled=false` in its state file, so if the box is
#     rebooted (or this script is killed) with the radio off, Wi-Fi stays off
#     after the next boot. The watchdog therefore never turns the radio off.
#
# A soft reconnect is the only safe action. If it does not bring the link back,
# the watchdog logs that a reboot is required and keeps retrying under the
# cooldown. It can reboot by itself only if REBOOT_LAST_RESORT=1 is set in the
# environment (off by default, so a runaway watchdog can never reboot the phone),
# and it never touches the radio while the user has it switched off.

set -u

IFACE=wlan0
LOOP=25                  # seconds between checks
COOLDOWN=45              # minimum seconds between recovery actions
PING_TIMEOUT=4           # seconds
FAILS_TO_RECOVER=2       # consecutive failed cycles before recovering
INIT_GRACE=30            # seconds to let boot/DHCP settle before the first check
PROFILE="${PROFILE:-CAPING GUNUNG}"
REBOOT_LAST_RESORT="${REBOOT_LAST_RESORT:-0}"
ERRPAT='firmware crashed|failed to restart hardware|wmi command .* timed out|failed to start'

START_EPOCH=$(date +%s)
LAST_ACTION=0
fails=0

log() { echo "$(date '+%F %T') ath10k-watchdog: $*"; }

gateway() {
    ip route show default dev "$IFACE" 2>/dev/null \
        | awk '/default/{for(i=1;i<=NF;i++) if($i=="via"){print $(i+1); exit}}'
}

ping_gw() {
    gw=$(gateway)
    [ -n "$gw" ] || return 1
    ping -c1 -W"$1" -I "$IFACE" "$gw" >/dev/null 2>&1
}

apply_fix() {
    iw dev "$IFACE" set power_save off 2>/dev/null || true
    ethtool -K "$IFACE" tx off rx off tso off gso off gro off 2>/dev/null || true
}

have_ip() {
    ip -4 addr show "$IFACE" 2>/dev/null | grep -q 'inet '
}

# ath10k_snoc errors logged at or after the given epoch (never before we started,
# so a boot-time crash cannot trigger a recovery on startup).
errors_since() {
    journalctl -k --since "@$1" --no-pager 2>/dev/null | grep -E "$ERRPAT"
}

reconnect() {
    ip link set "$IFACE" up >/dev/null 2>&1 || true
    nmcli device set "$IFACE" managed yes >/dev/null 2>&1 || true
    nmcli connection up "$PROFILE" >/dev/null 2>&1 || true
    sleep 4
    have_ip || { nmcli connection up "$PROFILE" >/dev/null 2>&1 || true; sleep 4; have_ip; }
}

recover() {
    log "link wedged ($1) -> soft reconnect"
    LAST_ACTION=$(date +%s)
    fails=0
    if reconnect; then
        log "recovered"
        apply_fix
        return 0
    fi
    log "still down; a reboot is required to restore Wi-Fi (see docs/FINDINGS.md I5)"
    if [ "$REBOOT_LAST_RESORT" = 1 ]; then
        log "REBOOT_LAST_RESORT=1 -> rebooting"
        reboot
    fi
    return 1
}

log "started (iface=$IFACE loop=${LOOP}s cooldown=${COOLDOWN}s grace=${INIT_GRACE}s reboot_last_resort=$REBOOT_LAST_RESORT)"

# Let boot/DHCP settle, then apply the fix once. The check below never looks at
# kernel errors older than START_EPOCH + INIT_GRACE.
sleep "$INIT_GRACE"
apply_fix

while :; do
    now=$(date +%s)

    # Never fight an intentionally disabled radio (and never turn it back on:
    # NetworkManager persists WirelessEnabled=false across reboots).
    if [ "$(nmcli -t radio wifi 2>/dev/null)" = "disabled" ]; then
        sleep "$LOOP"
        continue
    fi

    cooling=$(( now - LAST_ACTION < COOLDOWN ))

    # 1. A fresh kernel error and no IPv4 address at all.
    since=$(( now - LOOP ))
    [ "$since" -lt "$(( START_EPOCH + INIT_GRACE ))" ] && since=$(( START_EPOCH + INIT_GRACE ))
    if ! have_ip && [ -n "$(errors_since "$since")" ] && [ "$cooling" = 0 ]; then
        recover "kernel error, no IPv4"
        continue
    fi

    # 2. Silent TX/RX stall: consecutive gateway ping failures.
    if ping_gw "$PING_TIMEOUT"; then
        fails=0
    else
        fails=$((fails + 1))
        log "gateway ping failed ($fails/$FAILS_TO_RECOVER)"
        if [ "$fails" -ge "$FAILS_TO_RECOVER" ] && [ "$cooling" = 0 ]; then
            recover "consecutive ping failures"
            continue
        fi
    fi

    # 3. Keep the fix applied; a reconnect resets it.
    apply_fix

    sleep "$LOOP"
done
