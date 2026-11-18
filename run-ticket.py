#!/usr/bin/env python3
"""#570 guarded, bounded manifest runner. Invoke INSIDE the appropriate FIFO."""
import hashlib, importlib.util, json, os, re, signal, subprocess, sys, time
from pathlib import Path

R = Path('/tmp/ux-528-visible-proof')
M = json.loads((R / 'manifest.json').read_text())
PHASE, LABEL = sys.argv[1:3]
CFG = M['phases'][PHASE]
LIMIT = CFG['bound']
OUT = R / 'tickets' / LABEL
STATE = R / (LABEL + '-progress.json')
RECEIPT = R / (LABEL + '-receipt.json')
spec = importlib.util.spec_from_file_location('guard', '/tmp/ux-528-proof/a1-run.py')
g = importlib.util.module_from_spec(spec)
spec.loader.exec_module(g)
P = g.PREFIX
REPO = Path(M['source'])
BASE_FILE = 'Annex/AnnexTests/CompanionHomeVisibilityTests.swift'
METHOD = Path('/tmp/ux-557-proof/live-visible-method-r2.swift')
assert LABEL.replace('-', '').isalnum()

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def capture(args, cwd=REPO):
    return subprocess.check_output(P + args, cwd=cwd, text=True)

def vm_available(raw):
    page = re.search(r'page size of (\d+) bytes', raw)
    free = re.search(r'^Pages free:\s*(\d+)\.', raw, re.M)
    inactive = re.search(r'^Pages inactive:\s*(\d+)\.', raw, re.M)
    if not (page and free and inactive):
        raise ValueError('Cannot parse vm_stat free + inactive')
    page_bytes = int(page.group(1))
    return {'page_size_bytes': page_bytes, 'free_bytes': int(free.group(1)) * page_bytes,
            'inactive_bytes': int(inactive.group(1)) * page_bytes,
            'free_plus_inactive_bytes': (int(free.group(1)) + int(inactive.group(1))) * page_bytes}

def admission_guard():
    # One 10s window; refusal never waits or retries. Parent-approved global rule.
    swap_before = capture(['/usr/sbin/sysctl', 'vm.swapusage'])
    vm_before = capture(['/usr/bin/vm_stat'])
    top = capture(['/usr/bin/top', '-l', '2', '-s', '10', '-n', '0'])
    vm_after = capture(['/usr/bin/vm_stat'])
    swap_after = capture(['/usr/sbin/sysctl', 'vm.swapusage'])
    idle = re.findall(r'CPU usage:.*?([\d.]+)% idle', top)
    if len(idle) != 2:
        raise ValueError('Guard requires exactly two parseable CPU samples')
    memory = vm_available(vm_after)
    growth = g.swap_used(swap_after) - g.swap_used(swap_before)
    values = dict(policy='global-vm-stat-free-plus-inactive-8GiB',
                  authority='Orchestrator t_mwkvyvft global guard update before C2',
                  top=top, top_unused_informational_only=True,
                  vm_stat_before=vm_before, vm_stat_after=vm_after,
                  vm_memory_before=vm_available(vm_before), vm_memory_after=memory,
                  swap_before=swap_before, swap_after=swap_after,
                  cpu_idle_percent=float(idle[-1]), swap_growth_bytes=growth, window_seconds=10,
                  thresholds=dict(cpu_idle_percent=40, vm_free_plus_inactive_bytes=8*1024**3,
                                  swap_growth_bytes=64*1024**2))
    values['accepted'] = memory['free_plus_inactive_bytes'] >= 8*1024**3 and float(idle[-1]) >= 40 and growth <= 64*1024**2
    return values

def devices():
    return [d for group in json.loads(capture(['xcrun', 'simctl', 'list', 'devices', '-j']))['devices'].values() for d in group]

def save(state):
    tmp = STATE.with_suffix('.tmp')
    tmp.write_text(json.dumps(state, indent=2) + '\n')
    tmp.replace(STATE)

