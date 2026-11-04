#!/usr/bin/env python3
"""Retry a stalled bootstatus client once, without restarting the simulator.

Two bounded clients fit inside the existing five-minute CI step. The simulator
continues booting between them; an unhealthy device still fails the step.
"""
import subprocess
import sys


def wait_for_boot(simulator, run=subprocess.run):
    for attempt, budget in enumerate((120, 150), start=1):
        try:
            run(["xcrun", "simctl", "bootstatus", simulator, "-b"], check=True, timeout=budget)
            return 0
        except (subprocess.TimeoutExpired, subprocess.CalledProcessError) as error:
            print(f"bootstatus attempt {attempt}/2 failed: {type(error).__name__}", flush=True)
    return 1


if __name__ == "__main__":
    sys.exit(wait_for_boot(sys.argv[1]))
