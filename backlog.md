- [ ] Move time display a bit on screen save pixels on screen
- [ ] Implement RTSP support
DONE: Add Bonjour announcement - RTSP disovery via _rtsp._tcp
Add UDP support for RTSP.

- [ ] Check if migration logic for resolvedImageUrl and imageUrl is still needed (see didChangeModel).
- [ ] Detect movement in video stream
- [ ] Capture images and video when movement is detected.
- [ ] Check if tiered and storage logic work.



Issue 2

Title: Local HTTP server exposes camera control and device data without authentication

Lines:/home/runner/work/haios-kiosk/haios-kiosk/experiment-camera/CameraCaptureNetworking.swift:156-171/home/runner/work/haios-kiosk/haios-kiosk/experiment-camera/CameraCaptureNetworking.swift:334-376/home/runner/work/haios-kiosk/haios-kiosk/experiment-camera/CameraCaptureNetworking.swift:398-436

Problem:The /info, /latestImage.jpg, /mjpeg, and /camera endpoints are accessible to any client on the local network without authentication.

Impact:Any device on the same network may be able to read camera data or control camera state.

Recommendation:Add authentication or a shared secret, or make these endpoints opt-in behind an explicit configuration.


Issue 4

Title: MJPEG stream resends identical placeholder frames indefinitely

Lines:/home/runner/work/haios-kiosk/haios-kiosk/experiment-camera/CameraCaptureNetworking.swift:468-489/home/runner/work/haios-kiosk/haios-kiosk/experiment-camera/CameraCaptureNetworking.swift:497-506/home/runner/work/haios-kiosk/haios-kiosk/experiment-camera/CameraCaptureNetworking.swift:522-527

Problem:When the camera is off or waiting for the first image, the MJPEG stream keeps sending the same placeholder frame every 250 ms.

Impact:This wastes CPU, battery, and network bandwidth without changing the visible output.

Recommendation:Deduplicate placeholder frames and only resend them when the stream state changes.


Issue 5

Title: Tiered capture retention logic does not match documented behavior

Lines:/home/runner/work/haios-kiosk/haios-kiosk/experiment-camera/CameraCaptureView.swift:82-85/home/runner/work/haios-kiosk/haios-kiosk/experiment-camera/CameraCaptureView.swift:168-198

Problem:The tiered retention logic applies stride based on the global oldest-first index instead of applying the stride independently within each age tier.

Impact:The actual files kept may not match the retention behavior described in the UI helper text.

Recommendation:Split files into age buckets first, then apply per-tier sampling within each bucket. Add tests that cover mixed-age datasets.


Issue 6

Title: Device orientation rotation mapping conflicts with test expectations

Lines:/home/runner/work/haios-kiosk/haios-kiosk/experiment-camera/CameraCaptureView.swift:280-290/home/runner/work/haios-kiosk/haios-kiosk/experiment-cameraTests/ExperimentCameraTests.swift:212-216

Problem:The production mapping for landscape rotation angles does not match the unit test expectations.

Impact:Either camera rotation is incorrect in production, or the tests are asserting the wrong behavior.

Recommendation:Verify the intended orientation behavior on a real device, then align both implementation and tests.


Issue 7

Title: Capture pruning performs synchronous file I/O on the main thread

Lines:/home/runner/work/haios-kiosk/haios-kiosk/experiment-camera/Views/Home/MainContentView.swift:265-299

Problem:pruneStoredCaptures() performs directory scanning, file deletion, and model cleanup from UI lifecycle paths on the main thread.

Impact:This can cause UI stuttering or delayed screen updates when many captures exist.

Recommendation:Move filesystem pruning work off the main actor, then apply SwiftData updates back on the main actor.

