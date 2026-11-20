# Findings: lavender glyph corruption, stutter, and speaker loudness

Running log. Newest results go at the bottom of each section. Commands and
logs are in English; user-facing summaries are in Indonesian.

## Environment (verified 2026-11-16 09:3x WIB)

- Kernel `7.2.3-sdm660 #1 SMP PREEMPT Sun Nov 8 08:30:49 UTC 2026`, DTB shenchao.
- Mesa `1:26.2.6-1`, freedreno `FD512`, GLES 3.1.
- Session env in phoc: `GSK_RENDERER=ngl`, `FD_MESA_DEBUG=noubwc` (no `notile`).
- `phoc` renderer: gles2; compositor uses msm/freedreno.
- No cpufreq policy in sysfs. Measured single-thread throughput (2 s xorshift
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
