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
if getent passwd maf >/dev/null 2>&1; then
    fail "build account 'maf' still present (expected root + alarm only)"
else
    ok "no 'maf' build account"
fi

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

# The released tarball was repacked as uid 1000.  If the builder did not
# chown it back, setuid helpers run as euid 1000 and both the USB gadget and
# sshd fail.  Check the two symptoms directly.
owner=$(stat -c '%u:%g' /usr/bin/mount 2>/dev/null || true)
[ "$owner" = "0:0" ] && ok "/usr/bin/mount owned by root:root" \
    || fail "ownership bug: /usr/bin/mount is ${owner:-missing} (expected 0:0)"
[ -u /usr/bin/mount ] && ok "/usr/bin/mount is setuid" \
    || warn "/usr/bin/mount is not setuid"
sshd_owner=$(stat -c '%u' /usr/share/empty.sshd 2>/dev/null || true)
if [ -e /usr/share/empty.sshd ] && [ "$sshd_owner" != "0" ]; then
    fail "ownership bug: /usr/share/empty.sshd owned by ${sshd_owner}"
else
    ok "/usr/share/empty.sshd owned by root"
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
for u in sshd NetworkManager seatd phosh tqftpserv pd-mapper diag-router rmtfs modem-uim-init usb-net-debug zram-swap; do
    state=$(systemctl is-active "$u" 2>/dev/null || true)
    [ "$state" = "active" ] && ok "$u: active" || fail "$u: ${state:-unknown}"
done

echo "== graphical session =="
target=$(systemctl get-default 2>/dev/null || true)
[ "$target" = "graphical.target" ] && ok "default target: graphical.target" \
    || fail "default target: ${target:-unknown} (expected graphical.target)"

state=$(systemctl is-active phosh 2>/dev/null || true)
[ "$state" = "active" ] && ok "phosh: active" || fail "phosh: ${state:-unknown}"

for p in phoc phosh; do
    if pgrep -x "$p" >/dev/null 2>&1; then
        ok "session process: $p"
    else
        warn "session process not running: $p"
    fi
done
# The on-screen keyboard is phosh-osk-stevia (its comm is truncated to 15
# characters, so pgrep -x does not match); older images used squeekboard.
if pgrep -f 'phosh-osk-stevia' >/dev/null 2>&1 || pgrep -x squeekboard >/dev/null 2>&1; then
    ok "session process: on-screen keyboard"
else
    warn "no on-screen keyboard process (phosh-osk-stevia)"
fi

# Resolve phosh by exact name: `pgrep -n phosh` also matches
# phosh-osk-stevia, so it can read the keyboard's environment instead.
PHOSH_PID=$(pgrep -x phosh 2>/dev/null | head -n1)
# GTK 4.24's accelerated renderer is named "gl" ("ngl" is obsolete).
if [ -n "$PHOSH_PID" ]; then
    gsk=$(tr '\0' '\n' < "/proc/$PHOSH_PID/environ" 2>/dev/null | sed -n 's/^GSK_RENDERER=//p')
else
    gsk=""
fi
[ "$gsk" = "gl" ] && ok "GSK_RENDERER=gl" \
    || warn "GSK_RENDERER is '${gsk:-unset}' (expected gl; cairo is slower)"

# UBWC compression corrupts Firefox/WebRender buffers on Adreno 512.
if [ -n "$PHOSH_PID" ]; then
    ubwc=$(tr '\0' '\n' < "/proc/$PHOSH_PID/environ" 2>/dev/null | sed -n 's/^FD_MESA_DEBUG=//p')
else
    ubwc=""
fi
[ "$ubwc" = "noubwc" ] && ok "FD_MESA_DEBUG=noubwc" \
    || warn "FD_MESA_DEBUG is '${ubwc:-unset}' (GPU apps may show magenta blocks)"

[ -d /var/log ] && ok "/var/log exists" || fail "/var/log missing (usb-net-debug needs it)"

