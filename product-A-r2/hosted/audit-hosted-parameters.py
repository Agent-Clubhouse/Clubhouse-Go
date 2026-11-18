import json,re
from pathlib import Path
r=Path('/tmp/ux-569-fix-proof');o=r/'tickets/h-fix-r1';m=json.loads((r/'manifest.json').read_text());cfg=m['phases']['H'];d=json.loads(Path(str(o/'tests.xcresult')+'.single-run-details.json').read_text());summary=json.loads((o/'summary.json').read_text())
expected={suite+'/'+(name if name.endswith(')') else name+'()') for suite,names in cfg['method_names'].items() for name in names}
assert set(d)==expected,(set(d)-expected,expected-set(d))
executions=0;checked={}
for key,value in d.items():
 assert value['testResult']=='Passed',key
 name=key.split('/',1)[1];params=cfg['parameter_cases'].get(name)
 if params:
  runs=value['testRuns'];actual=[run['name'].removeprefix('.') for run in runs]
  assert len(actual)==len(params) and set(actual)==set(params),(key,actual,params)
  assert all(run['result']=='Passed' and run['nodeType']=='Arguments' for run in runs)
  assert value['testDescription']==f'Test case with {len(params)} runs'
  executions+=len(runs);checked[key]=actual
 else:
  assert value['testDescription']=='Test case with 1 run',key
  executions+=1;checked[key]=['exactly one run']
assert len(d)==15 and executions==19
assert summary['totalTestCount']==15 and summary['passedTests']==15
assert summary['devicesAndConfigurations'][0]['passedTests']==19
assert summary['failedTests']==summary['skippedTests']==summary['expectedFailures']==0
log=(o/'test.log').read_text();line=next(x for x in log.splitlines() if x.startswith('READING569_REGRESSION'))
fields=dict(re.findall(r'(shift|miss|attempts|elapsed|outcome)=([^ ]+)',line))
assert abs(float(fields['shift']))>8 and abs(float(fields['miss']))<=2 and fields['outcome']=='arrived'
assert float(fields['attempts'])<=10 and float(fields['elapsed'])<1
result={'offline_verification':'PASS; no test execution','methods':15,'executions':19,'exact_names':True,'arguments_each_once':checked,'regression':line,'native_test_rc':0,'original_receipt_rc':1,'original_stop':'Generic audit rejects declared parameter counts; parameter parent has no startTime. Original receipt preserved.'}
(r/'h-fix-r1-offline-audit.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result,indent=2))
