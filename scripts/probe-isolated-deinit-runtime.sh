#!/usr/bin/env bash
# Diagnostic control, not a workaround test. No runtime guard: older affected runtimes fail `inside`.
# Pass only a disposable simulator UUID. Never accepts or operates on a physical device.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
probe_device=${1:?Usage: scripts/probe-isolated-deinit-runtime.sh SIMULATOR_UUID}
probe_out=build/isolated-deinit-runtime
mkdir -p "$probe_out/Probe.app"
xcrun simctl list devices --json > "$probe_out/devices.json"
python3 - "$probe_device" "$probe_out" <<'PY'
import json,pathlib,plistlib,sys
uuid,out=sys.argv[1],pathlib.Path(sys.argv[2])
devices=json.loads((out/'devices.json').read_text())['devices']
matches=[(runtime,d) for runtime,ds in devices.items() for d in ds if d['udid']==uuid]
assert len(matches)==1 and matches[0][1]['state']=='Booted', 'Expected one booted disposable simulator'
print('DEINIT_RUNTIME simulator:',matches[0][0],matches[0][1]['name'])
(out/'Probe.app/Info.plist').write_bytes(plistlib.dumps({'CFBundleExecutable':'Probe','CFBundleIdentifier':'com.agentclubhouse.issue218.probe','CFBundleName':'Issue218Probe','CFBundlePackageType':'APPL','CFBundleVersion':'1','CFBundleShortVersionString':'1','MinimumOSVersion':'26.0','LSRequiresIPhoneOS':True,'UIDeviceFamily':[1,2]}))
PY
xcrun swiftc -version
xcrun swiftc -parse-as-library -swift-version 5 -default-isolation MainActor \
  -target arm64-apple-ios26.0-simulator -sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)" \
  scripts/isolated-deinit-runtime-probe.swift -o "$probe_out/Probe.app/Probe"
codesign --force --sign - "$probe_out/Probe.app"
xcrun simctl install "$probe_device" "$probe_out/Probe.app"
# This child UIKit app contains no XCTest/Swift Testing code and no Go or SDK telemetry.
python3 - "$probe_device" "$probe_out" <<'PY'
import pathlib,subprocess,sys
uuid,out=sys.argv[1],pathlib.Path(sys.argv[2]); failed=[]
for mode in ['outside','inside','explicit','empty','nonisolated','unisolated','after','async']:
    r=subprocess.run(['xcrun','simctl','launch','--console','--terminate-running-process',uuid,'com.agentclubhouse.issue218.probe',mode],capture_output=True,text=True,timeout=30)
    log=r.stdout+r.stderr; (out/f'{mode}.log').write_text(log)
    print(log,flush=True)
    # simctl can return 0 after SIGABRT: require the actual completion marker.
    if f'PROBE passed mode={mode}' not in log: failed.append(mode)
print('DEINIT_RUNTIME missing completion:',failed,flush=True)
raise SystemExit(bool(failed))
PY
