# Simulator harness

A small app and tests for what `swift test` can't reach: real UIKit windows, sheets and the composer. It uses in-memory stores and a fake transport, so it opens no socket and uses no real invitation. It isn't part of the package and isn't in CI.

```sh
cd adapters/swift/Harness
xcodebuild test -project FramebriarHarness.xcodeproj -scheme FramebriarHarness \
  -destination 'platform=iOS Simulator,name=iPhone 16' -derivedDataPath "$(mktemp -d)"
```

- `UITests/` post the Darwin notification `com.apple.UIKit.SimulatorShake`, and the event goes through UIKit's own motion delivery.
- `UnitTests/` run hosted in the app and call `motionEnded` directly, to test the hook and routing with real windows.
- `ComposerUITests` also runs the report diagnostics modes through the real `FeedbackView`, including the override dropped after an enrollment change.
- `ScreenshotEditorUITests` runs zoom, the pen, redaction, Undo, Cancel, Done, Send and a shake through the real `FeedbackScreenshotEditor`, and compares the bytes the fake service received with the capture. Synthetic drags and pinches say nothing about how drawing feels on a device.
- `ShakeMultiSceneUITests` needs an iPad simulator, and skips itself when two scenes aren't on screen.

**Simulator-only.** That notification skips the device's sensors and anything iOS does before UIKit delivers the event, so these results say nothing about hardware or the Shake to Undo setting there.

In the shake tests, `count-chain` means the event reached `UIApplication`, past every window, which separates "the hook received it and the chain continued" from "the composer opened" (`count-perform` and the composer's navigation bar).
