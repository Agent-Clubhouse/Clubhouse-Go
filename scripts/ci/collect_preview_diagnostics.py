#!/usr/bin/env python3
"""Bound the optional preview-log read client; preserve partial output on failure.

This command never decides the native verdict or touches an app/simulator lifecycle.
The workflow keeps it continue-on-error and uploads the original results always.
"""
import argparse
import json
from pathlib import Path
import subprocess
import time

PREDICATE = ('eventMessage BEGINSWITH "CHAT_FOLLOW " OR '
             'eventMessage BEGINSWITH "CHAT_PHASE " OR '
             'eventMessage BEGINSWITH "CHAT_UP "')


def collect(simulator, output, seconds=20, run=subprocess.run, clock=time.monotonic):
    output = Path(output)
    output.parent.mkdir(parents=True, exist_ok=True)
    command = ['xcrun', 'simctl', 'spawn', simulator, 'log', 'show', '--last', '1h',
               '--style', 'compact', '--predicate', PREDICATE]
    started = clock()
    status, reason = 0, 'completed'
    # Direct file output preserves every byte already received if the owned local
    # read client times out; do not buffer until successful command completion.
    with output.open('wb') as stream:
        try:
            result = run(command, stdout=stream, stderr=subprocess.STDOUT,
                         timeout=seconds, check=False)
            status = result.returncode
            if status:
                reason = 'client failed'
        except subprocess.TimeoutExpired:
            # subprocess.run kills and waits for only its own local client.
            status, reason = 124, 'client timeout; partial output retained'
        except OSError:
            status, reason = 127, 'client unavailable; output may be empty'
    receipt = dict(reason=reason, client_exit=status, elapsed_s=round(clock()-started, 6),
                   client_timeout_s=seconds, output_bytes=output.stat().st_size,
                   complete_log=(status == 0), native_verdict_changed=False)
    output.with_suffix('.status.json').write_text(json.dumps(receipt, indent=2)+'\n')
    print('Optional preview diagnostics: ' + json.dumps(receipt), flush=True)
    return status if status >= 0 else 128-status


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('simulator')
    parser.add_argument('output', type=Path)
    args = parser.parse_args(argv)
    return collect(args.simulator, args.output)


if __name__ == '__main__':
    raise SystemExit(main())
