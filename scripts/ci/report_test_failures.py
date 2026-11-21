#!/usr/bin/env python3
"""Stream test output unchanged and annotate the first failed attempt immediately.

This is a stdout filter, not a verdict. Keep pipefail and the existing result,
retry and inventory verifiers. JSONL times measure this stream and a known item
start, not queue time or the workflow critical path. A later passing retry does
not erase an earlier observation; the complete xcresult still decides the job.
"""
import argparse
import datetime
import json
from pathlib import Path
import re
import sys
import time


CASE = re.compile(r"Test Case '-\[(?P<suite>[\w.]+) (?P<method>\w+)\]' "
                  r"(?P<state>started|passed|failed|skipped)(?: \(Iteration (?P<attempt>\d+) of \d+\))?")
XCTEST = re.compile(r"(?P<file>[^\r\n]+?\.swift):(?P<line>\d+)(?::\d+)?: error: "
                    r"-\[(?P<suite>[\w.]+) (?P<method>\w+)\] : (?P<assertion>.*)")
SWIFT_START = re.compile(r"◇ Test (?P<method>.+?) started\.")
SWIFT_ISSUE = re.compile(r"✘ Test (?P<method>.+?) recorded an issue at "
                        r"(?P<file>[^\r\n]+?\.swift):(?P<line>\d+):\d+: (?P<assertion>.*)")


def escape(value, prop=False):
    # Same escaping as actions/toolkit packages/core/src/command.ts.
    value = str(value).replace('%', '%25').replace('\r', '%0D').replace('\n', '%0A')
    return value.replace(':', '%3A').replace(',', '%2C') if prop else value


def source_path(value):
    # GitHub prepends a timestamp; the checkout path may be absolute. Never emit
    # an arbitrary runner path as a source annotation property.
    for prefix in ('Annex/AnnexUITests/', 'Annex/AnnexTests/', 'Tests/', 'Vendor/'):
        pos = value.find(prefix)
        if pos >= 0:
            path = value[pos:]
            if '..' not in Path(path).parts:
                return path
    name = Path(value).name
    return name if re.fullmatch(r'[\w.-]+\.swift', name) else None


class Reporter:
    def __init__(self, output, events, label, clock=time.monotonic):
        self.output, self.events, self.label, self.clock = output, events, label, clock
        self.started = clock()
        self.starts, self.attempts, self.reported = {}, {}, set()

    def failure(self, item, assertion, file=None, line=None):
        if item in self.reported:
            return
        self.reported.add(item)
        now = self.clock()
        elapsed = now - self.started
        item_elapsed = now - self.starts[item] if item in self.starts else None
        event = dict(label=self.label, item=item, assertion=assertion,
                     file=file, line=line, attempt=self.attempts.get(item),
                     stream_elapsed_seconds=round(elapsed, 3),
                     item_elapsed_seconds=round(item_elapsed, 3) if item_elapsed is not None else None,
                     observed_utc=datetime.datetime.now(datetime.timezone.utc).isoformat(),
                     final_verdict=False)
        self.events.write(json.dumps(event, ensure_ascii=False) + '\n')
        self.events.flush()
        props = {'title': 'First test failure; final result pending'}
        if file:
            props.update(file=file, line=line)
        fields = ','.join(f'{key}={escape(value, True)}' for key, value in props.items())
        message = f'{self.label}: {item}: {assertion}'
        self.output.write(f'::warning {fields}::{escape(message)}\n')
        self.output.flush()

    def consume(self, line):
        # Retain the original method/assertion and every other byte of decoded
        # output. tee before this filter retains the unmodified raw log as well.
        self.output.write(line)
        self.output.flush()
        text = line.rstrip('\n')
        match = CASE.search(text)
        if match:
            item = match['suite'] + '/' + match['method']
            if match['state'] == 'started':
                self.starts[item] = self.clock()
                self.attempts[item] = int(match['attempt'] or 1)
            elif match['state'] == 'failed':
                self.failure(item, 'Failed attempt; see the original test log for its diagnostic')
            return
        match = XCTEST.search(text)
        if match:
            self.failure(match['suite'] + '/' + match['method'], match['assertion'],
                         source_path(match['file']), int(match['line']))
            return
        match = SWIFT_START.search(text)
        if match:
            self.starts[match['method']] = self.clock()
            return
        match = SWIFT_ISSUE.search(text)
        if match:
            self.failure(match['method'], match['assertion'], source_path(match['file']), int(match['line']))


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--label', required=True)
    parser.add_argument('--events', required=True)
    args = parser.parse_args(argv)
    path = Path(args.events)
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open('w') as events:
        reporter = Reporter(sys.stdout, events, args.label)
        for line in sys.stdin:
            reporter.consume(line)
    return 0


if __name__ == '__main__':
    sys.exit(main())
