# Switching the desktop environment or window manager

The release image boots **Phosh** on `tty1` as user `alarm`. Phosh is the
tested default, but the same rootfs can run another Wayland session (Plasma
Mobile, GNOME, Sway, Hyprland, ...) or an X11 session.

This page shows how to switch sessions **without rebuilding the image** and
without losing the device-specific patches that make this port usable. The
kernel, Mesa, ModemManager, audio and sleep fixes are system-wide; they are
not tied to Phosh.

> Phosh remains the supported default. Plasma Mobile is available in the
> Arch Linux ARM `aarch64` repositories, but it has not been validated on the
> Redmi Note 7 hardware by this project. Treat a new session as experimental
> until you have tested it yourself.

## 1. How the current session starts

The image does not use a display manager. `graphical.target` pulls in a
single systemd service that runs the compositor as `alarm` on `tty1`:

```
graphical.target
└── phosh.service
    ├── User=alarm, PAMName=login, TTYPath=/dev/tty1
    ├── XDG_RUNTIME_DIR=/run/user/1000
    ├── LIBSEAT_BACKEND=seatd
    ├── GSK_RENDERER=ngl
    ├── FD_MESA_DEBUG=noubwc
    └── ExecStart=/usr/bin/phosh-session
```

`seatd` grants the session access to DRM and input devices. `getty@tty2`
stays enabled, so Ctrl+Alt+F2 on a USB keyboard still gives a text console if
the compositor breaks. USB and Wi-Fi SSH remain available as well.

Only **one** compositor can own the DRM device at a time. Always stop the old
session before starting a new one; do not enable two session units together.

## 2. Before switching

1. Keep SSH or `getty@tty2` working. Test it **before** changing the session.
2. Keep Phosh installed. Disable its service, do not uninstall the package;
   switching back is then one command.
3. Check free space. Plasma Mobile and its KDE/Qt dependencies can need
   roughly 1.5–2.5 GB:

   ```sh
   df -h /
   ```

4. Check the patches in section 3 after any `pacman -Syu`. A package upgrade
   can replace the patched Mesa or ModemManager binaries.

## 3. Patches that must survive a desktop switch

These are installed by the release image or by `rootfs/build-rootfs.sh` and
are independent of the desktop:

| Patch | Installed at | How it is kept |
| --- | --- | --- |
| Mesa a5xx 2D-blit fix | `/usr/lib/libgallium-26.2.6-arch1.1.so` | pacman hook + `/usr/local/sbin/reinstall-patched-libs` |
| ModemManager without a network/data port | `/usr/local/lib/patched/ModemManager`, copied to `/usr/bin` and `/usr/sbin` | same pacman hook |
| ALSA UCM2 profile | `/usr/share/alsa/ucm2/conf.d/sdm660/`, `/usr/share/alsa/ucm2/Qualcomm/lavender/` | shipped in the rootfs; re-copy if `alsa-ucm-conf` overwrites it |
| WirePlumber speaker format | `/etc/wireplumber/wireplumber.conf.d/50-lavender-s16.conf` | shipped in the rootfs |
| No-suspend policy | `/etc/systemd/sleep.conf.d/10-lavender.conf` | shipped in the rootfs |
| 7.2.3 kernel and modules | `/usr/lib/modules/7.2.3-sdm660/` | do not install `linux-aarch64`; it is in `IgnorePkg` |

Verify the important ones after installing desktop packages:

```sh
ls -l /usr/lib/libgallium-*.so
grep -a libgallium /usr/lib/libEGL_mesa.so.0
sudo /usr/local/sbin/reinstall-patched-libs
pacman -Q mesa modemmanager wireplumber
```

If a Mesa upgrade changes the `libgallium` soname, the old patched library no
longer matches `libEGL_mesa` and must be rebuilt from
[`userspace/mesa/`](../userspace/mesa/README.md). The pacman hook only
restores a patched library whose soname is still requested by the installed
Mesa.

The Adreno 512 UBWC bug affects every compositor, so keep
`FD_MESA_DEBUG=noubwc` in all session units. `GSK_RENDERER=ngl` is a GTK
setting; it is harmless for Qt/KDE sessions and required for GTK-based ones
(Phosh, GNOME).

## 4. Generic Wayland session unit

The safest pattern is one systemd unit per session, modelled on
`phosh.service`. Create `/etc/systemd/system/wayland-session.service`:

```ini
[Unit]
Description=Wayland session on tty1
After=systemd-user-sessions.service systemd-logind.service NetworkManager.service seatd.service user@1000.service
Wants=systemd-logind.service user@1000.service
Conflicts=getty@tty1.service phosh.service
After=getty@tty1.service

[Service]
Type=simple
User=alarm
PAMName=login
TTYPath=/dev/tty1
WorkingDirectory=/home/alarm
Environment=XDG_SESSION_TYPE=wayland
Environment=XDG_SESSION_CLASS=user
Environment=XDG_CURRENT_DESKTOP=sway
Environment=XDG_SESSION_DESKTOP=sway
Environment=XDG_RUNTIME_DIR=/run/user/1000
Environment=DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus
Environment=LIBSEAT_BACKEND=seatd
Environment=FD_MESA_DEBUG=noubwc
ExecStartPre=/bin/sh -c 'for i in $(seq 1 100); do [ -S /run/user/1000/bus ] && exit 0; sleep 0.1; done; exit 0'
ExecStart=/usr/bin/sway
Restart=on-failure
RestartSec=3
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=graphical.target
```

