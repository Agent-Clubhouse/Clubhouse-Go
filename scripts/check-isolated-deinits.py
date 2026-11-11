#!/usr/bin/env python3
"""Check reviewed field-affinity policy against a Debug app's actual deinit symbols.

Field/constructor changes invalidate review fingerprints; new isolated classes require
classification. Never update the policy merely to suppress a failure: review owned
fields, callback captures and pointee deinits, then document the decision in the PR.
"""
import json
import pathlib
import re
import subprocess
import sys
from deinit_surface import extract

root = pathlib.Path(__file__).resolve().parent.parent
policy_path = 'scripts/isolated-deinit-policy.json'
policy = json.loads((root / policy_path).read_text())
binary = pathlib.Path(sys.argv[1])
symbols = subprocess.check_output(['xcrun', 'nm', '-j', str(binary)], text=True)
demangled = subprocess.check_output(['xcrun', 'swift-demangle'], input=symbols, text=True)
isolated = set()
for line in demangled.splitlines():
    if line.startswith('ClubhouseGo.') and line.endswith('.__isolated_deallocating_deinit'):
        name = line.removeprefix('ClubhouseGo.').removesuffix('.__isolated_deallocating_deinit')
        isolated.add(re.sub(r'\((\w+) in _[0-9A-F]+\)', r'\1', name))
errors = []
sources = [str(p.relative_to(root)) for p in (root / 'Annex/Annex').rglob('*.swift')]
surfaces = extract(root, sources)
for name in isolated - policy['classes'].keys():
    errors.append(
        f'{name}: add this class to {policy_path} and the docs/isolated-deinit.md ownership table. '
        'Use arc_only only after reviewing stored fields, constructor/callback captures and pointee teardown '
        'to prove off-main ARC is safe; then add an empty nonisolated deinit. '
        'Otherwise use main_actor and retain isolated teardown. Record the narrow stored-property/type and capture surfaces only after that review.'
    )
for name, entry in policy['classes'].items():
    mode = entry['policy']
    if mode not in ('arc_only', 'main_actor_task', 'main_actor', 'generated') or not entry['reason']:
        errors.append(f'{name}: invalid/missing teardown-affinity rationale')
    source = entry['source']
    if mode != 'generated' and not source:
        errors.append(f'{name}: {policy_path} requires the reviewed class source path for {mode}')
    if mode in ('arc_only', 'main_actor_task'):
        actual = surfaces.get(source, {}).get('classes', {}).get(name)
        if actual is None or entry.get('surface') != actual:
            errors.append(f'{name}: stored properties/types, base storage, or storage macros changed; review ownership and update only this class surface in {policy_path}')
        if '<requires explicit type>' in json.dumps(actual):
            errors.append(f'{name}: add an explicit stored-property type so ownership review does not depend on method implementations')
    if mode in ('arc_only', 'main_actor_task') and name in isolated:
        errors.append(f'{name}: {mode} policy requires an explicit nonisolated deinit')
    if mode == 'main_actor_task':
        actual_deinit = surfaces.get(source, {}).get('deinits', {}).get(name)
        if not entry.get('deinit') or actual_deinit != entry['deinit']:
            errors.append(f'{name}: deferred main-actor teardown changed; review retained UI owners and update the deinit policy only after proving destruction stays on MainActor inside a Swift task')
    if mode in ('main_actor', 'generated') and name not in isolated:
        errors.append(f'{name}: main-only/generated policy lost its isolated teardown; do not bypass UI field destruction')
    if mode == 'arc_only' and entry['source']:
        if 'nonisolated deinit {}' not in (root / entry['source']).read_text():
            errors.append(f'{name}: missing reviewed empty nonisolated deinit')
actual_sites = {path: data['captureSites'] for path, data in surfaces.items() if data['captureSites']}
for path in actual_sites.keys() | policy['captureSites'].keys():
    actual, expected = actual_sites.get(path, {}), policy['captureSites'].get(path, {})
    for site in actual.keys() | expected.keys():
        if actual.get(site) != expected.get(site):
            errors.append(f'{path}: {site} capture/producer site changed; review the captured owners and update this site in {policy_path} captureSites')
if errors:
    print('\n'.join(errors), file=sys.stderr)
    print(f'Review rules: {policy_path}; docs/isolated-deinit.md. Do not waive UI teardown affinity or refresh ownership surfaces without review.', file=sys.stderr)
    sys.exit(1)
print(f'Deinit policy: {sum(e["policy"] == "arc_only" for e in policy["classes"].values())} ARC-only protections; {sum(e["policy"] == "main_actor_task" for e in policy["classes"].values())} deferred main-actor protections; {len(isolated)} reviewed isolated paths retained. UI affinity is not waived.')
