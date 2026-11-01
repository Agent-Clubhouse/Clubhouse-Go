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
sources = [*output.glob('*.log'), *(fixture / name for name in ('desktop-stdout.log', 'desktop-stderr.log'))]
for file in sources:
    if not file.is_file():
        continue
    text = file.read_text(errors='replace')
    for secret in sorted(secrets, key=len, reverse=True):
        text = text.replace(secret, '<redacted>')
    (output / file.name).write_text(text)