Change `XDG_CURRENT_DESKTOP`, `XDG_SESSION_DESKTOP` and `ExecStart` for the
session you want. Then switch:

```sh
sudo systemctl daemon-reload
sudo systemctl disable --now phosh.service
sudo systemctl enable --now wayland-session.service
```

Check it:

```sh
systemctl status wayland-session.service
journalctl -b -u wayland-session.service -n 100 --no-pager
pgrep -af 'sway|kwin_wayland|gnome-shell|Hyprland'
```

To go back to Phosh:

```sh
sudo systemctl disable --now wayland-session.service
sudo systemctl enable --now phosh.service
```

For the first test it is often easier to leave the unit disabled and use
`sudo systemctl start wayland-session.service` after stopping Phosh. If the
screen stays black, SSH in and start Phosh again; the unit can be fixed
without rebooting.

## 5. Plasma Mobile

`plasma-mobile` is packaged for Arch Linux ARM `aarch64` (6.8.3-1 at the time
of writing). It pulls in KWin, Plasma Workspace, Plasma NM/PA, PowerDevil,
`plasma-keyboard`, `plasma-nano` and the mobile shell. It does **not** install
Waydroid; the optional Waydroid KCM only works if you install Waydroid
yourself.

### Install

```sh
sudo pacman -Syu
sudo pacman -S --needed plasma-mobile

# optional phone apps
sudo pacman -S --needed plasma-phonebook plasma-dialer kclock kalk kweather kasts kdeconnect
```

Watch the pacman output for Mesa/ModemManager upgrades and re-apply the
patches as described in section 3.

### Service

Create `/etc/systemd/system/plasma-mobile.service`:

```ini
[Unit]
Description=Plasma Mobile on tty1
After=systemd-user-sessions.service systemd-logind.service NetworkManager.service seatd.service user@1000.service
Wants=systemd-logind.service user@1000.service
Conflicts=getty@tty1.service phosh.service
After=getty@tty1.service

[Service]
Type=simple
User=alarm
PAMName=login
TTYPath=/dev/tty1
WorkingDirectory=/home/alarm
Environment=XDG_SESSION_TYPE=wayland
Environment=XDG_SESSION_CLASS=user
Environment=XDG_CURRENT_DESKTOP=KDE
Environment=XDG_SESSION_DESKTOP=KDE
Environment=XDG_RUNTIME_DIR=/run/user/1000
Environment=DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus
Environment=LIBSEAT_BACKEND=seatd
Environment=FD_MESA_DEBUG=noubwc
ExecStartPre=/bin/sh -c 'for i in $(seq 1 100); do [ -S /run/user/1000/bus ] && exit 0; sleep 0.1; done; exit 0'
ExecStart=/usr/bin/startplasmamobile
Restart=on-failure
RestartSec=3
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=graphical.target
```

`startplasmamobile` sets the Plasma Mobile environment itself
(`PLASMA_PLATFORM=phone:handset`, `QT_QUICK_CONTROLS_MOBILE`, the mobile
shell, and the env-manager defaults). The unit supplies the session bus,
logind seat and `XDG_*` variables that a display manager would normally set.
Both XDG names are `KDE` because the upstream
`plasma-mobile.desktop` declares `DesktopNames=KDE`.
If the session complains that no D-Bus session bus is available, use the
command from the upstream desktop file instead:

```ini
ExecStart=/usr/lib/plasma-dbus-run-session-if-needed /usr/bin/startplasmamobile
```

### Start it

```sh
sudo systemctl daemon-reload
sudo systemctl disable --now phosh.service
sudo systemctl enable --now plasma-mobile.service
```

The first start creates the Plasma Mobile config in
`/home/alarm/.config/plasma-mobile/` and may show the first-run setup. Watch
the log from SSH:

```sh
journalctl -b -u plasma-mobile.service -f
```

A working session shows `kwin_wayland` and `plasmashell`:

```sh
pgrep -af 'startplasma|kwin_wayland|plasmashell'
```

### Back to Phosh

```sh
sudo systemctl disable --now plasma-mobile.service
sudo systemctl enable --now phosh.service
```

### Plasma Mobile notes

- This is not the tested default. Expect mobile-shell, scaling, keyboard or
  KWin/Adreno issues that Phosh does not have. Report them with the output of
  `journalctl -b -u plasma-mobile.service`.
