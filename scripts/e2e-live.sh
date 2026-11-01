#!/usr/bin/env bash
# Live end-to-end test of Clubhouse Go against a real Clubhouse desktop.
#
#   scripts/e2e-live.sh [--desktop-ref <ref>] [--simulator <name|udid>] [--only <TestClass[/testMethod]>]
#                       [--skip-desktop-build] [--skip-ios-build] [--keep-simulator] [--shared-simulator]
#
# 1. Checks out the desktop (Agent-Clubhouse/Clubhouse) at a pinned ref, default main, into .desktop/ and builds its
#    webpack bundle (npm ci + electron-forge package). Meanwhile it builds Clubhouse Go for testing.
# 2. Launches the desktop through scripts/e2e-live/desktop-fixture.spec.ts: a disposable profile, Annex loopback-only
#    and ephemeral, and the desktop's scripted fake Claude CLI, so no model is called and no tokens are spent.
# 3. Waits for its Annex endpoint and the pairing invitation the fixture mints.
# 4. Runs CompanionLiveE2ETests on a new simulator of the chosen model (--shared-simulator uses the existing device),
#    passing the invitation to the app in memory.
# 5. Tears everything down: the desktop, its profile and the simulator.
#
# Results land in build/e2e-live/ (override with E2E_OUT_DIR): LiveE2E.xcresult, xcodebuild and desktop logs.
# Environment: DESKTOP_REF, DESKTOP_REPO, DESKTOP_DIR, E2E_SIMULATOR, E2E_OUT_DIR, E2E_SKIP_DESKTOP_CHECKOUT=1 (build
# DESKTOP_DIR as it is checked out). See docs/testing.md.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DESKTOP_REF="${DESKTOP_REF:-main}"
DESKTOP_REPO="${DESKTOP_REPO:-https://github.com/Agent-Clubhouse/Clubhouse.git}"
DESKTOP_DIR="${DESKTOP_DIR:-$ROOT/.desktop}"
SIMULATOR="${E2E_SIMULATOR:-iPhone 17 Pro}"
OUT="${E2E_OUT_DIR:-$ROOT/build/e2e-live}"
DERIVED="${E2E_DERIVED_DATA:-$ROOT/build/e2e-live-dd}"
ONLY="ClubhouseGoUITests/CompanionLiveE2ETests"
BUILD_DESKTOP=1
BUILD_IOS=1
KEEP_SIMULATOR=0
SHARED_SIMULATOR=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --desktop-ref) DESKTOP_REF="$2"; shift 2 ;;
    --simulator) SIMULATOR="$2"; shift 2 ;;
    --only) ONLY="ClubhouseGoUITests/${2#ClubhouseGoUITests/}"; shift 2 ;;
    --skip-desktop-build) BUILD_DESKTOP=0; shift ;;
    --skip-ios-build) BUILD_IOS=0; shift ;;
    --keep-simulator) KEEP_SIMULATOR=1; shift ;;
    --shared-simulator) SHARED_SIMULATOR=1; shift ;;
    -h|--help) sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