def run(args, path, cwd):
    print('+ ' + ' '.join(args), flush=True)
    with path.open('w') as stream:
        return subprocess.call(P + args, cwd=cwd, stdout=stream, stderr=subprocess.STDOUT)

def artifacts(dd):
    products = dd / 'Build/Products'
    selected = list(products.glob('*.xctestrun')) + list(products.rglob('*.debug.dylib'))
    for name in ('ClubhouseGoTests', 'ClubhouseGoUITests', 'ClubhouseGoUITests-Runner'):
        selected += [p for p in products.rglob(name) if p.is_file()]
    assert len(selected) >= 4, 'App, hosted/UI test and xctestrun fingerprints required'
    return {str(path): digest(path) for path in sorted(set(selected))}

def side_build(side):
    build = json.loads((R / ('success-A-' + side + '.json')).read_text())
    expected = capture(['git', 'rev-parse', M['base']]).strip() if side == 'before' else M['head']
    assert build['rc'] == 0 and build['head'] == expected, 'Exact successful build prerequisite'
    source, dd = Path(build['source']), Path(build['DD'])
    assert capture(['git', 'rev-parse', 'HEAD'], source).strip() == expected
    assert digest(source / BASE_FILE) == build['overlay']['file_sha256']
    assert capture(['git', 'diff', '--name-only'], source).splitlines() == [BASE_FILE]
    assert artifacts(dd) == build['artifact_sha256'], 'Built artifact drift'
    return build, source, dd

def prepare_build(state):
    side = PHASE.removeprefix('A-')
    head = capture(['git', 'rev-parse', M['base'] if side == 'before' else M['head']]).strip()
    source, dd = OUT / 'source', OUT / 'DD'
    assert digest(METHOD) == M['r2_method_sha256'], 'Identical r2 method required'
    subprocess.run(P + ['git', 'worktree', 'add', '--detach', str(source), head], cwd=REPO, check=True)
    target = source / BASE_FILE
    original = target.read_text()
    marker = '    @MainActor private final class Fixture {'
    assert original.count(marker) == 1 and 'import Darwin\n' not in original
    edited = original.replace('import XCTest\n', 'import XCTest\nimport Darwin\n', 1).replace(marker, METHOD.read_text() + marker, 1)
    target.write_text(edited)
    # Exact inverse proves the overlay changes only the import plus the byte-identical method.
    assert edited.replace('import Darwin\n', '', 1).replace(METHOD.read_text(), '', 1) == original
    patch = capture(['git', 'diff', '--', BASE_FILE], source)
    (OUT / 'measurement-overlay.diff').write_text(patch)
    assert capture(['git', 'diff', '--name-only'], source).splitlines() == [BASE_FILE]
    state.update(head=head, source=str(source), DD=str(dd), side=side,
                 overlay={'method_sha256': digest(METHOD), 'file_sha256': digest(target),
                          'base_file_sha256': hashlib.sha256(original.encode()).hexdigest(),
                          'patch_sha256': hashlib.sha256(patch.encode()).hexdigest(), 'additive_inverse_verified': True})
    save(state)
    common = ['xcodebuild', 'build-for-testing', '-project', 'Annex/Annex.xcodeproj', '-scheme', 'ClubhouseGo',
              '-configuration', 'Debug', '-jobs', '2', '-parallel-testing-enabled', 'NO', 'CODE_SIGNING_ALLOWED=NO',
              '-derivedDataPath', str(dd), '-destination', 'generic/platform=iOS Simulator']
    assert not dd.exists()
    state['build_rc'] = run(common, OUT / 'build.log', source)
    state['rc'] = state['build_rc']
    save(state)
    if not state['rc']:
        state['artifact_sha256'] = artifacts(dd)
        if side == 'after':
            dylibs = list((dd / 'Build/Products/Debug-iphonesimulator/ClubhouseGo.app').glob('*.debug.dylib'))
            assert len(dylibs) == 1
            state['deinit_rc'] = run(['python3', 'scripts/check-isolated-deinits.py', str(dylibs[0])], OUT / 'deinit.log', source)
            state['policy_rc'] = run(['python3', '-m', 'unittest', 'discover', '-s', 'scripts/deinit/tests'], OUT / 'policy.log', source)
            state['rc'] = 0 if state['deinit_rc'] == state['policy_rc'] == 0 else 1
        save(state)
    return state['rc']

