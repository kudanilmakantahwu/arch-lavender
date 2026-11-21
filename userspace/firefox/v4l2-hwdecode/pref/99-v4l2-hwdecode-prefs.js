// SPDX-License-Identifier: MPL-2.0
//
// Firefox hardware video decode on qcom-venus (V4L2-M2M, DRM-PRIME).
//
// Firefox's Linux media stack only ever asks ffmpeg for the stateful
// `h264_v4l2m2m` wrapper when a real hardware candidate exists, and it
// requires that wrapper to hand back DRM-PRIME (dmabuf) frames.  Upstream
// ffmpeg does not implement the v4l2m2m zero-copy path, so Firefox receives
// "non-DRM-PRIME" frames and silently falls back to software (Mozilla bug
// 1852765).  The patched ffmpeg staged in /opt/rpi-ffmpeg is the Raspberry Pi
// fork that adds DRM-PRIME output; these defaults switch the hardware path on
// for every profile.
//
//   * media.hardware-video-decoding.force-enabled skips the gfxInfo
//     blocklist so the V4L2 probe result is actually used.
//   * media.ffmpeg.vaapi.enabled=false keeps Firefox from wasting a start-up
//     on the absent VA-API backend first.
pref('media.hardware-video-decoding.enabled', true);
pref('media.hardware-video-decoding.force-enabled', true);
pref('media.ffmpeg.vaapi.enabled', false);
