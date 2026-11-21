# Wi-Fi: `ath10k_snoc` throughput fix and auto-recovery

The WCN3990 Wi-Fi (`ath10k_snoc`) on lavender periodically wedges: the firmware
crashes, auto-recovers with a fresh interface, or silently stalls TX/RX. This
directory installs a power-save/offload fix and a watchdog that recovers the
recoverable case:

| File | Installed as | Purpose |
| --- | --- | --- |
| `99-ath10k-fix` | `/etc/NetworkManager/dispatcher.d/99-ath10k-fix` (root:root, 0755) | On every `wlan0` `up`, disable power save and turn off the `tx/rx/tso/gso/gro` offloads. |
| `ath10k-watchdog.sh` | `/usr/local/sbin/ath10k-watchdog.sh` (root:root, 0755) | Soft-reconnect a wedged link; keep the fix applied. |
| `ath10k-watchdog.service` | `/etc/systemd/system/ath10k-watchdog.service` (root:root, 0644) | Runs the watchdog, `Restart=always`. |
| `install.sh` | — | Installs all of the above, disables IPv6 + pins DNS on the profile, enables/starts the service. |

## Install

```sh
pacman -S --needed ethtool     # required
sudo ./install.sh              # PROFILE="My SSID" to override the profile name
```

`install.sh` also runs, on the Wi-Fi profile:

```sh
nmcli connection modify "CAPING GUNUNG" \
    ipv6.method disabled ipv4.ignore-auto-dns yes ipv4.dns "1.1.1.1 8.8.8.8"
```

## Watchdog behaviour

Every 25 s it checks the default gateway on `wlan0` and scans `journalctl -k` for
`ath10k_snoc` failures (`firmware crashed`, `failed to restart hardware`,
`wmi command ... timed out`, `failed to start`). It recovers when:

* a fresh kernel error is seen **and** `wlan0` has no IPv4 address at all, or
* two consecutive gateway pings fail (a silent TX/RX stall).

Recovery is a **soft reconnect only**: `ip link set wlan0 up`,
`nmcli device set wlan0 managed yes`, `nmcli connection up <profile>` (retried
once). This handles the realistic case where the firmware crashed, ath10k
recovered, but `wlan0` came back `DOWN` without DHCP (FINDINGS §I6).

A 45-second cooldown keeps it from looping, a 30-second start-up grace avoids
reacting to boot-time log noise, and after every reconnect it re-applies the fix.
It does nothing while the Wi-Fi radio is switched off.

> ### No reload, no radio toggle — both are unsafe here
>
> Everything stronger than a reconnect needs a **full reboot** on this device, and
> the watchdog deliberately does none of it:
>
> * **`modprobe -r ath10k_snoc`** tears down the WLAN subsystem inside the shared
>   MSS (`4080000.remoteproc`); the next probe fails with
>   `msa info req rejected: 90`, `qmi-board-id=0` / `failed to fetch board-2.bin`
>   and `wlan0` never returns.
> * **A live `18800000.wifi` `unbind`/`bind`** does exactly the same (reproduced
>   2026-11-21) — it is *not* a safe reload alternative.
> * **`nmcli radio wifi off`/`on`** can also leave the WCNSS wedged on a working
>   link (`failed to create WMI vdev 0: -108`). Worse, NetworkManager persists
>   `WirelessEnabled=false` in its state file, so a reboot (or a killed script)
>   while the radio is off leaves Wi-Fi disabled after the next boot. The watchdog
>   never turns the radio off.
>
> See `docs/FINDINGS.md` sections I5 and K.

> ### Reboot last resort
>
> When the soft reconnect does not bring the link back, the watchdog logs that a
> reboot is required and keeps retrying. It reboots the phone by itself only if
> `REBOOT_LAST_RESORT=1` is set in the service environment (off by default, so a
> runaway watchdog can never reboot the phone).
