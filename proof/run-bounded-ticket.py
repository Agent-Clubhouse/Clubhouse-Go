#!/usr/bin/env python3
"""Outer admission-to-cleanup deadline; leaves reviewed proof runner unchanged."""
import datetime,json,os,pathlib,signal,subprocess,sys,time
root=pathlib.Path(os.environ['UX610_PROOF_ROOT']);phase,label=sys.argv[1:3]
manifest=json.loads((root/'manifest.json').read_text());limit=manifest['phases'][phase]['bound'];started=time.monotonic()
assert limit>=120
receipt=root/(label+'-outer-closure.json');assert not receipt.exists()
runner='/tmp/ux-610-evidence/proof/run-ticket-stabilized.py'
process=subprocess.Popen([sys.executable,'-u',runner,phase,label],start_new_session=True)
worker=None;deadline_stop=False;error=None

def rows():return subprocess.check_output(['/bin/ps','-axo','pid=,ppid=,pgid=,command='],text=True,timeout=3).splitlines()
def interrupted(*unused):raise KeyboardInterrupt()
signal.signal(signal.SIGTERM,interrupted);signal.signal(signal.SIGINT,interrupted)
try:
 while process.poll() is None and time.monotonic()-started<limit-60:
  for row in rows():
   parts=row.split(None,3)
   if len(parts)==4 and parts[1]==str(process.pid) and runner in parts[3] and parts[3].endswith(phase+' '+label+' --worker'):
    assert parts[0]==parts[2];worker=int(parts[0])
  try:process.wait(timeout=min(5,max(.01,limit-60-(time.monotonic()-started))))
  except subprocess.TimeoutExpired:pass
 if process.poll() is None:deadline_stop=True
except BaseException as failure:error=repr(failure)
finally:
 if process.poll() is None:
  process.send_signal(signal.SIGTERM)
  try:process.wait(timeout=max(.01,min(45,limit-10-(time.monotonic()-started))))
  except subprocess.TimeoutExpired:
   if worker:
    members=[r.split(None,3)for r in rows()if len(r.split(None,3))==4 and r.split(None,3)[2]==str(worker)]
    owned=any(p[0]==str(worker)and runner in p[3]and p[3].endswith(phase+' '+label+' --worker')for p in members)
    owned=owned or any(str(root)in p[3]for p in members)
    if members and owned:os.killpg(worker,signal.SIGKILL)
    elif members:error='Cannot prove surviving worker group ownership; no unrelated signal'
   process.kill();process.wait(timeout=3)
 if worker is None and (root/(label+'-receipt.json')).exists():worker=json.loads((root/(label+'-receipt.json')).read_text()).get('owned_process_group')
 elapsed=time.monotonic()-started
 report=dict(phase=phase,label=label,runner_pid=process.pid,worker_group=worker,runner_rc=process.returncode,deadline_stop=deadline_stop,error=error,outer_duration_seconds=elapsed,outer_bound_seconds=limit,closed_at=datetime.datetime.now(datetime.timezone.utc).isoformat())
 report['owned_worker_members_after']=[r.strip()for r in rows()if len(r.split(None,3))==4 and r.split(None,3)[2]==str(worker)]if worker else[]
 report['rc']=0 if process.returncode==0 and not deadline_stop and error is None and elapsed<limit and not report['owned_worker_members_after'] else 1
 receipt.write_text(json.dumps(report,indent=2)+'\n');print('OUTER CLOSURE '+json.dumps(report),flush=True)
sys.exit(report['rc'])
