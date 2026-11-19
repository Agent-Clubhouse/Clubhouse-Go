#!/usr/bin/env python3
"""#610 synthetic exact-head proof. Execute only after independent static review."""
import hashlib, importlib.util, json, os, re, signal, subprocess, sys, time, shutil
from pathlib import Path
R=Path(os.environ.get('UX610_PROOF_ROOT', '/tmp/ux-610-proof/head'))
M=json.loads((R/'manifest.json').read_text())
PHASE,LABEL=sys.argv[1:3]
CFG=M['phases'][PHASE];LIMIT=CFG['bound']
OUT=R/'tickets'/LABEL;STATE=R/(LABEL+'-progress.json');RECEIPT=R/(LABEL+'-receipt.json')
REPO=Path(M['source'])
P=['env','-u','COPILOT_CONNECTION_TOKEN','GIT_CONFIG_COUNT=1','GIT_CONFIG_KEY_0=safe.bareRepository','GIT_CONFIG_VALUE_0=all']
class GuardUtilities:
    @staticmethod
    def utc():
        import datetime
        return datetime.datetime.now(datetime.timezone.utc).isoformat()
    @staticmethod
    def swap_used(raw):
        match=re.search(r'used = ([\d.]+)([KMG])',raw)
        if not match: raise ValueError('Unparseable swap usage')
        return float(match[1])*{'K':1024,'M':1024**2,'G':1024**3}[match[2]]
g=GuardUtilities()
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
    patch=subprocess.check_output(P+['git','diff','--binary',M['base'],M['head']],cwd=source)
    assert hashlib.sha256(patch).hexdigest()==M['full_diff_sha256']
    return dict(head=M['head'], base=M['base'], source_sha256=M['source_sha256'], full_diff_sha256=M['full_diff_sha256'])

