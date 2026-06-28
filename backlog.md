# Backlog

- [ ] Move time display a bit on screen save pixels on screen
- [ ] Implement RTSP support
DONE: Add Bonjour announcement - RTSP disovery via _rtsp._tcp
Add UDP support for RTSP.

- [ ] Check if migration logic for resolvedImageUrl and imageUrl is still needed (see didChangeModel).
- [ ] Detect movement in video stream
- [ ] Capture images and video when movement is detected.
- [ ] Check if tiered and storage logic work.
- [ ] Add option to reduce resolution for rtps streaming.

There should be 3 options that can be set in settings: full, 1/2 and 1/4. In full the resolution of stream is the same as currently (maximal), in 1/2 the image is resized to 50% of the resolution, and in 1/4 the image is resized to 25% of the resolution. The aspect is kept as is. Think how this can be implemented most efficiently.

## Issue 5

Title: Tiered capture retention logic does not match documented behavior

Lines:/home/runner/work/haios-kiosk/haios-kiosk/experiment-camera/CameraCaptureView.swift:82-85/home/runner/work/haios-kiosk/haios-kiosk/experiment-camera/CameraCaptureView.swift:168-198

Problem:The tiered retention logic applies stride based on the global oldest-first index instead of applying the stride independently within each age tier.

Impact:The actual files kept may not match the retention behavior described in the UI helper text.

Recommendation:Split files into age buckets first, then apply per-tier sampling within each bucket. Add tests that cover mixed-age datasets.
