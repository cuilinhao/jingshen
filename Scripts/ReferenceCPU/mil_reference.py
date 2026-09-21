"""LIMITED CPU reference evaluator of the uploaded MLProgram, not Core ML.
Runs its real graph/weights in PyTorch for evidence. It is analysis tooling only.
Every tensor output shape and every blob extent is validated. FP16 boundaries
are emulated, but backend rounding/fusion and resizing differ from Apple SDK.
"""
from mil_inspect import *
import numpy as np
import torch
import torch.nn.functional as F
from PIL import Image
import time, math, sys

def packed_ints(b, signed_bits=64):
 vals=[];p=0
 while p<len(b):
  x,p=varint(b,p)
  x=x & ((1<<signed_bits)-1)
  if x&(1<<(signed_bits-1)):x-=1<<signed_bits
  vals.append(x)
 return vals

class Program:
 def __init__(self,package,round_half=True):
  self.ops,self.block=inspect(package); self.blob=(package/'Data/com.apple.CoreML/weights/weight.bin').read_bytes();self.round_half=round_half
  self.constants={o['outputs'][0][0]:self.value(o['attrs']['val']) for o in self.ops if o['op']=='const'}
  self.refs=Counter(n for o in self.ops for ns in o['inputs'].values() for n in ns if isinstance(n,str))
 def value(self,b):
  d=msg(b);t=typeinfo(one(d,2));dt=t['dtype'];shape=t['shape']
  if 5 in d:
   blob=msg(one(d,5));offset=one(blob,2,0)
   magic,ty,size,start=struct.unpack_from('<IIQQ',self.blob,offset)
   assert magic==0xdeadbeef and start+size<=len(self.blob)
   dtype={10:'<f2',11:'<f4',23:'<i4'}[dt];a=np.frombuffer(self.blob,dtype=dtype,count=math.prod(shape),offset=start).copy()
   assert a.nbytes==size
  else:
   ten=msg(one(msg(one(d,3)),1));k=next(iter(ten));r=msg(one(ten,k));v=one(r,1,b'')
   if k==4:
    vs=[x.decode() for x in r.get(1,[])];return vs[0] if not shape else vs
   if k==7:a=np.frombuffer(v,dtype={10:'<f2',11:'<f4',1:'?'}[dt]).copy()
   elif k==1:a=np.frombuffer(v,dtype='<f4').copy()
   elif k in (2,5):a=np.array(packed_ints(v,32 if k==2 else 64))
   elif k==3:a=np.array(packed_ints(v),dtype=bool)
   else:raise NotImplementedError(('tensor kind',k))
  a=a.reshape(shape)
  if dt in (10,11,12):return torch.from_numpy(a.astype(np.float32))
  return a.item() if not shape else a.tolist()
 @torch.inference_mode()
 def run(self,arr):
  env=dict(self.constants);env['image']=torch.from_numpy(arr.copy()).permute(2,0,1).unsqueeze(0).float();refs=self.refs.copy();start=time.time()
  for idx,o in enumerate(self.ops):
   typ=o['op']
   if typ=='const':continue
   a={k:([env[n] for n in ns] if k=='values' else env[ns[0]]) for k,ns in o['inputs'].items()}
   x=a.get('x')
   def scalar(v):return v.item() if isinstance(v,torch.Tensor) else v
   try:
    if typ=='cast':y=x.half().float() if a['dtype']=='fp16' else x.float()
    elif typ=='sub':y=x-a['y']
    elif typ=='add':y=x+a['y']
    elif typ=='mul':y=x*a['y']
    elif typ=='real_div':y=x/a['y']
    elif typ=='reshape':y=x.reshape(a['shape'])
    elif typ=='transpose':y=x.permute(a['perm'])
    elif typ=='concat':
     assert not a.get('interleave',False);y=torch.cat(a['values'],int(a['axis']))
    elif typ=='expand_dims':
     y=x
     for ax in sorted((v if v>=0 else v+x.ndim+len(a['axes'])) for v in a['axes']):y=y.unsqueeze(ax)
    elif typ=='squeeze':
     y=x
     for ax in sorted((v%x.ndim for v in a.get('axes',range(x.ndim)) if x.shape[v]==1),reverse=True):y=y.squeeze(ax)
    elif typ=='slice_by_index':
     slices=[];endmask=a.get('end_mask',[False]*x.ndim);beginmask=a.get('begin_mask',[False]*x.ndim);squeezemask=a.get('squeeze_mask',[False]*x.ndim)
     for j,(b,e,s) in enumerate(zip(a['begin'],a['end'],a.get('stride',[1]*x.ndim))):
      slices.append(int(b) if squeezemask[j] else slice(None if beginmask[j] else b,None if endmask[j] else e,s))
     y=x[tuple(slices)]
    elif typ=='einsum':y=torch.einsum(a['equation'],*a['values'])
    elif typ=='softmax':y=x.softmax(int(a['axis']))
    elif typ=='gelu':y=F.gelu(x,approximate='none' if a['mode']=='EXACT' else 'tanh')
    elif typ=='relu':y=F.relu(x)
    elif typ=='reduce_max':
     axes=tuple(a.get('axes',range(x.ndim)));y=torch.amax(x,dim=axes,keepdim=a.get('keep_dims',False))
    elif typ=='layer_norm':
     axes=tuple(a['axes']);mean=x.mean(axes,keepdim=True);var=((x-mean)**2).mean(axes,keepdim=True)
     y=(x-mean)*torch.rsqrt(var+scalar(a['epsilon']))
     gamma=a.get('gamma',1);beta=a.get('beta',0)
     if isinstance(gamma,torch.Tensor) and gamma.ndim!=x.ndim:
      shp=[1]*x.ndim
      for ax,n in zip(axes,gamma.shape):shp[ax]=n
      gamma=gamma.reshape(shp);beta=beta.reshape(shp)
     y=y*gamma+beta
    elif typ=='upsample_bilinear':
     scales=(float(scalar(a['scale_factor_height'])),float(scalar(a['scale_factor_width'])))
     y=F.interpolate(x,scale_factor=scales,mode='bilinear',align_corners=a.get('align_corners',True),recompute_scale_factor=False)
    elif typ in ('conv','conv_transpose'):
     pad=a.get('pad',[0,0,0,0]);assert a.get('pad_type','custom') in ['custom','valid']
     stride=a.get('strides',[1,1]);dilation=a.get('dilations',[1,1]);groups=int(a.get('groups',1))
     if typ=='conv':
      inp=F.pad(x,(pad[2],pad[3],pad[0],pad[1])) if any(pad) else x
      y=F.conv2d(inp,a['weight'],a.get('bias'),stride=stride,dilation=dilation,groups=groups)
     else:
      y=F.conv_transpose2d(x,a['weight'],a.get('bias'),stride=stride,dilation=dilation,groups=groups)
      y=y[:,:,pad[0]:y.shape[2]-pad[1],pad[2]:y.shape[3]-pad[3]]
    else:raise NotImplementedError(typ)
    name,ti=o['outputs'][0]; assert len(o['outputs'])==1
    assert list(y.shape)==ti['shape'],(idx,typ,list(y.shape),ti)
    if self.round_half and ti['dtype']==10:y=y.half().float()
    if not torch.isfinite(y).all():raise ValueError(f'non-finite output {name}')
    env[name]=y
   except Exception:
    print('FAILED',idx,typ,o['outputs'], {k:(tuple(v.shape) if isinstance(v,torch.Tensor) else v) for k,v in a.items()},flush=True);raise
   for ns in o['inputs'].values():
    for n in ns:
     refs[n]-=1
     if refs[n]==0 and n not in self.constants:env.pop(n,None)
  out=env['depth'].squeeze().numpy(); print('Reference graph executed',len(self.ops),'ops; depth',out.shape,'range',float(out.min()),float(out.max()),'seconds',round(time.time()-start,3),flush=True);return out

