# Performance and stability measurements

All numbers below were measured on the Redmi Note 7 (`lavender`, SDM660, Adreno
512) running `7.2.3-sdm660` with Phosh on `tty1`, screen awake, backlight fixed
at 1600/4095, no other user activity. Each configuration was measured at least
three times; the tables show every run plus the mean.

Test tools live outside the image (they are small binaries/scripts in
`/usr/local/bin` while testing):

| Tool | What it does |
| --- | --- |
| `scrollbench` | GTK4 4000-line `GtkTextView`; scrolls it for 12 s and reports frames per second from `GdkFrameClock::after-paint` |
| `videobench` | plays a 600-frame 1280×720/30 VP8 WebM (`vp8dec` → `videoconvert` → `waylandsink`) and reports effective fps |
| `benchrun` | runs `scrollbench` N times while sampling all `thermal_zone*` and the GPU `cur_freq`; keeps the screen awake |
| `memab` | opens Firefox, Settings, and Chatty, then samples `MemAvailable`, `/proc/pressure/memory`, swap, OOM and liveness for 60–90 s |
| `browserbench` | loads a 586 KB/4000-row local page in Firefox and reports time to idle CPU, RSS and idle CPU |
| `tempsample` | samples thermal zones and GPU frequency for N seconds |

## GTK4 renderer A/B

One variable (`GSK_RENDERER`), same session, same app, 12 s per run:

| Config | Run 1 | Run 2 | Run 3 | Mean | Avg frame | Worst frame |
| --- | --- | --- | --- | --- | --- | --- |
| `cairo` (previous default) | 21.8 fps | 24.1 fps | 23.1 fps | **23.0 fps** | 41–46 ms | 133–152 ms |
| `ngl` (GL, new default) | 52.0 fps | 50.4 fps | 50.5 fps | **51.0 fps** | 18.6–19.3 ms | 182–226 ms |
| `gl` (legacy GL) | 50.3 fps | 50.2 fps | 50.8 fps | **50.4 fps** | 19.1–19.4 ms | 177–261 ms |

A 22 s stress run scrolled 1207 frames (54.8 fps) with `ngl` and 542 frames
(24.6 fps) with `cairo`; the `ngl` screenshots showed every glyph intact, so the
historical Adreno glyph-cache bug did not reproduce. `ngl` is the new default;
`cairo` stays available as the glyph fallback.

## Video playback

720p30 VP8, software decode, same fullscreen sink:

| Config | Runs | Mean |
| --- | --- | --- |
| `cairo` session | 33.4, 33.1 fps | 33.3 fps |
| `ngl` session (final) | 32.4, 32.9, 32.6 fps | 32.6 fps |

Video is decode-bound, not renderer-bound: the GL and cairo sessions are within
noise, and the range across the whole session (31–41 fps) comes from cache and
on-screen-keyboard state, not from the renderer.

Hardware H.264 decode is **not** usable yet: `v4l2h264dec` (`qcom-venus`) fails
with `session error: event id:1001` a few seconds into a 720p stream, and the
image ships no software H.264 decoder (`gst-libav` is not installed), so H.264
video playback currently depends on the broken venus path. VP8/VP9 decode is
fine.

## GPU governor A/B

The kernel exposes no cpufreq policy at all (`/sys/devices/system/cpu/cpu*/cpufreq`
does not exist), so CPU frequency scaling cannot be tested or tuned; only the
GPU devfreq governor is available.

| Governor | Runs | Mean | GPU zone peak | GPU max freq |
| --- | --- | --- | --- | --- |
| `simple_ondemand` (default) | 32.0, 32.1 fps | 32.05 fps | 56.8 °C | 588 MHz |
| `performance` | 32.6, 31.9 fps | 32.25 fps | 56.8 °C | 588 MHz |

No measurable difference under video load; both reach 588 MHz. `simple_ondemand`
stays the default because it drops to 19 MHz when idle.

## Memory: zram on vs off

Workload: Firefox (586 KB page), Settings, Chatty; 90 s sampling.

| Config | Min `MemAvailable` | Max PSI some/full (10 s) | Swap used | OOM kills |
| --- | --- | --- | --- | --- |
| zram on (2.7 GiB zstd) | 3289 MB | 0.00 / 0.00 | 0 MB | 0 |
| zram off (no swap) | 3318 MB | 0.00 / 0.00 | 0 MB | 0 |

With 5.6 GB RAM, three desktop apps never create memory pressure, so zram is
not needed for that workload. It stays enabled as a safety net (4 KB used when
idle, no measurable cost) because Firefox alone reaches ~1.6 GB RSS.

## Speaker loudness

1 kHz tone, built-in mic 5 cm from the speaker, 3 repetitions per level,
`Speaker Volume=6`, ADC1 `8`, amp gain 800:

| `Digital Volume` | Mean RMS | Delta vs 100 | Peak sample |
| --- | --- | --- | --- |
| 100 (old default) | 4276.7 | — | 6478 |
| 112 | 5844.7 | +2.71 dB | 8810 |
| 127 (new default) | 8394.4 | **+5.86 dB** | 12617 |

The microphone never clipped, so 127 (the maximum) is used. `Speaker Volume`
cannot go above 6: the vendor codec only defines even gain codes 0/2/4/6.

## Final configuration and 3× retest

Locked defaults: `GSK_RENDERER=ngl`, `FD_MESA_DEBUG=noubwc`, zram swap enabled,
GPU governor `simple_ondemand`, `Digital Volume=127`, speaker amp enabled by the
MAX98937 driver + UCM2 profile.

| Scenario | Run 1 | Run 2 | Run 3 | Notes |
| --- | --- | --- | --- | --- |
| Scroll (GTK4 text) | 50.6 fps | 50.0 fps | 50.6 fps | mean 50.4 fps, worst frame 156–232 ms |
| Three apps | 3371 MB free | 3351 MB free | 3396 MB free | PSI 0, 0 OOM, all three apps alive |
| Browser (local page) | 30.1 s | 29.5 s | 41.6 s | 1.56–1.61 GB RSS, idle CPU 3–4 % |
| Video (720p30 VP8) | 32.4 fps | 32.9 fps | 32.6 fps | mean 32.6 fps |

Temperatures during these runs stayed at 52–58 °C on the CPU/GPU zones and
37–39 °C on the battery, with no thermal throttling (the GPU held 588 MHz).

## Known limits / open items

- **No CPU frequency scaling**: the kernel exposes no cpufreq policy, so CPU
  governor or frequency/thermal A/B testing is impossible; the CPU clock is
  fixed by firmware.
- **`phoc` touch crash**: `handle_touch_up` → `wlr_surface_get_root_surface`
  SIGSEGV in wlroots 0.20 when the surface under the finger disappears during
  the touch (app closes, keyboard hides, a job finishes). Happens with both
  renderers and is not configurable; see
  [TROUBLESHOOTING.md](TROUBLESHOOTING.md#compositor-dies-while-touching-the-screen-phoc-sigsegv).
- **Venus H.264 decode** errors out with `session error 1001`; no software
  H.264 decoder is installed.
- **In-call audio** is still unsupported (no `q6voice`/CVS driver).
- Firefox needs ~30–40 s to settle on a 586 KB local page and peaks above
  400 % CPU; this is a Firefox/WebRender cost on this SoC, not a renderer
  setting.
