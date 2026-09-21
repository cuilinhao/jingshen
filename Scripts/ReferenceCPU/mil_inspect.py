"""Read only the public protobuf fields needed for the uploaded Core ML MLProgram.
Analysis tooling only; never bundled in or required by the Swift app.
Schema references: apple/coremltools mlmodel/format/{Model,MIL,FeatureTypes}.proto.
"""
from pathlib import Path
from collections import defaultdict, Counter
import struct, json

def varint(b, p=0):
 n=0;s=0
 while p<len(b):
  v=b[p];p+=1;n|=(v&127)<<s
  if v<128:return n,p
  s+=7
  if s>70:raise ValueError('oversized varint')
 raise ValueError('truncated varint')

def msg(b):
 d=defaultdict(list); p=0
 while p<len(b):
  key,p=varint(b,p); f,w=key>>3,key&7
  if w==0:v,p=varint(b,p)
  elif w==2:
   n,p=varint(b,p); v=b[p:p+n]; p+=n
   if len(v)!=n:raise ValueError('truncated length')
  elif w in (1,5):
   n=8 if w==1 else 4;v=b[p:p+n];p+=n
  else:raise ValueError(f'wire {w}')
  d[f].append(v)
 return dict(d)

def one(d,k,default=None):return d.get(k,[default])[0]
def text(d,k):return one(d,k,b'').decode()
def maps(d,k):
 return {text(msg(e),1):one(msg(e),2) for e in d.get(k,[])}
def typeinfo(b):
 t=msg(one(msg(b),1)); shape=[]
 for dim in t.get(3,[]):shape.append(one(msg(one(msg(dim),1)),1,0))
 return {'dtype':one(t,1), 'shape':shape}
def named(b):
 d=msg(b);return text(d,1),typeinfo(one(d,2))
def inspect(package):
 m=msg((package/'Data/com.apple.CoreML/model.mlmodel').read_bytes());desc=msg(one(m,2))
 print('specVersion:',one(m,1))
 for key in [1,10]:
  for fd in desc.get(key,[]):
   f=msg(fd);print('input' if key==1 else 'output',text(f,1),'featuretype',msg(one(f,3)))
 meta=msg(one(desc,100)); print('metadata:',{k:[str(v)[:200] for v in vs] for k,vs in meta.items()})
 prog=msg(one(m,502));func=msg(maps(prog,2)['main']);print('function inputs:',[named(b) for b in func.get(1,[])], 'opset',text(func,2))
 block=msg(maps(func,3)[text(func,2)])
 ops=[]
 for b in block[3]:
  d=msg(b); typ=text(d,1)
  inp={}
  for k,v in maps(d,2).items():
   inp[k]=[text(msg(x),1) if 1 in msg(x) else {'value':one(msg(x),2).hex()} for x in msg(v).get(1,[])]
  ops.append({'op':typ, 'inputs':inp, 'outputs':[named(x) for x in d.get(3,[])], 'attrs':maps(d,5)})
 print('counts:',Counter(o['op'] for o in ops));print('block outputs',[v.decode() for v in block.get(2,[])])
 return ops,block

if __name__=='__main__':
 import sys
 p=Path(sys.argv[1]);ops,_=inspect(p)
 out=Path(sys.argv[2]) if len(sys.argv)>2 else Path('model-operations.json')
 out.write_text(json.dumps(ops,default=lambda x:x.hex(),indent=2))
 print('non-constant operations (first 30):')
 for o in [o for o in ops if o['op']!='const'][:30]:print({k:v for k,v in o.items() if k!='attrs'})
 for o in ops[:8]:print('head raw',o)