echo "== console fallback (tty2) =="
[ -e /dev/fb0 ] && ok "framebuffer /dev/fb0 present" || warn "no /dev/fb0"
font=$(sed -n 's/^FONT=//p' /etc/vconsole.conf 2>/dev/null | head -n1)
[ -n "$font" ] && ok "console font: $font" || warn "no FONT in /etc/vconsole.conf"

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

echo "== swap =="
if grep -q '^/dev/zram' /proc/swaps 2>/dev/null; then
    ok "zram swap active: $(awk '$1 ~ /^\/dev\/zram/ { printf "%s %s kB", $1, $3 }' /proc/swaps)"
    command -v zramctl >/dev/null 2>&1 && zramctl 2>/dev/null | sed 's/^/  /'
else
    warn "no zram swap (zram-swap.service inactive?)"
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

echo "== audio =="
if [ -f /usr/share/alsa/ucm2/Qualcomm/lavender/HiFi.conf ] &&
   [ -f /usr/share/alsa/ucm2/Qualcomm/lavender/Mic.conf ]; then
    ok "lavender UCM2 profile installed"
else
    fail "lavender UCM2 profile missing"
fi
if [ -r /proc/asound/card0/id ]; then
    ok "sound card present: $(cat /proc/asound/card0/id)"
else
    fail "no sound card (kernel needs CONFIG_SND_SOC_SM8250=m)"
fi
for m in snd_soc_sm8250 snd_soc_max98937; do
    if grep -q "^$m " /proc/modules 2>/dev/null; then
        ok "$m loaded"
    else
        warn "$m not loaded (speaker will not work)"
    fi
done
if [ -f /etc/wireplumber/wireplumber.conf.d/50-lavender-s16.conf ]; then
    ok "WirePlumber speaker S16LE rule installed"
else
    warn "WirePlumber speaker S16LE rule missing (speaker runs ~48 dB quiet)"
fi
state=$(systemctl is-active rtkit-daemon 2>/dev/null || true)
[ "$state" = "active" ] && ok "rtkit-daemon: active" \
    || warn "rtkit-daemon: ${state:-unknown} (PipeWire runs without realtime priority)"
if [ -f /etc/systemd/sleep.conf.d/10-lavender.conf ] &&
   grep -q '^AllowSuspend=no' /etc/systemd/sleep.conf.d/10-lavender.conf; then
    ok "automatic suspend disabled (s2idle is broken)"
else
    warn "suspend is not disabled; a failed resume can take down audio"
fi
if command -v amixer >/dev/null 2>&1 && amixer -c 0 info >/dev/null 2>&1; then
    dv=$(amixer -c 0 cget name='Digital Volume' 2>/dev/null | sed -n 's/.*: values=//p')
    sv=$(amixer -c 0 cget name='Speaker Volume' 2>/dev/null | sed -n 's/.*: values=//p')
    dsp=$(amixer -c 0 cget name='Amp DSP Switch' 2>/dev/null | sed -n 's/.*: values=//p')
    [ "$dv" = "56" ] && ok "Digital Volume: 56 (-2 dB)" \
        || warn "Digital Volume: ${dv:-unknown} (expected 56)"
    case "$sv" in
        5) ok "Speaker Volume: 5 (+18 dB, vendor init)" ;;
        6) ok "Speaker Volume: 6 (+21 dB, UCM)" ;;
        *) warn "Speaker Volume: ${sv:-unknown} (expected 5 or 6)" ;;
    esac
    [ "$dsp" = "off" ] && ok "Amp DSP Switch: off" \
        || warn "Amp DSP Switch: ${dsp:-unknown} (expected off)"
fi

echo
if [ "$OK" -eq 0 ]; then
    echo "RESULT: core checks passed (warnings: $WARN)"
else
    echo "RESULT: failures found (warnings: $WARN)"
fi
exit "$OK"