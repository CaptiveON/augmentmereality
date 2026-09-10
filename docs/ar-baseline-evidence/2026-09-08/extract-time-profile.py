#!/usr/bin/env python3
"""Summarize xctrace Time Profiler export; all times are nanoseconds from trace start.
Weights estimate sampled on-CPU work. They are not scheduler CPU accounting,
power, GPU work, elapsed duration of an individual operation, or presentation.
"""
import sys,json,collections,xml.etree.ElementTree as ET
from pathlib import Path
source=Path(sys.argv[1]); duration=float(sys.argv[2])
root=ET.parse(source).getroot()
ids={e.attrib['id']:e for e in root.iter() if 'id' in e.attrib}
def resolve(e):
 while 'ref' in e.attrib: e=ids[e.attrib['ref']]
 return e
def value(e): return resolve(e).text
def label(e):
 e=resolve(e); return e.attrib.get('fmt',e.text or '')
def frames(e):
 e=resolve(e)
 if e.tag=='frame':
  binary=resolve(e[0]).attrib.get('name','unknown') if len(e) else 'unknown'
  return [(binary,e.attrib.get('name','unknown'))]
 return [f for child in e for f in frames(child)]
count=0; total=0; first=None; last=None
threads=collections.Counter(); leaves=collections.Counter(); inclusive=collections.Counter()
windows=collections.defaultdict(lambda:dict(count=0,weightedCPUSeconds=0))
for row in root.iter('row'):
 cells=list(row)
 if len(cells)!=7: raise ValueError('Unexpected time-profile schema')
 ns=int(value(cells[0])); state=label(cells[4]); weight=int(value(cells[5]))
 if state!='Running': raise ValueError('Unexpected sample state '+state)
 second=ns/1e9; cpu=weight/1e9
 first=second if first is None else min(first,second); last=second if last is None else max(last,second)
 total+=cpu; count+=1
 threads[label(cells[1])]+=cpu
 stack=frames(cells[6])
 if stack: leaves[' / '.join(stack[0])]+=cpu
 for binary in set(b for b,f in stack): inclusive[binary]+=cpu
 for key in ['whole','0-10s' if second<10 else 'after10s',f'minute{int(second//60):02}']:
  windows[key]['count']+=1; windows[key]['weightedCPUSeconds']+=cpu
for key,entry in windows.items():
 if key=='whole': length=duration
 elif key=='0-10s': length=min(10,duration)
 elif key=='after10s': length=max(0,duration-10)
 else: length=min(60,max(0,duration-60*int(key[6:])))
 entry['windowSeconds']=length
 entry['sampledCPUPercentOneCore']=entry['weightedCPUSeconds']/length*100 if length else None
result={'source':str(source),'traceDurationSeconds':duration,'count':count,'firstSampleSeconds':first,'lastSampleSeconds':last,'weightedCPUSeconds':total,'sampledCPUPercentOneCore':total/duration*100,'definition':__doc__.strip(),'windows':windows,'threadsWeightedCPUSeconds':threads.most_common(20),'leafWeightedCPUSeconds':leaves.most_common(30),'inclusiveBinaryWeightedCPUSeconds':inclusive.most_common(20)}
Path(sys.argv[3]).write_text(json.dumps(result,indent=2)+'\n')
print(json.dumps({k:result[k] for k in ['count','firstSampleSeconds','lastSampleSeconds','weightedCPUSeconds','sampledCPUPercentOneCore','threadsWeightedCPUSeconds','inclusiveBinaryWeightedCPUSeconds']},indent=2))
