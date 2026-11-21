# Findings: lavender glyph corruption, stutter, and speaker loudness

Running log. Newest results go at the bottom of each section. Commands and
logs are in English; user-facing summaries are in Indonesian.

## Environment (verified 2026-11-16 09:3x WIB)

- Kernel `7.2.3-sdm660 #1 SMP PREEMPT Sun Nov 8 08:30:49 UTC 2026`, DTB shenchao.
- Mesa `1:26.2.6-1`, freedreno `FD512`, GLES 3.1.
- Session env in phoc: `GSK_RENDERER=ngl`, `FD_MESA_DEBUG=noubwc` (no `notile`).
- `phoc` renderer: gles2; compositor uses msm/freedreno.
- No cpufreq policy in sysfs (see section F; not fixable without the unmerged
  CPRh/OSM/SPM patchset). Measured single-thread throughput (2 s xorshift
  loop, 3x repeatable): CPU0/5/6/7 = 98 Mops/s, CPU1-4 = 42 Mops/s.
- GPU devfreq: simple_ondemand, 19.2 MHz - 588 MHz.
- dpkg not used; Firefox profile prefs are in
  `/home/alarm/.config/mozilla/firefox/ksvpr5j7.default-release/user.js`.

## Symptom under investigation

User reports missing/corrupt glyphs in system UI (Settings, Mobile Settings,
Device Info) and in all browsers (Firefox, Epiphany, Angelfish) on real sites
(YouTube, Facebook, Instagram, WebNovel), worsening with uptime. Current
`GSK_RENDERER=ngl` + `FD_MESA_DEBUG=noubwc` did not fix it. Stutter in real use
feels like ~20 fps; earlier 50 fps synthetic scrollbench is not accepted as
evidence.

## A. Glyph corruption: root cause

### A1. Root cause (proven upstream, reproduced locally)

On a512 (FD512), `CP_BLIT(BLIT_OP_COPY)` is silently a no-op: the packet is
consumed, the 2D registers read back as programmed, but no memory write is
issued. No fault, no error. This is the path taken by `glTexSubImage2D` when
the destination texture is still referenced by an unflushed batch: freedreno
stages the upload and copies it with `CP_BLIT`, so the destination keeps its
old contents. That is exactly the "glyph missing" symptom: the atlas tile
looks untouched, the rest of the texture is fine.

Upstream fix series (Mesa main, merged 2026-11-07):

| Commit | Subject |
| --- | --- |
| `ba27232` | freedreno/registers: make the 2D blit ifmt enums common |
| `a5c42c0` | freedreno/a5xx: convert 2D blits through the right intermediate format |
| `c0235ef` | freedreno/a5xx: program the 2D source and use BLIT_OP_SCALE (MR !45483) |

`c0235ef` describes the a512 no-op verbatim and fixes it by programming
`TPL1_A2D_SRC_TEXTURE_INFO` / `SP_A2D_OUTPUT_INFO` and switching both
`CP_BLIT` sites to `BLIT_OP_SCALE`. `a5c42c0` is the prerequisite that describes
the 2D intermediate format; `ba27232` moves the ifmt enums into
`adreno_common.xml` so a5xx can use them.

Version check: Mesa `26.2.7` (tag 2026-11-11) still has `BLIT_OP_COPY`, no
`TPL1_A2D_SRC_TEXTURE_INFO`, and no `HIGHESTBANKBIT`. The fix is not in the
26.2 stable series; it will first appear in 26.3. A backport is required for
this device.

