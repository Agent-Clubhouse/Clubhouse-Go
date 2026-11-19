import json, subprocess, sys
from pathlib import Path
manifest, phase, bundle = sys.argv[1:]
m=json.loads(Path(manifest).read_text()); cfg=m['phases'][phase]
def tool(*args):
    return json.loads(subprocess.check_output(['xcrun','xcresulttool','get','test-results',*args,'--path',bundle]))
tree=tool('tests'); cases=[]
def visit(node):
    if node.get('nodeType')=='Test Case': cases.append(node['nodeIdentifier'])
    for child in node.get('children',[]): visit(child)
for node in tree['testNodes']: visit(node)
assert len(cases)==len(set(cases)), 'No duplicate native test identifiers'
details={case:tool('test-details','--test-id',case) for case in cases}
Path(bundle+'.single-run-details.json').write_text(json.dumps(details,indent=2)+'\n')
if cfg.get('method_names'):
    expected={suite+'/'+(name if name.endswith(')') else name+'()') for suite,names in cfg['method_names'].items() for name in names}
else:
    expected={selector.split('/',1)[1]+'()' for selector in cfg['selectors']}
assert set(details)==expected, (set(details)-expected,expected-set(details))
executions=0; arguments={}
for key,value in details.items():
    parameters=cfg.get('parameter_cases',{}).get(key.split('/',1)[1])
    if parameters:
        runs=value['testRuns']; names=[run['name'].removeprefix('.') for run in runs]
        assert len(names)==len(parameters) and set(names)==set(parameters),(key,names,parameters)
        assert all(run['nodeType']=='Arguments' and run['result']=='Passed' for run in runs)
        assert value['testDescription']==f'Test case with {len(parameters)} runs'
        arguments[key]=names; executions+=len(runs)
    else:
        assert value['testDescription']=='Test case with 1 run',(key,value['testDescription'])
        executions+=1
    assert value['testResult'] in m['known_native_outcomes'].get(key,['Passed']),(key,value['testResult'])
summary=tool('summary')
assert summary['totalTestCount']==len(expected)
assert summary['failedTests']==0
if cfg.get('parameter_executions'):
    assert executions==cfg['parameter_executions']
    assert summary['devicesAndConfigurations'][0]['passedTests']==executions
order=sorted(details,key=lambda k: details[k].get('startTime',float('inf')))
Path(bundle+'.actual-order.json').write_text(json.dumps(order,indent=2)+'\n')
if cfg.get('order_file'): assert order==json.loads(Path(cfg['order_file']).read_text()),'Original method order changed'
print(json.dumps({'verification':'PASS','methods':len(expected),'executions':executions,'arguments':arguments,'order_verified':bool(cfg.get('order_file'))},indent=2))
