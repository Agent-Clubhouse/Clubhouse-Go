#!/usr/bin/env python3
"""#569 deterministic test-only fail-before; no product restoration logic changes or retries."""
import hashlib, importlib.util, json, os, re, signal, subprocess, sys, time
from pathlib import Path
R=Path('/tmp/ux-569-prefix-proof')
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
    assert capture(['git','rev-parse','HEAD'],source).strip()==M['head']
    assert not capture(['git','status','--porcelain'],source).strip()
    assert all(digest(source/f)==v for f,v in M['source_sha256'].items())
    core=['Annex/Annex/Companion/Views/CompanionConversationView.swift',
          'Annex/Annex/Companion/Domain/CompanionReadingPosition.swift',
          'Annex/Annex/Companion/Domain/CompanionMessageSlices.swift']
    assert not capture(['git','diff',M['main_base'],'HEAD','--']+core,source).strip()
    return dict(head=M['head'], main_base=M['main_base'], source_sha256=M['source_sha256'], core_diff_empty=True)

def build(state):
    if CFG.get('gate_only_from'):
        prior=json.loads(Path(CFG['gate_only_from']).read_text())
        assert prior['phase']=='A' and prior['build_rc']==0 and prior['rc']==1
        assert prior['deinit_rc']==1 and prior['policy_rc']==0
        source,dd=Path(prior['source']),Path(prior['DD'])
        assert artifacts(dd)==prior['artifact_sha256']
        assert capture(['git','rev-parse','HEAD'],source).strip()==prior['head']
        assert not capture(['git','status','--porcelain'],source).strip()
        changed=capture(['git','diff','--name-only',prior['head'],M['head']],source).splitlines()
        assert sorted(changed)==['docs/isolated-deinit.md','scripts/isolated-deinit-policy.json']
        subprocess.run(P+['git','checkout','--detach',M['head']],cwd=source,check=True)
        state['gate_only_from']=CFG['gate_only_from']
        state['build_origin_head']=prior['head']
    elif CFG.get('incremental_from'):
        prior=json.loads(Path(CFG['incremental_from']).read_text())
        assert prior['phase']=='A' and prior['rc']==65 and prior.get('build_rc')==65
        source,dd=Path(prior['source']),Path(prior['DD'])
        assert capture(['git','rev-parse','HEAD'],source).strip()==prior['head']
        assert not capture(['git','status','--porcelain'],source).strip()
        subprocess.run(P+['git','merge-base','--is-ancestor',prior['head'],M['head']],cwd=source,check=True)
        subprocess.run(P+['git','checkout','--detach',M['head']],cwd=source,check=True)
        state['incremental_from']=CFG['incremental_from']
    else:
        source, dd = OUT/'source', OUT/'DD'
        subprocess.run(P+['git','worktree','add','--detach',str(source),M['head']],cwd=REPO,check=True)
    state.update(source=str(source), DD=str(dd), source_provenance=verify_source(source), runner_sha256=digest(Path(__file__)))
    save(state)
    if CFG.get('gate_only_from'):
        state['build_rc']=0
        state['build_reused_without_compilation']=True
    else:
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
    state.update(source=str(source),DD=str(dd),build_receipt=prior['receipt_path'],artifact_sha256=prior['artifact_sha256'],simulator_uuid=uuid,cases=[])
    save(state)
    assert run(['xcrun','simctl','boot',uuid],OUT/'boot.log',source)==0
    assert run(['xcrun','simctl','bootstatus',uuid,'-b'],OUT/'bootstatus.log',source)==0
    assert run(['xcrun','simctl','spawn',uuid,'defaults','write','com.apple.keyboard.preferences','DidShowContinuousPathIntroduction','-bool','YES'],OUT/'quickpath-suppression.log',source)==0
    state['quickpath_suppression']=True
    state['postboot_resources_record_only']=capture(['/usr/bin/top','-l','1','-n','0'])
    for case in M['cases']:
        folder=OUT/case['label'];folder.mkdir()
        result=OUT/(case['label']+'.xcresult')
        item=dict(case,result_bundle=str(result));state['cases'].append(item);save(state)
        item['test_rc']=run(['xcodebuild','test-without-building','-project','Annex/Annex.xcodeproj','-scheme','ClubhouseGo',
            '-configuration','Debug','-jobs','2','-parallel-testing-enabled','NO','CODE_SIGNING_ALLOWED=NO',
            '-derivedDataPath',str(dd),'-destination','platform=iOS Simulator,id='+uuid,'-resultBundlePath',str(result),
            '-test-timeouts-enabled','YES','-default-test-execution-time-allowance','180','-maximum-test-execution-time-allowance','180',
            '-only-testing:'+case['selector']],folder/'test.log',source)
        for key in ['summary','tests']:
            item[key+'_rc']=run(['xcrun','xcresulttool','get','test-results',key,'--path',str(result)],folder/(key+'.json'),source)
        item['audit_rc']=run(['python3','/tmp/go-footer-560/audit-single-runs.py',str(result)],folder/'audit.log',source)
        item['attachments_rc']=run(['xcrun','xcresulttool','export','attachments','--path',str(result),'--output-path',str(folder/'attachments')],folder/'attachments.log',source)
        item['diagnostics_rc']=run(['xcrun','xcresulttool','export','diagnostics','--path',str(result),'--output-path',str(folder/'diagnostics')],folder/'diagnostics-export.log',source)
        summary=json.loads((folder/'summary.json').read_text());item['summary']=summary
        details=json.loads(Path(str(result)+'.single-run-details.json').read_text())
        item['exactly_one_target']=list(details)==[case['identifier']] and summary['totalTestCount']==1 and item['audit_rc']==0
        item['target_result']=details.get(case['identifier'],{}).get('testResult')
        # Offline inspection still decides the H1 signature. This strict automated map only permits the
        # unexecuted UI invocation after one native six-point failure and no other issue on the hosted case.
        failures=summary.get('testFailures',[])
        item['six_point_only_failure']=len(failures)==1 and case['signature'] in json.dumps(failures)
        item['diagnostic_map_ok']=(item['exactly_one_target'] and summary['failedTests']==1
            and summary['expectedFailures']==0 and summary['skippedTests']==0
            and item['target_result']=='Failed' and item['six_point_only_failure']
            and all(item[k]==0 for k in ['summary_rc','tests_rc','audit_rc','attachments_rc','diagnostics_rc']))
        save(state)
        if not item['diagnostic_map_ok']:
            state.update(rc=1,stop='Not an accepted six-point-only fail-before map. Inspect artifacts; no executed case may be retried.')
            save(state);return 1
    state.update(rc=0,diagnostic_only=True,product_acceptance=False,classification='Both exact-once six-point failures captured; H1 signature requires independent review.')
    save(state);return 0


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
