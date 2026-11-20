# mobile-config-firefox

Touch/mobile configuration for Firefox, vendored from
[postmarketOS / NuraOS mobile-config-firefox](https://gitlab.postmarketos.org/postmarketOS/mobile-config-firefox)
(now hosted at <https://gitlab.nura.eco/postmarketOS/mobile-config-firefox>).

The upstream project is distro-independent and is the reference implementation
used by postmarketOS, Mobian, DanctNIX, and NuraOS. This directory is a
verbatim copy of upstream commit
`84913a3c67099f335cb94a55de7bd469b09ee23e` (5.5.2 era) so that the image
stays plug-and-play: no network access and no package manager are needed at
build time, and the exact tested revision is pinned in this repository.

`README.md` here documents the local integration; the upstream project's own
documentation lives in the clone under `docs/`.

## What it does

- Moves the Firefox chrome (address bar and tab bar) to the bottom of the
  screen and shrinks it for a small touch panel.
- Enables touch gestures (two-finger zoom, double-tap zoom) and a single
  always-visible tab with a tab counter.
- Uses the native file picker through the XDG desktop portal.
- Applies privacy defaults: no search suggestions, no Firefox studies, no
  Telemetry, DuckDuckGo as the default engine, and uBlock Origin installed.
- Tunes the mobile UI (`browser.uidensity = 2`) and disables cosmetic
  animations.

The full preference list is set at startup by
`src/modules/boot.sys.mjs` (`set_default_preferences()`), including
`toolkit.legacyUserProfileCustomizations.stylesheets = true`, which Firefox
needs before a profile `chrome/` directory is honoured. That flag is what
makes the modern system-extension themes work on this build.

## Layout installed by the script

`install.sh <rootfs-root>` installs the same files as upstream's
`make install`:

| Source | Destination | Purpose |
| --- | --- | --- |
| `src/policies.json` | `/usr/lib/firefox/distribution/policies.json` | Enterprise policies (privacy, search engines, uBlock Origin). |
| `src/mobile-config-prefs.js` | `/usr/lib/firefox/defaults/pref/mobile-config-prefs.js` | Enables the autoconfig script and sets touch density / PipeWire cameras. |
| `src/mobile-config-autoconfig.js` | `/usr/lib/firefox/mobile-config-autoconfig.js` | Firefox `general.config.filename`; registers the chrome manifest and imports `boot.sys.mjs` at every start. |
| `src/modules/` | `/usr/lib/mobile-config-firefox/` | `chrome.manifest` plus the JS modules (`boot`, `PrefManager`, `StyleSheetManager`, `UserAgentManager`, `TabCounter`, `AboutMobile`, `about:mobile` page). |
| `src/themes/` | `/usr/lib/mobile-config-firefox/themes/` | The `shared` + `release` (or `esrNNN`) CSS that the `StyleSheetManager` registers as user sheets. |
| `metainfo/…xml` | `/usr/share/metainfo/eco.nura.mobile_config_firefox.metainfo.xml` | AppStream metadata. |

The autoconfig looks for the manifest at the hard-coded path
`/usr/lib/mobile-config-firefox/chrome.manifest`, so the module directory must
keep that name; `install.sh` does.

## Runtime log

`mobile-config-autoconfig.js` writes to
`<profile>/chrome/mobile-config-firefox.log`. Check it after a change:

```sh
tail -F "$(find ~/.config/mozilla/firefox -name mobile-config-firefox.log)"
```

A missing manifest is logged as
`chrome.manifest not found at: /usr/lib/mobile-config-firefox/chrome.manifest`.

## Adreno 512 / Wayland notes

Firefox already runs on this image with `FD_MESA_DEBUG=noubwc` set globally in
`/etc/environment` (UBWC compression corrupts the shared buffers; see
`docs/FINDINGS.md`). Nothing here touches that. The vendored config is pure
user-sheet CSS plus prefs and does not change the GPU path, so it is
compatible with Wayland/Phosh and the Adreno 512 as-is. Keep
`FD_MESA_DEBUG=noubwc` in place; if the mobile theme ever renders with green
or magenta blocks, that variable being overridden is the first thing to check.

## Build integration

`rootfs/build-rootfs.sh` calls this installer:

```sh
sh "$REPO/userspace/firefox/install.sh" "$MNT"
```

## Updating from upstream

```sh
git clone --depth 1 https://gitlab.postmarketos.org/postmarketOS/mobile-config-firefox.git
cp -a mobile-config-firefox/src/modules      userspace/firefox/src/
cp -a mobile-config-firefox/src/themes       userspace/firefox/src/
cp -a mobile-config-firefox/src/policies.json \
      mobile-config-firefox/src/mobile-config-prefs.js \
      mobile-config-firefox/src/mobile-config-autoconfig.js \
      userspace/firefox/src/
cp -a mobile-config-firefox/eco.nura.mobile_config_firefox.metainfo.xml userspace/firefox/metainfo/
cp -a mobile-config-firefox/LICENSE          userspace/firefox/
```

Then update the commit hash in this file and the attribution here.
