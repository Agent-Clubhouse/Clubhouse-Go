# Simulator harness

A small app and tests for what `swift test` can't reach: real UIKit windows, sheets and the composer. It uses in-memory stores and a fake transport, so it opens no socket and uses no real invitation. It isn't part of the package and isn't in CI.

```sh
cd adapters/swift/Harness
xcodebuild test -project FramebriarHarness.xcodeproj -scheme FramebriarHarness \
  -destination 'platform=iOS Simulator,name=iPhone 16' -derivedDataPath "$(mktemp -d)"
```

- `UITests/` post the Darwin notification `com.apple.UIKit.SimulatorShake`, and the event goes through UIKit's own motion delivery.
- `UnitTests/` run hosted in the app and call `motionEnded` directly, to test the hook and routing with real windows.
- `ShakeMultiSceneUITests` needs an iPad simulator, and skips itself when two scenes aren't on screen.

**Simulator-only.** That notification skips the device's sensors and anything iOS does before UIKit delivers the event, so these results say nothing about hardware or the Shake to Undo setting there.

In the shake tests, `count-chain` means the event reached `UIApplication`, past every window, which separates "the hook received it and the chain continued" from "the composer opened" (`count-perform` and the composer's navigation bar).
