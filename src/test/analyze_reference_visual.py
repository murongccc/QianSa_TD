"""对照旧 32 段插值与直接 FFT 的同一音乐帧，输出统计和 RTL 预览输入。"""
import sys
sys.dont_write_bytecode=True
import argparse
import json
from pathlib import Path
import numpy as np
from analyze_ring_visual import lengths


def summary(bars,levels=None):
    result={"frames":len(bars),"mean_frame_change_px":float(np.abs(np.diff(bars,axis=0)).mean()),
            "mean_adjacent_difference_px":float(np.abs(np.diff(bars,axis=1)).mean()),
            "mean_seam_difference_px":float(np.abs(bars[:,0]-bars[:,-1]).mean()),
            "maximum_bar_length_px":int(bars.max())}
    if levels is not None:
        result["clipped_bar_ratio"]=float((levels==240).mean())
    return result


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument("before",type=Path);p.add_argument("after",type=Path);p.add_argument("output",type=Path)
    p.add_argument("--before-direct",action="store_true",help="前版也是 80 柱 FFT 直取")
    p.add_argument("--fft-points",type=int,choices=[512,1024,2048],default=512)
    p.add_argument("--minimum-length",type=int,choices=[2,4,8],default=2)
    args=p.parse_args()
    before=np.loadtxt(args.before,delimiter=",",skiprows=1).astype(int)
    after=np.loadtxt(args.after,delimiter=",",skiprows=1).astype(int)
    assert np.array_equal(before[:,0],after[:,0])
    levels=after[:,1:81]
    assert levels.shape[1]==80
    bars=np.where(levels.any(axis=1)[:,None],np.maximum(levels>>2,args.minimum_length),0)
    frames=[]
    for index in [100,413]:
        before_key="before_bars" if args.before_direct else "before_bands"
        frames.append({"sample":int(after[index,0]),"seconds":float(after[index,0]/48000),
            before_key:f"{sum(int(v)<<(8*i) for i,v in enumerate(before[index,1:81] if args.before_direct else before[index,1:])):0{160 if args.before_direct else 64}x}",
            "after_bars":f"{sum(int(v)<<(8*i) for i,v in enumerate(levels[index])):0160x}"})
    if args.before_direct:
        assert before.shape[1]>=81
        old_levels=before[:,1:81]
        old_bars=np.where(old_levels.any(axis=1)[:,None],np.maximum(old_levels>>2,args.minimum_length),0)
    else:
        old_bars=lengths(before[:,1:],True)
    result={"input":"src/python/1.wav, 48 kHz 24-bit stereo, left channel raw volume",
            "fft_points":args.fft_points,"sample_rate":48000,"frequency_spacing_hz":48000/args.fft_points,
            "highest_bar_target_hz":float((320**(79/80)-1)*44100/2048),
            "before":summary(old_bars),"after":summary(bars,levels),
            "preview_frames":frames,
            "note":"Same source samples. No board-level audio/volume simulation."}
    result["minimum_bar_length_px"]=args.minimum_length
    if after.shape[1]>=82:
        radius=after[:,81]
        result["breathing"]={"radius_min":int(radius.min()),"radius_max":int(radius.max()),
            "radius_changes":int(np.count_nonzero(np.diff(radius))),
            "mean_absolute_radius_change_px":float(np.abs(np.diff(radius)).mean())}
        for entry,index in zip(frames,[100,413]):
            entry["after_radius"]=int(radius[index])
    if args.before_direct:
        pairs=[(16,20),(20,23),(16,23)]
        result["low_frequency_column_correlation"]={
            "before":{f"{a}-{b}":float(np.corrcoef(old_levels[:,a],old_levels[:,b])[0,1]) for a,b in pairs},
            "after":{f"{a}-{b}":float(np.corrcoef(levels[:,a],levels[:,b])[0,1]) for a,b in pairs}}
    args.output.write_text(json.dumps(result,ensure_ascii=False,indent=2)+"\n",encoding="utf-8")
    print(json.dumps({k:result[k] for k in ["before","after"]},indent=2))


if __name__=="__main__":main()
