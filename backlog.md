# Backlog

- [ ] Move time display a bit on screen save pixels on screen
- [ ] Implement RTSP support
DONE: Add Bonjour announcement - RTSP disovery via _rtsp._tcp
Add UDP support for RTSP.

- [ ] Check if migration logic for resolvedImageUrl and imageUrl is still needed (see didChangeModel).
- [ ] Detect movement in video stream
- [ ] Capture images and video when movement is detected.
- [ ] Check if tiered and storage logic work.

## Issue 5

Title: Tiered capture retention logic does not match documented behavior

Lines:/home/runner/work/haios-kiosk/haios-kiosk/experiment-camera/CameraCaptureView.swift:82-85/home/runner/work/haios-kiosk/haios-kiosk/experiment-camera/CameraCaptureView.swift:168-198

Problem:The tiered retention logic applies stride based on the global oldest-first index instead of applying the stride independently within each age tier.

Impact:The actual files kept may not match the retention behavior described in the UI helper text.

Recommendation:Split files into age buckets first, then apply per-tier sampling within each bucket. Add tests that cover mixed-age datasets.
