from pathlib import Path
import hashlib

def sha(p): return hashlib.sha256(p.read_bytes()).hexdigest()

def apply(source):
    source = Path(source)
    relative = 'Annex/Annex/Companion/Views/CompanionHomeScrollAnchor.swift'
    p = source / relative
    notes = {}
    if p.exists():
        original = p.read_text()
        s = original
        def insert(old, new):
            nonlocal s
            assert s.count(old) == 1, old
            s = s.replace(old, new, 1)
        insert('    func suspend() {\n', '    func suspend() {\n        diagnostic("suspend")\n')
        insert('    func cancelRestoration() {\n', '    func cancelRestoration() {\n        diagnostic("cancel")\n')
        insert('        geometry = value\n', '        geometry = value\n        diagnostic("geometry incoming", detail: "offset=\\(value.contentOffset) insets=\\(value.contentInsets) container=\\(value.containerSize) visible=\\(value.visibleRect)")\n')
        insert('        resumeApplied = true\n', '        diagnostic("resume accepted")\n        resumeApplied = true\n')
        insert('        guard bookmark != nil else { return }\n', '        guard bookmark != nil else { diagnostic("fresh nil bookmark: capture only"); return }\n')
        insert('            guard remaining > 0 else { self.cancelRestoration(); return }\n', '            guard remaining > 0 else { self.diagnostic("timeout"); self.cancelRestoration(); return }\n')
        insert('            if stable >= 8, current != nil, self.viewport.height > 0 {\n', '            if stable >= 8, current != nil, self.viewport.height > 0 {\n                self.diagnostic("stable", detail: "samples=\\(stable) corrections=\\(corrections) remaining=\\(remaining)")\n')
        insert('                    proxy.scrollTo(id, anchor: requestedAnchor)\n', '                    self.diagnostic("identity issued", detail: "id=\\(id) requested=\\(requestedAnchor)")\n                    proxy.scrollTo(id, anchor: requestedAnchor)\n')
        insert('                    if abs(delta) <= 1 || corrections >= 1 { self.cancelRestoration(); return }\n', '                    self.diagnostic("identity outcome", detail: "desired=\\(desired) delta=\\(delta) requestedAnchor=\\(requestedAnchor) corrections=\\(corrections)")\n                    if abs(delta) <= 1 || corrections >= 1 { self.diagnostic(abs(delta) <= 1 ? "converged" : "one correction exhausted"); self.cancelRestoration(); return }\n')
        insert('                    proxy.scrollTo(saved.id, anchor: adjusted)\n', '                    self.diagnostic("adjusted identity issued", detail: "anchor=\\(adjusted) delta=\\(delta) span=\\(span)")\n                    proxy.scrollTo(saved.id, anchor: adjusted)\n')
        insert('                    proxy.scrollTo(saved.id, anchor: saved.alignment)\n', '                    self.diagnostic("identity reissue", detail: "id=\\(saved.id) alignment=\\(saved.alignment)")\n                    proxy.scrollTo(saved.id, anchor: saved.alignment)\n')
        insert('        bookmark = .init(id: first.key, alignment: .init(x: 0.5, y: max(0, min(1, fraction))))\n', '        bookmark = .init(id: first.key, alignment: .init(x: 0.5, y: max(0, min(1, fraction))))\n        diagnostic("capture", detail: "frame=\\(first.value)")\n')
        helper='''    private func diagnostic(_ event: String, detail: String = "") {
            #if DEBUG
            print("HOME_ANCHOR", event, "bookmark=", String(describing: bookmark?.id),
                  "alignment=", String(describing: bookmark?.alignment), "frame=", String(describing: bookmark.flatMap { frames[$0.id] }),
                  "viewport=", viewport, "presented=", presented, "suspended=", suspended,
                  "restoring=", restoring, "generation=", resumeGeneration, detail)
            #endif
        }

    '''
        insert('    private func capture() {\n', helper+'    private func capture() {\n')
        # The instrumentation calls have no effects outside DEBUG; this worktree is diagnostic-only.
        p.write_text(s)
        notes[relative] = {'before_sha256': hashlib.sha256(original.encode()).hexdigest(), 'after_sha256': sha(p)}
    root = source / 'Annex/Annex/Companion/Views/CompanionRootView.swift'
    r = root.read_text(); before = r
    needle='        let _ = CompanionHomeBuildProbe.record?(.owner)\n'
    assert r.count(needle)==1;r=r.replace(needle,'        let _ = Self._printChanges()\n'+needle)
    needle='    var body: some View { home.content(layout) }'
    assert r.count(needle)==1;r=r.replace(needle,'    var body: some View {\n        #if DEBUG\n        let _ = Self._printChanges()\n        #endif\n        home.content(layout)\n    }')
    if p.exists():
        needle = '            CompanionHomeBuildProbe.state?(scrollAnchor, $desktopSelection)\n'
        assert r.count(needle) == 1
        r = r.replace(needle, needle + '            CompanionHomeBuildProbe.diagnosticScrollTo = { id, anchor in proxy.scrollTo(id, anchor: anchor) }\n')
        needle = '        .onScrollPhaseChange { _, phase in\n'
        assert r.count(needle) == 1
        r = r.replace(needle, '        .onDisappear {\n            #if DEBUG\n            CompanionHomeBuildProbe.diagnosticScrollTo = nil\n            #endif\n        }\n' + needle)
        probe = source / 'Annex/Annex/Companion/Views/CompanionHomeBuildProbe.swift'
        before_probe = probe.read_text()
        needle = '    static var scrollToIssued: ((CompanionHomeAnchor) -> Void)?\n'
        assert before_probe.count(needle) == 1
        probe.write_text(before_probe.replace(needle, needle + '    static var diagnosticScrollTo: ((CompanionHomeAnchor, UnitPoint) -> Void)?\n'))
        notes[str(probe.relative_to(source))] = {'before_sha256': hashlib.sha256(before_probe.encode()).hexdigest(), 'after_sha256': sha(probe)}
        test = source / 'Annex/AnnexTests/CompanionHomeVisibilityTests.swift'
        before_test = test.read_text()
        needle = '        func close() {\n'
        assert before_test.count(needle) == 1
        test.write_text(before_test.replace(needle, needle + '            CompanionHomeBuildProbe.diagnosticScrollTo = nil\n'))
        # Test file already belongs to the additive-method overlay and is fingerprinted there.
    root.write_text(r)
    notes[str(root.relative_to(source))] = {'before_sha256': hashlib.sha256(before.encode()).hexdigest(), 'after_sha256': sha(root)}
    return notes