log() { printf '\n==> [%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

mkdir -p "$OUT"
rm -rf "$OUT/LiveE2E.xcresult" "$OUT"/*.log "$OUT/dispatcher-wire.json"
# Under /tmp, not $TMPDIR: macOS's $TMPDIR resolves into /private/var, where the desktop won't open a terminal.
FIXTURE_DIR="$(mktemp -d /tmp/clubhouse-go-e2e.XXXXXX)"
FIXTURE_PID=""
IOS_BUILD_PID=""
BOOTED_SIMULATOR=""
CREATED_SIMULATOR=""
UDID=""

teardown() {
  local status=$?
  set +e
  log "Tearing down"
  if [[ -n "$IOS_BUILD_PID" ]] && kill -0 "$IOS_BUILD_PID" 2>/dev/null; then kill "$IOS_BUILD_PID"; fi
  if [[ -n "$UDID" ]]; then xcrun simctl terminate "$UDID" com.Agent-Clubhouse.Go >/dev/null 2>&1; fi
  if [[ -n "$FIXTURE_PID" ]] && kill -0 "$FIXTURE_PID" 2>/dev/null; then
    touch "$FIXTURE_DIR/stop"
    for _ in $(seq 1 30); do kill -0 "$FIXTURE_PID" 2>/dev/null || break; sleep 1; done
    # Only ever the processes this script started: the Playwright runner and the desktop it launched.
    if kill -0 "$FIXTURE_PID" 2>/dev/null; then
      local desktop_pid; desktop_pid="$(cat "$FIXTURE_DIR/desktop.pid" 2>/dev/null)"
      [[ -n "$desktop_pid" ]] && kill "$desktop_pid" 2>/dev/null
      kill "$FIXTURE_PID" 2>/dev/null
    fi
  fi
  # The fake child's nonce stays in the 0600 temp files. Scrub desktop diagnostics before artifact upload.
  python3 "$ROOT/scripts/e2e-live/redact-logs.py" "$FIXTURE_DIR" "$OUT" || {
    echo "Log redaction failed; removing logs rather than uploading unsanitized diagnostics" >&2
    rm -f "$OUT"/*.log "$OUT/dispatcher-wire.json"
  }
  if [[ -n "$BOOTED_SIMULATOR" && "$KEEP_SIMULATOR" == 0 ]]; then xcrun simctl shutdown "$BOOTED_SIMULATOR" >/dev/null 2>&1; fi
  if [[ -n "$CREATED_SIMULATOR" && "$KEEP_SIMULATOR" == 0 ]]; then xcrun simctl delete "$CREATED_SIMULATOR" >/dev/null 2>&1; fi
  rm -f "$DESKTOP_DIR/e2e/phone-live/desktop-fixture.spec.ts" 2>/dev/null
  rm -rf "$FIXTURE_DIR"
  if [[ $status -eq 0 ]]; then log "Live E2E passed"; else log "Live E2E failed (exit $status); see $OUT"; fi
  exit $status
}
trap teardown EXIT
trap 'exit 130' INT TERM

# --- Simulator -------------------------------------------------------------------------------------------------
resolve_simulator() {
  xcrun simctl list devices available -j | python3 -c '
import json, sys
want = sys.argv[1]
devices = json.load(sys.stdin)["devices"]
runtimes = sorted((r for r in devices if "iOS" in r), key=lambda r: [int(x) for x in r.rsplit("iOS-", 1)[-1].split("-") if x.isdigit()], reverse=True)
for match in (lambda d: d["udid"] == want, lambda d: d["name"] == want, lambda d: d["name"].startswith("iPhone")):
    for r in runtimes:
        for d in devices[r]:
            if match(d):
                print(d["udid"], d["state"], d["name"], d["deviceTypeIdentifier"], r, sep="\t"); sys.exit(0)
sys.exit(1)' "$SIMULATOR"
}
IFS=$'\t' read -r UDID SIM_STATE SIM_NAME SIM_TYPE SIM_RUNTIME < <(resolve_simulator) || die "No iOS simulator matches '$SIMULATOR'"
[[ "$SIM_NAME" == "$SIMULATOR" || "$UDID" == "$SIMULATOR" ]] || echo "warning: '$SIMULATOR' not found; using $SIM_NAME" >&2
if [[ "$SHARED_SIMULATOR" == 1 ]]; then
  log "Simulator: $SIM_NAME ($UDID, $SIM_STATE)"
  if [[ "$SIM_STATE" != "Booted" ]]; then
    xcrun simctl boot "$UDID"
    BOOTED_SIMULATOR="$UDID"
  fi
else
  # A device of our own: on a dev Mac, other builds and agents boot, drive and shut down the usual simulators, which
  # crashed runs and launched the same app mid-test. It is deleted at teardown.
  UDID="$(xcrun simctl create "Clubhouse Go Live E2E ($SIM_NAME)" "$SIM_TYPE" "$SIM_RUNTIME")"
  CREATED_SIMULATOR="$UDID"
  log "Simulator: a new $SIM_NAME ($UDID, ${SIM_RUNTIME##*.})"
  xcrun simctl boot "$UDID"
  BOOTED_SIMULATOR="$UDID"
fi
DEST="platform=iOS Simulator,id=$UDID"

# --- Clubhouse Go build (in the background while the desktop builds) -------------------------------------------
if [[ "$BUILD_IOS" == 1 ]]; then
  log "Building Clubhouse Go for testing (log: $OUT/xcodebuild-build.log)"
  xcodebuild build-for-testing \
    -project "$ROOT/Annex/Annex.xcodeproj" -scheme ClubhouseGo -destination "$DEST" \
    -derivedDataPath "$DERIVED" CODE_SIGNING_ALLOWED=NO ASSETCATALOG_COMPILER_SKIP_MIGRATION_CHECK=YES \
    > "$OUT/xcodebuild-build.log" 2>&1 &
  IOS_BUILD_PID=$!
fi

# --- Desktop checkout and build --------------------------------------------------------------------------------
if [[ ! -d "$DESKTOP_DIR/.git" ]]; then
  log "Cloning $DESKTOP_REPO into $DESKTOP_DIR"
  git clone --quiet --filter=blob:none "$DESKTOP_REPO" "$DESKTOP_DIR"
fi
if [[ "$BUILD_DESKTOP" == 1 && "${E2E_SKIP_DESKTOP_CHECKOUT:-0}" != 1 ]]; then
  log "Checking out desktop $DESKTOP_REF"
  git -C "$DESKTOP_DIR" fetch --quiet origin "$DESKTOP_REF" 2>/dev/null || git -C "$DESKTOP_DIR" fetch --quiet origin
  git -C "$DESKTOP_DIR" checkout --quiet --detach FETCH_HEAD 2>/dev/null || git -C "$DESKTOP_DIR" checkout --quiet --detach "$DESKTOP_REF"
fi
DESKTOP_SHA="$(git -C "$DESKTOP_DIR" rev-parse HEAD)"
echo "$DESKTOP_SHA" > "$OUT/desktop-sha.txt"
log "Desktop at $DESKTOP_SHA"

if [[ "$BUILD_DESKTOP" == 1 ]]; then
  (
    cd "$DESKTOP_DIR"
    # npm ci only when the lockfile changed since the last install here.
    lock_hash="$(shasum -a 256 package-lock.json | cut -d' ' -f1)"
    if [[ ! -f node_modules/.e2e-live-lock || "$(cat node_modules/.e2e-live-lock)" != "$lock_hash" ]]; then
      log "npm ci (log: $OUT/desktop-npm.log)"
      npm ci --no-audit --no-fund > "$OUT/desktop-npm.log" 2>&1 || { tail -40 "$OUT/desktop-npm.log"; exit 1; }
      echo "$lock_hash" > node_modules/.e2e-live-lock
    fi
    # The webpack bundle only when the desktop commit changed since the last build here.
    if [[ ! -f .webpack/.e2e-live-sha || "$(cat .webpack/.e2e-live-sha)" != "$DESKTOP_SHA" ]]; then
      log "Building the desktop (electron-forge package; log: $OUT/desktop-build.log)"
      npx electron-forge package > "$OUT/desktop-build.log" 2>&1 || { tail -60 "$OUT/desktop-build.log"; exit 1; }
      echo "$DESKTOP_SHA" > .webpack/.e2e-live-sha
    fi
  ) || die "Desktop build failed"
fi
[[ -d "$DESKTOP_DIR/.webpack" ]] || die "No desktop build at $DESKTOP_DIR/.webpack; run without --skip-desktop-build"

# --- Desktop fixture -------------------------------------------------------------------------------------------
log "Launching the desktop fixture (log: $OUT/desktop-fixture.log)"
mkdir -p "$DESKTOP_DIR/e2e/phone-live"
cp "$ROOT/scripts/e2e-live/desktop-fixture.spec.ts" "$DESKTOP_DIR/e2e/phone-live/desktop-fixture.spec.ts"
(
  cd "$DESKTOP_DIR"
  # The isolated profile flags are set by the fixture itself; nothing inherits the user's Clubhouse profile.
  unset CLUBHOUSE_USER_DATA
  E2E_FIXTURE_DIR="$FIXTURE_DIR" exec npx playwright test e2e/phone-live/desktop-fixture.spec.ts \
    --reporter=line --retries=0 --timeout=0
) > "$OUT/desktop-fixture.log" 2>&1 &
FIXTURE_PID=$!

for _ in $(seq 1 180); do
  [[ -s "$FIXTURE_DIR/invitation.json" ]] && break
  kill -0 "$FIXTURE_PID" 2>/dev/null || { tail -60 "$OUT/desktop-fixture.log"; die "The desktop fixture exited before Annex was ready"; }
  sleep 1
done
[[ -s "$FIXTURE_DIR/invitation.json" ]] || { tail -60 "$OUT/desktop-fixture.log"; die "Timed out waiting for the desktop's Annex endpoint"; }
PORT="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["port"])' "$FIXTURE_DIR/invitation.json")"
log "Desktop Annex is listening on 127.0.0.1:$PORT"

# --- Live UI tests ---------------------------------------------------------------------------------------------
if [[ -n "$IOS_BUILD_PID" ]]; then
  log "Waiting for the Clubhouse Go build"
  wait "$IOS_BUILD_PID" || { IOS_BUILD_PID=""; tail -60 "$OUT/xcodebuild-build.log"; die "Clubhouse Go build failed"; }
  IOS_BUILD_PID=""
fi
xcrun simctl bootstatus "$UDID" -b > /dev/null
# A stale installed runner has run old tests; install both fresh.
for bundle in com.Agent-Clubhouse.Go com.Agent-Clubhouse.GoUITests.xctrunner; do xcrun simctl uninstall "$UDID" "$bundle" 2>/dev/null || true; done

fixture() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$FIXTURE_DIR/agents.json" "$1"; }

# The invitation reaches the app in memory: the runner reads TEST_RUNNER_ variables without the prefix and passes it in
# the app's launch environment. It pairs only with this loopback, ephemeral desktop, which is gone after teardown;
# still, xcodebuild prints the launch environment when a launch fails, so the log is scrubbed.
run_tests() {
  rm -rf "$OUT/LiveE2E.xcresult"
  TEST_RUNNER_CLUBHOUSE_RUN_LIVE_E2E=1 \
  TEST_RUNNER_CLUBHOUSE_COMPANION_TEST_INVITATION="$(cat "$FIXTURE_DIR/invitation.json")" \
  TEST_RUNNER_CLUBHOUSE_E2E_PROJECT="$(fixture project)" \
  TEST_RUNNER_CLUBHOUSE_E2E_ECHO_AGENT="$(fixture echo)" \
  TEST_RUNNER_CLUBHOUSE_E2E_BUILDER_AGENT="$(fixture builder)" \
  TEST_RUNNER_CLUBHOUSE_E2E_FIXTURE_DIR="$FIXTURE_DIR" \
  xcodebuild test-without-building \
    -project "$ROOT/Annex/Annex.xcodeproj" -scheme ClubhouseGo -destination "$DEST" \
    -derivedDataPath "$DERIVED" -only-testing:"$ONLY" \
    -parallel-testing-enabled NO -test-timeouts-enabled YES -default-test-execution-time-allowance 300 \
    -retry-tests-on-failure -test-iterations 2 \
    CODE_SIGNING_ALLOWED=NO -resultBundlePath "$OUT/LiveE2E.xcresult" \
    2>&1 | sed -E 's/("?CLUBHOUSE_COMPANION_TEST_INVITATION"? = ).*/\1"<redacted>";/' > "$1" || true
}

log "Running $ONLY (log: $OUT/xcodebuild-test.log)"
run_tests "$OUT/xcodebuild-test.log"
# A simulator crash ("server died", a failed launch) aborts the whole xcodebuild run, which per-test retries can't
# recover. Reboot the simulator and run the suite once more; the tests cope with what the first attempt left.
if grep -qE "server died|Failed to launch app|Test runner exited|Lost connection to the test manager" "$OUT/xcodebuild-test.log"; then
  log "The simulator crashed; rebooting it and running again (log: $OUT/xcodebuild-test-retry.log)"
  xcrun simctl shutdown "$UDID" >/dev/null 2>&1 || true
  xcrun simctl boot "$UDID"
  BOOTED_SIMULATOR="$UDID"
  xcrun simctl bootstatus "$UDID" -b > /dev/null
  run_tests "$OUT/xcodebuild-test-retry.log"
  grep -E "^Test (Case|Suite)|error:|Executed" "$OUT/xcodebuild-test-retry.log" | tail -60 || true
else
  grep -E "^Test (Case|Suite)|error:|Executed" "$OUT/xcodebuild-test.log" | tail -60 || true
fi
python3 "$ROOT/scripts/verify-xcresult.py" "$OUT/LiveE2E.xcresult"
