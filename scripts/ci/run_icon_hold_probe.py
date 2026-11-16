#!/usr/bin/env python3
"""Constrain the actual Swift Testing host, without constraining SwiftPM itself."""
import os
from pathlib import Path
import signal
import subprocess
import sys

FILTER = 'CompanionAppUpdateTests/(queuedCompleteIconMapDistinguishesOmissionFromRemoval|progressFloodBypassesBlockedIconsAndQueuedSnapshotsCannotRegressIt|qaNewEpochCannotPublishThePreviousEpochsApprovalWhileSnapshotWaitsForIcons)'
bin_path = Path(sys.argv[1]).resolve()
binary = bin_path / 'ClubhouseTransportPackageTests.xctest/Contents/MacOS/ClubhouseTransportPackageTests'
swift = Path(subprocess.check_output(['xcrun', '--find', 'swift'], text=True).strip())
helper = swift.parent.parent / 'libexec/swift/pm/swiftpm-testing-helper'
platform = Path(subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-platform-path'], text=True).strip())
frameworks = platform / 'Developer/Library/Frameworks'
libraries = platform / 'Developer/usr/lib'
if not binary.is_file() or not helper.is_file():
    raise SystemExit(f'Missing compiled test bundle or matching SwiftPM test host: {binary}; {helper}')
(bin_path / 'codecov').mkdir(exist_ok=True)
command = ['env', '-u', 'COPILOT_CONNECTION_TOKEN', 'GIT_CONFIG_COUNT=1', 'GIT_CONFIG_KEY_0=safe.bareRepository', 'GIT_CONFIG_VALUE_0=all', 'LIBDISPATCH_COOPERATIVE_POOL_STRICT=1', f'DYLD_FRAMEWORK_PATH={frameworks}', f'DYLD_LIBRARY_PATH={libraries}', f'LLVM_PROFILE_FILE={bin_path}/codecov/icon-hold-%m-%p.profraw', str(helper), '--test-bundle-path', str(binary), '--filter', FILTER, str(binary), '--testing-library', 'swift-testing']
process = subprocess.Popen(command, start_new_session=True)
try:
    code = process.wait(timeout=30)
except subprocess.TimeoutExpired:
    os.killpg(process.pid, signal.SIGTERM)
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        process.wait()
    print('::error::Strict-pool icon-hold test host exceeded 30 seconds.', file=sys.stderr)
    code = 124
raise SystemExit(code)
