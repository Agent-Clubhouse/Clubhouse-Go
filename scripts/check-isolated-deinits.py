#!/usr/bin/env python3
"""Check reviewed field-affinity policy against a Debug app's actual deinit symbols.

Field/constructor changes invalidate review fingerprints; new isolated classes require
classification. Never update the policy merely to suppress a failure: review owned
fields, callback captures and pointee deinits, then document the decision in the PR.
"""
import hashlib
import json
import pathlib
import re
import subprocess
import sys

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
for source, expected in policy['reviewedSources'].items():
    if hashlib.sha256((root / source).read_bytes()).hexdigest() != expected:
        errors.append(f'{source}: field/ownership review is stale; re-review before changing its fingerprint')
for name in isolated - policy['classes'].keys():
    errors.append(
        f'{name}: add this class to {policy_path} and the docs/isolated-deinit.md ownership table. '
        'Use arc_only only after reviewing stored fields, constructor/callback captures and pointee teardown '
        'to prove off-main ARC is safe; then add an empty nonisolated deinit. '
        'Otherwise use main_actor and retain isolated teardown. Record reviewed source fingerprints only after that review.'
    )
for name, entry in policy['classes'].items():
    mode = entry['policy']
    if mode not in ('arc_only', 'main_actor', 'generated') or not entry['reason']:
        errors.append(f'{name}: invalid/missing teardown-affinity rationale')
    source = entry['source']
    if mode != 'generated' and not source:
        errors.append(f'{name}: {policy_path} requires the reviewed class source path for {mode}')
    if source and source not in policy['reviewedSources']:
        errors.append(f'{name}: add {source} to {policy_path} reviewedSources only after field/capture ownership review')
    if mode == 'arc_only' and name in isolated:
        errors.append(f'{name}: ARC-only policy requires an explicit nonisolated deinit')
    if mode in ('main_actor', 'generated') and name not in isolated:
        errors.append(f'{name}: main-only/generated policy lost its isolated teardown; do not bypass UI field destruction')
    if mode == 'arc_only' and entry['source']:
        if 'nonisolated deinit {}' not in (root / entry['source']).read_text():
            errors.append(f'{name}: missing reviewed empty nonisolated deinit')
for name, allowed in policy['reviewedConstructorFiles'].items():
    for source in (root / 'Annex/Annex').rglob('*.swift'):
        text = re.sub(r'\b(?:class|extension)\s+' + name + r'\b', '', source.read_text())
        if re.search(r'\b' + name + r'\s*(?:<[^>]*>\s*)?(?:\(|\{)', text):
            if str(source.relative_to(root)) not in allowed:
                errors.append(f'{source.relative_to(root)}: new {name} constructor needs capture/value ownership review')
for name, allowed in policy['reviewedCallbackFiles'].items():
    for source in (root / 'Annex/Annex').rglob('*.swift'):
        if re.search(r'\.' + name + r'\s*=', source.read_text()):
            if str(source.relative_to(root)) not in allowed:
                errors.append(f'{source.relative_to(root)}: new {name} assignment needs capture-affinity review')
if errors:
    print('\n'.join(errors), file=sys.stderr)
    print(f'Review rules: {policy_path}; docs/isolated-deinit.md. Do not waive UI teardown affinity or refresh fingerprints without ownership review.', file=sys.stderr)
    sys.exit(1)
print(f'Deinit policy: {sum(e["policy"] == "arc_only" for e in policy["classes"].values())} ARC-only protections; {len(isolated)} reviewed isolated paths retained. UI affinity is not waived.')
