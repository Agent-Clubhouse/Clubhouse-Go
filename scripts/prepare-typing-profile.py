#!/usr/bin/env python3
"""Prepare an isolated source archive for the offline Release typing pilot; never runs an app.

Example: scripts/prepare-typing-profile.py 1b030cf build/dispatcher-typing/pre217
Build with -configuration Release ENABLE_CODE_COVERAGE=NO and your owned sim destination.
Install/launch ONLY on a simulator you created; attach xctrace to that app PID, never all processes.
The --staggered app argument separates stream and edit turns and uses fresh stream text in phase 3.
"""
import argparse
import pathlib
import subprocess
import tarfile
import io

root = pathlib.Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('revision')
parser.add_argument('output', type=pathlib.Path)
args = parser.parse_args()
output = (root / args.output).resolve()
if not output.is_relative_to(root / 'build') or output.exists():
    parser.error('Output must be a new directory inside this worktree/build')
archive = subprocess.check_output(['git', 'archive', '--format=tar', args.revision], cwd=root)
output.mkdir(parents=True)
with tarfile.open(fileobj=io.BytesIO(archive)) as contents:
    contents.extractall(output, filter='data')
app = output / 'Annex/Annex'
(app / 'AnnexApp.swift').write_text((root / 'scripts/fixtures/typing-profile.swift').read_text())
view = app / 'Companion/Views/CompanionConversationView.swift'
source = view.read_text()
source = source.replace('    var body: some View {', '    var body: some View {\n        let _ = TypingProfile.bodyPass()', 1)
source = source.replace('        .task(id: target)', '        .task { try? await Task.sleep(for: .seconds(1)); composerFocused = true }\n        .task(id: target)', 1)
start = source.index('    private var timeline: some View {')
source = source[:start] + source[start:].replace('    private var timeline: some View {',
    '    private var timeline: some View {\n        let _ = TypingProfile.timelinePass()', 1)
# The pre-217 getter was a single expression; a probe statement needs an explicit return.
a, b = source[:start], source[start:]
if 'return ScrollViewReader' not in b:
    b = b.replace('        ScrollViewReader {', '        return ScrollViewReader {', 1)
view.write_text(a + b)
print(output)
