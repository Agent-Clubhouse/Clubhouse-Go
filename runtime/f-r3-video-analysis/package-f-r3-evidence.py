from pathlib import Path
import shutil,json,hashlib,gzip,tarfile
R=Path('/tmp/ux-582-proof');E=Path('/tmp/ux-582-evidence/runtime');D=E/'f-r3-video-analysis';D.mkdir(exist_ok=True)
shutil.copytree(R/'f-r3-video-review',D,dirs_exist_ok=True)
for n in ['decode-video-ranges.swift','ocr-frames.swift','analyze-f-r3-videos.py','ocr-f-r3-videos.py','analyze-opening-log.py']:shutil.copy2(R/n,D/n)
def split(src,dest):
 dest.mkdir(parents=True,exist_ok=True);parts=[];h=hashlib.sha256()
 with src.open('rb') as i:
  while block:=i.read(40*1024**2):
   h.update(block);name=src.name+f'.part-{len(parts):03d}';(dest/name).write_bytes(block);parts.append({'file':name,'bytes':len(block),'sha256':hashlib.sha256(block).hexdigest()})
 (dest/(src.name+'.json')).write_text(json.dumps({'original':src.name,'bytes':src.stat().st_size,'sha256':h.hexdigest(),'parts':parts,'reassemble':f'cat {src.name}.part-* > {src.name}'},indent=2)+'\n')
for label in ['a-r9','f-r3','fse-r2','fax-r2','fl-r2']:
 d=E/label;d.mkdir(exist_ok=True);s=R/'tickets'/label
 for suffix in ['-receipt.json','-progress.json','-fifo.log']:
  p=R/(label+suffix)
  if p.exists():shutil.copy2(p,d/p.name)
 for p in s.iterdir():
  if p.is_file() and p.name!='first-paint-recording.mp4':shutil.copy2(p,d/p.name)
 if (s/'attachments').exists():shutil.copytree(s/'attachments',d/'attachments',dirs_exist_ok=True)
 for n,p in enumerate((s/'diagnostics').rglob('StandardOutputAndStandardError*.txt')):
  with p.open('rb') as i,gzip.open(d/f'app-stdout-{n:02d}.txt.gz','wb',compresslevel=1) as o:shutil.copyfileobj(i,o)
 video=s/'first-paint-recording.mp4'
 if video.exists():
  if video.stat().st_size>=40*1024**2:split(video,d/'video-parts')
  else:shutil.copy2(video,d/video.name)
 frames=s/'exact-frames'
 if frames.exists():
  archive=R/(label+'-exact-frames.tar.gz')
  with tarfile.open(archive,'w:gz',compresslevel=1) as tar:tar.add(frames,arcname='exact-frames')
  split(archive,d/'exact-frame-parts')
  shutil.copy2(frames/'exact-frames.json',d/'exact-frames.json')
print('Packaged complete immutable F-r3 evidence, raw byte video parts and full actual-PTS frame archives.')