def simulator(state):
    assert not any(d['state'] == 'Booted' for d in devices()), 'One Go simulator at a time'
    uuid_file = R / 'simulator-uuid.txt'
    if uuid_file.exists():
        uuid = uuid_file.read_text().strip()
    else:
        assert not any(d['name'] == M['simulator']['name'] for d in devices()), 'No orphan private simulator'
        uuid = capture(['xcrun', 'simctl', 'create', M['simulator']['name'],
                        'com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro-Max',
                        'com.apple.CoreSimulator.SimRuntime.iOS-26-0']).strip()
        uuid_file.write_text(uuid + '\n')
    state['simulator_uuid'] = uuid
    save(state)
    d = next(d for d in devices() if d['udid'] == uuid)
    assert d['name'] == M['simulator']['name'] and d['state'] == 'Shutdown'
    assert run(['xcrun', 'simctl', 'boot', uuid], OUT / 'boot.log', REPO) == 0
    assert run(['xcrun', 'simctl', 'bootstatus', uuid, '-b'], OUT / 'bootstatus.log', REPO) == 0
    state['postboot_resources_record_only'] = capture(['/usr/bin/top', '-l', '1', '-n', '0'])
    save(state)
    return uuid

def test_phase(state):
    live = PHASE.startswith('L-')
    side = PHASE.removeprefix('L-') if live else 'after'
    build, source, dd = side_build(side)
    state.update(head=build['head'], source=str(source), DD=str(dd), build_receipt=build['receipt_path'],
                 artifact_sha256=build['artifact_sha256'], overlay=build['overlay'])
    if PHASE == 'S' and (R / 'strict-fixture-identity.json').exists():
        identity = json.loads((R / 'strict-fixture-identity.json').read_text())
        assert identity['head'] == M['head'] and identity['product_tree_identical']
        assert digest(R / 'strict-fixture-identity.diff') == identity['diff_sha256']
        state['fixture_identity'] = identity
    save(state)
    if PHASE in ('S', 'B', 'C1', 'C2', 'C3'):
        gate = json.loads((R / 'live-gate.json').read_text())
        assert gate['pass'] and gate['head'] == M['head'], 'Zero-work live gate must pass before strict/broad'
    if PHASE in ('B', 'C1', 'C2', 'C3'):
        strict = json.loads((R / 'success-S.json').read_text())
        assert strict['rc'] == 0 and strict['head'] == M['head'], 'Strict prerequisite'
    uuid = simulator(state)
    target = 'ClubhouseGoUITests' if PHASE.startswith('C') else 'ClubhouseGoTests'
    common = ['xcodebuild', 'test-without-building', '-project', 'Annex/Annex.xcodeproj', '-scheme', 'ClubhouseGo',
              '-configuration', 'Debug', '-jobs', '2', '-parallel-testing-enabled', 'NO', 'CODE_SIGNING_ALLOWED=NO',
              '-derivedDataPath', str(dd), '-destination', 'platform=iOS Simulator,id=' + uuid]
    state['runs'] = []
    for index in range(CFG.get('invocations', 1)):
        out = OUT / ('run-' + str(index + 1))
        out.mkdir()
        row = {'selectors': CFG['selectors'], 'normal_dispatcher': PHASE == 'C3'}
        row['uninstall_rc'] = run(['xcrun', 'simctl', 'uninstall', uuid, 'com.Agent-Clubhouse.Go'], out / 'uninstall.log', source)
        result = out / 'tests.xcresult'
        assert not result.exists()
        row['result_bundle'] = str(result)
        row['test_rc'] = run(common + ['-resultBundlePath', str(result)] + ['-only-testing:' + s for s in CFG['selectors']], out / 'test.log', source)
        row['strict_rc'] = run(['python3', 'scripts/verify-xcresult.py', str(result), target, '--no-retries-in', target], out / 'strict.log', source)
        for key in ('summary', 'tests'):
            row[key + '_rc'] = run(['xcrun', 'xcresulttool', 'get', 'test-results', key, '--path', str(result)], out / (key + '.json'), source)
        row['attachments_rc'] = run(['xcrun', 'xcresulttool', 'export', 'attachments', '--path', str(result), '--output-path', str(out / 'attachments')], out / 'attachments.log', source)
        summary = json.loads((out / 'summary.json').read_text())
        row['exact_count_ok'] = summary['totalTestCount'] == len(CFG['selectors']) and summary['skippedTests'] == 0
        state['runs'].append(row)
        save(state)
        if not row['exact_count_ok'] or any(row[key] != 0 for key in ('test_rc', 'strict_rc', 'summary_rc', 'tests_rc', 'attachments_rc')):
            state['rc'] = 1
            save(state)
            return 1
    state['rc'] = 0
    save(state)
    return 0

