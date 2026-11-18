#!/usr/bin/env python3
"""Source-only setup. Never builds, tests, creates simulators or admits FIFO work."""
import hashlib,json,os,subprocess,sys
from pathlib import Path
R=Path('/tmp/ux-582-proof');M=json.loads((R/'manifest.json').read_text());REPO=Path(M['source'])
P=['env','-u','COPILOT_CONNECTION_TOKEN','GIT_CONFIG_COUNT=1','GIT_CONFIG_KEY_0=safe.bareRepository','GIT_CONFIG_VALUE_0=all']
def git(*args,cwd=REPO):return subprocess.check_output(P+['git',*args],cwd=cwd)
def sha(data):return hashlib.sha256(data).hexdigest()
scroll=Path(M['phases']['CPU']['method_file']).read_bytes();paused=Path(M['phases']['CPU']['paused_stream_method_file']).read_bytes()
assert sha(scroll)==M['phases']['CPU']['method_sha256']
assert sha(paused)==M['phases']['CPU']['paused_stream_method_sha256']
deep=Path(M['phases']['CPU']['deep_open_method_file']).read_bytes()
assert sha(deep)==M['phases']['CPU']['deep_open_method_sha256']
path='Annex/AnnexTests/CompanionHomeVisibilityTests.swift';new='Annex/AnnexTests/CompanionReadingPausedCostTests.swift'
# Identical additive test source plus identical DEBUG-only count hooks on both product trees.
# The full patch positions differ with product layout; prove test diff and hook text separately.
probe='Annex/Annex/Companion/Views/CompanionConversationBuildProbe.swift'
view='Annex/Annex/Companion/Views/CompanionConversationView.swift'
probe_marker='    static var record: ((Kind, CompanionTarget) -> Void)?\n'
probe_hook='    static var preparedRows: ((CompanionTarget, Int) -> Void)?\n'
view_marker='        let entries = window.entries\n'
view_hook='        #if DEBUG\n        let _ = CompanionConversationBuildProbe.preparedRows?(target, window.preparedRowCount)\n        #endif\n'

assert git('show',M['base']+':'+path)==git('show',M['head']+':'+path)
generation=sys.argv[1] if len(sys.argv)>1 else ''
assert not generation or generation.isalnum()
reports={}
for side,head in [('main',M['base']),('head',M['head'])]:
 root=R/('cpu-'+side+('-'+generation if generation else ''));root.mkdir();source=root/'overlay-source'
 git('worktree','add','--detach',str(source),head)
 original=(source/path).read_text();marker='@MainActor final class CompanionHomeVisibilityTests: XCTestCase {\n';assert original.count(marker)==1
 (source/path).write_text(original.replace(marker,marker+scroll.decode(),1));(source/new).write_bytes(paused+b'\n'+deep)
 probe_source=(source/probe).read_text();assert probe_source.count(probe_marker)==1
 (source/probe).write_text(probe_source.replace(probe_marker,probe_marker+probe_hook,1))
 view_source=(source/view).read_text();assert view_source.count(view_marker)==1
 (source/view).write_text(view_source.replace(view_marker,view_marker+view_hook,1))
 git('add',path,new,probe,view,cwd=source);git('commit','-m','Uncredited identical reading CPU measurement overlay',cwd=source)
 overlay_head=git('rev-parse','HEAD',cwd=source).decode().strip()
 all_patch=git('diff','--binary',head,overlay_head,cwd=source)
 assert set(git('diff','--name-only',head,overlay_head,cwd=source).decode().splitlines())=={path,new,probe,view}
 assert all(row.split('\t')[1]=='0' for row in git('diff','--numstat',head,overlay_head,cwd=source).decode().splitlines()), 'Every overlay file must be additive' 
 m={**M,'base':head,'head':overlay_head,'source':str(source),'full_diff_sha256':sha(all_patch)}
 m['source_sha256']={p:sha((source/p).read_bytes()) for p in [path,new,probe,view]}
 test_patch=git('diff','--binary',head,overlay_head,'--',path,new,cwd=source)
 hook_patch=git('diff','--binary',head,overlay_head,'--',probe,view,cwd=source)
 # Both product hooks are only the exact same additions at unique shared semantic markers.
 additions='\n'.join(line for line in hook_patch.decode().splitlines() if line.startswith('+') and not line.startswith('+++'))
 assert additions=='\n'.join('+'+line for line in (probe_hook+view_hook).splitlines()), additions
 (root/'measurement-hooks.diff').write_bytes(hook_patch)
 (root/'additive-tests.diff').write_bytes(test_patch)
 m['phases']={'A':M['phases']['A'],'P':{'kind':'hosted','bound':480,'device':'iPhone-17-Pro-Max','selectors':['ClubhouseGoTests/CompanionHomeVisibilityTests/testDiagnosticHomeScrollStepsReportExpensiveWork','ClubhouseGoTests/CompanionReadingPausedCostTests/testPausedStreamingReportsPerBatchConversationWork','ClubhouseGoTests/CompanionReadingDeepOpeningCostTests/testDeepPausedOpeningReportsWorkForTwoFreshMounts'],'methods':3,'count':3,'method_names':{'CompanionHomeVisibilityTests':['testDiagnosticHomeScrollStepsReportExpensiveWork'],'CompanionReadingPausedCostTests':['testPausedStreamingReportsPerBatchConversationWork'],'CompanionReadingDeepOpeningCostTests':['testDeepPausedOpeningReportsWorkForTwoFreshMounts']}}}
 m['phases']['A']=dict(M['phases']['A'])
 m['phases']['A'].pop('incremental_from',None);m['phases']['A']['bound']=900
 m['private_simulator']={'name':'ux-582-cpu-'+side}
 (root/'manifest.json').write_text(json.dumps(m,indent=2)+'\n');(root/'overlay.diff').write_bytes(all_patch)
 runner=(R/'run-ticket.py').read_text().replace("R=Path('/tmp/ux-582-proof')",'R=Path('+repr(str(root))+')')
 (root/'run-ticket.py').write_text(runner);(root/'audit-native.py').write_bytes((R/'audit-native.py').read_bytes())
 m['runner_sha256']=sha((root/'run-ticket.py').read_bytes());m['native_auditor_sha256']=sha((root/'audit-native.py').read_bytes())
 (root/'manifest.json').write_text(json.dumps(m,indent=2)+'\n')
 reports[side]={'base':head,'head':overlay_head,'source':str(source),'manifest':str(root/'manifest.json'),'overlay_sha256':sha(all_patch),'scroll_sha256':sha(scroll),'paused_sha256':sha(paused),'deep_open_sha256':sha(deep),'source_sha256':m['source_sha256'],'additive_tests_sha256':sha(test_patch),'hook_additions_sha256':sha(additions.encode()),'measurement_hooks_sha256':sha(hook_patch)}
assert reports['main']['additive_tests_sha256']==reports['head']['additive_tests_sha256'], 'Both additive test patches must be byte-identical'
assert reports['main']['hook_additions_sha256']==reports['head']['hook_additions_sha256'], 'Both measurement hook additions must be byte-identical'
(R/'cpu-overlay-provenance.json').write_text(json.dumps(reports,indent=2)+'\n')
print(json.dumps(reports,indent=2))
