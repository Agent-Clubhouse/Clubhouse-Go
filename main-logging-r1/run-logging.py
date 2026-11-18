#!/usr/bin/env python3
"""#569 one uncredited main DEBUG logging prefix; no product logic changes or retries."""
import hashlib, importlib.util, json, os, re, signal, subprocess, sys, time
from pathlib import Path
R=Path('/tmp/ux-569-logging-proof')
M=json.loads((R/'manifest.json').read_text())
PHASE,LABEL=sys.argv[1:3]
CFG=M['phases'][PHASE];LIMIT=CFG['bound']
OUT=R/'tickets'/LABEL;STATE=R/(LABEL+'-progress.json');RECEIPT=R/(LABEL+'-receipt.json')
REPO=Path(M['source'])
spec=importlib.util.spec_from_file_location('guard','/tmp/ux-528-proof/a1-run.py')
g=importlib.util.module_from_spec(spec);spec.loader.exec_module(g);P=g.PREFIX
assert LABEL.replace('-','').isalnum()
def digest(path):return hashlib.sha256(path.read_bytes()).hexdigest()
def capture(args,cwd=REPO):return subprocess.check_output(P+args,cwd=cwd,text=True)
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

def non_ui_payloads(dd):
    app = dd / 'Build/Products/Debug-iphonesimulator/ClubhouseGo.app'
    payloads = {str(p.relative_to(app)): digest(p) for p in app.rglob('*') if p.is_file()}
    assert any('ClubhouseGoTests.xctest' in p for p in payloads), 'Hosted payload must be included'
    assert 'ClubhouseGo.debug.dylib' in payloads
    return payloads

def verify_source(source):
    assert capture(['git','rev-parse','HEAD'], source).strip() == M['historical_product']
    assert capture(['git','diff','--name-only'], source).splitlines() == M['only_changed_files']
    assert len(capture(['git','status','--porcelain'],source).splitlines()) == 2
    assert all(digest(source/f)==v for f,v in M['expected_source_sha256'].items())
    assert digest(Path(M['patch'])) == M['patch_sha256']
    return dict(product_base=M['historical_product'], helper_head=M['head'],
                only_changed_files=M['only_changed_files'], patch_sha256=M['patch_sha256'],
                reading_sha256=M['patched_reading_sha256'])

def build(state):
    source, dd = OUT/'source', OUT/'DD'
    subprocess.run(P+['git','worktree','add','--detach',str(source),M['historical_product']],cwd=REPO,check=True)
    subprocess.run(P+['git','apply',M['patch']],cwd=source,check=True)
    state.update(source=str(source), DD=str(dd), source_provenance=verify_source(source), runner_sha256=digest(Path(__file__)))
    save(state)
    state['build_rc']=run(['xcodebuild','build-for-testing','-project','Annex/Annex.xcodeproj','-scheme','ClubhouseGo',
        '-configuration','Debug','-jobs','2','-parallel-testing-enabled','NO','CODE_SIGNING_ALLOWED=NO',
        '-derivedDataPath',str(dd),'-destination','generic/platform=iOS Simulator'],OUT/'build.log',source)
    state['rc']=state['build_rc'];save(state)
    if not state['rc']:
        state['artifact_sha256']=artifacts(dd)
        dylibs=list((dd/'Build/Products/Debug-iphonesimulator/ClubhouseGo.app').glob('*.debug.dylib'));assert len(dylibs)==1
        state['deinit_rc']=run(['python3','scripts/check-isolated-deinits.py',str(dylibs[0])],OUT/'deinit.log',source)
        state['policy_rc']=run(['python3','-m','unittest','discover','-s','scripts/deinit/tests'],OUT/'policy.log',source)
        state['rc']=0 if state['deinit_rc']==state['policy_rc']==0 else 1;save(state)
    return state['rc']

