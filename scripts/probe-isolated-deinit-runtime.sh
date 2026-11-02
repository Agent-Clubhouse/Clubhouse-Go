#!/usr/bin/env bash
# Observation only, never a shard gate. No runtime guard: observe affected releases too.
# Pass only a disposable simulator UUID. Never accepts or operates on a physical device.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
exec python3 scripts/observe-isolated-deinit-runtime.py "${1:?Usage: scripts/probe-isolated-deinit-runtime.sh SIMULATOR_UUID}"
