from pathlib import Path
import runpy,sys,json,subprocess,time,signal,os
R=Path('/tmp/ux-582-proof');sys.argv=['run-ticket.py','A','f-r3-ocr'];a=runpy.run_path(str(R/'run-ticket.py'),run_name='analysis_only');g=a['g'];guard=a['admission_guard']();report={'guard':guard,'kind':'read-only full-frame OCR, supporting only','hard_seconds':240,'jobs':[]}
if not guard['accepted']:
 report['rc']=4;(R/'f-r3-ocr-receipt.json').write_text(json.dumps(report,indent=2));raise SystemExit(4)
start=time.monotonic();swap=g.swap_used(a['capture'](['/usr/sbin/sysctl','vm.swapusage']));maximum=swap;rc=0
for label in ['f-r3','fse-r2','fax-r2']:
 root=R/'tickets'/label/'exact-frames';m=json.loads((root/'exact-frames.json').read_text());files=[str(root/x['file']) for x in m['selectedFrames']]
 out=R/(label+'-exact-ocr.json')
 with out.open('w') as stream,(R/(label+'-ocr.log')).open('w') as log:
  p=subprocess.Popen(g.PREFIX+['xcrun','swift',str(R/'ocr-frames.swift'),*files],stdout=stream,stderr=log,start_new_session=True)
  while True:
   try:status=p.wait(timeout=2);break
   except subprocess.TimeoutExpired:
    maximum=max(maximum,g.swap_used(a['capture'](['/usr/sbin/sysctl','vm.swapusage'])))
    if time.monotonic()-start>240:
     try:os.killpg(p.pid,signal.SIGKILL)
     except ProcessLookupError:pass
     p.wait();status=124;break
  owned=[x.strip() for x in subprocess.check_output(['/bin/ps','-axo','pid=,ppid=,pgid=,comm='],text=True).splitlines() if len(x.split())>=4 and x.split()[2]==str(p.pid)]
  report['jobs'].append({'label':label,'frames':len(files),'rc':status,'owned_process_group':p.pid,'owned_processes_after':owned})
  if status or owned:rc=status or 1;break
maximum=max(maximum,g.swap_used(a['capture'](['/usr/sbin/sysctl','vm.swapusage'])))
report.update(rc=rc,duration_seconds=time.monotonic()-start,swap_watch={'record_only':True,'start_bytes':swap,'max_bytes':maximum,'growth_bytes':maximum-swap,'exceeded_256MiB':maximum-swap>256*1024**2});(R/'f-r3-ocr-receipt.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report,indent=2));raise SystemExit(rc)