def test(state):
    prior=json.loads((R/'success-A.json').read_text());assert prior['rc']==0 and prior['head']==M['head']
    source,dd=Path(prior['source']),Path(prior['DD'])
    state['source_provenance']=verify_source(source)
    assert artifacts(dd)==prior['artifact_sha256'],'Artifact drift'
    assert not any(d['state']=='Booted' for d in devices()),'Only one Go simulator'
    uuid=capture(['xcrun','simctl','create',M['private_simulator']['name'],'com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro-Max','com.apple.CoreSimulator.SimRuntime.iOS-26-0']).strip()
    state.update(source=str(source),DD=str(dd),build_receipt=prior['receipt_path'],artifact_sha256=prior['artifact_sha256'],simulator_uuid=uuid)
    save(state)
    assert run(['xcrun','simctl','boot',uuid],OUT/'boot.log',source)==0
    assert run(['xcrun','simctl','bootstatus',uuid,'-b'],OUT/'bootstatus.log',source)==0
    assert run(['xcrun','simctl','spawn',uuid,'defaults','write','com.apple.keyboard.preferences','DidShowContinuousPathIntroduction','-bool','YES'],OUT/'quickpath-suppression.log',source)==0
    state['quickpath_suppression']=True
    state['postboot_resources_record_only']=capture(['/usr/bin/top','-l','1','-n','0'])
    result=OUT/'tests.xcresult';state['result_bundle']=str(result);save(state)
    state['test_rc']=run(['xcodebuild','test-without-building','-project','Annex/Annex.xcodeproj','-scheme','ClubhouseGo',
        '-configuration','Debug','-jobs','2','-parallel-testing-enabled','NO','CODE_SIGNING_ALLOWED=NO',
        '-derivedDataPath',str(dd),'-destination','platform=iOS Simulator,id='+uuid,'-resultBundlePath',str(result),
        '-test-timeouts-enabled','YES','-default-test-execution-time-allowance','360','-maximum-test-execution-time-allowance','360']
        +['-only-testing:'+s for s in CFG['selectors']],OUT/'test.log',source)
    for key in ['summary','tests']:
        state[key+'_rc']=run(['xcrun','xcresulttool','get','test-results',key,'--path',str(result)],OUT/(key+'.json'),source)
    state['attachments_rc']=run(['xcrun','xcresulttool','export','attachments','--path',str(result),'--output-path',str(OUT/'attachments')],OUT/'attachments.log',source)
    state['single_run_audit_rc']=run(['python3','/tmp/go-footer-560/audit-single-runs.py',str(result)],OUT/'single-run.log',source)
    details=json.loads(Path(str(result)+'.single-run-details.json').read_text())
    order=[k for k,v in sorted(details.items(),key=lambda x:x[1]['startTime'])]
    expected=json.loads(Path(M['original_order']).read_text())
    state['execution_order_identical']=order==expected
    (OUT/'actual-order.json').write_text(json.dumps(order,indent=2)+'\n')
    confirmation=json.loads(Path(M['original_case_map_receipt']).read_text())
    assert confirmation['diagnostic_scope_ok'] and confirmation.get('simulator_deleted')
    original=json.loads(Path(confirmation['result_bundle']+'.single-run-details.json').read_text())
    state['unrelated_case_map_identical']=all(details[k]['testResult']==original[k]['testResult'] for k in expected if k!=M['case'])
    state['target_result']=details[M['case']]['testResult']
    state['activity_rc']=run(['xcrun','xcresulttool','get','test-results','activities','--path',str(result),'--test-id',M['case']],OUT/'reading-activities.json',source)
    state['diagnostics_rc']=run(['xcrun','xcresulttool','export','diagnostics','--path',str(result),'--output-path',str(OUT/'diagnostics')],OUT/'diagnostics-export.log',source)
    state['trace_extract_rc']=run(['python3',str(R/'extract-reading-traces.py'),str(OUT)],OUT/'trace-extract.log',source)
    state['frames_summary_rc']=run(['python3','/tmp/ux-569-proof/summarize-frames.py',str(OUT)],OUT/'frames-summary.log',source)
    summary=json.loads((OUT/'summary.json').read_text())
    state['summary']=summary
    state['exact_count_ok']=summary['totalTestCount']==23 and summary['expectedFailures']==2 and summary['skippedTests']==1
    state['diagnostic_scope_ok']=state['exact_count_ok'] and state['execution_order_identical'] and state['unrelated_case_map_identical'] and state['single_run_audit_rc']==0 and state['diagnostics_rc']==state['trace_extract_rc']==state['frames_summary_rc']==0
    state['rc']=0 if state['diagnostic_scope_ok'] and state['test_rc']==0 and state['target_result']=='Passed' else 1
    save(state);return state['rc']


def worker():
    state={'head':M['head'],'phase':PHASE,'started_at':g.utc()}
    try:
        state['guard']=admission_guard();save(state)
        print('GUARD '+json.dumps({k:v for k,v in state['guard'].items() if k not in ['top','vm_stat_before','vm_stat_after','swap_before','swap_after']}),flush=True)
        if not state['guard']['accepted']:state['rc']=4;save(state);return 4
        assert not OUT.exists(),'Fresh label required';OUT.mkdir(parents=True)
        assert capture(['git','rev-parse','HEAD']).strip()==M['head']
        assert not capture(['git','status','--porcelain']).strip(),'Clean source required'
        if PHASE=='A':return build(state)
        if PHASE == 'C':return test(state)
        raise ValueError('Unknown phase')
    except Exception as error:
        state.update(rc=1,error=str(error));save(state);print(str(error),flush=True);return 1

def cleanup(state):
    uuid = state.get('simulator_uuid')
    if uuid:
        d = next(d for d in devices() if d['udid'] == uuid)
        assert d['name'] == M['private_simulator']['name'], 'Exact private simulator only'
        if d['state'] != 'Shutdown':
            subprocess.run(P + ['xcrun', 'simctl', 'shutdown', uuid], timeout=45, check=True)
        state['simulator_final_state_before_delete'] = next(d['state'] for d in devices() if d['udid'] == uuid)
        subprocess.run(P+['xcrun','simctl','delete',uuid],timeout=45,check=True)
        state['simulator_deleted'] = not any(d['udid']==uuid for d in devices())
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