def build(state):
    if CFG.get('incremental_from'):
        prior=json.loads(Path(CFG['incremental_from']).read_text())
        assert prior['phase']=='A' and prior['build_rc']==65 and prior['rc']==65
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
    uuid=capture(['xcrun','simctl','create',M['private_simulator']['name'],
        'com.apple.CoreSimulator.SimDeviceType.'+CFG['device'],'com.apple.CoreSimulator.SimRuntime.iOS-26-0']).strip()
    state.update(source=str(source),DD=str(dd),build_receipt=prior['receipt_path'],artifact_sha256=prior['artifact_sha256'],simulator_uuid=uuid)
    save(state)
    assert run(['xcrun','simctl','boot',uuid],OUT/'boot.log',source)==0
    assert run(['xcrun','simctl','bootstatus',uuid,'-b'],OUT/'bootstatus.log',source)==0
    assert run(['xcrun','simctl','spawn',uuid,'defaults','write','com.apple.keyboard.preferences','DidShowContinuousPathIntroduction','-bool','YES'],OUT/'quickpath-suppression.log',source)==0
    state['quickpath_suppression']=True
    state['pretest_guard']=admission_guard();save(state)
    assert state['pretest_guard']['accepted'],'Pretest guard refused; zero test execution'
    result=OUT/'tests.xcresult';state['result_bundle']=str(result);save(state)
    video=None
    if CFG.get('record_video'):
        video_log=(OUT/'video.log').open('w')
        video_path=OUT/'first-paint-recording.mp4'
        state['video_command_started_epoch_seconds']=time.time()
        video=subprocess.Popen(P+['xcrun','simctl','io',uuid,'recordVideo','--codec=h264',str(video_path)],stdout=video_log,stderr=subprocess.STDOUT)
        state.update(video_pid=video.pid,video_path=str(video_path));save(state)
        deadline=time.monotonic()+10
        while time.monotonic()<deadline:
            if video.poll() is not None: raise RuntimeError('Recording failed before tests; no test execution')
            if 'Recording started' in (OUT/'video.log').read_text():break
            time.sleep(0.1)
        else: raise RuntimeError('Recording did not start before tests; no test execution')
        state['video_recording_observed_epoch_seconds']=time.time();save(state)
    try:
        state['test_command_started_epoch_seconds']=time.time();save(state)
        state['test_rc']=run(['xcodebuild','test-without-building','-project','Annex/Annex.xcodeproj','-scheme','ClubhouseGo',
            '-configuration','Debug','-jobs','2','-parallel-testing-enabled','NO','CODE_SIGNING_ALLOWED=NO',
            '-derivedDataPath',str(dd),'-destination','platform=iOS Simulator,id='+uuid,'-resultBundlePath',str(result),
            '-test-timeouts-enabled','YES','-default-test-execution-time-allowance','240','-maximum-test-execution-time-allowance','240']
            +['-only-testing:'+selector for selector in CFG['selectors']],OUT/'test.log',source)
    finally:
        if video:
            video.send_signal(signal.SIGINT)
            try: video.wait(timeout=15)
            except subprocess.TimeoutExpired:video.kill();video.wait()
            video_log.close()
            state.update(video_closed=True,video_rc=video.returncode,video_bytes=video_path.stat().st_size if video_path.exists() else 0)
            save(state)
    for key in ['summary','tests']:
        state[key+'_rc']=run(['xcrun','xcresulttool','get','test-results',key,'--path',str(result)],OUT/(key+'.json'),source)
    state['audit_rc']=run(['python3',str(R/'audit-native.py'),str(R/'manifest.json'),PHASE,str(result)],OUT/'audit.log',source)
    state['attachments_rc']=run(['xcrun','xcresulttool','export','attachments','--path',str(result),'--output-path',str(OUT/'attachments')],OUT/'attachments.log',source)
    state['diagnostics_rc']=run(['xcrun','xcresulttool','export','diagnostics','--path',str(result),'--output-path',str(OUT/'diagnostics')],OUT/'diagnostics-export.log',source)
    fixture_files=[]
    for path in sorted((OUT/'diagnostics').rglob('StandardOutputAndStandardError-com.Agent-Clubhouse.Go.txt')):
        events=[line for line in path.read_text(errors='replace').splitlines() if 'PROVIDER_APPLY_FIXTURE ' in line]
        fixture_files.append({'path':str(path),'sha256':digest(path),'events':events})
    (OUT/'synthetic-command-traces.json').write_text(json.dumps(fixture_files,indent=2)+'\n')
    state['synthetic_command_trace_files']=len(fixture_files)
    if CFG.get('fixture_counts'):
        events=[event.split('PROVIDER_APPLY_FIXTURE ',1)[1] for file in fixture_files for event in file['events']]
        counts={kind:sum(event.startswith(kind+' ') for event in events) for kind in ['preview','change','replay','start']}
        changes=[re.fullmatch(r'change id=(\S+) saved=codex-cli starts=0',event) for event in events if event.startswith('change ')]
        starts=[re.fullmatch(r'start id=(\S+) expected=codex-cli starts=1',event) for event in events if event.startswith('start ')]
        replays=[re.fullmatch(r'replay change id=(\S+)',event) for event in events if event.startswith('replay ')]
        state['fixture_counts']=counts
        change_ids={match[1] for match in changes if match}
        start_ids={match[1] for match in starts if match}
        state['fixture_command_ids']={'changes':sorted(change_ids),'starts':sorted(start_ids),'replays':[match[1] for match in replays if match]}
        state['fixture_order_identity_ok']=(counts==CFG['fixture_counts'] and all(changes) and all(starts) and all(replays)
            and len(change_ids)==3 and len(start_ids)==3 and not change_ids.intersection(start_ids)
            and all(match[1] in change_ids for match in replays)
            and sum(event=='preview proposed=codex-cli saved=claude-code starts=0' for event in events)==4
            and sum(event=='preview proposed=codex-cli saved=codex-cli starts=0' for event in events)==3)

    state['independent_fixture_order_and_visual_review_required']=True
    summary=json.loads((OUT/'summary.json').read_text());state['summary']=summary
    details=json.loads(Path(str(result)+'.single-run-details.json').read_text())
    order=[key for key,value in sorted(details.items(),key=lambda pair:pair[1].get('startTime',float('inf')))]
    (OUT/'actual-order.json').write_text(json.dumps(order,indent=2)+'\n')
    if CFG.get('method_names'):
        expected={suite+'/'+(name if name.endswith(')') else name+'()') for suite,names in CFG['method_names'].items() for name in names}
        state['exact_identifiers_ok']=set(details)==expected and len(details)==len(expected)
        state['declared_parameter_executions']=CFG.get('parameter_executions',len(expected))
        state['rc']=0 if state['test_rc']==state['audit_rc']==0 and state['exact_identifiers_ok'] and summary['failedTests']==summary['expectedFailures']==summary['skippedTests']==0 and all(state[k]==0 for k in ['summary_rc','tests_rc','attachments_rc','diagnostics_rc']) else 1
        if state['rc']:state['stop']='Unexpected hosted outcome/count/argument map; no executed retry'
        save(state);return state['rc']
    expected={selector.split('/',1)[1]+'()' for selector in CFG['selectors']}
    state['exact_identifiers_ok']=set(details)==expected and len(details)==CFG['count'] and summary['totalTestCount']==CFG['count']
    state['order_ok']=True if not CFG.get('order_file') else order==json.loads(Path(CFG['order_file']).read_text())
    state['outcome_map_ok']=all(v['testResult'] in M['known_native_outcomes'].get(k,['Passed']) for k,v in details.items())
    state['known_skip_review_required']=any(v['testResult']=='Skipped' and 'ForcedTray' in k for k,v in details.items())
    for key in details:
        if 'testHistoryPrependStreamingKeyboardAndReturnKeepTheReadingEntry' in key:
            state['reading_activity_rc']=run(['xcrun','xcresulttool','get','test-results','activities','--path',str(result),'--test-id',key],OUT/'reading-activities.json',source)
    if CFG.get('expected_fail_before'):
        failures=json.dumps(summary.get('testFailures',[]))
        state['intended_failure_observed']=('Apply must be reachable before selecting' in failures)
        state['rc']=0 if (state['test_rc']!=0 and summary['failedTests']==1 and summary['passedTests']==0
            and summary['skippedTests']==0 and summary['expectedFailures']==0 and state['intended_failure_observed']
            and state['exact_identifiers_ok'] and all(state[k]==0 for k in ['summary_rc','tests_rc','audit_rc','attachments_rc','diagnostics_rc'])) else 1
    else:
        state['rc']=0 if (state['test_rc']==0 and summary['failedTests']==0 and state['exact_identifiers_ok']
            and state['order_ok'] and state['outcome_map_ok'] and state.get('fixture_order_identity_ok',True) and all(state[k]==0 for k in ['summary_rc','tests_rc','audit_rc','attachments_rc','diagnostics_rc'])) else 1
    if state['rc']:state['stop']='Unexpected count/order/outcome; no executed test retry'
    save(state);return state['rc']


