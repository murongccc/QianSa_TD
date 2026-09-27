"""统计 512 点视觉版与上一版的同一 WAV，准备 RTL 预览帧。"""
import sys
sys.dont_write_bytecode = True
import argparse
import json
from pathlib import Path
import numpy as np
from generate_ring_visual_tables import mapping, ENDS

def lengths(values, visual):
    if not visual:
        levels=np.zeros((len(values),64),dtype=int)
        levels[:,::2]=values
        levels[:,1:63:2]=(values[:,:-1]+values[:,1:])//2
        levels[:,63]=values[:,31]
        result=(levels>>2)+(levels>>4)
    else:
        levels=np.zeros((len(values),80),dtype=int)
        for i in range(80):
            band,weight,virtual=mapping(i)
            a=0 if virtual else values[:,band]
            b=values[:,0] if virtual else values[:,min(31,band+1)]
            levels[:,i]=((4-weight)*a+weight*b)//4
        levels[:,76]=(levels[:,76]>>1)+(levels[:,76]>>2)
        levels[:,77]>>=1;levels[:,78]>>=2;levels[:,79]=0
        result=levels>>2
    return np.where(values.any(axis=1)[:,None],np.maximum(result,2),0)

def summary(values,visual):
    bars=lengths(values,visual)
    return {'frames':len(values),'bar_count':bars.shape[1],
            'mean_visible_bars':float((bars>0).sum(axis=1).mean()),
            'mean_seam_difference_px':float(np.abs(bars[:,0]-bars[:,-1]).mean()),
            'max_seam_difference_px':int(np.abs(bars[:,0]-bars[:,-1]).max()),
            'mean_adjacent_difference_px':float(np.abs(np.diff(bars,axis=1)).mean()),
            'mean_frame_change_px':float(np.abs(np.diff(bars,axis=0)).mean()),
            'max_length_px':int(bars.max())}

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('before',type=Path);p.add_argument('after',type=Path)
    p.add_argument('output',type=Path);p.add_argument('frames',type=Path)
    args=p.parse_args()
    old=np.loadtxt(args.before,delimiter=',',skiprows=1).astype(int)
    new=np.loadtxt(args.after,delimiter=',',skiprows=1).astype(int)
    assert np.array_equal(old[:,0],new[:,0]),'sample frames do not match'
    ordinary=100;peak=int(new[:,1:].sum(axis=1).argmax())
    frames=[]
    for label,index in [('ordinary',ordinary),('strong',peak)]:
        for name,data in [('before',old),('after',new)]:
            packed=sum(int(v)<<(8*i) for i,v in enumerate(data[index,1:]))
            frames.append({'label':label,'version':name,'sample':int(data[index,0]),
                           'seconds':float(data[index,0]/48000),'bands':f'{packed:064x}'})
    result={'input':'src/python/1.wav, 48000 Hz, 24-bit stereo left, raw source volume',
            'before':summary(old[:,1:],False),'after':summary(new[:,1:],True),
            'band_last_bins_512':ENDS,'preview_frames':frames,
            'note':'Bar length and seam are intentionally changed for appearance; frame-change numbers are not equal-scale spectrum fidelity measures.'}
    args.output.write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    args.frames.write_text(json.dumps(frames,indent=2)+'\n',encoding='utf-8')
    print(json.dumps({k:result[k] for k in ['before','after']},indent=2))

if __name__=='__main__':main()
