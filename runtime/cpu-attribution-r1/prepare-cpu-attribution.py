from pathlib import Path
import subprocess,json,hashlib,shutil
R=Path('/tmp/ux-582-proof'); prior=R/'cpu-head-r8';D=R/'cpu-attribution-r1';D.mkdir()
M=json.loads((prior/'manifest.json').read_text());source=D/'overlay-source'
P=['env','-u','COPILOT_CONNECTION_TOKEN','GIT_CONFIG_COUNT=1','GIT_CONFIG_KEY_0=safe.bareRepository','GIT_CONFIG_VALUE_0=all']
def git(*a):return subprocess.check_output(P+['git',*a],cwd=source)
def sha(b):return hashlib.sha256(b).hexdigest()
subprocess.run(P+['git','-C',M['source'],'worktree','add','--detach',str(source),M['head']],check=True)
probe='Annex/Annex/Companion/Views/CompanionConversationBuildProbe.swift';view='Annex/Annex/Companion/Views/CompanionConversationView.swift';test='Annex/AnnexTests/CompanionReadingPausedCostTests.swift'
p=source/probe;t=p.read_text();needle='    static var preparedRows: ((CompanionTarget, Int) -> Void)?\n';assert t.count(needle)==1
t=t.replace(needle,needle+'    /// Logging-only CPU attribution overlay. Removed from all credited builds.\n    static var attribution: ((String, String) -> Void)?\n');p.write_text(t)
p=source/view;t=p.read_text()
def change(a,b):
 global t
 assert t.count(a)==1,(a[:100],t.count(a));t=t.replace(a,b,1)
change('        let _ = CompanionConversationBuildProbe.record?(.body, target)\n','''        let _ = CompanionConversationBuildProbe.record?(.body, target)
        let _ = { if let trace = CompanionConversationBuildProbe.attribution {
            trace("parent.body", String(describing: target))
            Self._printChanges()
        } }()
''')
change('''        _seed = StateObject(wrappedValue: CompanionReadingSeed(store: store, target: target))
        self.content = content
''','''        _seed = StateObject(wrappedValue: CompanionReadingSeed(store: store, target: target))
        self.content = content
        #if DEBUG
        CompanionConversationBuildProbe.attribution?("seed.init", String(describing: target))
        #endif
''')
change('    var body: some View { content(seed.value) }\n','''    var body: some View {
        #if DEBUG
        let _ = { if let trace = CompanionConversationBuildProbe.attribution {
            trace("seed.body", String(describing: seed.value))
            Self._printChanges()
        } }()
        #endif
        content(seed.value)
    }
''')
change('''        self.entry = entry
        // Repeated View initialization''','''        self.entry = entry
        #if DEBUG
        CompanionConversationBuildProbe.attribution?("transcript.init",
            "store=\\(ObjectIdentifier(store)) target=\\(target) opening=\\(opening) managed=\\(isVisibilityManaged) jump=\\(String(describing: decisionChatJump?.id))")
        #endif
        // Repeated View initialization''')
change('        let _ = CompanionConversationBuildProbe.record?(.timeline, target)\n','''        let _ = CompanionConversationBuildProbe.record?(.timeline, target)
        let _ = { if let trace = CompanionConversationBuildProbe.attribution {
            trace("transcript.body", String(describing: target))
            Self._printChanges()
        } }()
''');p.write_text(t)
p=source/test;t=p.read_text()
# Logging is non-observable: it never mutates View State or Store; original fixture and count checks remain.
t=t.replace('        var body = 0, timeline = 0\n','''        var body = 0, timeline = 0
        var attributionPhase = "paused.mount"
        var attribution: [[String: String]] = []
        CompanionConversationBuildProbe.attribution = { event, inputs in
            let sample = ["phase": attributionPhase, "event": event, "inputs": inputs]
            attribution.append(sample)
            print("READING_CPU_ATTRIBUTION \\(sample)")
        }
''',1)
t=t.replace('        defer {\n            CompanionConversationBuildProbe.record = nil','        defer {\n            CompanionConversationBuildProbe.attribution = nil\n            CompanionConversationBuildProbe.record = nil',1)
t=t.replace('        for batch in 0..<10 {\n','        for batch in 0..<10 {\n            attributionPhase = "paused.batch.\\(batch)"\n            print("READING_CPU_MUTATION_BEGIN \\(batch)")\n',1)
t=t.replace('let report: [String: Any] = ["uncredited": true,','let report: [String: Any] = ["attribution": attribution, "uncredited": true,',1)
# Deep loop same fixture; separate phase and source input trace for each fresh mount.
t=t.replace('            var body = 0, timeline = 0\n','''            var body = 0, timeline = 0
            var attribution: [[String: String]] = []
            CompanionConversationBuildProbe.attribution = { event, inputs in
                let sample = ["phase": "deep.mount.\\(iteration)", "event": event, "inputs": inputs]
                attribution.append(sample)
                print("READING_CPU_ATTRIBUTION \\(sample)")
            }
''',1)
t=t.replace('            defer {\n                CompanionConversationBuildProbe.preparedRows = nil','            defer {\n                CompanionConversationBuildProbe.attribution = nil\n                CompanionConversationBuildProbe.preparedRows = nil',1)
t=t.replace('reports.append(["iteration": iteration,','reports.append(["attribution": attribution, "iteration": iteration,',1)
t=t.replace('            CompanionConversationBuildProbe.preparedRows = nil\n            CompanionConversationBuildProbe.record = nil\n            window.isHidden = true','            CompanionConversationBuildProbe.attribution = nil\n            CompanionConversationBuildProbe.preparedRows = nil\n            CompanionConversationBuildProbe.record = nil\n            window.isHidden = true',1)
p.write_text(t)
git('add',probe,view,test);git('commit','-m','Uncredited DEBUG transcript invalidation attribution')
base=M['base'];head=git('rev-parse','HEAD').decode().strip();patch=git('diff','--binary',base,head);increment=git('diff','--binary',M['head'],head)
(D/'diagnostic-only.diff').write_bytes(increment);(D/'overlay.diff').write_bytes(patch)
M.update(base=base,head=head,source=str(source),status='Uncredited DEBUG attribution only; unchanged product logic and CPU bars',full_diff_sha256=sha(patch))
M['source_sha256']={p:sha((source/p).read_bytes()) for p in M['source_sha256']}
M['phases']['P']['selectors']=M['phases']['P']['selectors'][1:];M['phases']['P'].update(methods=2,count=2)
del M['phases']['P']['method_names']['CompanionHomeVisibilityTests']
M['private_simulator']={'name':'ux-582-cpu-attribution'}
runner=(prior/'run-ticket.py').read_text().replace(str(prior),str(D));(D/'run-ticket.py').write_text(runner);shutil.copy2(prior/'audit-native.py',D/'audit-native.py')
M['runner_sha256']=sha((D/'run-ticket.py').read_bytes());M['native_auditor_sha256']=sha((D/'audit-native.py').read_bytes());(D/'manifest.json').write_text(json.dumps(M,indent=2)+'\n')
report={'product':base,'overlay_base':json.loads((prior/'manifest.json').read_text())['head'],'diagnostic_head':head,'diagnostic_diff_sha256':sha(increment),'full_diff_sha256':sha(patch),'manifest_sha256':sha((D/'manifest.json').read_bytes()),'source_sha256':M['source_sha256'],'source':str(source),'counts':'A1 fresh900; P2 once480; no Home; all original paused/deep assertions; no behavioral product edits; no performance credit'}
(D/'review.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report,indent=2))
