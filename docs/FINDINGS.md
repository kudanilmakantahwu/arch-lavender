# Findings: lavender glyph corruption and stutter

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

The first session-wide attempt failed because two ABI details were wrong, not
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

Commands on the phone:

```
cd /root/mesa-26.2.6
VERSION=26.2.6-arch1.1 PYTHONPATH=/root/lab/pystub \
  meson setup --reconfigure build -Dplatforms=wayland,x11
ninja -C build src/gallium/targets/dri/libgallium-26.2.6-arch1.1.so
cp build/src/gallium/targets/dri/libgallium-26.2.6-arch1.1.so \
   /usr/lib/libgallium-26.2.6-arch1.1.so
```

`meson setup --reconfigure` is required; `meson configure` re-runs ninja's
regenerate step without `PYTHONPATH`, and the run then fails at the PyYAML
probe even though `/root/lab/pystub/yaml.py` exists.

Installed file (2026-11-18): `/usr/lib/libgallium-26.2.6-arch1.1.so`,
sha256 `3f9a7e7da3f13ebff4f21b199e308cd5a34a02c96e680c885788df13787cb388`.
Pristine Arch backup: `/root/lab/backup/libgallium-26.2.6-arch1.1.so.system`,
sha256 `34bb5b1b0eb80f86fab45a4485eddb9f60b283f2ed45309d1fc4ac4f235a411d`.
The `/opt` drop-in `zz-mesa-hbb.conf` was removed; only the pre-existing
`mesa-noubwc.conf` (`FD_MESA_DEBUG=noubwc`) remains. phoc maps the system
libgallium. This is a lab-only build (freedreno only, `llvm=disabled`, glvnd
disabled, no swrast/zink); do not ship it as a general Mesa replacement.

### A9. System-wide validation

All runs below use the installed system-wide library, no `/opt` or
`LD_LIBRARY_PATH` override.

- `glatlas2` 3x50 (150 cycles): 150/150 clean, renderer FD512.
  Logs: `/root/lab/logs/glatlas2-sys-{1,2,3}.log`.
- `glatlasvis` without env: readback clean and the captured frame shows the
  gradient tile, not the black tile. Screenshot:
  `/home/maf/lavender-lab/shots/glatlasvis-sys.png`.
- Firefox `about:support`: `Compositing: WebRender`, `Window Protocol:
  wayland`, WebGL 2 driver renderer `freedreno -- FD512`, driver version
  `OpenGL ES 3.1 Mesa 26.2.6-arch1.1`, GPU #1 `FD512` active.
  Screenshots: `shots/firefox-support7.png`, `shots/firefox-support8.png`.
- `glmark2-es2-wayland -b texture:duration=10`: 202 fps, clean wood-texture
  frame (`shots/glmark2-tex.png`). `--validate` reports 24 failures on the
  patched lib and the exact same 24 failures with the pristine Arch lib, so
  that validation mode is not a usable correctness signal on this stack.
- `gskstress` (400 GSK glyph-atlas frames) and `gskimg` (300 GtkImage churn
  frames) render their final frames complete:
  `shots/gskstress-sys.png`, `shots/gskimg-sys.png`.
- The new phoc stays up. The only core dump is the old phoc PID 8435
  (`SIGSEGV`) at the moment of the forced `systemctl restart phosh`; the new
  PID 16432 starts cleanly and maps the system libgallium. Treat that teardown
  crash as the known phoc cleanup issue, separate from rendering.
- Waydroid container/session start, but `waydroid show-full-ui` loops on
  `Failed to get service waydroidplatform`; Android UI does not come up. This is
  a Waydroid/binder issue on the current setup, not a Mesa rendering result.

### A10. Remaining work

- Keep the system-wide lib only as a lab override; an Arch `mesa` upgrade will
  overwrite it. For distribution, carry the three patches in a Mesa PKGBUILD
  until 26.3.
- Re-test Epiphany (`WEBKIT_DISABLE_DMABUF_RENDERER=1`) and Angelfish under the
  system-wide lib, and use a browser on a real site for a longer uptime run.
- Fix/decide Waydroid separately (binder/platform service); it is not blocked
  by the glyph fix.
- Verify squeekboard and the lock screen after a clean reboot (session restart
  already keeps them working).

### A11. Separate issue: no Wi-Fi password prompt

Symptom: selecting a secured network in Settings or the phosh quick settings
closed without a password dialog; the connection stayed in `need-auth`/failed.

Root cause: `gnome-keyring` was not installed, so the session had no
`org.freedesktop.secrets` provider. phosh's `ShellNetworkAgent` always queries
the keyring first in `get_secrets_keyring_cb()`; when the secret service is
missing the query fails, the callback returns `NM_SECRET_AGENT_ERROR_FAILED`,
and `secret_request_new_cb()` never creates `PhoshNetworkAuthPrompt`. NM then
reports no secrets even though the agent is registered.

Evidence:

- `secret-tool search foo bar` as `alarm` returned
  `The name is not activatable`.
- `busctl --user list` had no `org.freedesktop.secrets` before the install;
  after `pacman -S gnome-keyring` it is activatable.
- After the install, the prompt appears for a saved-but-secretless network in
  Settings (`shots/wifi-prompt-now.png`) and from the quick settings Wi-Fi list
  (`shots/qs-wifi5.png`).
- A root `nmcli` test is not a valid reproducer: NM filters secret agents by
  the activating UID, so the uid-1000 phosh agent is skipped for a root-owned
  profile.

Fix: install `gnome-keyring` (provides `org.freedesktop.secrets`; the package
enables its user socket). No phosh or NetworkManager configuration was changed.

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
