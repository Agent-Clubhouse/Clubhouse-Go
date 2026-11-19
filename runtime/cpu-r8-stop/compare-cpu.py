from pathlib import Path
import json,sys,hashlib
R=Path('/tmp/ux-582-proof');generation=sys.argv[1];label=sys.argv[2];sides={};paths={};names={'home':'Home step-scroll redraw measurement JSON','paused':'Paused streaming conversation work JSON','deep':'Deep paused opening work JSON'}
for side in ['main','head']:
 root=R/f'cpu-{side}-{generation}';receipt=json.loads((root/(label+'-receipt.json')).read_text());assert receipt['rc']==receipt['audit_rc']==0
 t=root/'tickets'/label; manifest=json.loads((t/'attachments/manifest.json').read_text());data={};evidence={}
 for kind,name in names.items():
  found=[a for test in manifest for a in test['attachments'] if a['suggestedHumanReadableName'].startswith(name+'_')]
  assert len(found)==1,(side,kind,found);f=t/'attachments'/found[0]['exportedFileName'];data[kind]=json.loads(f.read_text());evidence[kind]={'path':str(f),'sha256':hashlib.sha256(f.read_bytes()).hexdigest()}
 sides[side]=data;paths[side]=evidence
main,head=sides['main'],sides['head'];checks=[];fail=[]
def check(where,key,a,b):
 assert isinstance(a,(int,float)) and isinstance(b,(int,float)) and a>=0 and b>=0,(where,key,a,b)
 row={'where':where,'counter':key,'main':a,'head':b,'pass':b<=a};checks.append(row)
 if not row['pass']:fail.append(row)
assert len(main['home']['samples'])==len(head['home']['samples'])==16
home_keys=['owner','contentInputs','content','layout','header']
for i,(a,b) in enumerate(zip(main['home']['samples'],head['home']['samples'])):
 assert a['step']==b['step']==i;assert a['requestedOffset']==b['requestedOffset']
 assert set(home_keys)<=set(a['delta']) and set(home_keys)<=set(b['delta'])
 for k in home_keys:check('Home step '+str(i),k,a['delta'][k],b['delta'][k])
assert len(main['paused']['samples'])==len(head['paused']['samples'])==10
for i,(a,b) in enumerate(zip(main['paused']['samples'],head['paused']['samples'])):
 assert a['batch']==b['batch']==i and a['chunks']==b['chunks']==10
 for k in ['body','timeline']:check('Paused batch '+str(i),k,a[k],b[k])
assert len(main['deep'])==len(head['deep'])==2
cpu_flags=[]
for i,(a,b) in enumerate(zip(main['deep'],head['deep'])):
 assert a['iteration']==b['iteration']==i and a['rows']==b['rows']==600 and a['bookmarkIndex']==b['bookmarkIndex']==60
 for x in [a,b]:
  assert len(x['preparedRowCountByBuild'])==x['timeline']
  assert max(x['preparedRowCountByBuild'])==x['preparedRowCount'];assert sum(x['preparedRowCountByBuild'])==x['preparedRowCountTotal']
 for k in ['body','timeline','preparedRowCount','preparedRowCountTotal']:check('Deep opening '+str(i),k,a[k],b[k])
 equal=all(a[k]==b[k] for k in ['body','timeline','preparedRowCount','preparedRowCountTotal'])
 if equal and b['processCPUSeconds']>a['processCPUSeconds']*1.2:
  cpu_flags.append({'iteration':i,'main_cpu':a['processCPUSeconds'],'head_cpu':b['processCPUSeconds'],'non_blocking':True,'reason':'process CPU >20% higher with equal gated counts'})
home_differ=any(c['where'].startswith('Home step') and c['head']!=c['main'] for c in checks)
report={'home_expensive_counts_differ_requires_QA_live_followup':home_differ,'counts_verdict':'PASS' if not fail else 'STOP','supporting_cpu_flags':cpu_flags,'checks':checks,'count_regressions':fail,'source_attachments':paths,'all_raw_reports':sides,'notes':'Home row/menu/scope lazy-realisation deltas reported in raw data separately; only reviewed five expensive Home sites gate. Process CPU supporting only. No reruns or allowances.'}
(R/f'cpu-{generation}-comparison.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps({'counts_verdict':report['counts_verdict'],'checks':len(checks),'regressions':fail,'supporting_flags':cpu_flags},indent=2));sys.exit(bool(fail))
