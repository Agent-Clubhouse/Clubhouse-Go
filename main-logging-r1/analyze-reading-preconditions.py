#!/usr/bin/env python3
"""List H1/H2 evidence candidates; does not assign a product verdict."""
import json,re,sys
from pathlib import Path
folder=Path(sys.argv[1]);data=json.loads((folder/'app-reading-trace-records.json').read_text())
records=[r for r in data['target_records'] if Path(r['file']).name.endswith('-com.Agent-Clubhouse.Go.txt')]
window=None;attempt=None;away=None;episodes=[];gaps=[]
for r in records:
    text=r['text'];event=re.search(r'\bevent=(\S+)',text)
    event=event[1] if event else None
    if event=='window':
        match=re.search(r'\bhidden=(\d+) first=(\S+)',text)
        if match:window={'hidden':int(match[1]),'first':match[2]}
        if attempt is not None:
            attempt['windows_after_pin'].append({'window':window,'record':r})
    if event in ['disappear','visibility-hidden'] and away is None:away={'departure':r,'saved':[]}
    if event=='saved' and away is not None:
        caller=re.search(r'\bcaller=(\S+)',text)
        away['saved'].append({'caller':caller[1] if caller else 'unknown','record':r})
    if event=='mount-saved' and away is not None:
        away['next_mount']=r
        away['disallowed_saved']=[s for s in away['saved'] if s['caller'] not in ['restore-arrived','scroll-idle']]
        gaps.append(away);away=None
    if event=='restore-step':
        if attempt is None:
            attempt={'first_restore_step':r,'pin_observability':'Trailing pin/step/attempt fields truncated by NSLog; infer delivery only from source plus matching frame/metrics. No direct pin-field claim.','window_at_pin':window,'windows_after_pin':[],'steps':[]}
        attempt['steps'].append(r)
    if 'READING_RESTORE outcome=' in text and attempt is not None:
        attempt['outcome']=r
        base=attempt['window_at_pin']
        attempt['hidden_or_first_changes']=[v for v in attempt['windows_after_pin'] if base and v['window'] and (v['window']['hidden'],v['window']['first'])!=(base['hidden'],base['first'])]
        attempt['entry_frame_review_required']=True
        episodes.append(attempt);attempt=None
out={'classification':'Evidence candidates only; inspect entry frames and timing before assigning H1/H2. Missing episodes do not rule them out.',
     'restore_episodes':episodes,'unfinished_restore_episode':attempt,'departure_mount_gaps':gaps,'unfinished_departure':away,
     'observability':{'records':len(records),'restore_steps':sum('event=restore-step' in r['text'] for r in records),'windows':sum('event=window' in r['text'] for r in records),'saved':sum('event=saved' in r['text'] for r in records)}}
(folder/'reading-preconditions.json').write_text(json.dumps(out,indent=2)+'\n')
print(json.dumps({'observability':out['observability'],'episodes':len(episodes),'episodes_with_hidden_or_first_changes':sum(bool(e['hidden_or_first_changes']) for e in episodes),'departure_mount_gaps':len(gaps),'gaps_with_disallowed_saved':sum(bool(g['disallowed_saved']) for g in gaps)},indent=2))
