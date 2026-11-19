from pathlib import Path
from collections import Counter,defaultdict
import json,sys
R=Path('/tmp/ux-582-proof/cpu-attribution-r1');T=R/'tickets/p-r1'
reports={}
for p in (T/'attachments').glob('*.json'):
 try:x=json.loads(p.read_text())
 except (ValueError,UnicodeDecodeError):continue
 if isinstance(x,dict) and 'attribution' in x:reports['paused']=x
 if isinstance(x,list) and x and isinstance(x[0],dict) and 'attribution' in x[0]:reports['deep']=x
assert set(reports)=={'paused','deep'}
summary={'uncredited':True,'paused':[],'deep':[]}
for key,rows in [('paused',[reports['paused']]),('deep',reports['deep'])]:
 for item in rows:
  events=item['attribution'];groups=defaultdict(list)
  for seq,e in enumerate(events):groups[e['phase']].append({'seq':seq,**e})
  for phase,group in groups.items():
   inputs={e['inputs'] for e in group if e['event']=='transcript.init'}
   summary[key].append({'phase':phase,'counts':dict(Counter(e['event'] for e in group)),
     'distinct_transcript_value_signatures':sorted(inputs),'ordered':group})
summary['measurements']={'paused':reports['paused']['samples'],'deep':[{k:v for k,v in i.items() if k!='attribution'} for i in reports['deep']]}
(R/'attribution-events.json').write_text(json.dumps(summary,indent=2)+'\n')
lines=[]
for p in sorted((T/'diagnostics').rglob('StandardOutputAndStandardError*.txt')):
 for line in p.read_text(errors='replace').splitlines():
  if any(x in line for x in ['READING_CPU_','CompanionConversationView:','CompanionReadingSeedScope<','CompanionConversationTranscript<','READING_RESTORE']):lines.append(line)
(R/'attribution-stdout.txt').write_text('\n'.join(lines)+'\n')
print(json.dumps({k:[{a:b for a,b in x.items() if a!='ordered'} for x in v] for k,v in summary.items() if k in ['paused','deep']},indent=2))
print('stdout lines',len(lines))