The separate a5xx hbb fix `4fa3294` ("program the highest bank bit of the
part") is correct and is included in the local build, but on its own it did not
change the About-logo corruption. It is not the root cause here.

### A2. Minimal reproducer (authoritative)

`/home/maf/lavender-lab/glatlas2.c`, built on the phone as `/root/lab/glatlas2`.
One 1024x1024 tiled atlas; warm it by sampling through a shader; then
`glTexSubImage2D` a 64x64 tile into it and verify by direct FBO readback and by
sampling. `direct=4096 sample=4096` = 100% of the tile missing;
`direct=0 sample=0` = clean.

Flag matrix, 6 cycles per config (earlier runs; logs in `/root/lab/logs`):

| Config | Bad cycles | Interpretation |
| --- | --- | --- |
| baseline `noubwc` | 6/6 | reproducer hits the bug |
| `WARM_OTHER=1` | 0/6 | the destination must be the sampled texture |
| `FINISH_BEFORE=1` | 0/6 | finish bypasses the staging/CP_BLIT path |
| `noblit` | 0/6 | CP_BLIT itself is the broken operation |
| `inorder` | 0/6 | synchronous map avoids staging |
| `nogrow` | 6/6 | not a buffer-growth bug |
| `flush` | 6/6 | not a missing-flush bug |
| `sysmem` | 6/6 | not a tiling-layout bug |
| `notile` | 6/6 | not a tiling-layout bug |

The clean `FINISH_BEFORE` / `WARM_OTHER` / `inorder` cases do not mean "GPU
timing is fine"; they avoid the staging + `CP_BLIT` upload path entirely. The
earlier "tiled dst CP_BLIT works" result was a false pass from staging-BO
reuse.

### A3. Mesa A/B: 3x50 cycles

Same binary, same phone, only the Mesa under it changes. Baseline is system
Mesa `1:26.2.6-1` (`/usr/lib/libgallium-26.2.6-arch1.1.so`); patched is the
local backport below under `/opt/mesa-hbb/lib`. Both use `FD_MESA_DEBUG=noubwc`
and `DIRECT=1` (readback + sampling). Reproducer: `/root/lab/run-base.sh` and
`/root/lab/run.sh`.

| Run | Config | Cycles | Bad cycles | direct | sample |
| --- | --- | --- | --- | --- | --- |
| baseB1 | system 26.2.6 | 50 | 50 | 4096 | 4096 |
| baseB2 | system 26.2.6 | 50 | 50 | 4096 | 4096 |
| baseB3 | system 26.2.6 | 50 | 50 | 4096 | 4096 |
| fixB1 | patched | 50 | 0 | 0 | 0 |
| fixB2 | patched | 50 | 0 | 0 | 0 |
| fixB3 | patched | 50 | 0 | 0 | 0 |

Total: baseline 150/150 bad (100%), patched 150/150 clean (0%).
CSV (300 rows, `cycle,diff%,config,direct_bad_px,sample_bad_px`):
`/home/maf/lavender-lab/logs/ab-3x50.csv`.

### A4. Local patched Mesa

Patches (clean, no instrumentation) in `/home/maf/lavender-lab/patches/`:

- `0001-registers-make-2D-blit-ifmt-enums-common.patch` (`ba27232`)
- `0002-a5xx-intermediate-format.patch` (`a5c42c0`)
- `0003-a5xx-2D-source-BLIT_OP_SCALE.patch` (`c0235ef`)

Applied to `/root/mesa-26.2.6` on the phone. `0001` needed the XML part applied
selectively plus a mechanical `s/a6xx_2d_ifmt/adreno_2d_ifmt/` and
`s/a6xx_sp_a2d_output_ifmt_type/adreno_2d_output_ifmt_type/` rename in
`fd6_blitter.cc` and `tu_clear_blit.cc`, because 26.2.6's a6xx code differs
from main. `0002` and `0003` applied cleanly. The tree also carries the hbb
changes from `4fa3294` (`fd5_emit.c`, `fd5_blitter.c`, `a5xx.xml`).

Build and install:

```
ninja -C /root/mesa-26.2.6/build \
  src/gallium/targets/dri/libgallium-26.2.6.so
cp .../libgallium-26.2.6.so /opt/mesa-hbb/lib/libgallium-26.2.6.so
```

Patched run env adds:

```
LD_LIBRARY_PATH=/opt/mesa-hbb/lib
LIBGL_DRIVERS_PATH=/opt/mesa-hbb/lib/dri
MESA_LOADER_DRIVER_OVERRIDE=msm
```

All debug instrumentation (`BFLUSH`, `BDEP`, `FLUSHREADERS`, `BLIT5`,
`EMITBLIT`, `HBBDBG`) was removed before the 3x50 run; `fd5_emit.c` is pristine
26.2.6 + hbb only, `fd5_blitter.c` is the upstream `4fa3294` version. The only
`HBBDBG` left is in the uncompiled backup `fd5_blitter.c.orig`.

### A5. Real-app attempts: null result

Every harness below ran with baseline Mesa (system 26.2.6) and did **not**
produce visible glyph/logo loss, so they cannot yet prove end-user efficacy:

- gnome-control-center `system about`: first open + 8 reopen iterations + 5
  scroll rounds. Logo ROI stayed at `nonbg=18593/126000 (14.76%)` every time.
- `gskstress` (GTK4 custom widget, 400 frames of fresh Pango glyphs at random
  sizes, then a fixed Latin sample): final text complete, baseline and patched.
- `gskimg` (GtkImage + Arch logo churn, 300 frames): final logo complete,
  including with `GSK_GPU_DISABLE=blit`.
- Firefox 160 kiosk on `churn.html` (600 frames of random glyphs, then a fixed
  sample): final text complete.

Interpretation: these workloads do not hit the staging + `CP_BLIT` path that
the minimal reproducer hits. They are not evidence against the root cause; they
mean the real-app trigger is still unknown. The likely differentiator is an
upload into a texture that is still referenced by an unflushed batch (GSK
flushes per frame), but that is a hypothesis, not proven yet.

The session-wide run was later done with an ABI-matched system-wide libgallium;
see A8/A9. It confirms the minimal-reproducer fix is active in the real session
and in Firefox's GPU process, while the real-app harnesses above still do not
hit the staging path predictably.

### A6. Before/after screenshot set

Both captured with `grim` on the phone, same workload, same window size:

- Baseline: `/home/maf/lavender-lab/shots/glatlasvis-base.png` — the enlarged
  atlas tile is a black square; readback `direct=4096 sample=4096`.
- Patched: `/home/maf/lavender-lab/shots/glatlasvis-fix.png` — the same tile
  shows the uploaded gradient; readback `direct=0 sample=0`.

Driver: `/home/maf/lavender-lab/glatlasvis.c` (visual variant of `glatlas2`;
`glatlas2.c` is unchanged so the authoritative reproducer stays intact).

### A7. Upstream report needs

- Point at `c0235ef` and say sdm660/a512 reproduces it; 26.2.6 and 26.2.7 both
  lack the fix.
- Attach the minimal reproducer (`glatlas2.c`) and the A/B CSV.
- Note that the visible symptom is per-tile upload loss in a glyph atlas, not
  whole-texture loss.
- Keep `4fa3294` (hbb) as a separate fix; it is real but unrelated to this
  symptom.
- If a distro PKGBUILD patch is produced, add a short note to the
  sdm660-mainline tracker; cpufreq #33, the phoc touch-up SEGV and battery
  drain stay separate.

### A8. ABI-matched system-wide build

The first session-wide attempts failed because of three build/ABI details, not
because of the patch:

- Arch's `libEGL_mesa.so.0.0.0` has `NEEDED libgallium-26.2.6-arch1.1.so`.
  The local build was `libgallium-26.2.6.so`, so phoc loaded a mismatched
  library name. Rebuilding with `VERSION=26.2.6-arch1.1` fixed the soname.
- The local build used `-Dplatforms=wayland` only. Arch's `libEGL_mesa`
  additionally imports the X11/dri3 loader (`loader_dri3_*`), so phoc failed
  with `EGL_EXT_platform_base not supported`. `ldd -r` showed the missing
  symbols. Reconfiguring with `-Dplatforms=wayland,x11` and rebuilding fixed it:
  18 `loader_dri3_*` symbols are exported, and `ldd -r` reports zero undefined
  symbols against both `libEGL_mesa.so.0` and `dri/msm_dri.so`.
- The first ABI-matched build still had `opengl=false` in `meson configure`, so
  it exposed only OpenGL ES. That was not visible in the phosh/GSK/Firefox
  tests, but Qt apps need desktop GL: Angelfish aborted in
  `QSGRenderLoop::handleContextCreationFailure` with
  `Failed to initialize graphics backend for OpenGL`. `eglinfo` confirmed the
  missing `OpenGL core profile` section. Reconfiguring with `-Dopengl=true`
  restored `OpenGL core profile version: 3.1 Mesa 26.2.6-arch1.1` and Angelfish
  renders normally. This is a build-configuration issue, not a regression from
  the blit patches: the pristine Arch lib also provides desktop GL, and a lib
  built without it is not a drop-in replacement for Qt apps.

Commands on the phone:

```
cd /root/mesa-26.2.6
VERSION=26.2.6-arch1.1 PYTHONPATH=/root/lab/pystub \
  meson setup --reconfigure build -Dplatforms=wayland,x11 -Dopengl=true
ninja -C build src/gallium/targets/dri/libgallium-26.2.6-arch1.1.so
cp build/src/gallium/targets/dri/libgallium-26.2.6-arch1.1.so \
   /usr/lib/libgallium-26.2.6-arch1.1.so
```

`meson setup --reconfigure` is required; `meson configure` re-runs ninja's
regenerate step without `PYTHONPATH`, and the run then fails at the PyYAML
probe even though `/root/lab/pystub/yaml.py` exists.

Installed file (2026-11-18, after the desktop-GL rebuild):
`/usr/lib/libgallium-26.2.6-arch1.1.so`,
sha256 `2e66f90e955f745a98c8fa180e83a4f912f0873e48898d42f325a9200a47808c`.
Pristine Arch backup: `/root/lab/backup/libgallium-26.2.6-arch1.1.so.system`,
sha256 `34bb5b1b0eb80f86fab45a4485eddb9f60b283f2ed45309d1fc4ac4f235a411d`.
The intermediate GLES-only build is kept as
`/root/lab/backup/libgallium-26.2.6-arch1.1.so.glesonly`.
The `/opt` drop-in `zz-mesa-hbb.conf` was removed; only the pre-existing
`mesa-noubwc.conf` (`FD_MESA_DEBUG=noubwc`) remains. phoc maps the system
libgallium. This is a device-specific build (freedreno only, `llvm=disabled`,
glvnd disabled, no swrast/zink); ship it only as the lavender rootfs override,
not as a general Mesa replacement.

### A9. System-wide validation

All runs below use the installed system-wide library, no `/opt` or
`LD_LIBRARY_PATH` override.

- `glatlas2` 3x50 (150 cycles): 150/150 clean, renderer FD512.
  Logs: `/root/lab/logs/glatlas2-sys-{1,2,3}.log`.
- After the `-Dopengl=true` rebuild, `glatlas2` was repeated 3x50: 150/150 clean,
  renderer FD512. Logs: `/root/lab/logs/glatlas2-gl-{1,2,3}.log`.
- `glatlasvis` without env: readback clean and the captured frame shows the
  gradient tile, not the black tile. Screenshot:
  `/home/maf/lavender-lab/shots/glatlasvis-sys.png`.
- Firefox `about:support`: `Compositing: WebRender`, `Window Protocol:
  wayland`, WebGL 2 driver renderer `freedreno -- FD512`, driver version
  `OpenGL ES 3.1 Mesa 26.2.6-arch1.1`, GPU #1 `FD512` active.
  Screenshots: `shots/firefox-support7.png`, `shots/firefox-support8.png`.
- `glmark2-es2-wayland -b texture:duration=10`: 202 fps, clean wood-texture
  frame (`shots/glmark2-tex.png`); the rebuilt lib gives 199 fps with the same
  clean frame (`shots/glmark2-gl.png`). `--validate` reports 24 failures on the
  patched lib and the exact same 24 failures with the pristine Arch lib, so
  that validation mode is not a usable correctness signal on this stack.
- `gskstress` (400 GSK glyph-atlas frames) and `gskimg` (300 GtkImage churn
  frames) render their final frames complete:
  `shots/gskstress-sys.png`, `shots/gskimg-sys.png`.
- After the rebuild, `gskstress` logs `DONE frames=400` and shows the complete
  glyph set (`shots/gskstress-gl2.png`); `gskimg` logs `DONE frames=300` and
  ends with one clean 360 px Arch logo (`shots/gskimg-done.png`).
- Angelfish (QtWebEngine) loads `https://example.com` with the rebuilt lib and
  maps `/usr/lib/libgallium-26.2.6-arch1.1.so`: `shots/angelfish-gl2.png`.
  It fails to start on the GLES-only build, which is why desktop GL is enabled.
  The same page also renders with the pristine Arch lib
  (`shots/angelfish-base2.png`), so the patch is not required for Qt, it just
  must not remove desktop GL.
- Epiphany does not work on this setup: `WebKitWebProcess` aborts (`SIGABRT`)
  inside `libephywebprocessextension.so` during web-process extension init.
  This reproduces with `WEBKIT_DISABLE_DMABUF_RENDERER=1` under both the
  patched `shots/epiphany-now.png` and the pristine Arch lib
  `shots/epiphany-base.png`, so it is a WebKit/Epiphany issue on this image,
  not a Mesa blit regression.
- The current phoc stays up and maps the rebuilt lib. The old phoc PID 8435
  (`SIGSEGV`) dumped during the forced `systemctl restart phosh`; the new
  phoc (PID 26908 after the rebuild) starts cleanly. Treat that teardown crash
  as the known phoc cleanup issue, separate from rendering.
- Waydroid is usable: the container and Android UI start and stay up. It can
  show occasional font glitches, but they do not affect normal use; keep it
  optional and do not enable it in the release image by default.

### A10. Remaining work

- The fix is now carried in the repo as
  `userspace/mesa/patches/0001-freedreno-a5xx-2d-blit-and-hbb.patch` plus
  `userspace/mesa/build-libgallium.sh`, with an ABI-matched prebuilt library;
  `rootfs/build-rootfs.sh` installs it (or a `MESA_GALLIUM` override). Keep
  the system-wide lib on the lab phone as an override; an Arch `mesa` upgrade
  will overwrite it until the pacman hook restores it. The same backport
  should go into a Mesa PKGBUILD (or be dropped after 26.3).
- Use a browser on a real site for a longer uptime run (hours); the 3x50
  reproducer and the short app checks are done.
- Epiphany is broken independently of Mesa: `WebKitWebProcess` aborts in the
  Epiphany web-process extension. Debug the WebKit/Epiphany packaging on this
  image separately; Angelfish and Firefox are the working browsers.
- Keep Waydroid optional (occasional font glitches); it is not blocked by the
  glyph fix.
- Verify stevia and the lock screen after a clean reboot (session restart
  already keeps them working).

### A11. Repo build and rootfs install check

A pristine `mesa-26.2.6.tar.xz` plus
`userspace/mesa/patches/0001-freedreno-a5xx-2d-blit-and-hbb.patch` was built on
the phone with `userspace/mesa/build-libgallium.sh`. The result is AArch64,
soname `libgallium-26.2.6-arch1.1.so`, exports the 18 `loader_dri3_*` symbols,
and `ldd -r` reports no undefined symbols against the rootfs
`libEGL_mesa.so.0` or `dri/msm_dri.so`. Fresh-build sha256:
`3771d039bb92b339946bf80be42ffafae7638bc83433764c59d92a134dba52e2`.

`glatlas2` 3x50 against that fresh artifact (via `LD_LIBRARY_PATH`, so the
installed library and phoc were untouched) was 150/150 clean, renderer FD512:
`/root/lab/logs/glatlas2-repo-{1,2,3}.log`.

The fresh artifact was then installed system-wide, phosh was restarted, and
`glatlas2` was run again 3x50: 150/150 clean, renderer FD512
(`/root/lab/logs/glatlas2-repofinal-{1,2,3}.log`). The pacman restore path was
tested by copying the pristine distro library over
`/usr/lib/libgallium-26.2.6-arch1.1.so`; running
`/usr/local/sbin/reinstall-patched-libs` restored the patched sha256 and left
phosh active.

The `rootfs/build-rootfs.sh` install block was exercised against a real
AArch64 `libgallium` and a copy of the image's `libEGL_mesa.so.0`: it installs
the library into both `/usr/lib` and `/usr/local/lib/patched`, and rejects a
wrong soname or a non-AArch64 file before touching the image.

The repository ships the system-validated build from A9
(`userspace/mesa/libgallium-26.2.6-arch1.1.so`, sha256
`2e66f90e…a47808c`), with `SHA256SUMS`. The clean-tree rebuild above has a
different BuildID because the build directory differs; it is the same ABI and
passed the same 3x50 test. The prebuilt exists so a rootfs build includes the
fix without an aarch64 Mesa build; the patch and script remain authoritative.

## B. Stutter (after A)

Pending. Known measurements from the previous session (to be re-validated):
- Real touch scroll, HW WebRender, `noubwc,notile`, Firefox on CPU0/5/6/7:
  59.6 fps avg, p95 19.1 ms.
- Same on CPU1-4: 57.4 fps, p95 21.4 ms.
- phoc + Firefox on 5/6/7: 59.0 fps, p95 18.6 ms.
- GPU IRQ CPU0 vs CPU6: no difference (59.8-60.0 fps, p95 18.0 ms).
- GPU min_freq 160 vs 370 MHz: no difference (59.9-60.0 fps, p95 18.0-18.1 ms).
- GPU residency during scroll: 588 MHz 97.1%, 465 MHz 2.9%.
These were measured with a local synthetic-ish page and are not yet accepted as
evidence for real sites.

## C. Speaker: clean but ~48 dB too quiet (FE/BE format mismatch)

Reported 2026-11-19.  The main speaker played clean audio, but even at 100% it
was only just audible; the same phone is loud under the vendor ROM.

Ruled out before the format was found:

- Source and userspace: the angelfish playback PCM peaked at -5.4 dBFS
  (RMS -18.1 dBFS); `wpctl` sink volume was 1.00 and `pactl` reported
  100%/0.00 dB for both sink and stream, unmuted.
- Amplifier: MAX98937 revision `0x43`; the 62-entry init sequence matched the
  vendor `max98937_reg_common_map` plus channel map; live registers matched
  the vendor values; `GLOBAL_EN` (`0x0500`) and `SPK_EN` (`0x0039`) were set
  during playback.
- Routing and clocks: FE->BE route `PRI_MI2S_RX Audio Mixer MultiMedia1=on`,
  pinmux on GPIO12-15 was `pri_mi2s`/`pri_mi2s_ws`, and the Q6AFE port was
  48 kHz/16-bit/2ch/SD0.
- Gain: vendor `Digital Volume 56` (-2 dB) with `Speaker Volume 6` (+21 dB)
  did not change the loudness; the current limit was already the vendor
  maximum raw `0x40` (4.10 A).

The mismatch: while playing, `hw:0,0` (the `MultiMedia1` front end) was open
at `S24_LE`, 2ch, 48 kHz, but the machine driver's BE fixup forces Primary
MI2S to `S16_LE`, 2ch, 48 kHz (`MI2S_BCLK_RATE` 1,536,000 = 48k x 2 x 16).
The Q6 DSP behaves as if only the low 16 bits of each 24-bit sample reach the
MAX98937, which is 1/256 of the amplitude, i.e. -48.16 dB.  The vendor kernel
never hits this: `mi2s_rx_cfg[PRIM_MI2S]` is `{48000, S16_LE, 2}`, so the
vendor HAL always feeds the DSP 16-bit samples.

Test and fix: adding a WirePlumber rule that sets `audio.format = "S16LE"` on
the speaker sink (`alsa_output.platform-sound.HiFi__Speaker__sink`) restored
normal loudness on the same YouTube video at 100%; the user confirmed it was
loud and normal, with no distortion at full volume.  The sink node shows
`audio.format = "S16LE"`.  A 130-sample live check during both Linux
(angelfish) and Waydroid playback reported `S16_LE`, 48 kHz, 2 channels for
every sample.  The rule lives at
`userspace/audio/wireplumber/wireplumber.conf.d/50-lavender-s16.conf` and
`rootfs/build-rootfs.sh` installs it to `/etc/wireplumber/...`, so it covers
every client on the speaker sink, including Waydroid's PulseAudio output;
headphone and microphone nodes are not matched.

Do not raise `Digital Volume` to compensate: it cannot restore the truncated
low bits and only adds clipping gain.  A true 24-bit path would need the BE
format, BCLK ratio, and MAX98937 PCM mode changed together; 16-bit matches
the vendor configuration and the amp's init sequence.

The kernel must also build the machine driver.  The repo config had
`# CONFIG_SND_SOC_SM8250 is not set`, so the card never bound and
`/proc/asound/cards` stayed empty even with the WirePlumber rule installed.
`CONFIG_SND_SOC_SM8250=m` is now enabled; it is required for any speaker fix
on this tree.

Hardware re-validation (7.2.3, 2026-11-19, kernel without a kernel-side
format quirk): with only the repo WirePlumber rule, Firefox playback opened
`hw:0,0` at `S16_LE`, 48 kHz, 2 channels (`state: RUNNING`) and the speaker
was loud and clean at 100%.  The rule alone is sufficient once the card is
present.

### Kernel-side fix (works on any distribution)

A userspace rule only helps distributions that install it, so the same
constraint now lives in the machine driver.  The sound card opts in with the
`qcom,force-s16-fe` property; `sm8250_fe_startup()` then masks the front end
PCM's format to `S16_LE` for `MultiMedia1` playback, and `sm8250_add_fe_ops()`
attaches those ops to the front-end links during probe.  The property is
opt-in, so no other `sm8250` board is affected.  The patch is
`kernel/patches/local/0002-ASoC-qcom-sdm660-force-16-bit-front-end.patch`.

Hardware validation (7.2.3, 2026-11-20) with the WirePlumber rule **removed**
and the sink carrying no `audio.format` property: `/proc/device-tree/sound/
qcom,force-s16-fe` was present, Firefox opened `hw:0,0` at `S16_LE`, 48 kHz,
2 channels (`state: RUNNING`) and the speaker was loud and clean at full
volume.  That proves the kernel constraint alone is enough: a distribution
only needs the kernel, its DTB, and the `snd-soc-sm8250` module.

The WirePlumber rule is still shipped for older kernels that predate the
quirk, but it is no longer required by the current boot image.

One UCM detail matters: ACP probes every device in a verb.  On 7.2.3 the
`MultiMedia2` capture PCM (`hw:X7,1`) fails to open with `EINVAL`, which made
the whole `HiFi` profile unsupported and left only `Dummy Output`.  The
microphone therefore lives in its own `Mic` verb (`Mic.conf`); the speaker
`HiFi` verb contains only the `Speaker` device and remains usable even when
capture cannot be probed.

## D. Suspend / s2idle (2026-11-20)

The shipped sleep policy keeps suspend disabled.  Three manual `rtcwake -m mem`
cycles on the current boot image show that s2idle is not a hard hang — it enters
and resumes — but it is not usable yet.

| Cycle | Alarm | Suspend entry | Suspend exit | Result |
| --- | --- | --- | --- | --- |
| 1 | 60 s | 23:15:21 | 23:16:54 | resumed in ~93 s |
| 2 | 45 s | 23:18:59 | 03:10:54 | woke ~3 h 52 min late |
| 3 | 60 s | 05:17:24 | 05:19:00 | resumed in ~96 s |

`/proc/uptime` (which counts suspend time) and the wall clock agree on the
durations, so cycle 2 really did stay asleep for hours.

- **The RTC wake is intermittent.**  The hardware RTC reads 1970 and cannot be
  set (`hwclock -w` fails with `RTC_SET_TIME ... No such device`), so the alarm
  is programmed against a bogus clock: cycles 1 and 3 fired on time, cycle 2
  fired hours late (`rtcwake` still returned `rc=0`).  Do not use RTC wake
  alone to judge whether s2idle works.
- **Every resume is rough.**  Cycles 1 and 3 both logged `WARNING` at
  `__ieee80211_suspend` (`mac80211/pm.c:171`), `clk_branch_toggle`
  (`clk-branch.c:88`), `ieee80211_reconfig` (`util.c:1957`) and `drv_stop`
  (`driver-ops.c:41`); `wiphy_resume` returns `-110`; the `ath10k` firmware
  crashes and reloads; the modem `remoteproc` reports `crash detected` on the
  way down and `recovering` on the way up.
- **Recovery is inconsistent.**  In cycle 3 the session, WiFi, modem and the
  audio sink all came back.  After cycle 2 the phone stayed up but unreachable
  (neither WiFi nor the USB gadget worked, and `ath10k_start`
  (`ath10k/mac.c:5208`) crash-looped every ~7 minutes until a reboot).

Because the system stays up after the `-110`/crash, `suspend_stats` reports
`success=1` / `fail=0` *and* `last_failed_dev=phy0` / `last_failed_step=resume`
for the same cycle.  A `mute:true` / 0% entry was also restored to the speaker
sink after the cycle-2 session (see TROUBLESHOOTING).  Keep
`AllowSuspend=no`; the `ath10k` and modem suspend/resume paths need a
kernel-side fix before this is worth enabling.

### D1. Why WiFi *and* the modem disappear together

`4080000.remoteproc` (the modem DSP, `qcom-q6v5-mss`) also hosts the WCN3990
WLAN firmware, so an ath10k failure takes the modem down with it:

- On the resume path, `wiphy_resume` returns `-110`; the ath10k firmware
  crashes and the MSS logs `fatal error received: err_qdi.c:459:
  EX:wlan_process ... WLAN RT:2065`, `crash detected` and reboots.  The modem
  object is destroyed and re-created, so ModemManager re-enumerates it under a
  new index (`Modem/1` -> `Modem/2`); while that is in flight `mmcli -L` prints
  "No modems were found" and the SIM looks absent.
- It does not need suspend at all.  Turning the radio off reproduced it in the
  WiFi-off experiment: `nmcli radio wifi off` ->
  `wlan0: deauthenticating ... by local choice (DEAUTH_LEAVING)` ->
  `EX:wlan_process ... WLAN RT:2065` -> `remoteproc1: crash detected` ->
  `ath10k firmware crashed` -> MSS reboot -> `No modems were found`.  A
  "turn WiFi off before suspend" workaround is therefore counter-productive:
  it triggers the very crash it is meant to avoid.

In that WiFi-off cycle the phone recovered on its own within a few seconds:
the MSS came back, WiFi re-associated, and the modem re-registered (Telkomsel
LTE, `signal 84%`, IMSI read back as `Modem/2`).  The failure the user sees
("kartu tidak kebaca") is this recovery not completing, leaving the modem
object gone until reboot.

A best-effort recovery after a resume that lost WiFi or the modem (may itself
re-trigger one MSS restart):

```sh
nmcli radio wifi off; sleep 1; nmcli radio wifi on
systemctl restart ModemManager
```

### D2. ath10k_snoc unbind/rebind (one cycle)

Tested 2026-11-20: take `18800000.wifi` out of NetworkManager management,
`unbind` it, suspend once, then `bind` it again on resume.

- **Q1 - unbinding before suspend still restarts the MSS.**  The MSS logged
  `fatal error received: err_qdi.c:459:EX:wlan_process:1:WLAN RT:1084` and
  `crash detected` at the start of the run, during the pre-suspend teardown,
  and `ath10k firmware crashed`.  We could not separate the NetworkManager
  disconnect (`nmcli dev set wlan0 managed no`) from the `remove()`/`ath10k_stop`
  that followed (it logged `-108` `ESHUTDOWN` failures such as
  `failed to update channel list`), because both walk the same down path — but
  either way, unbinding does not avoid an MSS restart, it only moves it earlier.
- **The suspend/resume itself was clean.**  With ath10k unbound there is no
  `wiphy_resume`, so there was no `-110`, no resume-time firmware crash, and the
  modem did **not** re-enumerate across the suspend.  The only remaining warning
  was `clk_branch_toggle` (`clk-branch.c:88`), which is on the display/`mdss`
  path and unrelated to WiFi.
- **Q2 - rebind after resume works as a recovery.**  `bind` returned `0`; `wlan0`
  re-probed, reconnected and got an IP, and the modem stayed registered.  This is
  the same effect as `nmcli radio wifi off/on`, i.e. a forced clean ath10k + MSS
  restart without a reboot.

Net: unbinding before suspend does not save the MSS restart and adds moving
parts, so it is not a reason to enable suspend.  `AllowSuspend=no` stays.  The
rebind path is useful only as a *recovery* step (TROUBLESHOOTING).

## E. Mesa 26.3.1 GTK renderer and a5xx glyph fixes (2026-11-20)

Two independent Mesa bugs prevented the phone from rendering GTK4 through GL:

1. **a5xx 2D-blit upload loss.** Mesa 26.3.1 still contains the code path where
   `CP_BLIT(BLIT_OP_COPY)` silently drops texture uploads on FD512. The
   existing `0001-freedreno-a5xx-2d-blit-and-hbb.patch` is still required;
   upstream MR !45483 was not in this branch.
2. **No default EGL configs for GTK.** Mesa 26.3 disables GLES1 in the Arch
   build. `dri_util.c` therefore omits `__DRI_API_GLES` from `screen->api_mask`;
   EGL then has no `EGL_OPENGL_ES_BIT` configs. GTK 4.24's EGL config request
   omits `EGL_RENDERABLE_TYPE`, whose EGL default is ES_BIT, so the request
   returns zero and GTK falls back to cairo with `No EGL configuration
   available`.

The new `0002-gallium-dri-advertise-egl-es-bit.patch` sets the legacy GLES API
bit whenever ES2 is available. It does **not** enable GLES1 contexts (`gles1`
stays disabled); it only makes EGL publish the ES_BIT configs GTK expects.
An LD_PRELOAD shim was used only during investigation; it is not part of the
runtime fix and is not shipped in this repository or the image.

### E1. Build and verification

Built Mesa 26.3.1 on-device with `-Dgles1=disabled`, `-Dopengl=true`,
`-Dplatforms=wayland,x11`, and both repo patches. The library ABI matches the
phone's `libEGL_mesa.so.0` (`libgallium-26.3.1-arch1.1.so`), has no unresolved
`ldd -r` dependencies, and exports `driDestroyConfigs`.

- Before patch: EGL probe reports `gtk attrs=0`; `glatlas2` on Mesa 26.3.1
  reports `bad_cycles=30/30`, renderer FD512.
- After both patches, without shim: the GTK attribute request reports 15
  configs; the complete EGL list reports 75. `glatlas2` reports
  `bad_cycles=0/30`, renderer FD512. Repeated after copying into `/usr/lib`,
  also `bad_cycles=0/30`.
- A GTK4 window test with `GSK_RENDERER=gl` maps `libEGL`, `libGLESv2`, and the
  patched `libgallium`, with no `No EGL configuration` / renderer warning.
- Phosh itself links GTK3, not GTK4; the Settings/GTK4 apps are the direct
  consumers of this fix. The compositor (phoc) already used FD512 GLES.
- GTK 4.24.1 warns that the old `GSK_RENDERER=ngl` name was renamed to `gl`;
  `ngl` was ignored. The shipped default is now `GSK_RENDERER=gl`.

The source tarball SHA256 was
`4e4e438eac7b840a9383988cbb7c08dad8041da544b9319fc26d319fa7348961`; the
built library SHA256 is `37a2bd628c39486638e1b141f4de00f409de8bd3e2c07e138bf201ac36815ceb`.
The prebuilt is in `userspace/mesa/` and its hash is in `SHA256SUMS`. Rootfs
build now selects the library that matches its own `libEGL_mesa` soname, rather
than taking the first glob match.

### E3. qcom-venus H.264 decode (silent capability test)

> **Historical; fixed by the patches in section H (2026-11-21).**  The test
> below is what the failure looked like before the EOS fix.

`/dev/video1` is `qcom-venus`'s decoder. It advertises `H264`, `VP8`, `VP9`,
`HEVC`, `VC1`, `MPEG4`, `MPEG2`, `H263`, and `XVID` as output (compressed)
formats and `NV12`/`Q08C` as capture formats. A 3 s 320x240 H.264 stream
(libx264, Constrained Baseline) was fed to `h264_v4l2m2m` with `-f null`:

- The decoder opens, negotiates `output=H264` / `capture=NV12`, and the filter
  graph starts (320x240 nv12).
- At end of stream, `capture POLLERR` is reported and the firmware logs
  `qcom-venus cc00000.video-codec: session error: event id:1001 (deadb000)`;
  ffmpeg then aborts (`Assertion pkt failed at fftools/ffmpeg_dec.c`).

So H.264 decode via venus is still broken, and the failure is the same
`event id:1001` seen before — a firmware/HFI session error at the end of the
stream, not a userspace configuration problem. No audio was played and no
screenshot was taken during this test.

### E2. Temporary on-device state

The live phone has the patched library installed and `GSK_RENDERER=gl` in both
`/etc/environment` and `phosh.service`. The original distro library is saved at
`/usr/local/lib/patched/libgallium-26.3.1-arch1.1.so.distro`; the committed
pacman hook restores the patched library after Mesa updates. The active GTK4
smoke test loaded the GL stack. SSH over USB remains available. No video or
sound test was played.

### E4. Release image with Mesa 26.3.1 (2026-11-20)

> **Historical, superseded by E5.** This 26.3.1 image was not the one shipped
> as v1.2. The release ships Mesa 26.2.6 and needs no package upgrade; the
> artifacts below were removed during disk cleanup.

The released rootfs tarball (`rootfs-arch.tar.zst`; kept locally as
`rootfs-arch-7.2.3.tar.zst`) still ships
`mesa 1:26.2.6-1`, but the device was upgraded to `mesa 1:26.3.1-1`, so the
release image was rebuilt and then upgraded to the same Mesa 26.3.1 file set
the phone runs. `rootfs/build-rootfs.sh` selected the ABI-matched 26.2.6
libgallium during the base build; a post-build step then replaced the Mesa
package files with the on-device-verified 26.3.1 set (libEGL_mesa, libGLX_mesa,
libgbm, `dri/libdril_dri.so` plus its driver symlinks, drirc, and the pacman db
entry), removed the 26.2.6 library and db entry, and installed the patched
`libgallium-26.3.1-arch1.1.so` into both `/usr/lib` and
`/usr/local/lib/patched`.

Because the image now ships exactly the Mesa libraries, patched libgallium
sha256 (`37a2bd62…`), GTK 4.24.1, and `GSK_RENDERER=gl` that were validated on
the phone (E1), the rendering behaviour is the same as the vetted on-device
stack. Verification of the built image (loop-mounted read-only):

- `var/lib/pacman/local/mesa-1:26.3.1-1` present; no `mesa-1:26.2.6-1`.
- `libEGL_mesa.so.0` NEEDED `libgallium-26.3.1-arch1.1.so`; no
  `libgallium-26.2.6-arch1.1.so` anywhere.
- active `/usr/lib/libgallium-26.3.1-arch1.1.so` sha256
  `37a2bd628c39486638e1b141f4de00f409de8bd3e2c07e138bf201ac36815ceb`.
- every `NEEDED` soname of `libEGL_mesa`, `libGLX_mesa`, `libgbm`,
  `libgallium` and `dri/libdril_dri` resolves inside the image.
- `GSK_RENDERER=gl` in `/etc/environment` and `phosh.service`.
- Firefox payload present (`policies.json`, `mobile-config-autoconfig.js`,
  `mobile-config-firefox/chrome.manifest`), all root-owned.
- non-root ownership scan: 0 files outside `/home/alarm` (the Firefox installer
  had been leaving its payload owned by uid 1000 via `cp -a`; now fixed).
- ext4 label `pmOS_root`, clean `e2fsck`.

Artifacts (local build host):

| File | Size | sha256 |
| --- | --- | --- |
| `rootfs-7.2.3-mesa263.img` | 8.0 GiB raw | `e58c94f2262169305ac541ef4dcff7f222a34a2eb210029155084febed095ad2` |
| `rootfs-7.2.3-mesa263.sparse.img` | 4.1 GiB sparse | `76a9d33738c343d34f051b7a79547f9a4ede7b30a04312699cacd7687931a744` |

### E5. Release image from the v1.2 tarball with the patched Mesa 26.2.6 (2026-11-20)

`release-assets-v1.2/rootfs-arch.tar.zst` (sha256
`a5355f24b59872c9994a2e9807d48edcc29276ddc0564e71476c1566bf09a5bb`) already
ships `mesa 1:26.2.6-1` and `gtk4 1:4.24.1-1`, so this image needs no Mesa
package upgrade: `libEGL_mesa.so.0` needs `libgallium-26.2.6-arch1.1.so`, and
that ABI-matched patched build is already in `userspace/mesa/` (sha256
`2e66f90e955f745a98c8fa180e83a4f912f0873e48898d42f325a9200a47808c`).
`rootfs/build-rootfs.sh` selects it by reading the soname its `libEGL_mesa`
requests and copies it to both `/usr/lib` and `/usr/local/lib/patched`. Patch
`0001` (a5xx 2D-blit/HBB) applies on both Mesa versions; patch `0002` (advertise
`EGL_OPENGL_ES_BIT`) is only applied on 26.3.1, because 26.2.6 still exposes the
bit with GLES1 enabled, so GTK finds an EGL config without it.

This is the first image whose build is self-checking. `rootfs/build-rootfs.sh`
now refuses to produce an image that would regress: before unmounting it
asserts that `snd-soc-sm8250` and `snd-soc-max98937`, the lavender UCM2 profile
and the WirePlumber S16LE rule are present, that every `NEEDED` soname of the
shipped Mesa stack (`libEGL_mesa`, `libgbm`, `dri/libdril_dri`, `libgallium`)
resolves inside the image, and that `GSK_RENDERER=gl` plus
`FD_MESA_DEBUG=noubwc` are in `/etc/environment` and `phosh.service`. A rebuild
that had dropped `snd-soc-sm8250.ko.zst` had silently muted the speaker; the
check turns that class of mistake into a failed build.

Flashing the sparse image to `userdata` and booting confirmed the stack on
hardware:

- `phoc` (the wlroots compositor) logs `Using OpenGL ES 3.1 Mesa
  26.2.6-arch1.1`, `GL vendor: freedreno`, `GL renderer: FD512`, `EGL driver
  name: msm`; the process maps `libEGL_mesa`, `libGLESv2` and
  `libgallium-26.2.6-arch1.1.so`.
- A GTK4 application started with `GSK_RENDERER=gl` maps `libEGL_mesa` and
  `libgallium-26.2.6-arch1.1.so` and logs no renderer fallback. Note that
  phosh 0.57 here is a GTK3 shell, so `GSK_RENDERER` governs GTK4
  applications (Firefox, GNOME apps), while `phoc` and the GTK4 renderer do
  the GPU work.
- Audio did not regress: `snd_soc_sm8250` and `snd_soc_max98937` are loaded,
  the lavender UCM2 profile and `50-lavender-s16.conf` are installed, and
  `AllowSuspend=no` is preserved. The speaker was confirmed working on the
  flashed image.
- `GSK_RENDERER=gl` and `FD_MESA_DEBUG=noubwc` are set in both
  `/etc/environment` and `phosh.service`.

Artifacts (local build host). `rootfs-v1.2-gpu.sparse.img` is the flashed,
verified image; `rootfs-v1.2-gpu.img` is the raw counterpart.

| File | Size | sha256 |
| --- | --- | --- |
| `rootfs-v1.2-gpu.img` | 6.0 GiB raw | `9f40cd0cb09df201aeb7b0c1b53bb5cdc1121c809a7cbc9386bb5201ac4273d1` |
| `rootfs-v1.2-gpu.sparse.img` | 4.1 GiB sparse | `5463e065374e92bfaa763d424925ef324ff69c2c5c32bfa773ce6aa0234feff7` |

## F. CPU frequency scaling: why it is not in this image (2026-11-21)

There is no `/sys/devices/system/cpu/cpu*/cpufreq` on 7.2.3. The kernel is not
missing a config option:

```
CONFIG_ARM_QCOM_CPUFREQ_HW=m
CONFIG_CPU_FREQ_DEFAULT_GOV_SCHEDUTIL=y
CONFIG_CPU_FREQ_GOV_SCHEDUTIL=y
CONFIG_QCOM_SPM=m
CONFIG_QCOM_CPR=m
```

`CONFIG_ARM_QCOM_CPUFREQ_HW` is already built and loaded, but it binds to
nothing, and no OPP table exists for the CPUs:

- `arch/arm64/boot/dts/qcom/sdm660.dtsi` deletes the CPU
  `operating-points-v2` property from every CPU core
  (`/delete-property/ operating-points-v2;`, eight times) and defines no
  CPU OPP table, no `qcom,freq-domain`, and no `cpufreq` node at all. The only
  OPP table left in the file is the GPU's.
- `drivers/cpufreq/qcom-cpufreq-hw.c` matches only `qcom,cpufreq-hw`
  (the SDM845-and-later EPSS register layout), plus the EPSS variants. SDM660
  is an older SoC that uses the **OSM/SPM/SAW** interface, which this driver
  does not program. There is no node in the SDM660 device tree for it to bind
  to in any case.
- The upstream sdm660-mainline tracker notes the missing pieces
  (issue #33): the Core Power Reduction v3/v4/Hardened series (CPRh), the
  `cpufreq-qcom-hw: Implement full OSM programming` series and the
  `Implement SPM/SAW for MSM8998 and SDM6xx` series. None of these are in
  mainline or in the `qcom-sdm660-7.2.y` tree yet; `msm8998.dtsi` (the closest
  supported sibling) also has no `cpufreq-hw` node.

Enabling CPU frequency scaling therefore means carrying a large out-of-tree
patchset (CPRh + OSM + SPM/SAW), adding the OSM/SPM/SAW/CPR nodes and complete
CPU OPP tables with the correct per-corner voltages to the SDM660 device tree,
and then validating corner transitions under load. A wrong OSM or CPR
programming raises the wrong rail voltage and can hang the SoC, so this is not
something to guess at. It is left out of the image until the upstream series
lands; the CPU stays at its firmware/bootloader-selected frequency.

## G. Sensors and vibration: both were already in the kernel (2026-11-21)

### G1. Vibrator works, the docs were stale

`sdm660-xiaomi-lavender-common.dtsi` already enables `&pm660_haptics`
(`qcom,pmi8998-haptics`, `qcom,spmi-haptics`) with an ERM actuator in
direct-play mode:

```dts
&pm660_haptics {
	qcom,actuator-type = <HAP_TYPE_ERM>;
	qcom,play-mode = <HAP_PLAY_DIRECT>;
	qcom,wave-play-rate-us = <6667>;
	qcom,wave-shape = <HAP_WAVE_SQUARE>;
	status = "okay";
};
```

`CONFIG_INPUT_QCOM_SPMI_HAPTICS=m` (`qcom_spmi_haptics`) loads and registers
`/dev/input/event4` (`spmi_haptics`). A tiny `FF_RUMBLE` client compiled on the
device vibrated it for 1.5 s, so only the README/STATUS tables needed fixing --
no kernel or device-tree change.

### G2. Sensors needed one firmware blob

`qcom_sns_reg` (`CONFIG_QCOM_SNS_REG`) failed at probe because
`qcom/sensors/sns.reg` was absent:

```
qcom_sns_reg ...: Direct firmware load for qcom/sensors/sns.reg-xiaomi,lavender-shenchao failed with error -2
qcom_sns_reg ...: Direct firmware load for qcom/sensors/sns.reg failed with error -2
qcom_sns_reg ...: error -ENOENT: qcom_sns_reg probe failed!
```

`sns.reg` is a small binary registry the Android sensors HAL writes to the
`persist` partition (`sensors/sns.reg`). It is not in the stock firmware
(`NON-HLOS.bin` has the venus/adsp firmware, not the sensor registry), not in
the stock `vendor`/`system` images (only the text
`etc/sensors/sensor_def_qcomdev.conf`), and not in postmarketOS
`firmware-xiaomi-lavender`. The device's own `persist` partition still had it.

Copying that 25468-byte file
(SHA-256 `402986feeabfdae1111bd010a9026f7a59dd05ece2748b12f121dacaf9d8f255`)
to `/lib/firmware/qcom/sensors/sns.reg`, reloading `qcom_sns_reg` and loading
`sns_smgr`, `qcom_smgr` and the per-sensor drivers enumerated the sensors:

```
iio:device2  qcom-smgr-prox
iio:device3  qcom-smgr-mag
iio:device4  qcom-smgr-gyro
iio:device5  qcom-smgr-accel
```

The ICM20607 accelerometer, ICM20607 gyroscope, AK09918 magnetometer and
STK3x3x light/proximity sensors were identified in `dmesg`. Reading
`/dev/iio:device5` with the accel scan elements enabled streamed real,
changing samples.

`iio-sensor-proxy` reports the accelerometer (orientation) but not light,
proximity or compass.  The reasons are in the driver and in iio-sensor-proxy,
not in the registry:

* `qcom_smgr.c` streams only the primary `sns_smgr` data type and
  `qcom_smgr_prox.c` exposes it only as a buffer channel with no
  `in_proximity_raw`; the STK3x3x secondary (ambient light) data type is
  never exposed at all.
* Upstream `iio-sensor-proxy` 3.9 has a polled-proximity driver but no
  buffer-proximity driver, so the prox buffer is ignored, and no
  `in_illuminance_*` channel exists for the light rule to match.
* The ADSP has no SSC service (QMI `0x0190`); the stock rules still probe the
  libssc backend for `/dev/fastrpc-adsp*`, and `ssc_sensor_light_new_sync()`
  then crashes the whole proxy.  The udev rule shipped in
  `userspace/sensors/udev/90-iio-sensor-proxy-no-ssc.rules` disables that
  backend, which is what makes orientation work at all.

The port ships the registry at `rootfs/firmware/qcom/sensors/sns.reg`
(`rootfs/build-rootfs.sh` installs it and refuses to build an image without
it), `userspace/sensors/modules-load.d/sdm660-sensors.conf`, and the udev
rule.  See [`userspace/sensors/README.md`](../userspace/sensors/README.md).


## H. Venus H.264 decode: EOS, and the two upstream fixes (2026-11-21)

### H1. The symptom

`v4l2h264dec` (`qcom-venus`, the decoder node — `/dev/video1` on the boot in
section H4; the number depends on module load order) starts a 720p H.264
stream but never finishes it.  A few seconds in, the driver logs

```
qcom-venus aa00000.video-codec: session error: event id:1001 (deadb000)
```

and puts both queues into an error state.  GStreamer's `poll()` then fails at
end of stream and ffmpeg aborts.  `event id:1001` is `HFI_ERR_SESSION_FATAL`
and `deadb000` is the buffer address the driver put in the command.

### H2. Why

`vdec_decoder_cmd()` implements `V4L2_DEC_CMD_STOP` by queuing an empty
`HFI_BUFFER_INPUT` marked `HFI_BUFFERFLAG_EOS`.  The host has no real input
buffer to name for that command, so (for everything except old IRIS2
firmware) it used the invented address `0xdeadb000`.  The Venus v4 firmware
on this SDM660 does not accept it -- it validates the address, finds that it
straddles the protected/non-protected regions and rejects it:

```
IsBufferProtected(1087): VenusCoreCtrl: CP_UNKNOWN, buffer straddles CP & non-CP regions
vDec_EmptyBuffer(1932): Invalidate buffer in ETB
```

The firmware then raises `HFI_ERR_SESSION_FATAL`.  The firmware swap that was
suspected first is a dead end: the venus blobs in the stock `NON-HLOS.bin` are
byte-identical to the ones the phone runs.

### H3. The fixes

Two of David Heidelberg's patches (lore.kernel.org, Sep 2026, message-ids
`20260928-venus-vdec-eos-v1-1-6e9eb3ce9849@ixit.cz` and
`...-v1-2-...`) are carried as `kernel/patches/local/0003` and `0004`:

* **0003** (`media: venus: vdec: signal EOS with a real buffer`) allocates a
  4 KiB DMA buffer (`DMA_ATTR_NO_KERNEL_MAPPING`) the first time an instance
  is drained and uses its device address for the EOS command, so the firmware
  gets a mapped address outside the protected regions.  It drains normally:
  every frame is returned and the last capture buffer carries
  `V4L2_BUF_FLAG_LAST`.  The old `NULL`-address quirk for IRIS2 is kept.
* **0004** (`media: venus: vdec: start capture after a seek that streams
  CAPTURE first`) finishes the capture start from the OUTPUT `SEEK` path when
  the CAPTURE queue is already streaming.  The stateful API does not require a
  stream-on order and GStreamer restarts with CAPTURE first; without this the
  decoder never receives DPB or capture buffers and no frame comes out.

Both are in `kernel/patches/local/` and applied on every build (see
[`BUILD-KERNEL.md`](BUILD-KERNEL.md#local-patches)).

### H4. Verification

> **Fixed; supersedes E3.**

On 2026-11-21 the freshly built kernel (7.2.3-sdm660 + `0003`/`0004`) was
booted with `fastboot boot` and the freshly built modules were installed in
`/lib/modules/7.2.3-sdm660/` (the whole 640-module tree replaced and
`depmod -a` run, so the running kernel and modules come from the same build;
`venus-dec.ko.zst` SHA-256
`d5446bfd50b3862eec108f1af512c9f7cea971c80cf8d6e21bfe3d8eb3153dfa`).  A
standard Annex-B stream was generated on the device with the software encoder:

```
ffmpeg -f lavfi -i testsrc=size=1280x720:rate=30 -t 4 \
    -pix_fmt yuv420p -c:v libx264 -preset ultrafast -f h264 /root/test.h264
# 154941 bytes, Constrained Baseline, 1280x720, 120 frames
```

GStreamer (`v4l2h264dec`):

```
$ gst-launch-1.0 -e filesrc location=/root/test.h264 ! h264parse \
      ! v4l2h264dec ! videoconvert ! fakesink sync=false
Setting pipeline to PLAYING ...
Got EOS from element "pipeline0".
EOS received - stopping pipeline...
Execution ended after 0:00:00.840324559
$ echo $?
0
```

ffmpeg (`h264_v4l2m2m`):

```
$ ffmpeg -c:v h264_v4l2m2m -i /root/test.h264 -f null -
[h264_v4l2m2m] driver 'qcom-venus' on card 'Qualcomm Venus video decoder' in mplane mode
[h264_v4l2m2m] requesting formats: output=H264/none capture=NV12/yuv420p
frame=  120 fps=0.0 q=-0.0 Lsize=N/A ...
$ echo $?
0
```

Both reached end of stream cleanly.  `dmesg` was cleared before each run and
showed no `session error`, no `event id:1001` and no `deadb000` afterwards.

The decoder was `/dev/video1` and the encoder `/dev/video0` on this boot, but
the numbering follows module load order, so `scripts/verify.sh` now names
them with `v4l2-ctl --list-devices` instead of hardcoding a number.

Regression checks on the same boot: `snd_soc_sm8250` and `snd_soc_max98937`
loaded, the `X7` sound card was present and a PipeWire playback (`pw-play`)
exited 0; `msm` loaded and `adreno 5000000.gpu` came up (`GPU speedbin fuse
135`); the sensor stack enumerated (`qcom-smgr-accel/gyro/mag/prox`),
`iio-sensor-proxy` stayed active with live orientation, and `spmi_haptics`
registered `/dev/input/event4`.

## I. Firefox H.264 hardware decode on venus (V4L2-M2M DRM-PRIME) (2026-11-21)

### I1. The symptom

Firefox played 1080p H.264 with the CPU pegged (the RDD media process at
~70%) and never touched venus: `fuser /dev/video0` was empty, and
`MOZ_LOG="PlatformDecoderModule:5,FFmpegVideo:5"` printed

```
Got non-DRM-PRIME frame from FFmpeg V4L2
```

after which Firefox discarded the hardware frames and fell back to software.

### I2. Why

Firefox (159.0.1) *does* build the Linux V4L2-M2M decoder support, and its own
probe finds the decoder (`gfxtest v4l2 -d /dev/video0` ->
`V4L2_SUPPORTED TRUE`, capture `NV12 Q08C`, output `H264 VP80 VP90 HEVC ...`).
The blocker is below Firefox: `FFmpegVideoDecoder::CreateImageV4L2` only
accepts DRM-PRIME (`AV_PIX_FMT_DRM_PRIME`) frames from the stateful
`h264_v4l2m2m` wrapper.  Upstream ffmpeg's `v4l2_m2m` always allocates
memory-mapped capture buffers and never exports them as dmabufs, so Firefox
logs the non-DRM-PRIME message and falls back to software (Mozilla bug
**1852765**).

venus itself is fully capable: `/dev/video0` supports `VIDIOC_EXPBUF` and
`V4L2_MEMORY_DMABUF` (`CONFIG_DMA_SHARED_BUFFER=y`, `VIDEOBUF2_DMA_SG=m`), and
it is the stateful M2M variant (`VIDIOC_QUERYCAP` capabilities `0x04204000`,
no stateless SPS/PPS controls).

A second blocker is the RDD (media) sandbox: without
`MOZ_DISABLE_RDD_SANDBOX=1` the RDD child cannot open `/dev/videoN`, so the
decoder never starts.

### I3. The fix

The Raspberry Pi fork `jc-kynesim/rpi-ffmpeg` implements the DRM-PRIME output
that Firefox needs.  It is staged into an **isolated** prefix
`/opt/rpi-ffmpeg/lib` so the distro ffmpeg (`2:9.0.2-2`, `libavcodec.so.63`)
is never replaced:

* the fork build is ffmpeg 7.1.5 (`libavcodec.so.61.19.101`);
* Firefox's `FFmpegRuntimeLinker` tries the newest soname first
  (`libavcodec.so.63`, then `.62`, then `.61`), so the prefix carries
  `libavcodec.so.62` and `libavcodec.so.63` symlinks to the built
  `libavcodec.so.61`; `LD_LIBRARY_PATH` precedes the ld.so cache, so Firefox
  picks the patched library and nothing else in the system sees the shadows;
* `/usr/local/bin/firefox` exports `LD_LIBRARY_PATH=/opt/rpi-ffmpeg/lib` and
  `MOZ_DISABLE_RDD_SANDBOX=1`, then execs the real binary; a per-user desktop
  override (`~/.local/share/applications/firefox.desktop`) points the Phosh app
  grid at the wrapper;
* `/usr/lib/firefox/defaults/pref/99-v4l2-hwdecode-prefs.js` sets
  `media.hardware-video-decoding.enabled=true`,
  `media.hardware-video-decoding.force-enabled=true` (skip the gfxInfo
  blocklist) and `media.ffmpeg.vaapi.enabled=false`.

The scripts live in `userspace/firefox/v4l2-hwdecode/`: `build-rpi-ffmpeg.sh`
(source build), `stage-ffmpeg-rpi-pkg.sh` (offline path) and `install.sh`
(wrapper + pref + desktop override); `rootfs/build-rootfs.sh` wires them in
behind `RPI_FFMPEG_LIBDIR` / `RPI_FFMPEG_PKG`.

> Build note: the fork's 7.1.5 tree is the branch `test/7.1.5/main`; there is
> no `release/7.1` branch.  Because the device had no working DNS and the
> host's GitHub throughput was ~20 KB/s, the tested libraries were taken from
> Arch Linux ARM's `ffmpeg-rpi 7.1.5-4` package, which is built from the same
> source.  `stage-ffmpeg-rpi-pkg.sh` reproduces exactly that staging.

### I4. Verification (2026-11-21)

Worked example: a YouTube stream (`aqz-KE-bpKQ`, VP9/AV1 disabled to force
H.264) and a local 1080p30 H.264 clip, played in Firefox launched through the
wrapper.

```
$ fuser -v /dev/video0
/dev/video0:  alarm  22370 F...m RDD Process      # RDD holds the venus decoder

$ grep -i venus /proc/interrupts                  # before -> after ~70 s
 191: 4422 ...   ->   191: 5129 ...               # delta ~800 IRQs

$ grep libav /proc/22370/maps
/opt/rpi-ffmpeg/lib/libavcodec.so.61.19.101       # the patched fork
/opt/rpi-ffmpeg/lib/libavutil.so.59.39.100        # only these two are mapped

$ ps -o pcpu= -p <RDD>                            # 1080p H.264
3.0                                               # ~70% with software decode
```

`MOZ_LOG` (`FFmpegVideo:5,PlatformDecoderModule:5`) — Firefox writes
child-process logs to `moz.log.child-<n>.moz_log`, not to the base name:

```
D/FFmpegVideo FFMPEG: Initialising V4L2-DRM FFmpeg decoder    # present
D/FFmpegVideo FFMPEG: V4L2 FFmpeg init successful             # present
D/FFmpegVideo FFMPEG: V4L2 Got one frame output ...           # 856 frames
D/FFmpegVideo FFMPEG: ... h264_v4l2m2m
D/Dmabuf VideoFrameSurface: V4L2 locking dmabuf surface ... mHWAVBuffer ...
# "Got non-DRM-PRIME frame from FFmpeg V4L2": 0 occurrences
```

`dmesg` showed no new venus errors during playback (the `1001`/`deadb000`
messages in the log predate the run by hours), and a `grim` screenshot of the
session showed the video rendering normally.

See [`userspace/firefox/v4l2-hwdecode/README.md`](../userspace/firefox/v4l2-hwdecode/README.md)
for the build/stage commands and the rollback steps.

### I5. Re-verification: node numbering, 1080p60, and the WiFi ceiling (2026-11-21)

* **The venus node numbers are not stable across boots.** The decoder and
  encoder are bound to `/dev/video0`/`/dev/video1` in probe order, so which is
  which flips between boots (in one boot `video0` was the decoder, in the next
  it was the encoder). Identify the decoder by its *coded* OUTPUT formats
  (`H264`/`VP80`/`VP90`/`HEVC`, with `NV12`/`Q08C` on CAPTURE); the encoder
  only takes `NV12` on OUTPUT:

  ```sh
  v4l2-ctl -d /dev/videoN --list-formats-out    # H264... => decoder
  ```

  A verification script that hard-codes `/dev/video0` therefore gives false
  passes and failures from one boot to the next even though nothing is wrong;
  check both nodes (or derive the decoder from the formats) before asserting
  that the RDD process holds it.

* **A full 1080p60 H.264 stream decodes on venus.** The YouTube video
  `LXb3EKWsInQ` ("COSTA RICA IN 4K 60fps HDR") was fetched at its 1080p60
  H.264 rendition (itag 299, 1920x1080, 60 fps) and played through Firefox:
  the RDD process held the decoder node, the venus IRQ counter rose by
  **3237** over ~39 s, `MOZ_LOG` showed `h264_v4l2m2m` +
  `Initialising V4L2-DRM FFmpeg decoder` with **1633** output frames and **0**
  `non-DRM-PRIME`, the decode ran at 16.68 ms/frame (60 fps), and RDD CPU was
  **12.7%**. Only `/opt/rpi-ffmpeg/lib` was mapped.

* **Streaming the same video *from YouTube* cannot reach 1080p on this access
  point, and the `ath10k_snoc` link — not the decoder — is the limit.**
  YouTube's own quality menu offers `1080p60 HD`, but "Auto" selects 480p and
  the player stalls (`waiting` x1.3e4). The link only sustains roughly
  0.1–0.5 MB/s (~1–4 Mbit/s), even after disabling WiFi power save
  (`wifi.powersave = 2` in `/etc/NetworkManager/conf.d/wifi-powersave-off.conf`)
  and setting the regulatory domain (`options cfg80211 ieee80211_regdom=ID` in
  `/etc/modprobe.d/cfg80211.conf`; `cfg80211` is a module here, and the
  associated AP sends a country IE that makes `iw reg get` report `CN`). Even
  after a clean reboot the link stays below what 1080p60 needs. `MOZ_LOG` still
  shows the DRM-PRIME V4L2 decoder engaged with 0 `non-DRM-PRIME` — the decode
  path is fine, the source simply cannot deliver 1080p over this link. Note
  also that a manual `modprobe -r ath10k_snoc` is *not* a safe recovery here:
  unloading the module tears down the shared MSS (`remoteproc0`), after which
  the WCN3990 QMI handshake fails (`msa map permissions -22`, `qmi-board-id=0`)
  and WiFi only returns after a full reboot.

### I6. The 1080p60 frame drops came from the stream, not the decoder or the compositor (2026-11-21)

* **Symptom reproduced on YouTube.** On `FzMN8UsRF8Y` at 1080p60
  (`avc1.64002A`, itag 299) the player decoded ~61.6 fps but reported ~51 fps
  dropped (only ~10 fps presented) while venus was decoding. At the same time
  the buffer was draining (23.9 s → 13.9 s in 15 s) and the connection estimate
  was 1.2–2.0 Mbit/s, so the source could not sustain the stream.

* **A network-free render test proves the decode + zero-copy compositor path is
  good.** The same itag-299 H.264 stream was cut into a 22.6 MB DASH fragment
  and played from `/tmp` in a private Firefox window (launcher wrapper and
  hardware-decode prefs unchanged). Evidence:

  * the RDD process held `/dev/video0` and six `/dmabuf:` fds, and the parent
    (`Renderer`) held the imported dmabufs;
  * `MOZ_LOG` reported `PlatformDecoderModule Broadcast support from 'RDD',
    support=H264 SWDEC HWDEC`, `DMABufSurfaceYUV::ImportSurfaceDescriptor()`
    and `Plane 0/1: zero-copy EGLImageTargetTexture2D succeeded`; the
    negotiated format is linear `NV12` (`0x3231564e`), not `Q08C`;
  * venus ran at **124 IRQ/s** with RDD CPU **11–14%**;
  * `HTMLVideoElement.getVideoPlaybackQuality()` (rendered in the test page):
    after the first ~10 s of startup, `decode 60.0 fps, dropped 0.0 fps,
    shown 60.0 fps`; over ~157 s in total **9448 decoded / 764 dropped
    (8.1%)**, almost all of it in that startup burst.

  So venus plus freedreno/WebRender can present a steady 1080p60. The YouTube
  drops are a source problem (buffer drain / late SABR chunks) plus the usual
  first-seconds decoder fill, not a decode or compositor ceiling.

* **A quality change can strand the session on software decode.** After
  YouTube auto-downgraded 1080p→720p, the same session kept decoding in
  software (venus IRQ 0, no `/dev/video*` open, RDD ~135% CPU). A clean restart
  of the launcher re-engaged `H264 HWDEC` immediately. When measuring, confirm
  that the RDD process still holds the venus node; a restart restores it.

* **The WiFi link remains the fragile part.** `ath10k_snoc` firmware crashed
  once at ~61 min uptime (`firmware crashed! (guid …)`), recovered by itself
  (`device successfully recovered`), but `wlan0` came back `DOWN` without
  DHCP. It was recovered **without a reboot** with:

  ```sh
  ip link set wlan0 up
  nmcli radio wifi on
  nmcli device set wlan0 managed yes
  nmcli connection up "CAPING GUNUNG"   # may need a second attempt
  ```

  After that: `192.168.0.114/24`, −48 dBm, 150 Mbit/s, power save off, and a
  22 MB `scp` moved at ~110 Mbit/s. A direct `1.1.1.1` ping still fails (ICMP
  filtered); the gateway, `8.8.8.8` and HTTPS work. `iw reg get` again reports
  `country CN` (the AP's country IE overrides `ieee80211_regdom=ID`).
  `modprobe -r ath10k_snoc` remains unsafe (see I5).

## J. Fingerprint TrustZone transport (QSEE): the vendor TA loads (2026-11-21)

lavender's fingerprint is not a normal SPI/I²C sensor: the bus is owned by
TrustZone and all imaging, feature extraction, template storage and matching run
inside a Qualcomm-signed TA (`fpctzappfingerprint`) in QSEE. Normal world can
only load that TA and relay commands to it. Upstream mainline `qcom_scm` gates
QSEECOM behind an allowlist of "tested" machines, and lavender's compatible
string is not on it, so the in-kernel driver logs
`qseecom: untested machine, skipping`.

This section records a **feasibility result only**: the out-of-tree transport
[`nyl/linux-qseecom-mobile`](https://github.com/nyl/linux-qseecom-mobile)
(`/dev/qseecom_mobile`; driver by Nitescu Ion Laurentiu `<contact@nyl.ro>`,
`GPL-2.0-or-later`) reaches QSEE on lavender and loads the device's own signed
FPC TA. It is **not** a working reader yet.

### J1. What works

* Kernel prerequisites are present in `7.2.3-sdm660`: `CONFIG_QCOM_SCM=y`,
  `CONFIG_QCOM_TZMEM=y` (mode **Generic**), the `qcom_tzmem_*` symbols are
  exported, and `CONFIG_MODULE_SIG_FORCE` is unset (an unsigned module loads and
  taints).
* The module builds with the exact toolchain (Clang 23.1.5, the same
  `kbuild-edge:7.2.3` image `kernel/build.sh` uses) and gets the matching
  `vermagic 7.2.3-sdm660`. Clang 23 needs one source fix (J2).
* `insmod` creates `/dev/qseecom_mobile` and the driver binds to the kernel SCM
  path: `SCM synchronization active: smc_call=__scm_smc_call scm_lock=… 
  scm_dev=firmware:scm`. It kprobes `kallsyms_lookup_name` and reuses the
  kernel's own `__scm_smc_call`/`qcom_scm_lock`, so it needs no allowlist entry
  and no kernel patch.
* The FPC TA is present in the stock `vendor.raw.img` (Xiaomi-signed):
  `firmware/fpctzappfingerprint.mdt` + `.b00`..`.b07`. Loading it succeeds:

  ```
  qseecom_mobile: loading 'fpctzappfingerprint': mdt_len=7004 total_len=2576481 segments=8
  qseecom_mobile: successfully loaded 'fpctzappfingerprint' with id 131074
  ```

  TrustZone verified the signature and started the TA. The driver auto-unloads
  the app when the last fd is closed.

### J2. The one build fix

Clang 23 rejects passing the driver's layout-identical mirror structs
(`struct qsee_scm_desc` / `qsee_scm_kernel_res`) to the kernel function pointer,
which is typed with the opaque forward declarations `struct qcom_scm_desc` /
`res`. Two explicit casts fix it. kCFI hashes the function-pointer *type*, which
is unchanged, so the casts are safe (this is also why the driver declares the
prototype with the kernel's own type names). The patch is kept in
[`userspace/fingerprint/qseecom-mobile/patches`](../userspace/fingerprint/qseecom-mobile/).

### J3. Remaining work

The upstream repo also ships a userspace `net.reactivated.Fprint` daemon
(`tz-qsee-fingerprintd`) with a per-device plugin vtable, but only a
Chipone/FP4 plugin. A new **FPC plugin** is required, plus the sensor's
reset/IRQ GPIO handling. Known blockers:

* the FPC TA protocol is undocumented and must be recovered from the Android
  vendor HAL (`vendor.qti.hardware.fingerprint@1.0.so` in the vendor image);
* committing an enrollment needs a **Gatekeeper/HAT token** (the prior art hit
  the same wall; `keymaster64` is not in the `vendor` image);
* malformed TA traffic can trip the EL3 watchdog (reboot).

Details, prior art and a reproduction recipe are in
[`userspace/fingerprint/qseecom-mobile/README.md`](../userspace/fingerprint/qseecom-mobile/README.md).
