#!/usr/bin/env python3
"""Bounded simulator observation; outcomes are artifacts, never a test gate."""
import datetime
import json
import pathlib
import plistlib
import subprocess
import sys
import time
import traceback

BUNDLE = "com.agentclubhouse.issue218.probe"
MODES = ("outside", "inside", "explicit", "empty", "nonisolated", "unisolated", "after", "async")


def run_logged(command, path, timeout):
    # Open before spawning, and redirect directly: partial output survives timeout/cancellation.
    start = time.monotonic()
    result = {"command": command, "startedAt": datetime.datetime.now(datetime.timezone.utc).isoformat(),
              "timeoutSeconds": timeout, "timedOut": False, "returncode": None}
    with path.open("w") as log:
        log.write(json.dumps(result) + "\n")
        log.flush()
        with subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT) as child:
            try:
                result["returncode"] = child.wait(timeout=timeout)
            except subprocess.TimeoutExpired:
                result["timedOut"] = True
                # Only stop our simctl client here, never any host application.
                child.kill()
                child.wait()
        result["durationSeconds"] = round(time.monotonic() - start, 3)
        log.write("\nOBSERVER " + json.dumps(result) + "\n")
    return result


def classify(mode, result, log):
    # A completion marker followed by a stuck console/exit is still a timeout.
    if result["timedOut"]:
        return "timeout"
    if result["returncode"] != 0:
        return "command_failed"
    # simctl may return zero after SIGABRT. Missing markers are NOT proof of a crash.
    marker = f"PROBE passed mode={mode}"
    return "passed" if any(line == marker or line.startswith(marker + " ") for line in log.splitlines()) else "incomplete"


def timeout_diagnostics(uuid, out, mode):
    """Best effort: distinguish no launch, still-live process, and console-only wait."""
    path = out / f"{mode}-timeout.log"
    with path.open("w") as log:
        try:
            status = subprocess.run(["xcrun", "simctl", "spawn", uuid, "launchctl", "list"],
                                    capture_output=True, text=True, timeout=5)
            rows = [line for line in status.stdout.splitlines() if BUNDLE in line]
            log.write("probe launchctl rows: " + repr(rows) + "\n" + status.stderr)
            log.flush()
            for row in rows:
                pid = row.split()[0]
                if pid.isdecimal():
                    subprocess.run(["sample", pid, "1", "-file", str(out / f"{mode}-sample.log")],
                                   stdout=log, stderr=subprocess.STDOUT, timeout=5)
        except (subprocess.TimeoutExpired, OSError) as error:
            log.write(f"diagnostics unavailable: {error}\n")
    # Only our probe in the explicitly supplied disposable simulator. No Go app termination.
    try:
        run_logged(["xcrun", "simctl", "terminate", uuid, BUNDLE], out / f"{mode}-cleanup.log", 10)
    except OSError as error:
        with path.open("a") as log:
            log.write(f"cleanup unavailable: {error}\n")


def observe(uuid, out, total_seconds=270, mode_seconds=120):
    out.mkdir(parents=True, exist_ok=True)
    summary = {"simulator": uuid, "setup": "pending", "modes": []}
    # Every mode has an artifact even if setup or the overall budget prevents a launch.
    for mode in MODES:
        (out / f"{mode}.log").write_text("DEINIT_RUNTIME not_run: awaiting setup/budget\n")
        summary["modes"].append({"mode": mode, "outcome": "not_run"})
    (out / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    deadline = time.monotonic() + total_seconds

    def command(name, argv, limit=120):
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise RuntimeError("observation budget exhausted during setup")
        result = run_logged(argv, out / f"{name}.log", min(limit, remaining))
        if result["timedOut"] or result["returncode"] != 0:
            raise RuntimeError(f"{name}: {result}")
        return (out / f"{name}.log").read_text()

    try:
        command("devices", ["xcrun", "simctl", "list", "devices", "--json"])
        # Commands have a header/footer; keep structured command output separate from their logs.
        devices_text = (out / "devices.log").read_text().split("\n", 1)[1].rsplit("\nOBSERVER ", 1)[0]
        devices = json.loads(devices_text)["devices"]
        matches = [(runtime, device) for runtime, ds in devices.items() for device in ds if device["udid"] == uuid]
        if len(matches) != 1 or matches[0][1]["state"] != "Booted":
            raise RuntimeError("Expected one booted disposable simulator")
        summary["runtime"] = matches[0][0]
        print("DEINIT_RUNTIME simulator:", summary["runtime"], matches[0][1]["name"], flush=True)
        command("compiler", ["xcrun", "swiftc", "-version"])
        sdk = command("sdk", ["xcrun", "--sdk", "iphonesimulator", "--show-sdk-path"])
        sdk = sdk.split("\n", 1)[1].rsplit("\nOBSERVER ", 1)[0].strip()
        app = out / "Probe.app"
        app.mkdir(exist_ok=True)
        (app / "Info.plist").write_bytes(plistlib.dumps({"CFBundleExecutable": "Probe", "CFBundleIdentifier": BUNDLE,
            "CFBundleName": "Issue218Probe", "CFBundlePackageType": "APPL", "CFBundleVersion": "1",
            "CFBundleShortVersionString": "1", "MinimumOSVersion": "26.0", "LSRequiresIPhoneOS": True,
            "UIDeviceFamily": [1, 2]}))
        command("compile", ["xcrun", "swiftc", "-parse-as-library", "-swift-version", "5", "-default-isolation", "MainActor",
            "-target", "arm64-apple-ios26.0-simulator", "-sdk", sdk,
            "scripts/isolated-deinit-runtime-probe.swift", "-o", str(app / "Probe")])
        command("codesign", ["codesign", "--force", "--sign", "-", str(app)])
        command("install", ["xcrun", "simctl", "install", uuid, str(app)])
        summary["setup"] = "completed"
        for entry in summary["modes"]:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                break
            mode = entry["mode"]
            result = run_logged(["xcrun", "simctl", "launch", "--console", "--terminate-running-process", uuid, BUNDLE, mode],
                                out / f"{mode}.log", min(mode_seconds, remaining))
            text = (out / f"{mode}.log").read_text()
            entry.update(result, outcome=classify(mode, result, text))
            (out / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
            print(text, flush=True)
            print("DEINIT_RUNTIME", mode, entry["outcome"], flush=True)
            if result["timedOut"]:
                timeout_diagnostics(uuid, out, mode)
    except Exception:
        summary["error"] = traceback.format_exc()
        if summary["setup"] != "completed":
            summary["setup"] = "failed"
        (out / "observer-error.log").write_text(summary["error"])
        print(summary["error"], flush=True)
    finally:
        (out / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
        print("DEINIT_RUNTIME observation:", json.dumps(summary), flush=True)
    return summary


if __name__ == "__main__":
    observe(sys.argv[1], pathlib.Path("build/isolated-deinit-runtime").resolve())
    # Observation outcomes (including setup failures/timeouts) never gate tests or CI.