- If KWin fails to initialise OpenGL, try its OpenGL ES backend:

  ```ini
  Environment=KWIN_COMPOSE=O2ES
  ```

  For a slow software fallback, `KWIN_COMPOSE=Q` can be used for debugging.
  If KWin reports DRM modifier errors, add
  `Environment=KWIN_DRM_USE_MODIFIERS=0`. Remove these lines once the normal
  GPU path works.
- If Qt Quick itself crashes, `QT_QUICK_BACKEND=software` is a last-resort
  fallback; it is much slower and not suitable for daily use.
- Audio uses the same PipeWire/WirePlumber/UCM2 stack, so the speaker fix is
  independent of the desktop. Check with `wpctl status` and `speaker-test`.
- Waydroid is still optional and still needs
  `sudo pacman -S waydroid`, `sudo waydroid init`, and
  `sudo systemctl enable --now waydroid-container`.
- Suspend must stay disabled; the shipped sleep policy blocks it because
  s2idle does not complete on this kernel.

## 6. Other sessions

The generic unit in section 4 works for any Wayland session. Only the package
set, `ExecStart` and the `XDG_*` names differ:

| Session | Install | `ExecStart` | `XDG_CURRENT_DESKTOP` |
| --- | --- | --- | --- |
| Phosh (default) | `phosh phoc squeekboard` | `/usr/bin/phosh-session` | `Phosh:GNOME` |
| Plasma Mobile | `plasma-mobile` | `/usr/bin/startplasmamobile` | `KDE` |
| GNOME | `gnome-shell gnome-session mutter` | `/usr/bin/gnome-session` | `GNOME` |
| Sway | `sway` | `/usr/bin/sway` | `sway` |
| Hyprland | `hyprland` | `/usr/bin/Hyprland` | `Hyprland` |

GNOME is considerably heavier than Phosh on this device; Sway and Hyprland
are lighter but do not provide a mobile shell or an on-screen keyboard by
default (install `squeekboard` or `wvkbd` if needed). For Sway, keep
`WLR_BACKENDS=drm,libinput` in the unit if you want to pin the backends.

### X11 (XFCE, i3, ...)

The release is Wayland-first and X11 is **not tested** on this image. Xorg can
work with the modesetting driver, but only one compositor may own the DRM
device: stop Phosh/Plasma Mobile first. A minimal XFCE test from the `tty2`
console:

```sh
sudo pacman -S --needed xorg-server xorg-xinit xf86-input-libinput xfce4-session

# as alarm
echo 'exec startxfce4' > ~/.xinitrc
sudo systemctl stop phosh.service
startx -- :0 vt2
```

Expect poor touchscreen and scaling behaviour compared with the Wayland
sessions, and no on-screen keyboard unless you configure one. The same
`FD_MESA_DEBUG=noubwc` rule applies.

## 7. Optional: a graphical session picker

The image deliberately avoids a display manager: one unit owns `tty1` and
there is no greeter to break. If you want to choose a session at boot, a
small greeter such as `greetd` + `tuigreet` can replace the per-session units.
This is optional and not tested on the phone.

```sh
sudo pacman -S --needed greetd greetd-tuigreet
sudo systemctl disable --now phosh.service
sudo systemctl disable --now plasma-mobile.service 2>/dev/null || true
```

`/etc/greetd/config.toml`:

```toml
[terminal]
vt = 1

[default_session]
command = "tuigreet --time --remember --sessions /usr/share/wayland-sessions"
user = "greeter"
```

Then:

```sh
sudo systemctl enable --now greetd.service
```

Keep `getty@tty2` enabled and keep SSH available while testing. `sddm` also
works as a KDE greeter, but its desktop-oriented UI is awkward on a phone.

## 8. Troubleshooting

- **Black screen, SSH works**: stop the new unit and start Phosh:
  ```sh
  sudo systemctl stop plasma-mobile.service
  sudo systemctl start phosh.service
  ```
- **`/dev/dri/card0` busy or permission denied**: another compositor is still
  running. Check `pgrep -af 'phoc|kwin_wayland|sway|Hyprland|gnome-shell'` and
  stop the old unit. Confirm `systemctl status seatd` is active.
- **No session bus / logind errors**: check `systemctl status user@1000` and
  `loginctl list-sessions`; keep the `ExecStartPre` bus wait from the unit.
- **Glyphs disappear after a Mesa upgrade**: re-run
  `sudo /usr/local/sbin/reinstall-patched-libs`, then check that
  `/usr/lib/libEGL_mesa.so.0` asks for the patched `libgallium` soname. Rebuild
  it if the soname changed.
- **No sound**: `wpctl status`, then `speaker-test -c 2 -t wav`; verify the
  UCM2 files and `50-lavender-s16.conf` are still present.
- **Suspend hangs**: the system-wide policy in
  `/etc/systemd/sleep.conf.d/10-lavender.conf` must stay in place. Do not
  enable suspend from the desktop's power settings.
- **Disk full during install**: grow the root filesystem
  (`resize2fs /dev/disk/by-partlabel/userdata`) or remove unused sessions.
  Plasma Mobile is the largest option in this list.