def coverage(state):
    state['source_provenance']=verify_source(REPO)
    assert run(['git','fetch','origin'],OUT/'fetch.log',REPO)==0
    main=capture(['git','rev-parse','origin/main']).strip()
    combined=OUT/'source'
    subprocess.run(P+['git','worktree','add','--detach',str(combined),M['head']],cwd=REPO,check=True)
    merge_rc=run(['git','merge','--no-ff','--no-edit',main],OUT/'merge.log',combined)
    state.update(main_at_runtime=main, merge_rc=merge_rc, combined_source=str(combined))
    if merge_rc:
        state.update(rc=1,stop='Merge conflict; no resolution authorized',conflicts=capture(['git','diff','--name-only','--diff-filter=U'],combined).splitlines())
        save(state);return 1
    assert not capture(['git','status','--porcelain'],combined).strip()
    state['combined_head']=capture(['git','rev-parse','HEAD'],combined).strip()
    state['combined_tree']=capture(['git','rev-parse','HEAD^{tree}'],combined).strip()
    expected_tree=capture(['git','merge-tree','--write-tree',M['head'],main],REPO).splitlines()[0]
    state['fresh_merge_tree']=expected_tree
    assert state['combined_tree']==expected_tree,'Combined tree differs from a fresh merge'
    changed_main=set(capture(['git','diff','--name-only',M['base'],main],REPO).splitlines())
    product_files=set(M['source_sha256'])
    state['main_product_overlap']=sorted(changed_main & product_files)
    assert not state['main_product_overlap'],'Main touched tested product files; review before coverage'
    assert run(['git','fetch','origin'],OUT/'refetch.log',REPO)==0
    assert capture(['git','rev-parse','origin/main']).strip()==main,'Main changed before compile; STOP'
    assert not (combined/'.build').exists(),'Fresh coverage build only'
    shim=OUT/'bin';shim.mkdir()
    swift_path=capture(['/usr/bin/xcrun','--find','swift']).strip()
    (shim/'swift').write_text('#!/bin/sh\ncase "$1" in test|build) op="$1"; shift; exec "'+swift_path+'" "$op" --jobs 2 "$@";; *) exec "'+swift_path+'" "$@";; esac\n')
    (shim/'swift').chmod(0o700)
    state.update(swift_jobs=2,swift_shim_sha256=digest(shim/'swift'))
    os.environ['PATH']=str(shim)+os.pathsep+os.environ['PATH']
    save(state)
    state['coverage_rc']=run(['bash','scripts/coverage.sh','--check'],OUT/'coverage.log',combined)
    state['rc']=state['coverage_rc'];save(state);return state['rc']



