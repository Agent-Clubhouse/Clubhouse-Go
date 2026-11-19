from pathlib import Path
import sys,runpy,json,subprocess,os,signal,time,hashlib
R=Path('/tmp/ux-582-proof');sys.argv=['run-ticket.py','A','f-r3-video-analysis'];api=runpy.run_path(str(R/'run-ticket.py'),run_name='analysis_only')
g=api['g'];P=g.PREFIX;report={'kind':'read-only exact-frame video decode','hard_seconds':300,'decoder_sha256':hashlib.sha256((R/'decode-video-ranges.swift').read_bytes()).hexdigest(),'jobs':[]}
report['guard']=api['admission_guard']()
if not report['guard']['accepted']:
 report['rc']=4;(R/'f-r3-video-analysis-receipt.json').write_text(json.dumps(report,indent=2));raise SystemExit(4)
started=time.monotonic();swapstart=g.swap_used(api['capture'](['/usr/sbin/sysctl','vm.swapusage']));maximum=swapstart
jobs=[('f-r3',['initial:23.0:24.7','tab:31.8:33.4','destination:40.2:41.8','switch:53.8:55.4','prepend:96.3:99.3','tail:103.3:108.4'])]
import re
for label in ['fse-r2','fax-r2']:
 receipt=json.loads((R/(label+'-receipt.json')).read_text());assert receipt['rc']==0
 events=[]
 for p in (R/'tickets'/label/'diagnostics').rglob('StandardOutputAndStandardError*.txt'):
  for line in p.read_text(errors='replace').splitlines():
   x=re.search(r'READING_OPEN time=([\d.]+).*?phase=body .*?follow=0 .*?first=message:reading-90\b',line)
   if x:events.append(float(x[1])-receipt['video_command_started_epoch_seconds'])
 assert events, label
 t=min(events);jobs.append((label,[f'initial:{t-0.65:.6f}:{t+1.2:.6f}']))
(R/'f-r3-video-analysis-config.json').write_text(json.dumps({'jobs':jobs,'method':'actual finite sample PTS, full uncropped PNGs; wallclock only brackets selection; no first-frame inference from AX'},indent=2)+'\n')
rc=0
for label,ranges in jobs:
 out=R/'tickets'/label/'exact-frames';cmd=P+['xcrun','swift',str(R/'decode-video-ranges.swift'),str(R/'tickets'/label/'first-paint-recording.mp4'),str(out),*ranges]
 with (R/(label+'-decode.log')).open('w') as log:
  p=subprocess.Popen(cmd,stdout=log,stderr=subprocess.STDOUT,start_new_session=True)
  while True:
   try:status=p.wait(timeout=2);break
   except subprocess.TimeoutExpired:
    maximum=max(maximum,g.swap_used(api['capture'](['/usr/sbin/sysctl','vm.swapusage'])))
    if time.monotonic()-started>300:
     try:os.killpg(p.pid,signal.SIGKILL)
     except ProcessLookupError:pass
     p.wait();status=124;break
  rows=subprocess.check_output(['/bin/ps','-axo','pid=,ppid=,pgid=,comm='],text=True).splitlines();owned=[x.strip() for x in rows if len(x.split())>=4 and x.split()[2]==str(p.pid)]
  report['jobs'].append({'label':label,'command':cmd,'rc':status,'owned_process_group':p.pid,'owned_processes_after':owned})
  if status or owned:rc=status or 1;break
maximum=max(maximum,g.swap_used(api['capture'](['/usr/sbin/sysctl','vm.swapusage'])))
report.update(rc=rc,duration_seconds=time.monotonic()-started,swap_watch={'record_only':True,'start_bytes':swapstart,'max_bytes':maximum,'growth_bytes':maximum-swapstart,'exceeded_256MiB':maximum-swapstart>256*1024**2})
(R/'f-r3-video-analysis-receipt.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report,indent=2));raise SystemExit(rc)
