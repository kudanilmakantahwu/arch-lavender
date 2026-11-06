# Experimental GUI (Phosh)

> **The GUI is not the default and it is not reliable yet.** The headless
> install is the supported path. Read this page before enabling Phosh, and
> keep the USB SSH link working so you can recover.

## What it is

The GUI is a Phosh session on top of the mainline `msm`/`a5xx` stack:

| Component | Role |
| --- | --- |
| `phosh` | mobile shell (GTK) |
| `phoc` | wlroots-based compositor |
| `squeekboard` | on-screen keyboard |
| `touch-zoom` | local helper that maps a pinch gesture to zoom in GNOME Console |
| patched `libwlroots-0.20.so` | allows layer-shell surfaces with a zero dimension |

The base install already contains the Phosh packages. The GUI is opt-in only
because the session is still buggy, not because anything has to be installed.

## What works

- Phosh starts, shows the lock screen and the home screen
- Touch input
- On-screen keyboard
- WiFi settings
- Chatty (SMS)
- GNOME Calls (call setup; audio untested)
- Terminal / GNOME Console
- Pinch-to-zoom in the terminal via `touch-zoom`

## Known problems

- The session can crash after a GPU hang. The a5xx kernel patches reduce this,
  but they do not eliminate it.
- Rotation and scaling are not reliable.
- Some Phosh dialogs are larger than the 1080×2340 screen.
- The compositor sometimes starts before the panel is ready, leaving a black
  screen. Restarting `phosh` or rebooting fixes it.
- `touch-zoom` is a workaround, not a proper gesture implementation.
- Audio routing during calls is unverified.

## Enable it at image-build time

```sh
sudo ./rootfs/build-rootfs.sh rootfs-arch.tar.zst rootfs.img --with-gui
```

This:

- installs `userspace/gui-experimental/bin/touch-zoom`,
- installs `phosh.service` and `touch-zoom.service`,
- enables both in `graphical.target`,
- sets `default.target` to `graphical.target` and stops enabling
  `getty@tty1`.

Then flash the image as usual.

## Enable it on an existing headless install

The GUI files are already in the shipped rootfs. On the phone:

```sh
install -Dm755 /path/to/touch-zoom /usr/local/bin/touch-zoom

install -Dm644 /path/to/phosh.service \
    /etc/systemd/system/phosh.service
install -Dm644 /path/to/touch-zoom.service \
    /etc/systemd/system/touch-zoom.service

systemctl disable getty@tty1
ln -sf /etc/systemd/system/phosh.service \
    /etc/systemd/system/graphical.target.wants/phosh.service
ln -sf /etc/systemd/system/touch-zoom.service \
    /etc/systemd/system/graphical.target.wants/touch-zoom.service

systemctl set-default graphical.target
reboot
```

The service files are in
[`../userspace/gui-experimental/systemd/`](../userspace/gui-experimental/systemd/),
and `touch-zoom` is in
[`../userspace/gui-experimental/bin/`](../userspace/gui-experimental/bin/).

## The wlroots patch

`phoc` creates layer-shell surfaces whose width or height can be zero while
the shell is laying out. Upstream wlroots 0.20 rejects that with:

```
layer surface configured with an anchor on an axis with a zero dimension
```

The patch
[`wlroots-0.20.2-layer-shell-0dim.patch`](../userspace/gui-experimental/patches/wlroots-0.20.2-layer-shell-0dim.patch)
disables that validation (`#if 0` in `types/wlr_layer_shell_v1.c`). The
patched library is installed to `/usr/lib/libwlroots-0.20.so` and kept in
`/usr/local/lib/patched/libwlroots-0.20.so`.

It is an experiment, not an upstream-quality fix. If you rebuild wlroots,
re-apply the patch.

## touch-zoom

`touch-zoom` reads touchscreen events and translates a two-finger pinch into
`Ctrl`+`+` / `Ctrl`+`-` for GNOME Console. It is a separate user service:

```ini
[Unit]
Description=Touchscreen pinch zoom for GNOME Console (EXPERIMENTAL)
After=phosh.service
```

It is intentionally not part of the base install.

## Going back to headless

```sh
systemctl set-default multi-user.target
systemctl disable phosh touch-zoom
systemctl enable getty@tty1
reboot
```

If the GUI is wedged, the reliable path is still USB:

```sh
ssh root@172.16.42.1 'systemctl set-default multi-user.target; reboot'
```

The USB gadget is created before the graphical target, so it survives a broken
Phosh session.

## Why not ship it by default?

Because a headless system is useful and stable, while a mobile shell that
crashes after a GPU hang is not a good first impression. The GUI is here for
people who want to work on it, with the expectation that they will need the
USB link to recover.