def combined_coverage(state):
    for phase in ('S', 'B', 'C1', 'C2', 'C3', 'D'):
        receipt = json.loads((R / ('success-' + phase + '.json')).read_text())
        assert receipt['rc'] == 0 and receipt['head'] == M['head'], phase + ' prerequisite'
    subprocess.run(P + ['git', 'fetch', 'origin', 'main'], cwd=REPO, check=True)
    main = capture(['git', 'rev-parse', 'origin/main']).strip()
    common = capture(['git', 'merge-base', main, M['head']]).strip()
    ours = set(capture(['git', 'diff', '--name-only', common, M['head']]).splitlines())
    theirs = set(capture(['git', 'diff', '--name-only', common, main]).splitlines())
    state.update(current_main_at_execution=main, merge_base=common, overlap_files=sorted(ours & theirs))
    save(state)
    assert not state['overlap_files'], 'STOP: current-main overlap needs source review before merge/coverage'
    source = OUT / 'source'
    subprocess.run(P + ['git', 'worktree', 'add', '--detach', str(source), main], cwd=REPO, check=True)
    state['merge_rc'] = run(['git', 'merge', '--no-ff', '--no-edit', M['head']], OUT / 'merge.log', source)
    save(state)
    assert state['merge_rc'] == 0, 'STOP: merge conflict; do not resolve silently'
    state['combined_head'] = capture(['git', 'rev-parse', 'HEAD'], source).strip()
    state['source'] = str(source)
    assert not capture(['git', 'status', '--porcelain'], source).strip()
    assert not (source / '.build').exists(), 'Fresh combined coverage build required'
    shim = Path('/tmp/ux-528-proof/coverage-bin')
    state['swift_jobs'] = 2
    state['jobs_shim_sha256'] = digest(shim / 'swift')
    os.environ['PATH'] = str(shim) + os.pathsep + os.environ['PATH']
    save(state)
    state['coverage_rc'] = run(['bash', 'scripts/coverage.sh', '--check'], OUT / 'coverage.log', source)
    state['rc'] = state['coverage_rc']
    save(state)
    return state['rc']