def package(state):
    source=OUT/'source'
    subprocess.run(P+['git','worktree','add','--detach',str(source),M['head']],cwd=REPO,check=True)
    state.update(source=str(source),source_provenance=verify_source(source),runner_sha256=digest(Path(__file__)))
    save(state)
    command=['swift','test','--jobs','2','--filter',CFG['filter'],'--xunit-output',str(OUT/'tests.xml')]
    state['package_command']=command
    state['package_rc']=run(command,OUT/'package.log',source)
    log=(OUT/'package.log').read_text()
    state['swift_test_completions']=re.findall(r'^.*Test run with .*$',log,re.M)
    state['argument_starts']=re.findall(r'^.*Test case passing .*$',log,re.M)
    state['method_starts']=re.findall(r'^.*?Test (\w+)\([^\n]* started\.$',log,re.M)
    state['expected_fail_before']=CFG.get('expected_fail_before',False)
    if state['expected_fail_before']:
        # A nonzero compile/crash/fixture result is never the intended failure.
        state['intended_failure_observed']=(state['package_rc']==1 and len(state['swift_test_completions'])==1
            and 'genericCrossProviderUpdateNeverDispatchesEvenWithGuidedSupport' in log
            and 'A generic update must not switch providers' in log
            and len([x for x in state['argument_starts'] if 'genericCrossProviderUpdateNeverDispatchesEvenWithGuidedSupport' in x])==2
            and 'error: emit-module' not in log and 'crashed' not in log.lower())
        state['rc']=0 if state['intended_failure_observed'] else 1
    else:
        method_counts={name:state['method_starts'].count(name) for name in state['method_starts']}
        argument_methods=[re.search(r' to (\w+)\(',line)[1] for line in state['argument_starts']]
        argument_counts={name:argument_methods.count(name) for name in argument_methods}
        state['method_counts']=method_counts;state['argument_counts']=argument_counts
        state['package_exact_map_ok']=(set(method_counts)==set(CFG['method_names']) and all(count==1 for count in method_counts.values())
            and argument_counts==CFG['parameter_cases'] and len(set(state['argument_starts']))==len(state['argument_starts']))
        state['rc']=0 if state['package_rc']==0 and len(state['swift_test_completions'])==1 and ' passed after ' in state['swift_test_completions'][0] and state['package_exact_map_ok'] else 1
    state['independent_exact_count_review_required']=True
    save(state);return state['rc']


