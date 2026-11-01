#!/usr/bin/env python3
"""Remove isolated pairing/MCP secrets before live E2E logs become CI artifacts."""
import json
import pathlib
import sys

fixture, output = map(pathlib.Path, sys.argv[1:])
secrets = set()
for file in [fixture / 'invitation.json', *fixture.glob('mcp-*.json')]:
    try:
        data = json.loads(file.read_text())
    except (OSError, ValueError):
        continue
    for key in ('pin', 'CLUBHOUSE_HOOK_NONCE'):
        if value := data.get(key):
            secrets.add(str(value))
sources = [*output.glob('*.log'), *(fixture / name for name in ('desktop-stdout.log', 'desktop-stderr.log', 'dispatcher-wire.json', 'desktop-annex.json'))]
for file in sources:
    if not file.is_file():
        continue
    text = file.read_text(errors='replace')
    def redact(value):
        if isinstance(value, str):
            for secret in sorted(secrets, key=len, reverse=True):
                value = value.replace(secret, '<redacted>')
        elif isinstance(value, dict):
            value = {key: redact(item) for key, item in value.items()}
        elif isinstance(value, list):
            value = [redact(item) for item in value]
        return value
    text = json.dumps(redact(json.loads(text))) if file.suffix == '.json' else redact(text)
    (output / file.name).write_text(text)
