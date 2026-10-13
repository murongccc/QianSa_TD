from pathlib import Path
import hashlib,json,itertools,random
ROOT=Path(__file__).resolve().parents[2]
OUT=ROOT/'prj/log/three_touch_20261013';OUT.mkdir(parents=True,exist_ok=True)
DATA=ROOT/'src/test/data';manifest=[]
class Reference:
 def __init__(self):
  self.slots=[[0,False,0,0] for _ in range(3)];self.previous=set();self.bind={};self.down=0
 def frame(self,frame,valid=True):
  old=self.down;p=r=0
  if valid:
   b=frame[4:];records={b[2+5*i]>>4:(bool(b[2+5*i]&1),int.from_bytes(bytes(b[3+5*i:5+5*i]),'little'),int.from_bytes(bytes(b[5+5*i:7+5*i]),'little')) for i in range(b[54])}
   held={i for i,v in records.items() if v[0]}
   for s in self.slots:
    if s[0] in records:s[2:]=records[s[0]][1:]
    s[1]=s[1] and s[0] in held
   for identity in sorted(held-self.previous):
    vacant=next((s for s in self.slots if not s[1]),None)
    if vacant is not None:vacant[:]=[identity,True,*records[identity][1:]]
   new_bind={}
   for identity,live,x,y in self.slots:
    if live:
     if identity in self.bind:new_bind[identity]=self.bind[identity]
     else:
      edges=[486,2494,4503,6512,8521]
      new_bind[identity]=0 if x<edges[0] or x>=edges[-1] or y<5096 else 1<<sum(x>=e for e in edges[1:4])
   self.bind=new_bind;self.down=0
   for v in self.bind.values():self.down|=v
   p=self.down & ~old;r=old & ~self.down;self.previous=held
  value=0
  for identity,live,x,y in self.slots:
   for n,width in [(identity,4),(int(live),1),(x,16),(y,16)]:value=(value<<width)|n
  for n,width in [(bool(self.previous),1),(p,4),(r,4),(self.down,4)]:value=(value<<width)|int(n)
  return value

def packet(records,seq=0):
 b=[0]*57;b[0]=64;b[1]=13;b[52:54]=[1,1];b[54]=len(records);b[55]=seq&255
 for k,(i,d,x,y) in enumerate(records):b[2+5*k:7+5*k]=[(i<<4)|d,x&255,x>>8,y&255,y>>8]
 b[56]=sum(b[1:56])&255
 return [87,171,136,57]+b

def save(name,frames,source=None):
 model=Reference();raw=[];expected=[]
 for f,valid in frames:
  raw.extend(f);expected.append((int(valid)<<124)|model.frame(f,valid))
 (DATA/(name+'.hex')).write_text(''.join(' '.join(f'{v:02x}' for v in raw[i:i+61])+'\n' for i in range(0,len(raw),61)))
 (DATA/(name+'.expected')).write_text(''.join(f'{v:032x}\n' for v in expected))
 entry={'fixture':name,'frames':len(frames),'fixture_sha256':hashlib.sha256(bytes(raw)).hexdigest()}
 if source:entry.update(source)
 manifest.append(entry)

names=['touch_01_three_down_release','touch_02_third_move','touch_03_contact_replace','touch_04_four_limit']
analysis=json.loads((ROOT/'prj/log/three_touch_capture_20261013/analysis.json').read_text(encoding='utf-8'))
for name,prior in zip(names,analysis):
 path=Path('C:/Users/murong/Desktop')/(name+'.txt');source=path.read_bytes();assert hashlib.sha256(source).hexdigest()==prior['sha256']
 raw=bytes.fromhex(source.decode('utf-8-sig'));assert len(raw)%61==0
 save(name,[(list(raw[i:i+61]),True) for i in range(0,len(raw),61)],{'source':str(path),'source_sha256':prior['sha256']})
# 定向用例 + 固定种子随机快照；每帧独立参考模型验证身份、坐标、生命周期、轨道原子事件。
frames=[];seq=0
pts=lambda ids,xs=None,ys=None:[(i,1,(xs or [1500,3500,5500,7500])[k],(ys or [8000]*4)[k]) for k,i in enumerate(ids)]
def emit(records,kind=None):
 global seq
 f=packet(records,seq);seq+=1
 if kind=='checksum':f[-1]^=1
 elif kind=='reserved':f[6]|=2;f[-1]=sum(f[5:-1])&255
 elif kind=='missing':f[58]+=1;f[-1]=sum(f[5:-1])&255
 elif kind=='report':f[5]=14;f[-1]=sum(f[5:-1])&255
 frames.append((f,kind is None))
for xs in [[1500,3500,5500],[1500]*3,[1500,1500,5500]]:
 emit([]);emit(pts([1,2,3],xs));
 for ids in itertools.permutations([1,2,3]):emit(pts(list(ids),[7500]*3))
 emit([(1,0,1500,8000),(2,1,xs[1],8000),(3,1,xs[2],8000)])
 emit([(3,1,xs[2],8000)]);emit([])
# 第四指优先记录，原第一指第四条；释放原三指而第四指仍按住，不提升。
emit(pts([1,2,3]));emit(pts([4,3,2,1]));emit([(4,1,7500,8000),(3,1,5500,8000),(2,1,3500,8000),(1,0,1500,8000)])
emit(pts([4,3,2]));emit(pts([4]));emit([(4,0,7500,8000)]);emit(pts([4]));emit([])
# 区外接触占名额，滑入不参与；区内跨轨移出绑定不变。
emit(pts([1,2,3],[1500,3500,5500],[100,100,100]));emit(pts([4,3,2,1]));emit(pts([1,2,3]));emit([])
emit(pts([1,2,3]));emit(pts([1,2,3],[7500]*3,[100]*3));emit([])
# 同报告显式释放或消失 + 新身份；确定性分配优先小编号。
emit(pts([7,9,11]));emit([(7,0,1500,8000),(9,1,3500,8000),(11,1,5500,8000),(2,1,7500,8000)])
emit(pts([15,13,9,1]));emit([]);emit(pts([9,7,5,3]));emit([])
for kind in ['checksum','reserved','missing','report']:
 emit(pts([1,2,3]));emit(pts([1,2,3,4]),kind);emit(pts([1,2,3]));emit([])
# 在第四条中制造重复编号与保留位错误；不得冻结以外泄漏半帧。
f=packet(pts([1,2,3,1]),seq);frames.append((f,False));seq+=1
f=packet(pts([1,2,3,4]),seq);f[21]|=2;f[-1]=sum(f[5:-1])&255;frames.append((f,False));seq+=1
# 五至十指仅模拟，绝不当作实测证据。
for count in range(5,11):
 emit([]);emit([(i,1,1500+(i%4)*2000,8000) for i in reversed(range(1,count+1))]);emit([(i,1,7500,8000) for i in range(4,count+1)]);emit([])
rng=random.Random(93503)
for _ in range(600):
 ids=rng.sample(range(1,16),rng.randrange(0,11));rng.shuffle(ids)
 emit([(i,rng.randrange(2),rng.randrange(65536),rng.randrange(65536)) for i in ids])
emit([]);save('touch_three_synthetic',frames)
(DATA/'touch_three_manifest.json').write_text(json.dumps(manifest,ensure_ascii=False,indent=2),encoding='utf-8')
print('PASS fixture hashes and reference generation',sum(e['frames'] for e in manifest))
