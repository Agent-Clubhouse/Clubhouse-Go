#!/usr/bin/env python3
"""Source-only setup. Never builds, tests, creates simulators or admits FIFO work."""
import hashlib,json,os,subprocess
from pathlib import Path
R=Path('/tmp/ux-582-proof');M=json.loads((R/'manifest.json').read_text());REPO=Path(M['source'])
P=['env','-u','COPILOT_CONNECTION_TOKEN','GIT_CONFIG_COUNT=1','GIT_CONFIG_KEY_0=safe.bareRepository','GIT_CONFIG_VALUE_0=all']
def git(*args,cwd=REPO):return subprocess.check_output(P+['git',*args],cwd=cwd)
def sha(data):return hashlib.sha256(data).hexdigest()
scroll=Path(M['phases']['CPU']['method_file']).read_bytes();paused=Path(M['phases']['CPU']['paused_stream_method_file']).read_bytes()
assert sha(scroll)==M['phases']['CPU']['method_sha256']
assert sha(paused)==M['phases']['CPU']['paused_stream_method_sha256']
path='Annex/AnnexTests/CompanionHomeVisibilityTests.swift';new='Annex/AnnexTests/CompanionReadingPausedCostTests.swift'
# Only additive common test inputs: no product instrumentation or anchor code.
assert git('show',M['base']+':'+path)==git('show',M['head']+':'+path)
reports={}
for side,head in [('main',M['base']),('head',M['head'])]:
 root=R/('cpu-'+side);root.mkdir();source=root/'overlay-source'
 git('worktree','add','--detach',str(source),head)
 original=(source/path).read_text();marker='@MainActor final class CompanionHomeVisibilityTests: XCTestCase {\n';assert original.count(marker)==1
 (source/path).write_text(original.replace(marker,marker+scroll.decode(),1));(source/new).write_bytes(paused)
 patch=git('diff','--binary',cwd=source)
 git('add',path,new,cwd=source);git('commit','-m','Uncredited identical reading CPU measurement overlay',cwd=source)
 overlay_head=git('rev-parse','HEAD',cwd=source).decode().strip()
 all_patch=git('diff','--binary',head,overlay_head,cwd=source)
 assert set(git('diff','--name-only',head,overlay_head,cwd=source).decode().splitlines())=={path,new}
 assert git('diff','--numstat',head,overlay_head,cwd=source).decode().splitlines()[0].split('\t')[1]=='0'
 m={**M,'base':head,'head':overlay_head,'source':str(source),'full_diff_sha256':sha(all_patch)}
 m['source_sha256']={p:sha((source/p).read_bytes()) for p in [path,new]}
 m['phases']={'A':M['phases']['A'],'P':{'kind':'hosted','bound':480,'device':'iPhone-17-Pro-Max','selectors':['ClubhouseGoTests/CompanionHomeVisibilityTests/testDiagnosticHomeScrollStepsReportExpensiveWork','ClubhouseGoTests/CompanionReadingPausedCostTests/testPausedStreamingReportsPerBatchConversationWork'],'methods':2,'count':2,'method_names':{'CompanionHomeVisibilityTests':['testDiagnosticHomeScrollStepsReportExpensiveWork'],'CompanionReadingPausedCostTests':['testPausedStreamingReportsPerBatchConversationWork']}}}
 m['private_simulator']={'name':'ux-582-cpu-'+side}
 (root/'manifest.json').write_text(json.dumps(m,indent=2)+'\n');(root/'overlay.diff').write_bytes(all_patch)
 runner=(R/'run-ticket.py').read_text().replace("R=Path('/tmp/ux-582-proof')",'R=Path('+repr(str(root))+')')
 (root/'run-ticket.py').write_text(runner);(root/'audit-native.py').write_bytes((R/'audit-native.py').read_bytes())
 reports[side]={'base':head,'head':overlay_head,'source':str(source),'manifest':str(root/'manifest.json'),'overlay_sha256':sha(all_patch),'scroll_sha256':sha(scroll),'paused_sha256':sha(paused),'added_test_files':m['source_sha256']}
assert reports['main']['overlay_sha256']==reports['head']['overlay_sha256'], 'Both additive test patches must be byte-identical'
(R/'cpu-overlay-provenance.json').write_text(json.dumps(reports,indent=2)+'\n')
print(json.dumps(reports,indent=2))
