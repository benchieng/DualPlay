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
3. Set the deployment target to **iOS 17.0** (loading uses `UIDocumentPickerViewController` directly — `.fileImporter` and SwiftUI-wrapped pickers misbehave on iOS 27 iPhone).
4. Add your Mac as a device (or your Duo) under Settings ▸ General ▸
   Device Management for free personal-team signing, pick your phone, hit ▶.

No Info.plist keys and no photo-library permission are needed — the document
picker runs out-of-process.

## Use

1. Tap **Load** under pane A, pick a video; repeat for pane B.
2. **Play Both**. Both clips run simultaneously with both soundtracks audible —
   blend them with the per-pane volume sliders. Each clip loops.
3. **Restart Both** re-syncs them to 0:00.
4. Unfold the Duo (or rotate to landscape) for a proper side-by-side.
5. **⇄** swaps the panes, so you can put video A on the physical left screen
   and B on the right (book posture). Swapping and rotating/moving the Duo
   animate pane positions — playback and browser pages are not interrupted
   (panes keep their identity across layout flips).

The split-line geometry lives in `DualPlay/LayoutLogic.swift` as pure
functions (no UIKit), asserted on every CI run by `Tools/HostTests/` under
plain `swiftc` — no simulator needed.

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

## Duo field notes (from auditing Apollo-Reborn's Duo sidebar, PR #1765)

Lessons from production Duo code that apply to any two-pane Duo app:

1. **Posture is geometry, not device state.** UIKit reserves a *vertical
   division region* in the view when the Duo is half-open ("book") — that inset,
   not window size or a hinge API, is the reliable posture signal, because a
   side window can fake any aspect ratio. Current DualPlay uses a plain
   width>height rule; a real half-open posture check should read the division
   region and treat the two physical screens as content boundaries.
2. **Never re-lay-out video layers mid-transition.** Apollo hands pane width to
   pages as an extra safe-area inset so nothing is re-measured while panels
   open/close, and pauses → moves layers → resumes around fold/rotation.
   Two `AVPlayerLayer`s re-laid-out mid-fold glitch or hitch audio.
3. **Duo bugs live in teardown order.** Both real review findings on Apollo's PR
   were posture state leaking across the fold (insets reapplied after release).
   Per-posture state — pane sizes, fit/fill, scroll — must be released before
   it is re-derived. Required test: *fold to cover with a sheet open*.
4. **Extract layout decisions to pure logic.** Apollo keeps divider/rail
   geometry in small pure functions with ~230 host-runnable assertions.
   Pane→video assignment, fit/fill per posture, and gesture precedence belong
   in a testable layer, not only in SwiftUI layout.
5. **Gesture priority is an ordered list.** Native back-swipe > close overlay >
   pane-local swipe; encode it, don't let SwiftUI resolve it implicitly.
6. **Media needs human testing on a real Duo.** The whole thesis — two
   `AVPlayer`s mixing in one audio session — can't be signed off in a
   simulator. Use the matrix below.
7. **CI pins the exact Xcode.** `build.yml` selects `Xcode_27.2.0.app` by exact
   path and fails fast if missing; "newest installed" drifts silently when the
   runner image updates.

## Tested on

| Device | iOS | Build | Real/Sim | Result |
|---|---|---|---|---|
| iPhone Duo | 27.2 | latest-ci | real | dual AVPlayer mix confirmed; per-pane browser OK; blob-capture probe pending |
| iPhone (compact) | 27.2 | latest-ci | real | stacked layout OK |
| iPhone Duo | 27.2 | latest-ci (post-layout-rework) | real | **PENDING human test:** rotate/fold while both videos play — audio must not hitch, browser panes must not reload; ⇄ swaps panes; scrub still tracks |

The pending row is the field-notes rule in action: layout changes that touch
media transitions are only "working" once a person ran them on the hardware.

Fill a row for every media/gesture change before calling it working.
