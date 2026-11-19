from pathlib import Path
import runpy,sys,json,subprocess,time,os,signal
R=Path('/tmp/ux-582-proof');sys.argv=['run-ticket.py','A','f-r3-package'];a=runpy.run_path(str(R/'run-ticket.py'),run_name='analysis_only');g=a['g'];receipt={'kind':'immutable evidence packaging, no product/test/simulator action','hard_seconds':300,'guard':a['admission_guard']()}
if not receipt['guard']['accepted']:
 receipt['rc']=4;(R/'f-r3-package-receipt.json').write_text(json.dumps(receipt,indent=2));raise SystemExit(4)
start=time.monotonic();swap=g.swap_used(a['capture'](['/usr/sbin/sysctl','vm.swapusage']));maximum=swap
p=subprocess.Popen(g.PREFIX+['python3',str(R/'package-f-r3-evidence.py')],start_new_session=True)
while True:
 try:rc=p.wait(timeout=2);break
 except subprocess.TimeoutExpired:
  maximum=max(maximum,g.swap_used(a['capture'](['/usr/sbin/sysctl','vm.swapusage'])))
  if time.monotonic()-start>300:
   try:os.killpg(p.pid,signal.SIGKILL)
   except ProcessLookupError:pass
   p.wait();rc=124;break
owned=[l.strip() for l in subprocess.check_output(['/bin/ps','-axo','pid=,ppid=,pgid=,comm='],text=True).splitlines() if len(l.split())>=4 and l.split()[2]==str(p.pid)]
receipt.update(rc=rc,duration_seconds=time.monotonic()-start,owned_process_group=p.pid,owned_processes_after=owned,swap_watch={'record_only':True,'start_bytes':swap,'max_bytes':maximum,'growth_bytes':maximum-swap,'exceeded_256MiB':maximum-swap>256*1024**2});(R/'f-r3-package-receipt.json').write_text(json.dumps(receipt,indent=2)+'\n');print(json.dumps(receipt,indent=2));raise SystemExit(rc or bool(owned))
