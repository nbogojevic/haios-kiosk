# Instructions for `experiment-camera`

## Project overview
- This is an Xcode iOS app built with **SwiftUI** and **SwiftData**.
- The app has three main areas:
  - `Dashboard` web view backed by `WKWebView`
  - `Camera` controls backed by `AVFoundation`
  - `Captures` backed by `SwiftData` and files stored in the app Documents directory
- Camera/networking behavior is implemented in:
  - `experiment-camera/CameraCaptureView.swift`
  - `experiment-camera/CameraCaptureNetworking.swift`
- Main app navigation and most UI lives in:
  - `experiment-camera/MainContentView.swift`

## Code style and structure
- Prefer **small, focused changes** over broad refactors.
- Preserve the existing **SwiftUI-first** structure and naming unless a change clearly requires otherwise.
- Match the existing style:
  - `private` helper types and extensions when possible
  - `@MainActor` for UI-facing observable objects and stateful app logic
  - concise computed properties for UI strings
  - `Task { @MainActor in ... }` when hopping back to the main actor from callbacks
- Keep public surface area minimal. Default to `private` or `fileprivate` for new helpers unless wider visibility is required.
- Avoid introducing new dependencies unless they are clearly necessary.

## UI and navigation conventions
- The root screen title is **`Home`**.
- Keep these navigation destinations and titles consistent unless the user explicitly asks to change them:
  - Web view: `Dashboard`
  - Camera screen: `Camera`
  - Captures screen: `Captures`
  - Settings sheet: `Settings`
- Existing UI tests rely on accessibility labels and titles. Do not rename these without also updating tests:
  - `Settings`
  - `Done`
  - `Open camera controls`
  - `Open web view`
  - `Open captures`
- Prefer explicit `.accessibilityLabel(...)` on icon-only buttons.

## Persistence and storage
- `SwiftData` model state is centered on `Item`.
- Captured images are stored in the app Documents directory under `Captures`.
- Keep retention-related behavior aligned with `CaptureRetentionPolicy`.
- When deleting captures, ensure both the persisted model entry and the on-disk file are handled consistently.
- Preserve existing `UserDefaults` / `@AppStorage` keys unless a migration is intentionally being added.

## Camera and concurrency guidance
- Camera capture is built on `AVFoundation` and should remain responsive and main-thread safe.
- Keep UI state updates on the main actor.
- Avoid blocking the main thread with image processing, file IO, or network work.
- If adding capture/session logic, follow the existing split:
  - UI-facing state in `CameraCaptureService`
  - lower-level session work in `CaptureSessionController`
  - frame persistence in `VideoFrameCaptureProcessor`
- Preserve the current behavior around:
  - authorization handling
  - start/stop semantics
  - periodic timed captures
  - app foreground/background pause and resume

## Networking guidance
- The embedded HTTP server exposes endpoints for latest image, MJPEG, info, and camera power state.
- Preserve compatibility for these paths unless explicitly changing the protocol:
  - `/latestImage.jpg`
  - `/mjpeg`
  - `/info`
  - `/camera`
- Prefer backwards-compatible changes to response formats and status behavior.
- Keep Bonjour service advertisement behavior intact unless the task is specifically about discovery or protocol changes.

## Testing expectations
- There are both unit tests and UI tests:
  - in `experiment-cameraTests/`
  - in `experiment-cameraUITests/`
- When changing behavior that affects navigation, button labels, screen titles, capture retention, or MJPEG state, update/add tests.
- Prefer adding focused tests for pure logic and regressions.
- Avoid adding tests that require real camera hardware unless explicitly requested.
- Do not run tests in emulator unless explicitly requested.

## What Copilot should optimize for
- Preserve existing app behavior unless the prompt requests a behavior change.
- Favor maintainability and clarity over clever abstractions.
- Keep changes aligned with the current architecture instead of rewriting major areas.
- When making UI changes, consider impact on accessibility labels and UI tests.
- When making storage or networking changes, consider compatibility with existing saved data and existing endpoints.

## Important point

If any of the changes diverges from this instructions, especially when user asked notify the user and propose update to instructions. 
When testing in simulator use iPhone SE 2nd generation.