if __name__=='__main__':
 torch.set_num_threads(4)
 package=Path(sys.argv[1]);image=Path(sys.argv[2]);outdir=Path(sys.argv[3]);outdir.mkdir(parents=True,exist_ok=True)
 model=Program(package)
 im=Image.open(image).convert('RGB')
 arr=np.array(im.resize((518,392),Image.Resampling.BILINEAR)).astype(np.float32)
 raw=model.run(arr);np.save(outdir/'reference-stretch-raw.npy',raw)
 Image.fromarray((raw*255).clip(0,255).astype('uint8')).resize(im.size,Image.Resampling.BILINEAR).save(outdir/'reference-stretch-depth.png')
 if len(sys.argv)>4:
  w,h=im.size;scale=min(518/w,392/h);ww,hh=round(w*scale),round(h*scale);xx,yy=(518-ww)//2,(392-hh)//2
  padded=Image.new('RGB',(518,392));padded.paste(im.resize((ww,hh),Image.Resampling.BILINEAR),(xx,yy))
  raw=model.run(np.array(padded).astype(np.float32))[yy:yy+hh,xx:xx+ww]
  np.save(outdir/'reference-fit-raw.npy',raw);Image.fromarray((raw*255).clip(0,255).astype('uint8')).resize(im.size,Image.Resampling.BILINEAR).save(outdir/'reference-fit-depth.png')