def worker():
    state = {'head': M['head'], 'phase': PHASE, 'started_at': g.utc()}
    try:
        state['guard'] = admission_guard()
        save(state)
        print('GUARD ' + json.dumps({k: v for k, v in state['guard'].items() if k not in ('top', 'swap_before', 'swap_after')}), flush=True)
        if not state['guard']['accepted']:
            state['rc'] = 4
            save(state)
            return 4
        assert not OUT.exists(), 'Fresh label required'
        OUT.mkdir(parents=True)
        assert capture(['git', 'rev-parse', 'HEAD']).strip() == M['head']
        assert not capture(['git', 'status', '--porcelain']).strip(), 'Clean source required'
        if PHASE.startswith('A-'):
            return prepare_build(state)
        if PHASE in ('P', 'D'):
            state['test_rc'] = run(['swift', 'test', '--jobs', '2', '--scratch-path', str(R / 'package-build'), '--filter', CFG['filter']], OUT / 'swift-test.log', REPO)
            state['rc'] = state['test_rc']
            save(state)
            return state['rc']
        if PHASE == 'combined-coverage':
            return combined_coverage(state)
        return test_phase(state)
    except Exception as error:
        state.update(rc=1, error=str(error))
        save(state)
        print(str(error), flush=True)
        return 1

def cleanup(state):
    uuid = state.get('simulator_uuid')
    if uuid:
        d = next(d for d in devices() if d['udid'] == uuid)
        assert d['name'] == M['simulator']['name'], 'Exact private simulator only'
        if d['state'] != 'Shutdown':
            subprocess.run(P + ['xcrun', 'simctl', 'shutdown', uuid], timeout=45, check=True)
        state['simulator_final_state'] = next(d['state'] for d in devices() if d['udid'] == uuid)
        state['booted_after'] = [d['udid'] for d in devices() if d['state'] == 'Booted']

def supervisor():
    assert not STATE.exists() and not RECEIPT.exists(), 'Preserve previous receipts'
    started = time.monotonic()
    admitted = g.utc()
    child = subprocess.Popen([sys.executable, '-u', __file__, PHASE, LABEL, '--worker'], start_new_session=True)
    def stop(*unused): raise KeyboardInterrupt()
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    watch = {'record_only': True, 'samples': 0, 'growth_bytes': 0}
    try:
        while True:
            remaining = LIMIT - (time.monotonic() - started)
            if remaining <= 0: raise subprocess.TimeoutExpired(child.args, LIMIT)
            try: rc = child.wait(timeout=min(15, remaining)); done = True
            except subprocess.TimeoutExpired: done = False
            if STATE.exists():
                guard = json.loads(STATE.read_text()).get('guard', {})
                if guard.get('accepted'):
                    base = g.swap_used(guard['swap_after'])
                    current = g.swap_used(subprocess.check_output(['/usr/sbin/sysctl', 'vm.swapusage'], text=True))
                    watch.update(start_bytes=base, max_bytes=max(watch.get('max_bytes', base), current))
                    watch['growth_bytes'] = max(0, watch['max_bytes'] - base)
                    watch['exceeded_256MiB'] = watch['growth_bytes'] > 256 * 1024**2
                    watch['samples'] += 1
            if done: break
    except (subprocess.TimeoutExpired, KeyboardInterrupt) as error:
        os.killpg(child.pid, signal.SIGKILL)
        child.wait()
        rc = 124 if isinstance(error, subprocess.TimeoutExpired) else 143
    state = json.loads(STATE.read_text()) if STATE.exists() else {}
    state.update(rc=rc, admitted_at=admitted, closed_at=g.utc(), duration_seconds=time.monotonic()-started,
                 hard_bound_seconds=LIMIT, swap_watch=watch, receipt_path=str(RECEIPT))
    try: cleanup(state)
    except Exception as error: state.update(cleanup_error=str(error), rc=1); rc = 1
    RECEIPT.write_text(json.dumps(state, indent=2) + '\n')
    if rc == 0:
        (R / ('success-' + PHASE + '.json')).write_text(RECEIPT.read_text())
    print(json.dumps({k: v for k, v in state.items() if k != 'guard'}, indent=2), flush=True)
    return rc

if __name__ == '__main__':
    sys.exit(worker() if sys.argv[3:] == ['--worker'] else supervisor())
