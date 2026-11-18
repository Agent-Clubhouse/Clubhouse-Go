#!/usr/bin/env python3
"""Extract opt-in Reading values/stdout, preserving bare-print time brackets."""
import datetime, hashlib, json, re, sys
from pathlib import Path
folder=Path(sys.argv[1])
case='CompanionReadingUITests/testHistoryPrependStreamingKeyboardAndReturnKeepTheReadingEntry()'
details=json.loads(Path(str(folder/'tests.xcresult')+'.single-run-details.json').read_text())[case]
start=details['startTime'];end=start+details['durationInSeconds']
stamp=re.compile(r'^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d+[+-]\d{4})')
records=[];sources=[]
for path in sorted((folder/'diagnostics').rglob('StandardOutputAndStandardError*.txt')):
    sources.append(str(path));previous=None;pending=[]
    def finish(next_stamp):
        for entry in pending:
            entry['next_timestamp']=next_stamp
            a=entry.get('previous_timestamp');b=next_stamp
            epochs=[datetime.datetime.strptime(x,'%Y-%m-%d %H:%M:%S.%f%z').timestamp() for x in [a,b] if x]
            entry['overlaps_target_interval']=bool(epochs and min(epochs)<=end and max(epochs)>=start)
        pending.clear()
    with path.open(errors='replace') as stream:
        for number,line in enumerate(stream,1):
            line=line.rstrip('\n');match=stamp.match(line)
            if match:finish(match[1]);previous=match[1]
            if not any(marker in line for marker in ['READING_RESTORE','READING569','CHAT_FOLLOW','CHAT_SCROLL_PHASE']):continue
            record={'file':str(path),'line':number,'text':line,'previous_timestamp':previous}
            if match:
                record['timestamp']=match[1]
                epoch=datetime.datetime.strptime(match[1],'%Y-%m-%d %H:%M:%S.%f%z').timestamp()
                record['overlaps_target_interval']=start<=epoch<=end
            else:pending.append(record)
            records.append(record)
    finish(None)
selected=[x for x in records if x['overlaps_target_interval']]
(folder/'app-reading-trace-records.json').write_text(json.dumps({'case':case,'start_epoch':start,'end_epoch':end,'sources':sources,'all_trace_count':len(records),'target_records':selected},indent=2)+'\n')
(folder/'app-reading-trace.txt').write_text('\n'.join(x['text'] if 'timestamp' in x else '[between '+str(x['previous_timestamp'])+' and '+str(x['next_timestamp'])+'] '+x['text'] for x in selected)+'\n')
(folder/'app-reading-restore-stdout.txt').write_text('\n'.join(x['text'] if 'timestamp' in x else '[between '+str(x['previous_timestamp'])+' and '+str(x['next_timestamp'])+'] '+x['text'] for x in selected if 'READING_RESTORE' in x['text'])+'\n')
print(json.dumps({'case':case,'target_trace_count':len(selected),'restore_count':sum('READING_RESTORE' in x['text'] for x in selected),'start_epoch':start,'end_epoch':end,'extracted_sha256':hashlib.sha256((folder/'app-reading-trace.txt').read_bytes()).hexdigest()},indent=2))
