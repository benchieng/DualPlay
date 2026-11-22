# DualPlay — two videos, one app, both soundtracks

Minimal SwiftUI demo proving the iPhone Duo loophole: the "one video at a time"
rule applies **between apps**. Inside a single app, two `AVPlayer`s run at once
and iOS mixes their audio, because the app owns one audio session and is never
interrupted by itself.

## CI (GitHub Actions)

Every push to `main` builds a **Release, unsigned, arm64 `DualPlay.app`** on a
macOS runner (`xcodegen` generates the project from `project.yml`, so the
`.xcodeproj` is never committed). Download it from the workflow run's
**Artifacts** → `DualPlay-unsigned`. Re-sign with your certificate/profile and
install — see "Signing" below.

## Signing

The CI artifact is deliberately unsigned (`CODE_SIGNING_ALLOWED=NO`). To make
it runnable on a device you need to codesign the `.app` (or repackage as an
`.ipa`) with a certificate plus a provisioning profile that includes your
iPhone's UDID — free personal-team or paid-program certs both work, e.g.:

```bash
codesign --force --deep -s "Apple Development: you@example.com (TEAMID)" DualPlay.app
# then drop it into Payload/ and zip into an .ipa, or use your resigning tool
```

## Run it locally (needs a Mac with Xcode 16+)

1. Xcode → File ▸ New ▸ Project ▸ iOS ▸ App.
   - Product name: `DualPlay`, Interface: SwiftUI, no Core Data.
2. Delete the generated `ContentView.swift` and `<Name>App.swift`, then drag in
   the two files from the `DualPlay/` folder.
3. Set the deployment target to **iOS 17.0** (uses `PhotosPicker` + `Transferable`).
4. Add your Mac as a device (or your Duo) under Settings ▸ General ▸
   Device Management for free personal-team signing, pick your phone, hit ▶.

No Info.plist keys and no photo-library permission are needed — `PhotosPicker`
runs out-of-process.

## Use

1. Tap **Load** under pane A, pick a video; repeat for pane B.
2. **Play Both**. Both clips run simultaneously with both soundtracks audible —
   blend them with the per-pane volume sliders. Each clip loops.
3. **Restart Both** re-syncs them to 0:00.
4. Unfold the Duo (or rotate to landscape) for a proper side-by-side.

## Notes

- Audio category is `.playback` (keeps playing when locked / backgrounded).
  Want it alongside Spotify etc.? Add `[.mixWithOthers]` in `Audio.configure()`.
- Swap the picker for bundled files: drop mp4s into the target and call
  `model.load(Bundle.main.url(forResource: "clip", withExtension: "mp4")!)`.
- Two 1080p streams are trivial for the A-series chip; several 4K HDR streams
  can exceed the hardware decoder budget. FairPlay DRM streams add per-stream
  license overhead.
- Duo extra: with iOS 27 multi-scene support you could later host each pane in
  its own scene (one per display) — same mixing rules apply.
