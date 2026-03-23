# E2E Testing Guide for Clubhouse Go

## Overview

Three layers of E2E testing, from fastest to most realistic:

### Layer 1: Mock Server Tests (Automated)

XCUI tests that pair the iOS app against a `MockAnnexServer` running on localhost.
The mock server handles real HTTP requests (POST /pair, GET /status).
UI data comes from `--test-snapshot` which loads MockData after pairing succeeds.

```bash
# Run all E2E tests
xcodebuild test -scheme Annex \
  -destination "platform=iOS Simulator,id=058FF012-6B95-455D-9E27-4D790305C8E7" \
  -only-testing:AnnexUITests/E2EPairingTests \
  -only-testing:AnnexUITests/E2EUITests

# Run just HTTP pairing tests
xcodebuild test -scheme Annex \
  -destination "platform=iOS Simulator,id=058FF012-6B95-455D-9E27-4D790305C8E7" \
  -only-testing:AnnexUITests/E2EPairingTests
```

### Layer 2: Launch Arguments (Manual Testing)

The app supports launch arguments for direct server connection:

| Argument | Description |
|----------|-------------|
| `--test-server host:port` | Bypass Bonjour discovery, connect directly to server |
| `--test-pin PIN` | Auto-submit pairing PIN |
| `--test-snapshot` | Load mock data after HTTP pairing (for UI testing) |
| `--ui-testing` | Load mock data without any networking |
| `--reset-onboarding` | Reset to welcome screen |

Example Xcode scheme setup for manual testing:
1. Edit scheme > Run > Arguments
2. Add `--test-server 127.0.0.1:63672` (use actual Clubhouse port)
3. Add `--test-pin` with the PIN from Clubhouse Settings > Go

### Layer 3: Isolated Clubhouse Desktop Instance

Launch a second, fully isolated Clubhouse instance for true end-to-end testing.
This does NOT affect the production Clubhouse instance.

```bash
# Launch isolated Clubhouse instance with separate data directory
CLUBHOUSE_USER_DATA=/tmp/clubhouse-e2e-data \
  /Applications/Clubhouse.app/Contents/MacOS/clubhouse &

# Wait for it to start, then check ports
lsof -iTCP -sTCP:LISTEN -P -n | grep clubhouse

# The isolated instance will:
# - Bind to different random ports (dynamic, port 0)
# - Have its own Bonjour service name
# - Have its own PIN (visible in its Settings > Go)
# - Have a separate identity and peer list
```

Then connect the simulator:
```bash
# Build and install to simulator
xcodebuild -scheme Annex -configuration Debug \
  -destination "platform=iOS Simulator,id=058FF012-6B95-455D-9E27-4D790305C8E7" \
  build

# Launch app on simulator with direct server connection
xcrun simctl launch booted com.Agent-Clubhouse.Annex \
  --test-server 127.0.0.1:PORT \
  --test-pin PIN
```

Clean up when done:
```bash
# Stop the isolated instance (NOT the production one!)
# Find the PID of the isolated instance by its CLUBHOUSE_USER_DATA
ps aux | grep "clubhouse-e2e-data"
kill <PID>
rm -rf /tmp/clubhouse-e2e-data
```

## Safety Notes

- Production Clubhouse runs on specific ports (check with `lsof`). Never kill it.
- The isolated instance uses `CLUBHOUSE_USER_DATA` for complete separation.
- All port binding is dynamic (port 0) — no conflicts possible.
- The mock server binds to random localhost ports — no interference.
- Simulator tests run on cloned simulator instances — no state leakage.
