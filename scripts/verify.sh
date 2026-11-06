#!/bin/sh
# Run this *on the phone* after the first boot.  It prints a short report so a
# fresh install can be checked without guessing.
#
#   sh verify.sh
#
# Exit code 0 means the core checks passed.  Warnings do not fail the run.
set -u

OK=0
WARN=0
fail() { echo "  FAIL: $*"; OK=1; }
warn() { echo "  WARN: $*"; WARN=$((WARN+1)); }
ok()   { echo "  ok:   $*"; }

echo "== system =="
echo "  kernel:   $(uname -r)"
echo "  machine:  $(uname -m)"
echo "  hostname: $(cat /etc/hostname 2>/dev/null)"
echo "  uptime:   $(uptime -p 2>/dev/null || true)"

echo "== root filesystem =="
ROOTDEV=$(findmnt -n -o SOURCE / 2>/dev/null || true)
ROOTFS=$(findmnt -n -o FSTYPE / 2>/dev/null || true)
echo "  device:   ${ROOTDEV:-unknown}"
echo "  fstype:   ${ROOTFS:-unknown}"
echo "  size:     $(df -h / | awk 'NR==2 {print $2}')"
echo "  used:     $(df -h / | awk 'NR==2 {print $3}')"
[ "$ROOTFS" = "ext4" ] || warn "root is not ext4"
if findmnt -n -o OPTIONS / 2>/dev/null | grep -q '\bro\b'; then
    fail "root is mounted read-only"
fi

echo "== kernel modules =="
KVER=$(uname -r)
if [ -d "/usr/lib/modules/$KVER" ]; then
    ok "module tree /usr/lib/modules/$KVER"
else
    fail "no module tree for $KVER"
fi
for m in msm ath10k_snoc qcom_q6v5_mss; do
    if lsmod 2>/dev/null | grep -q "^$m "; then
        ok "module loaded: $m"
    else
        # These may be built-in; only warn.
        grep -q "$m" /lib/modules/"$KVER"/modules.builtin 2>/dev/null \
            && ok "module built-in: $m" \
            || warn "module not loaded: $m"
    fi
done

echo "== services =="
for u in sshd NetworkManager tqftpserv pd-mapper diag-router rmtfs modem-uim-init; do
    state=$(systemctl is-active "$u" 2>/dev/null || true)
    [ "$state" = "active" ] && ok "$u: active" || fail "$u: ${state:-unknown}"
done

echo "== network =="
ip -brief addr show 2>/dev/null | sed 's/^/  /'
if ip -4 addr show 2>/dev/null | grep -q '172\.16\.42\.1'; then
    ok "USB debug address 172.16.42.1 present"
else
    warn "USB debug address 172.16.42.1 missing"
fi
if ping -c1 -W2 1.1.1.1 >/dev/null 2>&1; then
    ok "outbound IPv4 works"
else
    warn "no outbound IPv4 (WiFi not configured?)"
fi

echo "== clock =="
if command -v timedatectl >/dev/null 2>&1; then
    timedatectl status 2>/dev/null | sed 's/^/  /'
fi

echo "== modem =="
if command -v mmcli >/dev/null 2>&1; then
    mmcli -L 2>/dev/null | sed 's/^/  /' || true
    MODEM=$(mmcli -L 2>/dev/null | grep -o '/Modem/[0-9]*' | head -1)
    if [ -n "$MODEM" ]; then
        mmcli -m "$MODEM" 2>/dev/null | grep -E 'state|access technology|operator|signal quality' | sed 's/^/  /' || true
    else
        warn "ModemManager sees no modem yet"
    fi
else
    warn "mmcli not installed"
fi

echo
if [ "$OK" -eq 0 ]; then
    echo "RESULT: core checks passed (warnings: $WARN)"
else
    echo "RESULT: failures found (warnings: $WARN)"
fi
exit "$OK"