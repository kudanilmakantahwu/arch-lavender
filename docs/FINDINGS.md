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

Session-wide validation is still needed: swap the patched libgallium into the
session (or run phoc + apps with the `/opt/mesa-hbb` env) and use the device
normally, including browser sites and long uptime. This needs approval because
it restarts the session.

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

### A8. Remaining work

- Session-wide patched-Mesa run with real usage, then decide between keeping
  the `/opt/mesa-hbb` override or carrying the three patches in a Mesa
  PKGBUILD until 26.3.
- Re-test Epiphany (`WEBKIT_DISABLE_DMABUF_RENDERER=1` needed to avoid its
  crash loop) and Angelfish once the session runs patched Mesa.
- Verify squeekboard is still enabled/working after the session restart.

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