def worker():
    state={'head':M['head'],'phase':PHASE,'started_at':g.utc(),'runner_sha256':digest(Path(__file__)),'manifest_sha256':digest(R/'manifest.json')}
    try:
        assert digest(Path(__file__))==M['runner_sha256'],'Executed runner differs from reviewed pin'
        assert all(digest(Path(path))==value for path,value in M['fifo_sha256'].items()),'FIFO helper changed; re-review before admission'
        assert digest(R/'audit-native.py')==M['auditor_sha256'],'Auditor differs from reviewed pin'
        state['guard']=admission_guard();save(state)
        print('GUARD '+json.dumps({k:v for k,v in state['guard'].items() if k not in ['top','vm_stat_before','vm_stat_after','swap_before','swap_after']}),flush=True)
        if not state['guard']['accepted']:state['rc']=4;save(state);return 4
        assert not OUT.exists(),'Fresh label required';OUT.mkdir(parents=True)
        assert capture(['git','rev-parse','HEAD']).strip()==M['head']
        assert not capture(['git','status','--porcelain']).strip(),'Clean source required'
        if PHASE=='D':return coverage(state)
        if PHASE=='A':return build(state)
        if CFG['kind']=='package':return package(state)
        if CFG['kind'] in ('hosted','UI'):return test(state)
        raise ValueError('Unknown phase')
    except Exception as error:
        state.update(rc=1,error=str(error));save(state);print(str(error),flush=True);return 1

def cleanup(state):
    video_pid=state.get('video_pid')
    if video_pid and not state.get('video_closed'):
        # Do not signal an unrelated process if an already-ended PID was reused.
        command=subprocess.run(['/bin/ps','-p',str(video_pid),'-o','command='],text=True,capture_output=True).stdout
        if state.get('video_path','unmatched-path') in command:
            try: os.kill(video_pid,signal.SIGINT)
            except ProcessLookupError: pass
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

def signal_owned_group(group, sig):
    try:
        os.killpg(group, sig)
    except ProcessLookupError:
        # The group may exit between ps/wait and the signal. Still finish simulator cleanup/receipt.
        pass

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
        signal_owned_group(child.pid, signal.SIGKILL)
        child.wait()
        rc = 124 if isinstance(error, subprocess.TimeoutExpired) else 143
    state = json.loads(STATE.read_text()) if STATE.exists() else {}
    process_rows=subprocess.check_output(['/bin/ps','-axo','pid=,ppid=,pgid=,comm='],text=True).splitlines()
    owned=[row.strip() for row in process_rows if len(row.split())>=4 and row.split()[2]==str(child.pid)]
    state['owned_process_group']=child.pid
    state['owned_processes_before_cleanup']=owned
    if owned:
        signal_owned_group(child.pid,signal.SIGTERM)
        time.sleep(2)
        remaining=[row.strip() for row in subprocess.check_output(['/bin/ps','-axo','pid=,ppid=,pgid=,comm='],text=True).splitlines() if len(row.split())>=4 and row.split()[2]==str(child.pid)]
        if remaining:
            signal_owned_group(child.pid,signal.SIGKILL)
            time.sleep(0.2)
        rc=1
        state['stop']='Unexpected surviving owned process group; cleaned, acceptance STOP'
    state['owned_processes_after_cleanup']=[row.strip() for row in subprocess.check_output(['/bin/ps','-axo','pid=,ppid=,pgid=,comm='],text=True).splitlines() if len(row.split())>=4 and row.split()[2]==str(child.pid)]
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
