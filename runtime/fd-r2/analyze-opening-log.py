#!/usr/bin/env python3
"""Read-only extraction of actual app stdout events; no invented timing alignment."""
import json,re,sys
from pathlib import Path
root=Path(sys.argv[1]); receipt=json.loads(Path(sys.argv[2]).read_text())
paths=list((root/'diagnostics').rglob('StandardOutputAndStandardError-com.Agent-Clubhouse.Go.txt'))
assert paths,'App stdout must actually be exported'
text='\n'.join(p.read_text(errors='replace') for p in paths)
(root/'opening-stdout.txt').write_text(text)
events=[]
for line in text.splitlines():
    if not line.startswith('READING_OPEN '):continue
    event=dict(re.findall(r'(\w+)=([^\s]+)',line)); t=float(event['time'])
    event['relative_to_command_seconds']=t-receipt['video_command_started_epoch_seconds']
    event['relative_to_recording_observed_seconds']=t-receipt['video_recording_observed_epoch_seconds']
    events.append(event)
report=dict(video_command_epoch=receipt['video_command_started_epoch_seconds'],video_recording_observed_epoch=receipt['video_recording_observed_epoch_seconds'],start_wallclock_bracket_seconds=receipt['video_recording_observed_epoch_seconds']-receipt['video_command_started_epoch_seconds'],app_stdout_files=[str(p) for p in paths],events=events)
(root/'opening-timeline.json').write_text(json.dumps(report,indent=2)+'\n')
seen=set()
for e in events:
    key=(e.get('case'),e.get('mount'),e.get('phase'))
    if e.get('phase') in ['body','openingRequest','scroll','arrived','unmounted'] and key not in seen:
        seen.add(key);print({k:e.get(k) for k in ['time','case','phase','mount','target','id','first','offset','lower','relative_to_command_seconds']})
